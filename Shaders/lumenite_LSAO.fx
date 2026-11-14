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


        Filename   : lumenite_LSAO.fx
        Version    : 2026.11.01
        Author     : Afzaal (Kaidō)
        Description: Large-Scale Ray Traced Ambient Occlusion (Screen Space).
        License    : AGNYA License (https://github.com/nvb-uy/AGNYA-License)

        ========================================================================
*/

/*------------------.
| :: DEFINITIONS :: |
'------------------*/
#define FOV 60.0
#define NEAR_PLANE 0.01


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

uniform float RAY_LENGTH <
    ui_type = "drag";
    ui_min = 0.1; ui_max = 1.0;
    ui_label = "AO Radius";
    ui_tooltip = "The max ray trace distance before termination.";
    ui_category = "Ambient Occlusion";
> = 0.7;

uniform float FOG_BLOCK <
    ui_type = "drag";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "Fog Awareness";
    ui_tooltip = "How much to suppress the effect inside fog. 0 = off.\nRequires FOG_MASK set to 1 in Kernel.";
> = 1.0;


//scale march step with raylen: 100 at my old 7m ref
#define AO_MAX_MARCH_STEPS (max(1, int(ceil(RAY_LENGTH * 100.0 / 0.7))))

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

namespace LumeniteLSAO {

/*---------------------.
| :: RENDER TARGETS :: |
'---------------------*/

texture tAO1 { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RG16F; };
sampler sAO1 { Texture = tAO1; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

texture tAO2 { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RG16F; };
sampler sAO2 { Texture = tAO2; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

texture tAO3 { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RG16F; };
sampler sAO3 { Texture = tAO3; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

texture tPrevAO { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RG16F; };
sampler sPrevAO { Texture = tPrevAO; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; MipFilter = LINEAR; };

//nearest depth over each 32x32 px blk
texture tHiZ8    { Width = BUFFER_WIDTH/8;  Height = BUFFER_HEIGHT/8;  Format = R16F; };
texture tHiZMip5 { Width = BUFFER_WIDTH/32; Height = BUFFER_HEIGHT/32; Format = R16F; };
sampler sHiZ8    { Texture = tHiZ8;    MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; AddressU = CLAMP; AddressV = CLAMP; };
sampler sHiZMip5 { Texture = tHiZMip5; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; AddressU = CLAMP; AddressV = CLAMP; };

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

float2 ATrousFilter(sampler SourceSampler, float2 uv, uint dilation, bool adaptiveDilation, float geoLod)
{
    float4 gbuffer = tex2D(Kernel::sNormals, uv);
    float2 result = float2(1.0, 0.0);
    [branch] if (!(gbuffer.a == 0 || gbuffer.a >= DEPTH_BOUNDARY))
    {
        [branch] if (adaptiveDilation) {
            float confidence = tex2Dlod(Kernel::sConfidence, float4(uv, 0, 0)).r;
            dilation += uint(round((1.0 - confidence) * 2.0)); //scale filter kernel w. motion by up to a factor of 2
        }

        float2 centerData = tex2Dlod(SourceSampler, float4(uv, 0, 0)).rg;
        float variance = max(0.0, centerData.g - (centerData.r * centerData.r)); //Moment - AO^2
        variance = max(variance, 0.0001);
        float2 sum = centerData;
        float totalWeight = 1.0;
        //the eight neighbors in the order the 3x3 loop visited them (the center left out)
        static const float2 TAPS[8] = { float2(-1, -1), float2(0, -1), float2(1, -1), float2(-1, 0),
                                        float2( 1,  0), float2(-1, 1), float2(0,  1), float2(1,  1) };
        [unroll] for (int i = 0; i < 8; i++) {
            float2 sampleUV    = uv + TAPS[i] * dilation * (BUFFER_PIXEL_SIZE * 2.0); //don't forget the x2.0 to properly step half-res grid!
            float2 sampleData  = tex2Dlod(SourceSampler, float4(sampleUV, 0, 0)).rg;
            float4 sampleGeo   = tex2Dlod(Kernel::sNormals, float4(sampleUV, 0, geoLod));
            float depthWeight   = exp(-abs(gbuffer.a - sampleGeo.a) / (gbuffer.a * 0.02 + 0.001));
            float normalWeight = pow(saturate(dot(gbuffer.rgb, sampleGeo.rgb)), 50.0);
            float aoDiff       = centerData.r - sampleData.r;
            float aoWeight     = exp(-(aoDiff * aoDiff) / (variance + 0.0001));
            float weight       = depthWeight * normalWeight * aoWeight;
            sum += sampleData * weight;
            totalWeight += weight;
        }
        result = sum / (totalWeight + EPSILON);
    }
    return result;
}

//1st hit's occlusion along one cos-weighted ray
float TraceRay(VSOUT input)
{
    float4 gbuffer = tex2D(Kernel::sNormals, input.uv);
    float3 normal = gbuffer.rgb;
    float depth = gbuffer.a;
    float occlusion = 0.0;
    [branch] if (!(depth == 0 || depth >= DEPTH_BOUNDARY))
    {
        float3 startPos = UVToViewSpace(input.uv, depth, input);
        float3 tangent, bitangent;
        BuildOrthonormalBasis(normal, tangent, bitangent);
        float2 noise = GetStratifiedNoise(input.vpos.xy);
        float3 rayDir = GenerateHemisphereDirection(normal, noise, tangent, bitangent);
        float totalRayLength = RAY_LENGTH * depth;
        float baseStepSize = totalRayLength / (float)AO_MAX_MARCH_STEPS;
        float stepSize = baseStepSize;
        startPos += normal * depth * 0.0005; //push ray slightly OUTWARD along the normal; clears staircase artifacts
        float3 currentPos = startPos + rayDir * stepSize;
        float t = stepSize;
        [loop]
        for (int step = 0; step < AO_MAX_MARCH_STEPS; step++) {
            if (t >= totalRayLength) break;

            float2 hitPos = ViewSpaceToUV(currentPos, input);
            if (IsOOB(hitPos)) break;

            float HiZDepth = tex2Dlod(sHiZMip5, float4(hitPos,0,0)).r;
            //skip some empty space
            float currentStepSize = stepSize * 2.5;
            if (currentPos.z < HiZDepth && (HiZDepth - currentPos.z) > currentStepSize) {
                float leap = max(currentStepSize, (HiZDepth - currentPos.z) * 0.065);
                currentPos += rayDir * leap;
                t += leap;
                continue;
            }

            //hit test
            float sceneDepth = tex2Dlod(Kernel::sDepth, float4(hitPos, 0, 0)).r;
            float depthDiff = currentPos.z - sceneDepth;
            float maxThickness = currentPos.z * 0.6;
            if (depthDiff > (currentPos.z * 0.0001) && depthDiff < maxThickness) {
                float3 scenePos = UVToViewSpace(hitPos, sceneDepth, input);
                float hitDistance = length(scenePos - startPos);
                float normalizedDist = hitDistance / totalRayLength;
                occlusion = 1.0 - saturate(depthDiff / maxThickness);
                occlusion = occlusion * occlusion;
                occlusion = saturate(pow(saturate(1.0 - normalizedDist), 1.2) * occlusion * 1.4);
                break;
            }

            currentPos += rayDir * stepSize;
            t += stepSize;
        }
    }
    return 1.0 - saturate(occlusion * AO_INTENSITY);
}

/*--------------.
| :: SHADERS :: |
'--------------*/
//nearest depth over 8x8 px
float PS_HiZ8(VSOUT input) : SV_Target
{
    int2 first = int2(input.vpos.xy) * 8;
    float minDepth = 1.0;
    [unroll] for (int y = 0; y < 8; y++)
        [unroll] for (int x = 0; x < 8; x++)
            minDepth = min(minDepth, tex2Dfetch(Kernel::sDepth, first + int2(x, y)).r);
    return minDepth;
}

//4x4 of those
float PS_HiZ32(VSOUT input) : SV_Target
{
    int2 first = int2(input.vpos.xy) * 4;
    float minDepth = 1.0;
    [unroll] for (int y = 0; y < 4; y++)
        [unroll] for (int x = 0; x < 4; x++)
            minDepth = min(minDepth, tex2Dfetch(sHiZ8, first + int2(x, y)).r);
    return minDepth;
}

float2 PS_RayTracer(VSOUT input) : SV_Target
{
    float depth = tex2D(Kernel::sDepth, input.uv).r;
    //overwrite noise at boundary with clean White, prevents gaps
    if (depth >= DEPTH_BOUNDARY) return float2(1.0, 1.0); //1.0 AO, 1.0 Moment
    if (depth == 0) discard;
    float ao = TraceRay(input);
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

void PS_ATrousPass1(VSOUT input, out float2 filtered : SV_Target0, out float2 history : SV_Target1)
{
    filtered = ATrousFilter(sAO1, input.uv, 2, false, 1.0);
    float2 data = tex2D(sAO1, input.uv).rg;
    history = float2(max(1.0 - data.r, 0.0001), max(1.0 - data.g, 0.0001));
}

float2 PS_ATrousPass2(VSOUT input) : SV_Target
{
    float ao = ATrousFilter(sAO2, input.uv, 4, true, 1.0).r;
    return float2(ao, tex2Dlod(Kernel::sNormals, float4(input.uv, 0, 1)).a);
}

float4 PS_ToDisplay(VSOUT input) : SV_Target
{
    int2   pixel    = int2(input.vpos.xy);
    float4 geometry = tex2Dfetch(Kernel::sNormals, pixel);
    float  depth    = geometry.a;
    float  ao       = 1.0;
    [branch] if (!(depth == 0 || depth >= DEPTH_BOUNDARY))
    {
        float3 pointPos   = UVToViewSpace(input.uv, depth, input);
        float  planeScale = 1.0 / (depth * 0.004);
        float  depthScale = 1.0 / (depth * 0.02 + 0.0001);
        float2 halfPos = (float2(pixel) + 0.5) * 0.5 - 0.5;
        int2   base    = int2(floor(halfPos));
        float2 f       = halfPos - float2(base);
        float  aoSum = 0.0, weightSum = 0.0, nearest = 1.0, nearestDiff = 1e6;
        [unroll] for (int y = 0; y <= 1; y++)
        {
            [unroll] for (int x = 0; x <= 1; x++)
            {
                int2   at       = clamp(base + int2(x, y), 0, int2(BUFFER_WIDTH / 2, BUFFER_HEIGHT / 2) - 1);
                float2 tap      = tex2Dfetch(sAO3, at).rg;
                float  diff     = abs(tap.g - depth);
                float  bilinear = (x == 0 ? 1.0 - f.x : f.x) * (y == 0 ? 1.0 - f.y : f.y);
                float3 texelPos = UVToViewSpace((float2(at) + 0.5) / float2(BUFFER_WIDTH / 2, BUFFER_HEIGHT / 2), tap.g, input);
                float  w        = bilinear * exp(-diff * depthScale - abs(dot(texelPos - pointPos, geometry.rgb)) * planeScale);
                aoSum += tap.r * w; weightSum += w;
                nearest     = diff < nearestDiff ? tap.r : nearest;
                nearestDiff = min(diff, nearestDiff);
            }
        }
        ao = weightSum > 0.001 ? aoSum / weightSum : nearest;
    }
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
technique Lumenite_LSAO <
    ui_label = "LUMENITE: LSAO";
    ui_tooltip = "Large-Scale Ray Traced Ambient Occlusion (Screen Space).";
>
{
    pass { VertexShader = VS; PixelShader = PS_HiZ8;        RenderTarget  = tHiZ8;    }
    pass { VertexShader = VS; PixelShader = PS_HiZ32;       RenderTarget  = tHiZMip5; }

    pass { VertexShader = VS; PixelShader = PS_RayTracer;   RenderTarget  = tAO1;     }
    pass { VertexShader = VS; PixelShader = PS_ATrousPass1; RenderTarget0 = tAO2; RenderTarget1 = tPrevAO; }
    pass { VertexShader = VS; PixelShader = PS_ATrousPass2; RenderTarget  = tAO3;     }
    pass { VertexShader = VS; PixelShader = PS_ToDisplay;                             }
}

}
