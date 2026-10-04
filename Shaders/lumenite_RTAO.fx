/*
        ========================================================================
        Copyright (c) Afzaal. All rights reserved.

    	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND
    	EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
    	MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
    	IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
    	CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
    	TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
    	SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

        ========================================================================

        GitHub     : https://github.com/umar-afzaal/LumeniteFX
        Discord    : https://discord.gg/deXJrW2dx6


        Filename   : lumenite_RTAO.fx
        Version    : 2026.05.30
        Author     : Afzaal (Kaidō)
        Description: Ray Traced Ambient Occlusion (Screen Space).
        License    : AGNYA License (https://github.com/nvb-uy/AGNYA-License)

        ========================================================================
*/

/*------------------.
| :: DEFINITIONS :: |
'------------------*/
#define FOV 60.0
#define NEAR_PLANE 0.01
#define INITIAL_STEP_SCALE 0.9
#define STEP_GROWTH_FACTOR 1.2
#define AO_MAX_MARCH_STEPS 15

/*--------------.
| :: HEADERS :: |
'--------------*/
#include "ReShade.fxh"
#include "./include/lumenite_Projections.fxh"
#include "./include/lumenite_Helpers.fxh"
#include "./include/lumenite_ColorManagement.fxh"

/*---------------.
| :: UNIFORMS :: |
'---------------*/
uniform bool DEBUG_VIEW <
    ui_label = "Show AO Mask";
    ui_tooltip = "Debug view for the AO. Shows raw AO.";
    ui_category = "Ambient Occlusion";
> = 0;

uniform float DEPTH_BOUNDARY <
    ui_type = "slider";
    ui_min = 0.001; ui_max = 0.999; ui_step = 0.001;
    ui_label = "AO Range";
    ui_tooltip = "The Z+ range/depth in which the effect is applied.";
    ui_category = "Ambient Occlusion";
    hidden = false;
> = 0.6;

uniform float DEPTH_FADE_START <
    ui_type = "slider";
    ui_min = 0.1; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Z+ Fade Start (%)";
    ui_tooltip = "Z+ fraction where effect starts fading out (relative to AO Range)";
    ui_category = "Ambient Occlusion";
    hidden = true;
> = 0.75;

uniform float AO_INTENSITY <
    ui_type = "drag";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "AO Strength";
    ui_tooltip = "Controls the intensity of the ambient occlusion effect.";
    ui_category = "Ambient Occlusion";
> = 1.0;

uniform float FOG_BLOCK <
    ui_type = "drag";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "Fog Awareness";
    ui_tooltip = "How much to suppress the effect inside fog. 0 = off.\nRequires FOG_MASK set to 1 in Kernel.";
> = 1.0;

//deprecated
// uniform int USER_GUIDE <
// ui_type = "radio";
//     ui_category = "";
//     ui_label = " ";
//     ui_text =  "RESOLUTION_SCALING:\n0: Renders AO at full-resolution.\n1: Renders AO at half-resolution.";
// >;

/*--------------.
| :: IMPORTS :: |
'--------------*/
namespace Kernel {
    texture2D tFlow { Width = BUFFER_WIDTH/8; Height = BUFFER_HEIGHT/8; Format = RG16F; };
    sampler2D sFlow { Texture = tFlow; MagFilter = POINT; MinFilter = POINT; };

    texture2D tConfidence { Width = BUFFER_WIDTH/8; Height = BUFFER_HEIGHT/8; Format = R16F; };
    sampler2D sConfidence { Texture = tConfidence; };

    texture tNormals { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; MipLevels = 4; };
    sampler sNormals { Texture = tNormals; };

    texture2D tDepth { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16F; MipLevels = 4; };
    sampler2D sDepth { Texture = tDepth; };

    texture2D tFogMask { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16F; };
    sampler2D sFogMask { Texture = tFogMask; };

