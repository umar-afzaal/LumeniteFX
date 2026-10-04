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

        Filename   : lumenite_SSSR.fx
        Version    : 2026.09.06
        Author     : Afzaal (Kaidō)
        Description: Stochastic Screen Space Reflections.
        License    : AGNYA License (https://github.com/nvb-uy/AGNYA-License)

        ========================================================================
*/

/*------------------.
| :: DEFINITIONS :: |
'------------------*/
#define FOV 70.0
#define NEAR_PLANE 0.5
#define RAY_LENGTH_SCALE 9.0
#define RAY_ORIGIN_BIAS -0.0004

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
uniform bool SMOOTH_SHADING <
    ui_label = "Smooth Shading";
    ui_tooltip = "Slightly smoothens the raw normals. Turn OFF if SMOOTH_NORMALS is enabled in Kernel.";
    hidden = true;
> = 0;

uniform float DEPTH_BOUNDARY <
    ui_type = "slider";
    ui_min = 0.001; ui_max = 0.999; ui_step = 0.001;
    ui_label = "SSSR Range";
    ui_tooltip = "The Z+ range/depth in which the effect is applied.";
    ui_category = "";
    hidden = false;
> = 0.85;

uniform float DEPTH_FADE_START <
    ui_type = "slider";
    ui_min = 0.1; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Z+ Fade Start (%)";
    ui_tooltip = "Z+ fraction where effect starts fading out (relative to Z+ boundary)";
    ui_category = "";
    hidden = true;
> = 0.75;

uniform int MAX_STEPS <
    ui_type = "drag";
    ui_min = 1; ui_max = 32; ui_step = 1;
    ui_label = "Ray Resolution";
    ui_category = "";
    ui_tooltip = "";
> = 32;

uniform int BINARY_SEARCH_STEPS <
    ui_type = "drag";
    ui_min = 1; ui_max = 8; ui_step = 1;
    ui_label = "Hit Refinement";
    ui_category = "";
    ui_tooltip = "";
> = 4;

uniform float F0 <
    ui_type = "drag";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.001;
    ui_label = "Base Reflectivity (F0)";
    ui_category = "";
    ui_tooltip = "";
> = 1.0;

uniform float ROUGHNESS <
    ui_type = "drag";
    ui_min = 0.0; ui_max = 0.3; ui_step = 0.001;
    ui_label = "Roughness";
    ui_category = "";
    ui_tooltip = "";
> = 0.1;

uniform float BUMP_SCALE <
    ui_type = "drag";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.001;
    ui_label = "Bump Detail";
    ui_tooltip = "Scale of the extracted bump details. Lower = finer bumps.";
> = 0.5;

uniform float TAIL_FEATHERING <
    ui_type = "drag";
    ui_min = 0.0; ui_max = 5.0; ui_step = 0.001;
    ui_label = "Tail Feathering";
    ui_category = "";
    ui_tooltip = "";
> = 0.0;

uniform float FOG_BLOCK <
    ui_type = "drag";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "Fog Awareness";
    ui_tooltip = "How much to suppress the effect inside fog. 0 = off.\nRequires FOG_MASK set to 1 in Kernel.";
> = 1.0;

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

namespace LumeniteSSSR {

/*---------------------.
| :: RENDER TARGETS :: |
'---------------------*/
texture tSpec1 { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler sSpec1 { Texture = tSpec1; AddressU = CLAMP; AddressV = CLAMP; };

texture tSpec2 { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler sSpec2 { Texture = tSpec2; AddressU = CLAMP; AddressV = CLAMP; };

texture tPrevSpec { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler sPrevSpec { Texture = tPrevSpec; AddressU = CLAMP; AddressV = CLAMP; };

/*--------------.
| :: HELPERS :: |
'--------------*/
float CalculateDepthFade(float depth)
{
    float fadeStartDepth = DEPTH_BOUNDARY * DEPTH_FADE_START;
    float fadeRange = DEPTH_BOUNDARY - fadeStartDepth;
    return 1.0 - saturate((depth - fadeStartDepth) / fadeRange);
}

float GetFogMask(float2 uv)
{
    float stamp = tex2Dlod(Kernel::sFogState, float4(0.75, 0.5, 0, 0)).x;
    bool fogActive = (stamp == float((FRAME_COUNT & 0xFFFFFu) + 1u)) || (stamp == float(((FRAME_COUNT - 1u) & 0xFFFFFu) + 1u));
    [branch] if (!fogActive || FOG_BLOCK == 0.0) return 0.0;
    return saturate(tex2Dlod(Kernel::sFogMask, float4(uv, 0, 0)).r * FOG_BLOCK);
}

float3 CalculateSmoothNormal(float2 uv, float4 gbuffer, int dilation, sampler SrcSampler)
{
    float3 normal = gbuffer.rgb;
    float depth = gbuffer.a;
    float3 normalSum = normal;
    float weightSum = 1.0;
    [unroll] for(int dy = -4; dy <= 4; dy++) for (int dx = -4; dx <= 4; dx++) {
        float2 sampleUV = uv + float2(dx, dy) * ReShade::PixelSize * dilation;
        float4 neighborData = tex2Dlod(SrcSampler, float4(sampleUV, 0, 0));
        float depthDiff = abs(neighborData.a - depth);
        float normalDot = max(dot(normal, neighborData.rgb), 0.0);
        float weight = exp(-depthDiff * 300.0) * pow(normalDot, 20.0);
        normalSum += neighborData.rgb * weight;
        weightSum += weight;
    }
    return normalize(normalSum / weightSum);
}

float3 GetBackBuffer(float2 uv)
{
    return tex2Dlod(ReShade::BackBuffer, float4(uv,0,0)).rgb;
}

float3 CalculateBumpyNormal(float2 uv, float3 geoNormal)
{
    float2 texelSize = BUFFER_PIXEL_SIZE * BUMP_SCALE;
    float3 lumaWeights = float3(0.299, 0.587, 0.114);
    //use gamma space intentionally
    float lumaCenter = dot(GetBackBuffer(uv), lumaWeights);
    float lumaRight  = dot(GetBackBuffer(uv + float2(texelSize.x, 0.0)), lumaWeights);
    float lumaBottom = dot(GetBackBuffer(uv + float2(0.0, texelSize.y)), lumaWeights);
    //luma gradients
    float dx = (lumaRight - lumaCenter) * 2.5;
    float dy = (lumaBottom - lumaCenter) * 2.5;
    //orthogonal tangent basis around macro geometry normal
    float3 up = abs(geoNormal.z) < 0.999 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 tangent = normalize(cross(up, geoNormal));
    float3 bitangent = cross(geoNormal, tangent);
    //2D bump gradient to 3D tangent-space normal
    float3 bumpVec = normalize(float3(-dx, -dy, 1.0));
    return normalize(tangent * bumpVec.x + bitangent * bumpVec.y + geoNormal * bumpVec.z);
}

/*--------------.
| :: SHADERS :: |
'--------------*/
float4 PS_TraceSpecular(VSOUT input) : SV_Target
{
    float4 gbuffer = tex2D(Kernel::sNormals, input.uv);
    float3 normal = gbuffer.rgb;
    float depth = gbuffer.a;
    if (depth <= 0.0 || depth > DEPTH_BOUNDARY) return float4(0, 0, 0, 1);

    //process normals
    if (SMOOTH_SHADING) normal = CalculateSmoothNormal(input.uv, gbuffer, 3, Kernel::sNormals);
    if (BUMP_SCALE > 0.0) normal = CalculateBumpyNormal(input.uv, normal);

    float3 StartPos = UVToViewSpace(input.uv, depth, input);
    float3 viewDir = normalize(-StartPos);
    float dynamicRayLengthNormalized = min(RAY_LENGTH_SCALE * depth, 1.0-depth);
    float stepSize = dynamicRayLengthNormalized / float(MAX_STEPS);
    float3 mirrorDir = reflect(-viewDir, normal);
    if (dot(mirrorDir, mirrorDir) < 0.001) { //mirror reflection validation chck
        return float4(0, 0, 0, 1);
    }
    float2 noise = GetStratifiedNoise(input.vpos.xy);
    float3 jitterN = normalize(normal + float3((noise * 2.0 - 1.0) * ROUGHNESS * 0.2, 0.0));
    float3 rayDir = reflect(-viewDir, jitterN);
    if (dot(rayDir, normal) < 0.0) rayDir = mirrorDir; //prevent jitter from pushing ray inside the geometry
    float biasedOffset = RAY_ORIGIN_BIAS + (depth * RAY_ORIGIN_BIAS * 0.01); //intentional -ve origin bias
    float3 biasedStartPos = StartPos - (normal * biasedOffset); //deliberately pushes the ray slightly into the floor, makes it immediately collide with the floor's depth, killing "joined reflections"
    float t = stepSize * noise.x;
    float3 spec = float3(0.0, 0.0, 0.0);
    bool hitFound = false;
    float distanceRatio = 0.0;
    float2 finalUV = 0.0;

    for (int i = 0; i < MAX_STEPS; i++)
    {
        if (t >= dynamicRayLengthNormalized)
            break;

        float3 currentPos = biasedStartPos + rayDir * t;
        float2 hitUV = ViewSpaceToUV(currentPos, input);

        if (IsOOB(hitUV))
            break;

        float sceneDepth = tex2Dlod(Kernel::sDepth, float4(hitUV, 0, 0)).r;
        if (sceneDepth > DEPTH_BOUNDARY) {
            t += stepSize;
            continue;
        }

        float3 scenePos = UVToViewSpace(hitUV, sceneDepth, input);
        float depthDiff = currentPos.z - scenePos.z;

        if (depthDiff > 0.0) //passed behind surface
        {
            float gateThreshold = dynamicRayLengthNormalized * 0.1; //initially, a broad thickness check
            float extraThickness = (t > gateThreshold) ? 0.01 : 0.0; //if t is past the threshold, add extra thickness
            float dynamicThickness = (currentPos.z * 0.05) + extraThickness;

            if (depthDiff < dynamicThickness)
            {
                //binary search refinement
                float binarySearchT = t;
                float binarySearchStep = stepSize;
                float3 binarySearchCurrentPos = currentPos;
                float2 binarySearchUV = hitUV;
                float3 binarySearchScenePos = scenePos;

                for (int j = 0; j < BINARY_SEARCH_STEPS; j++) {
                    binarySearchStep *= 0.5;
                    binarySearchT += (binarySearchCurrentPos.z > binarySearchScenePos.z) ? -binarySearchStep : binarySearchStep; //move backwards if behind the surface, otherwise forwards
                    binarySearchCurrentPos = biasedStartPos + rayDir * binarySearchT;
                    binarySearchUV = ViewSpaceToUV(binarySearchCurrentPos, input);
                    float binarySearchSceneDepth = tex2Dlod(Kernel::sDepth, float4(binarySearchUV, 0, 0)).r;
                    binarySearchScenePos = UVToViewSpace(binarySearchUV, binarySearchSceneDepth, input);
                }

                float finalDepthDiff = binarySearchCurrentPos.z - binarySearchScenePos.z;

                if (abs(finalDepthDiff) < (binarySearchCurrentPos.z * 0.01 + 0.01)) {  //tighter thickness tolerance on the final refined hit to discard empty space behind thin grass
                    hitFound = true;
                    distanceRatio = binarySearchT / dynamicRayLengthNormalized;
                    finalUV = binarySearchUV;
                    break;
                }
            }
        }
        t += stepSize * noise.y;
    }

    if (hitFound) {
        float3 hitColor = GetLinearColor(finalUV, false);
        float2 edgeFadeUV = abs(finalUV * 2.0 - 1.0);
        float edgeFade = saturate(1.0 - max(edgeFadeUV.x, edgeFadeUV.y));
        edgeFade = smoothstep(0.0, 0.05, edgeFade);
        float maxDistFade = pow(saturate(1.0 - distanceRatio), TAIL_FEATHERING + EPSILON);
        spec = hitColor * maxDistFade * edgeFade;
    }

    return float4(spec, 1.0);
}

float4 PS_TemporalBlend(VSOUT input) : SV_Target
{
    float depth = tex2D(Kernel::sDepth, input.uv).r;
    if (depth >= DEPTH_BOUNDARY) return float4(0, 0, 0, 0);
    float3 spec = tex2D(sSpec1, input.uv).rgb;
    float2 flow = tex2D(Kernel::sFlow, input.uv).xy;
    float confidence = tex2D(Kernel::sConfidence, input.uv).x;
    confidence = saturate(confidence + log2(2.0 - confidence) * 0.5);
    float3 prevSpec = tex2D(sPrevSpec, input.uv + flow).rgb;
    float historyMax = max(prevSpec.r, max(prevSpec.g, prevSpec.b));
    float blendWeight = (historyMax < 0.00001) ? 0.0 : (confidence * 0.98);
    float3 blended = lerp(spec, prevSpec, blendWeight);
    return float4(blended, 1.0);
}

float4 PS_StoreHistory(VSOUT input) : SV_Target
{
    float depth = tex2D(Kernel::sDepth, input.uv).r;
    if (depth >= DEPTH_BOUNDARY) return float4(0, 0, 0, 0); //if past boundary, store 0.0 to 'clear' history for next frame
    return float4(max(tex2D(sSpec2, input.uv).rgb, 0.0001), 1.0); //clamp to 0.0001 so it knows 'valid hist data', prevents shimmer at depth boundary edges
}

float4 PS_ToDisplay(VSOUT input) : SV_Target
{
    float3 base = GetLinearColor(input.uv, false);
    float4 gbuffer = tex2D(Kernel::sNormals, input.uv);
    float3 normal = gbuffer.rgb;
    float depth = gbuffer.a;
    float3 surfacePos = UVToViewSpace(input.uv, depth, input);
    float depthFade = CalculateDepthFade(depth);
    float3 viewDir = normalize(-surfacePos);
    float NdotV = saturate(dot(normal, viewDir));
    float fresnel = F0 + (1.0 - F0) * pow(1.0 - NdotV, 5.0); //schlick's approximation
    float3 spec = tex2D(sSpec2, input.uv).rgb;
    spec *= depthFade;
    spec *= fresnel;
    float reflectionMask = saturate(length(spec) + fresnel * 0.5);
    spec *= 1.0 - GetFogMask(input.uv);            //reflected light crosses the same fog as the surface: keep its transmitted part
    reflectionMask *= 1.0 - GetFogMask(input.uv); //darken only the surface's share of the pixel, not the fog in front
    float3 conservationBase = base * (1.0 - reflectionMask * 0.7 * depthFade);
    return float4(ToOutputColorspace(conservationBase + spec, false), 1.0);
}

/*----------------.
| :: TECHNIQUE :: |
'----------------*/
technique LUMENITE_SSSR <
    ui_label = "LUMENITE: SSSR";
    ui_tooltip = "Stochastic Screen Space Reflections.";
>
{
    pass { VertexShader = VS; PixelShader = PS_TraceSpecular; RenderTarget = tSpec1;    }
    pass { VertexShader = VS; PixelShader = PS_TemporalBlend; RenderTarget = tSpec2;    }
    pass { VertexShader = VS; PixelShader = PS_ToDisplay;                               }
    pass { VertexShader = VS; PixelShader = PS_StoreHistory;  RenderTarget = tPrevSpec; }
}

}