    texture2D tFogState { Width = 2; Height = 1; Format = RGBA32F; };
    sampler2D sFogState { Texture = tFogState; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
}

namespace LumeniteRTAO {

/*---------------------.
| :: RENDER TARGETS :: |
'---------------------*/
texture tAOTrace   { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = R16F; };
sampler sAOTrace   { Texture = tAOTrace; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

texture tAO1       { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RG16F; };
sampler sAO1       { Texture = tAO1; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
sampler sAO1Linear { Texture = tAO1; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; MipFilter = LINEAR; };

texture tPrevAO    { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RG16F; };
sampler sPrevAO    { Texture = tPrevAO; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; MipFilter = LINEAR; };

/*--------------.
| :: HELPERS :: |
'--------------*/
void BuildOrthonormalBasis(float3 n, out float3 b1, out float3 b2)
{
    if (n.z < -0.9999999) {
        b1 = float3(0.0, -1.0, 0.0);
        b2 = float3(-1.0, 0.0, 0.0);
    } else {
        float a = rcp(1.0 + n.z);
        float b = -n.x * n.y * a;
        b1 = float3(mad(-n.x * n.x, a, 1.0), b, -n.x);
        b2 = float3(b, mad(-n.y * n.y, a, 1.0), -n.y);
    }
}

float3 GenerateHemisphereDirection(float3 normal, float2 rand, float3 tangent, float3 bitangent)
{
    float phi = rand.x * 6.28318530718; //2.0*PI as constant
    float sinPhi, cosPhi;
    sincos(phi, sinPhi, cosPhi);
    float cosTheta = sqrt(1.0 - rand.y);
    float sinTheta = sqrt(rand.y);
    float3 result = normal * cosTheta;
    result = mad(bitangent, sinTheta * sinPhi, result);
    result = mad(tangent, sinTheta * cosPhi, result);
    return result;
}

float CalculateDepthFade(float depth)
{
    float fadeStartDepth = DEPTH_BOUNDARY * DEPTH_FADE_START;
    float fadeRange = DEPTH_BOUNDARY - fadeStartDepth;
    return 1.0 - saturate((depth - fadeStartDepth) / fadeRange);
}

float GetFogBlock(float2 uv)
{
    float stamp = tex2Dlod(Kernel::sFogState, float4(0.75, 0.5, 0, 0)).x;
    bool fogActive = (stamp == float((FRAME_COUNT & 0xFFFFFu) + 1u)) || (stamp == float(((FRAME_COUNT - 1u) & 0xFFFFFu) + 1u));
    float3 airlight = tex2Dlod(Kernel::sFogState, float4(0.25, 0.5, 0, 0)).rgb;
    float  autoGain = clamp(GetLuminance(airlight) / max(GetLuminance(GetLinearColor(uv, false)), EPSILON), 0.0, 10.0);
    float  fogShare = tex2Dlod(Kernel::sFogMask, float4(uv, 0, 0)).r * autoGain;
    return fogActive ? saturate(fogShare * FOG_BLOCK) : 0.0;
}

float2 ATrousFilter(sampler SourceSampler, float2 uv, uint dilation)
{
    float4 gbuffer = tex2D(Kernel::sNormals, uv);
    if (gbuffer.a == 0 || gbuffer.a >= DEPTH_BOUNDARY) return float2(1.0, 0.0);
    float confidence = tex2Dlod(Kernel::sConfidence, float4(uv, 0, 0)).r;
    dilation += uint(round((1.0 - confidence))); //scale filter radius with motion
    float2 centerData = tex2Dlod(SourceSampler, float4(uv, 0, 0)).rg;
    float variance = max(0.0, centerData.g - (centerData.r * centerData.r)); //Moment - AO^2
    variance = max(variance, 0.0001);
    float2 sum = centerData;
    float totalWeight = 1.0;
    for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        if (x == 0 && y == 0) continue;
        float2 sampleUV    = uv + float2(x, y) * dilation * (BUFFER_PIXEL_SIZE * 2.0); //don't forget the x2.0 to properly step half-res grid!
        float2 sampleData  = tex2Dlod(SourceSampler, float4(sampleUV, 0, 0)).rg;
        float4 sampleGeo   = tex2Dlod(Kernel::sNormals, float4(sampleUV, 0, 0));
        float depthWeight   = exp(-abs(gbuffer.a - sampleGeo.a) / (gbuffer.a * 0.02 + 0.001));
        float normalWeight = pow(saturate(dot(gbuffer.rgb, sampleGeo.rgb)), 50.0);
        float aoDiff       = centerData.r - sampleData.r;
        float aoWeight     = exp(-(aoDiff * aoDiff) / (variance + 0.0001));
        float weight       = depthWeight * normalWeight * aoWeight;
        sum += sampleData * weight;
        totalWeight += weight;
    }
    return sum / (totalWeight + EPSILON);
}

/*--------------.
| :: SHADERS :: |
'--------------*/
float PS_TraceAO(VSOUT input) : SV_Target
{
    //deprecated
    // if (CHECKERBOARD_RENDERING) {
    //     #if RESOLUTION_SCALING
    //         if(CheckerboardSkip(uint2(input.vpos.xy), 2.0)) discard;
    //     #else
    //         if(CheckerboardSkip(uint2(input.vpos.xy), 1.0)) discard;
    //     #endif
    // }

    float4 gbuffer = tex2D(Kernel::sNormals, input.uv);
    float3 normal = gbuffer.rgb;
    float depth = gbuffer.a;
    if (depth == 0 || depth >= DEPTH_BOUNDARY) discard;
    float3 startPos = UVToViewSpace(input.uv, depth, input);
    float3 tangent, bitangent;
    BuildOrthonormalBasis(normal, tangent, bitangent);
    float2 noise = GetStratifiedNoise(input.vpos.xy);
    float3 rayDir = GenerateHemisphereDirection(normal, noise, tangent, bitangent);
    float invDepth = rcp(depth);
    float totalRayLength = 0.02 * depth;
    float initialStepScale = INITIAL_STEP_SCALE * rcp((float)AO_MAX_MARCH_STEPS);
    float stepSize = totalRayLength * initialStepScale;
    float3 rayPos = mad(rayDir, stepSize * 0.5, startPos);
    rayPos += normal * depth * 0.0005; //push ray slightly OUTWARD along the normal; clears staircase artifacts
    float occlusion = 0.0;
    [loop]
    for (int step = 0; step < AO_MAX_MARCH_STEPS; step++) {
        float2 sampleUV = ViewSpaceToUV(rayPos, input);
        float sceneDepth = GetDepth(sampleUV);
        float depthDiff = rayPos.z - sceneDepth;
        [branch]
        if (depthDiff > 0.0 && depthDiff < rayPos.z) {
            float3 scenePos = UVToViewSpace(sampleUV, sceneDepth, input);
            float hitDistance = length(scenePos - startPos);
            float normalizedDistance = hitDistance * invDepth;
            occlusion = exp(-normalizedDistance * 15.0);
            break;
        }
        stepSize *= STEP_GROWTH_FACTOR;
        rayPos = mad(rayDir, stepSize, rayPos);
    }

    float aoFactor = 1.0 - saturate(occlusion * AO_INTENSITY);
    return aoFactor;
}

float2 PS_TemporalFilter(VSOUT input) : SV_Target
{
    float depth = tex2D(Kernel::sDepth, input.uv).r;
    //overwrite noise at boundary with clean White, prevents gaps
    if (depth >= DEPTH_BOUNDARY) return float2(1.0, 1.0); //1.0 AO, 1.0 Moment
    if (depth == 0) discard;
    float ao = tex2D(sAOTrace, input.uv).r;
    ao = lerp(1.0, ao, CalculateDepthFade(depth));
    float moment = ao * ao;
    float2 flow = tex2D(Kernel::sFlow, input.uv).xy;
    float confidence = tex2D(Kernel::sConfidence, input.uv).x;
    confidence = saturate(confidence + log2(2.0 - confidence) * 0.6); //boost confidence
    float2 rawHistory = tex2D(sPrevAO, input.uv + flow).rg; //history stores "1.0 - AO". 0.0 (Black Texture) -> Reads as 1.0 (White)
    float prevAO = 1.0 - rawHistory.r;
    float prevMoment = 1.0 - rawHistory.g;
    float alpha = confidence * 0.98;
    ao = lerp(ao, prevAO, alpha);
    moment = lerp(moment, prevMoment, alpha);
    //max(..., 0.001) to ensure we NEVER write exactly 0.0 again
    //this tells the next frame "I contain data"
    return float2(max(ao, 0.001), max(moment, 0.001));
}

float2 PS_StoreAO(VSOUT input) : SV_Target
{
    //must prevent history collision here
    //if we store exactly 0.0 (means White), the next frame's blend pass thinks
    //history is empty and resets it, causing shimmer
    //so clamp to 0.0001 so the system knows "This is valid history data"
    float2 data = tex2D(sAO1, input.uv).rg;
    return float2(max(1.0 - data.r, 0.0001), max(1.0 - data.g, 0.0001)); //store inverted
}

float4 PS_ToDisplay(VSOUT input) : SV_Target
{
    float depth = tex2D(Kernel::sDepth, input.uv).r;
    float ao = ATrousFilter(sAO1Linear, input.uv, 2).r; //stable AO mask (fades to 1.0)
    if (DEBUG_VIEW) {
        #if BUFFER_COLOR_SPACE > 1
            return float4(ToOutputColorspace(ao.xxx, true), 1.0);
        #else
            return float4(ao.xxx, 1.0);
        #endif
    }
    if (depth == 0 || depth >= DEPTH_BOUNDARY) discard;
    float3 base = GetLinearColor(input.uv, true);
    ao = lerp(ao, 1.0, GetFogBlock(input.uv));
    base *= ao;
    return float4(ToOutputColorspace(base, true), 1.0);
}



/*----------------.
| :: TECHNIQUE :: |
'----------------*/
technique Lumenite_RTAO <
    ui_label = "LUMENITE: RTAO";
    ui_tooltip = "Ray Traced Ambient Occlusion (Screen Space).";
>
{
    pass { VertexShader = VS; PixelShader = PS_TraceAO;        RenderTarget = tAOTrace; }
    pass { VertexShader = VS; PixelShader = PS_TemporalFilter; RenderTarget = tAO1;     }
    pass { VertexShader = VS; PixelShader = PS_StoreAO;        RenderTarget = tPrevAO;  }
    pass { VertexShader = VS; PixelShader = PS_ToDisplay;                               }
}

}
