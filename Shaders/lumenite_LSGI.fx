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


        Filename   : lumenite_LSGI.fx
        Version    : 2026.11.10
        Author     : Afzaal (Kaidō)
        Description: Large-Scale Ray Traced Global Illumination (Screen Space)
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
uniform int DEBUG_VIEW <
    ui_type = "combo";
    ui_items = "Off\0AO Mask\0GI Light\0Albedo\0GI Contribution\0";
    ui_label = "Debug View";
    ui_tooltip = "AO Mask: raw AO. GI Light: the bounced light arriving. Albedo: the estimated surface color.\n"
                 "GI Contribution: what the bounce adds (albedo x light).";
    ui_category = "Global Illumination";
> = 0;

uniform float DEPTH_BOUNDARY <
    ui_type = "slider";
    ui_min = 0.001; ui_max = 0.999; ui_step = 0.001;
    ui_label = "Effect Range";
    ui_tooltip = "The Z+ range/depth in which the effect is applied.";
    ui_category = "Global Illumination";
    hidden = false;
> = 0.6;

uniform float DEPTH_FADE_START <
    ui_type = "slider";
    ui_min = 0.1; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Z+ Fade Start (%)";
    ui_tooltip = "Z+ fraction where effect starts fading out (relative to Effect Range)";
    ui_category = "Global Illumination";
    hidden = true;
> = 0.75;

uniform float AO_INTENSITY <
    ui_type = "drag";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "AO Strength";
    ui_tooltip = "Scales the ambient occlusion effect.";
    ui_category = "Global Illumination";
> = 1.0;

uniform float GI_INTENSITY <
    ui_type = "drag";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "GI Strength";
    ui_tooltip = "Scales the bounced light.";
    ui_category = "Global Illumination";
> = 1.0;

uniform float3 AMBIENT_COLOR <
    ui_type = "color";
    ui_label = "Ambient Color";
    ui_tooltip = "The color of the ambient light.";
    ui_category = "Global Illumination";
> = float3(1.0, 0.95, 0.9);

uniform float AMBIENT_INTENSITY <
    ui_type = "drag";
    ui_min = 0.0; ui_max = 0.1; ui_step = 0.001;
    ui_label = "Ambient Level";
    ui_tooltip = "Scales the ambient light. The game's own ambient is already in its colors, just use a little.";
    ui_category = "Global Illumination";
> = 0.03;

uniform float FOG_BLOCK <
    ui_type = "drag";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "Fog Awareness";
    ui_tooltip = "How much to suppress the AO and the bounce inside fog. 0 = off.\nRequires FOG_MASK set to 1 in Kernel.";
    ui_category = "Global Illumination";
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

    texture2D tCurrLuma { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16F; MipLevels = 8; };
    sampler2D sCurrLuma { Texture = tCurrLuma; MagFilter = LINEAR; MinFilter = LINEAR; MipFilter = LINEAR; AddressU = CLAMP; AddressV = CLAMP; AddressW = CLAMP; };
}

namespace LumeniteLSGI {

sampler sFlowLinear { Texture = Kernel::tFlow; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; MipFilter = POINT; };

/*---------------------.
| :: RENDER TARGETS :: |
'---------------------*/
//rg: AO and its 2nd moment
texture tAO1 { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };
sampler sAO1 { Texture = tAO1; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

texture tAO2 { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RG16F; };

//history stores 1-AO and 1-moment
texture tPrevAO { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };
sampler sPrevAO { Texture = tPrevAO; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; MipFilter = LINEAR; };

//rgb: bounce, a: its luminance's 2nd moment
texture tGI1 { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };
sampler sGI1 { Texture = tGI1; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

texture tGI2 { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };

texture tPrevGI { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };
sampler sPrevGI { Texture = tPrevGI; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; MipFilter = LINEAR; };

texture tGI3 { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };
texture tGI4 { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };

texture tPrevZ { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = R16F; };
sampler sPrevZ { Texture = tPrevZ; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
sampler sPrevAOPoint { Texture = tPrevAO; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
sampler sPrevGIPoint { Texture = tPrevGI; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

//view's motion along its axis per blk (r: depth change, g: 1 where valid); last mip is screen's mean
#if BUFFER_WIDTH / 8 >= 512 || BUFFER_HEIGHT / 8 >= 512
    #define LSGI_DRIFT_MIPS 10
#elif BUFFER_WIDTH / 8 >= 256 || BUFFER_HEIGHT / 8 >= 256
    #define LSGI_DRIFT_MIPS 9
#elif BUFFER_WIDTH / 8 >= 128 || BUFFER_HEIGHT / 8 >= 128
    #define LSGI_DRIFT_MIPS 8
#elif BUFFER_WIDTH / 8 >= 64 || BUFFER_HEIGHT / 8 >= 64
    #define LSGI_DRIFT_MIPS 7
#else
    #define LSGI_DRIFT_MIPS 6
#endif
texture tDrift { Width = BUFFER_WIDTH / 8; Height = BUFFER_HEIGHT / 8; Format = RG32F; MipLevels = LSGI_DRIFT_MIPS; };
sampler sDrift { Texture = tDrift; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

static const float2 HALF_SIZE  = float2(BUFFER_WIDTH / 2, BUFFER_HEIGHT / 2);
static const float2 HALF_PIXEL = float2(1.0, 1.0) / HALF_SIZE;

sampler sGeoPoint { Texture = Kernel::tNormals; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

texture tGeoHalf { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };
sampler sGeoHalf { Texture = tGeoHalf; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

sampler sAO2Point { Texture = tAO2; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
sampler sGI2Point { Texture = tGI2; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
sampler sGI3Point { Texture = tGI3; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
sampler sGI4Point { Texture = tGI4; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

//depth jitter filtering
texture tFinal { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler sFinalPoint { Texture = tFinal; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
texture tFinalPrev { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler sFinalPrev { Texture = tFinalPrev; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; MipFilter = POINT; };

//AO b/w its lvls (g: variance, w. crease share in last 4 bits)
texture tAO3 { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RG16F; };
sampler sAO3Point { Texture = tAO3; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

//8x8 blk: nearest (r), nearest/farthest +1 px ring (g, b); 32x32 blk: min of 4x4 r <- this style for DXVK
texture tHiZ8    { Width = (BUFFER_WIDTH + 7) / 8; Height = (BUFFER_HEIGHT + 7) / 8; Format = RGBA32F; };
texture tHiZMip5 { Width = BUFFER_WIDTH/32; Height = BUFFER_HEIGHT/32; Format = R16F; };
sampler sHiZ8    { Texture = tHiZ8;    MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; AddressU = CLAMP; AddressV = CLAMP; };
sampler sHiZMip5 { Texture = tHiZMip5; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; AddressU = CLAMP; AddressV = CLAMP; };

/*--------------.
| :: HELPERS :: |
'--------------*/
float CalculateDistanceToFrustum(float3 startPos, float3 rayDir) {
    float fovRad = FOV * 0.0174532925;
    float tanHalfFov = tan(fovRad * 0.5);
    float tMin = 1000.0; //just some arbitrary large fallback
    float t;

    //left and right screen bounds (X-axis)
    float denomX1 = rayDir.x - rayDir.z * tanHalfFov * BUFFER_ASPECT_RATIO;
    if (abs(denomX1) > 1e-4) { t = (startPos.z * tanHalfFov * BUFFER_ASPECT_RATIO - startPos.x) / denomX1; if (t > 0.0) tMin = min(tMin, t); }

    float denomX2 = rayDir.x + rayDir.z * tanHalfFov * BUFFER_ASPECT_RATIO;
    if (abs(denomX2) > 1e-4) { t = (-startPos.z * tanHalfFov * BUFFER_ASPECT_RATIO - startPos.x) / denomX2; if (t > 0.0) tMin = min(tMin, t); }

    //top and bottom bounds (Y-axis)
    float denomY1 = rayDir.y - rayDir.z * tanHalfFov;
    if (abs(denomY1) > 1e-4) { t = (startPos.z * tanHalfFov - startPos.y) / denomY1; if (t > 0.0) tMin = min(tMin, t); }

    float denomY2 = rayDir.y + rayDir.z * tanHalfFov;
    if (abs(denomY2) > 1e-4) { t = (-startPos.z * tanHalfFov - startPos.y) / denomY2; if (t > 0.0) tMin = min(tMin, t); }

    //far depth bounds (Z-axis)
    if (rayDir.z > 1e-4) { t = (DEPTH_BOUNDARY - startPos.z) / rayDir.z; if (t > 0.0) tMin = min(tMin, t); }

    return tMin;
}

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

float3 GetAlbedoColor(float2 uv)
{
    float3 color = tex2Dlod(ReShade::BackBuffer, float4(uv, 0, 0)).rgb;
    #if BUFFER_COLOR_SPACE == 2
        return color * (80.0 / HDR_WHITELEVEL);
    #elif BUFFER_COLOR_SPACE == 3
        return PQtoLinearAccurate(color);
    #elif BUFFER_COLOR_SPACE == 4
        return HLGtoLinear(color);
    #else
        return sRGBtoLinearAccurate(color);
    #endif
}

float DecodeKernelLuma(float kernelLuma)
{
    float luma = kernelLuma / max(1.0 - kernelLuma, 0.0001);
    float3 luma3 = luma.xxx;
    #if BUFFER_COLOR_SPACE == 2
        return luma3.x * (80.0 / HDR_WHITELEVEL);
    #elif BUFFER_COLOR_SPACE == 3
        return PQtoLinearAccurate(luma3).x;
    #elif BUFFER_COLOR_SPACE == 4
        return HLGtoLinear(luma3).x;
    #else
        return sRGBtoLinearAccurate(luma3).x;
    #endif
}

float3 EstimateAlbedo(float2 uv)
{
    static const float DETAIL_GAMMA = 0.75;
    static const float CHROMA_LIGHT = 0.1;
    static const float CHROMA_TEXTURE = 0.4;
    float3 color = max(GetAlbedoColor(uv), 0.0);
    float brightness = max(max(color.r, max(color.g, color.b)), 0.0001);
    float luminance = GetLuminance(color);
    float localMean = DecodeKernelLuma(tex2Dlod(Kernel::sCurrLuma, float4(uv, 0, 3)).r);
    float detail = clamp(luminance / max(localMean, 0.000001), 0.125, 8.0);
    float3 meanColor = max(GetAlbedoColor(uv + float2(-3.5, -3.5) * BUFFER_PIXEL_SIZE), 0.0)
                     + max(GetAlbedoColor(uv + float2( 3.5, -3.5) * BUFFER_PIXEL_SIZE), 0.0)
                     + max(GetAlbedoColor(uv + float2(-3.5,  3.5) * BUFFER_PIXEL_SIZE), 0.0)
                     + max(GetAlbedoColor(uv + float2( 3.5,  3.5) * BUFFER_PIXEL_SIZE), 0.0);
    float3 chromaDiff = color / max(luminance, 1e-6) - meanColor / max(GetLuminance(meanColor), 1e-6);
    float textured = saturate((length(chromaDiff) - CHROMA_LIGHT) / (CHROMA_TEXTURE - CHROMA_LIGHT));
    float detailKept = pow(detail, lerp(DETAIL_GAMMA, 1.0, textured));
    return saturate(color * (min(8.5, 0.78 / brightness) * sqrt(luminance / brightness) * detailKept));
}

float3 EstimateDirectLighting(float3 color)
{
    float brightness = max(color.r, max(color.g, color.b));
    float lightness = max((brightness - 0.135) / max(1.0 - 0.135, 0.001), 0.0);
    float3 rawAlbedo = color / max(GetLuminance(color), 0.01);
    float3 albedo = (color / max(brightness, 0.01)) * 0.45;
    return albedo * lightness * (rawAlbedo / max(rawAlbedo, 0.1));
}

float3 EstimateHitAlbedo(float3 color)
{
    float brightness = max(color.r, max(color.g, color.b));
    float3 rawAlbedo = color / max(GetLuminance(color), 0.01);
    return (color / max(brightness, 0.01)) * 0.45 * (rawAlbedo / max(rawAlbedo, 0.1));
}

float CalculateDepthFade(float depth)
{
    float fadeStartDepth = DEPTH_BOUNDARY * DEPTH_FADE_START;
    float fadeRange = DEPTH_BOUNDARY - fadeStartDepth;
    return 1.0 - saturate((depth - fadeStartDepth) / fadeRange);
}

float GetFogBlock(float2 uv, float3 sceneColor)
{
    float stamp = tex2Dlod(Kernel::sFogState, float4(0.75, 0.5, 0, 0)).x;
    bool fogActive = (stamp == float((FRAME_COUNT & 0xFFFFFu) + 1u)) || (stamp == float(((FRAME_COUNT - 1u) & 0xFFFFFu) + 1u));
    float fogBlock = 0.0;
    [branch] if (fogActive && FOG_BLOCK != 0.0)
        fogBlock = saturate(tex2Dlod(Kernel::sFogMask, float4(uv, 0, 0)).r * clamp(GetLuminance(tex2Dlod(Kernel::sFogState, float4(0.25, 0.5, 0, 0)).rgb) / max(GetLuminance(sceneColor), EPSILON), 0.0, 10.0) * FOG_BLOCK);
    return fogBlock;
}

float2 TexelPixelUV(float2 texel) { return (texel * 2.0 + 0.5) * BUFFER_PIXEL_SIZE; } //half-res txl's own pxl (top-left of its 2x2)
float2 TexelUV(float2 texel) { return (texel + 0.5) * HALF_PIXEL; } //center
float4 TexelGeo(float2 texel) { return tex2Dlod(sGeoHalf, float4(TexelUV(texel), 0, 0)); } //it's pxl's normal/depth

static const float2 TAPS8[8] = { float2(-1, -1), float2(0, -1), float2(1, -1), float2(-1, 0),
                                 float2( 1,  0), float2(-1, 1), float2(0,  1), float2(1,  1) };

static const float PLANE_TOL = 0.01; //tangent plane's tolerance as a share of depth
static const float GAUSS_LOG2 = 1.20112241; //sqrt(log2(e)): exp(-x^2) = exp2(-(x * GAUSS_LOG2)^2)
static const float NORMAL_POWER = 50.0;

float TapGeoLog2(float4 centerGeo, float rayDotN, float planeOffset, float planeScale, float2 tapTexel, VSOUT input)
{
    float4 tapGeo = TexelGeo(tapTexel);
    float projScale = mad(tapGeo.a, input.diff_ratio, input.near_ratio);
    float planeDist = (projScale * rayDotN + mad(tapGeo.a, centerGeo.b, -planeOffset)) * planeScale;
    return NORMAL_POWER * log2(clamp(dot(centerGeo.rgb, tapGeo.rgb), 1e-8, 1.0)) - planeDist * planeDist;
}

//a 0..1 share in the last 4 bits of a half float's mantissa
//lvls A and B hand their crease share fwd in the AO variance
float PackShare(float variance, float share)
{
    uint halfBits = f32tof16(max(variance, 0.0));
    return f16tof32((halfBits & 0xFFF0u) | (uint)(saturate(share) * 15.0 + 0.5));
}

float UnpackShare(float variance)
{
    return (float)(f32tof16(variance) & 15u) * (1.0 / 15.0);
}

//TapGeoLog2, plus whether tap lies across a crease and how near?
float TapGeoCrease(float4 centerGeo, float3 centerPos, float rayDotN, float planeOffset, float planeScale, float2 tapTexel,
                   VSOUT input, out float creaseCut, out float creaseShare)
{
    float4 tapGeo = TexelGeo(tapTexel);
    float projScale = mad(tapGeo.a, input.diff_ratio, input.near_ratio);
    float planeDist = (projScale * rayDotN + mad(tapGeo.a, centerGeo.b, -planeOffset)) * planeScale;
    float normalLog2 = NORMAL_POWER * log2(clamp(dot(centerGeo.rgb, tapGeo.rgb), 1e-8, 1.0));
    creaseCut = 0.0;
    creaseShare = 0.0;
    [branch] if (planeDist > 0.0 && normalLog2 < -5.0 * (NORMAL_POWER / 50.0)) //the normals over 21 deg apart
    {
        float3 tapPos = UVToViewSpace(TexelPixelUV(tapTexel), tapGeo.a, input);
        float centerDist = dot(centerPos - tapPos, tapGeo.rgb) * planeScale;
        creaseCut = (centerDist > 0.0) ? 1.0 : 0.0;
        creaseShare = creaseCut * saturate(1.0 - centerDist / max(planeDist + centerDist, 1e-6));
    }
    return normalLog2 - planeDist * planeDist;
}

float SpeedKeep(float2 flow)
{
    float px = max(length(flow * BUFFER_SCREEN_SIZE) - 40.0, 0.0);
    return max(rcp(1.0 + px * px * 0.0000826), 0.5);
}

float MotionShare(float2 uv)
{
    float flowPx = length(tex2Dlod(sFlowLinear, float4(uv, 0, 0)).xy * BUFFER_SCREEN_SIZE);
    return saturate((flowPx - 0.5) / 3.5);
}

float MotionWiden(float2 uv)
{
    return 1.0 + 3.0 * MotionShare(uv); //no more than 4x: wider flattens the wide lvls into a box printing contour lines in motion!!
}

float MotionAmount(float2 uv) //0 still, near 1 from 4 pxls a frame
{
    return 1.0 - rcp(1.0 + 100.0 * MotionShare(uv));
}

//flow on the surface at this depth
//4 blocks around weighed by depth too, so silhouettes don't mix motions
float2 GetSurfaceFlow(float2 uv, float depth)
{
    static const float2 BLOCKS = float2(BUFFER_WIDTH / 8, BUFFER_HEIGHT / 8);
    float2 blockPos = uv * BLOCKS - 0.5;
    float2 baseBlock = floor(blockPos);
    float2 blockFrac = blockPos - baseBlock;
    float2 flowSum = 0.0; float weightSum = 0.0;
    [unroll] for (int k = 0; k < 4; k++)
    {
        float2 corner = float2(k & 1, k >> 1);
        float2 blockUV = (clamp(baseBlock + corner, 0.0, BLOCKS - 1.0) + 0.5) / BLOCKS;
        float2 bilinear = lerp(1.0 - blockFrac, blockFrac, corner);
        float blockDepth = tex2Dlod(sGeoPoint, float4(blockUV, 0, 0)).a;
        float depthDiff = (blockDepth - depth) / (depth * 0.03);
        float weight = bilinear.x * bilinear.y * exp2(-1.44269504 * depthDiff * depthDiff);
        flowSum += tex2Dlod(Kernel::sFlow, float4(blockUV, 0, 0)).xy * weight;
        weightSum += weight;
    }
    return (weightSum > 0.01) ? flowSum / weightSum : tex2Dlod(sFlowLinear, float4(uv, 0, 0)).xy;
}

//last frame's accum (1 - AO, 1 - moment) and bounce, read txl by txl where its depth matches;
//under a sixteenth, the nearest matching neighbor stands in
void SampleHistory(float2 uv, float depth, out float3 ao, out float4 gi, out float same)
{
    float2 texelPos = uv * HALF_SIZE - 0.5;
    float2 baseTexel = floor(texelPos);
    float2 texelFrac = texelPos - baseTexel;
    float4 weights = 0.0; float allSame = 1.0;
    [unroll] for (int k = 0; k < 4; k++)
    {
        float2 corner = float2(k & 1, k >> 1);
        float2 bilinear = lerp(1.0 - texelFrac, texelFrac, corner);
        float prevDepth = tex2Dlod(sPrevZ, float4((baseTexel + corner + 0.5) * HALF_PIXEL, 0, 0)).r;
        float sameSurface = (prevDepth <= 0.0) ? 1.0 : saturate(2.0 - abs(prevDepth - depth) / (depth * 0.1));
        weights[k] = bilinear.x * bilinear.y * sameSurface;
        allSame = (bilinear.x * bilinear.y > 1.0 / 512.0) ? min(allSame, sameSurface) : allSame;
    }
    [branch] if (allSame >= 1.0)
    {
        ao = tex2Dlod(sPrevAO, float4(uv, 0, 0)).rgb;
        gi = tex2Dlod(sPrevGI, float4(uv, 0, 0));
        same = 1.0;
    }
    else
    {
        ao = 0.0; gi = 0.0;
        [unroll] for (int k = 0; k < 4; k++)
        {
            float2 texelUV = (baseTexel + float2(k & 1, k >> 1) + 0.5) * HALF_PIXEL;
            ao += tex2Dlod(sPrevAOPoint, float4(texelUV, 0, 0)).rgb * weights[k];
            gi += tex2Dlod(sPrevGIPoint, float4(texelUV, 0, 0)) * weights[k];
        }
        float weightSum = dot(weights, 1.0);
        float rcpWeight = rcp(max(weightSum, 1e-6));
        ao *= rcpWeight; gi *= rcpWeight;
        same = saturate(weightSum * 16.0);
        [branch] if (weightSum < 0.0625)
        {
            float2 nearestTexel = floor(texelPos + 0.5);
            float bestSame = 0.0; float2 bestTexel = nearestTexel;
            [unroll] for (int j = 0; j < 8; j++)
            {
                float2 neighbor = nearestTexel + TAPS8[j];
                float neighborDepth = tex2Dlod(sPrevZ, float4((neighbor + 0.5) * HALF_PIXEL, 0, 0)).r;
                float neighborSame = (neighborDepth <= 0.0) ? 0.0 : saturate(2.0 - abs(neighborDepth - depth) / (depth * 0.1));
                [flatten] if (neighborSame > bestSame) { bestSame = neighborSame; bestTexel = neighbor; }
            }
            [branch] if (bestSame > 0.0)
            {
                float2 texelUV = (bestTexel + 0.5) * HALF_PIXEL;
                ao = tex2Dlod(sPrevAOPoint, float4(texelUV, 0, 0)).rgb;
                gi = tex2Dlod(sPrevGIPoint, float4(texelUV, 0, 0));
                same = bestSame;
            }
        }
    }
}

//view's motion along its axis this frame, in view-depth
float GetDepthDrift()
{
    float2 drift = tex2Dlod(sDrift, float4(0.5, 0.5, 0, 16.0)).xy;
    return (drift.y > 1e-6) ? drift.x / drift.y : 0.0;
}

//center's plane terms for TapGeoLog2: n.p,
//its view ray against its normal, and that term's step per tap txl
void GetPlaneTerms(float4 centerGeo, float3 centerPos, float2 texel, float dilation, VSOUT input,
                   out float planeOffset, out float rayDotN, out float2 rayDotNStep)
{
    float2 normalTan = centerGeo.rg * float2(input.tan_half_fov_x, input.tan_half_fov_y);
    planeOffset = dot(centerPos, centerGeo.rgb);
    rayDotN = dot(TexelPixelUV(texel) * float2(2.0, -2.0) + float2(-1.0, 1.0), normalTan);
    rayDotNStep = normalTan * (dilation * 4.0 * float2(BUFFER_PIXEL_SIZE.x, -BUFFER_PIXEL_SIZE.y));
}

//later levels' range weights against this many times the variance handed on (narrower as the noise falls)
static const float VAR_SCALE_A = 9.0;
static const float VAR_SCALE = 4.0;

//bounce's variance floor per lvl as a share of the brighter luminance (0: absolute);
static const float GI_FLOOR   = 0.0;
static const float GI_FLOOR_A = 0.0;
static const float GI_FLOOR_B = 0.35;
static const float GI_FLOOR_C = 0.35;

static const float RCV_FLOOR = 0.02;

static const float INFINITE_BOUNCE = 1.0; //strenth

static const float NEAR_RADIUS = 0.03;
static const float NEAR_BOOST = 1.0;
static const int   NEAR_STEPS = 4;
static const float NEAR_STEP = 0.25;

//final pass's bound
static const float FINAL_MARGIN_AO = 0.04;
static const float FINAL_MARGIN_GI = 0.2;

float GIRange(float lumaDiff, float centerVar, float varScale, float floorShare, float centerLuma, float tapLuma, bool moments)
{
    float lumaFloor = floorShare * max(centerLuma, tapLuma);
    float variance = (floorShare > 0.0) ? max(centerVar * varScale, lumaFloor * lumaFloor) + 1e-12
                                        : max(centerVar * varScale, 0.0001) + 0.0001;
    float scaledDiff = lumaDiff * lumaDiff * (moments ? 1.44269504 : GAUSS_LOG2) / variance;
    return moments ? scaledDiff : scaledDiff * scaledDiff;
}

void ATrousBoth(sampler aoSampler, sampler giSampler, float2 texel, float dilation, bool moments, bool symmetric, VSOUT input,
                out float2 aoResult, out float4 giResult, out float2 centerAO, out float4 centerGI)
{
    float4 centerGeo = TexelGeo(texel);
    aoResult = float2(1.0, 0.0);
    giResult = 0.0;
    centerAO = 0.0;
    centerGI = 0.0;
    if (moments)
    {
        centerAO = tex2Dlod(aoSampler, float4(TexelUV(texel), 0, 0)).rg;
        centerGI = tex2Dlod(giSampler, float4(TexelUV(texel), 0, 0));
    }
    [branch] if (!(centerGeo.a == 0 || centerGeo.a >= DEPTH_BOUNDARY))
    {
        float3 centerPos = UVToViewSpace(TexelPixelUV(texel), centerGeo.a, input);
        float planeScale = GAUSS_LOG2 / (centerGeo.a * PLANE_TOL);
        float planeOffset, centerRayDotN; float2 rayDotNStep;
        GetPlaneTerms(centerGeo, centerPos, texel, dilation, input, planeOffset, centerRayDotN, rayDotNStep);
        if (!moments)
        {
            centerAO = tex2Dlod(aoSampler, float4(TexelUV(texel), 0, 0)).rg;
            centerGI = tex2Dlod(giSampler, float4(TexelUV(texel), 0, 0));
        }
        //vounce is filtered as its ratio to the occlusion it rode on (RCV);
        //centerGI stays as it is, for the hist
        float4 centerRatio = centerGI;
        float centerOcc = 1.0;
        if (moments)
        {
            centerOcc = (1.0 - centerAO.r) / max(AO_INTENSITY, 0.05);
            float centerScale = centerOcc / max(centerOcc * centerOcc, RCV_FLOOR * RCV_FLOOR); //clamp ratio at floor (scaling down below it to 0 at misses) cap at hitcolor to prevent >1 loop gain overflow into a black screen during infinite bounce
            centerRatio.rgb = min(centerRatio.rgb * centerScale, 255.0);
            centerRatio.a *= centerScale * centerScale;
        }
        float centerLuma = GetLuminance(centerRatio.rgb);
        float centerAOVar = moments ? max(0.0, centerAO.g - centerAO.r * centerAO.r) : centerAO.g;
        float centerGIVar = moments ? max(0.0, centerRatio.a - centerLuma * centerLuma) : centerRatio.a;
        float varScale = moments ? 1.0 : ((dilation < 4.0) ? VAR_SCALE_A : VAR_SCALE);
        float aoVar = max(centerAOVar * varScale, 0.0001);
        float aoRangeScale = (moments ? 1.44269504 : GAUSS_LOG2) / (aoVar + 0.0001);
        float aoSum = centerAO.r; float aoVarSum = centerAOVar; float aoWeightSum = 1.0;
        float3 giSum = centerGI.rgb; float giVarSum = centerGIVar; float giWeightSum = 1.0;
        float occSum = centerOcc;
        float shareOut = 0.0;
        if (symmetric)
        {
            float motion = MotionAmount(input.uv);
            float centerShare = UnpackShare(centerAO.g);
            float geoLog2[8]; float creaseCut[8]; float ownShare = 0.0; float anyCut = 0.0;
            [unroll] for (int i = 0; i < 8; i++) {
                float share;
                geoLog2[i] = TapGeoCrease(centerGeo, centerPos, centerRayDotN + dot(TAPS8[i], rayDotNStep), planeOffset, planeScale,
                                          texel + TAPS8[i] * dilation, input, creaseCut[i], share);
                ownShare = max(ownShare, share);
                anyCut = max(anyCut, creaseCut[i]);
            }
            float tapShare = 0.0;
            [unroll] for (int k = 0; k < 4; k++) {
                //the k-th tap and its mirror image: AO, bounce, and how deep into a crease each reaches (2: across it)
                float2 pairAO[2]; float4 pairGI[2]; float pairReach[2];
                [unroll] for (int j = 0; j < 2; j++) {
                    int i = (j == 0) ? k : 7 - k;
                    float2 tapTexel = texel + TAPS8[i] * dilation;
                    pairAO[j] = tex2Dlod(aoSampler, float4(TexelUV(tapTexel), 0, 0)).rg;
                    pairGI[j] = tex2Dlod(giSampler, float4(TexelUV(tapTexel), 0, 0));
                    float tapCreaseShare = UnpackShare(pairAO[j].g) * step(-1.0, geoLog2[i]);
                    tapShare = max(tapShare, tapCreaseShare);
                    pairReach[j] = (creaseCut[i] > 0.0) ? 2.0 : tapCreaseShare;
                }
                float fade = 1.0 - motion * saturate(max(pairReach[0], pairReach[1]) - centerShare);
                float pairGeoLog2 = min(geoLog2[k], geoLog2[7 - k]);
                [unroll] for (int j = 0; j < 2; j++) {
                    float aoDiff = centerAO.r - pairAO[j].r;
                    float aoRange = aoDiff * aoDiff * aoRangeScale;
                    float aoWeight = exp2(pairGeoLog2 - aoRange * aoRange) * fade;
                    float tapLuma = GetLuminance(pairGI[j].rgb);
                    float lumaDiff = centerLuma - tapLuma;
                    float giWeight = exp2(pairGeoLog2 - GIRange(lumaDiff, centerGIVar, VAR_SCALE, GI_FLOOR_B, centerLuma, tapLuma, false));
                    aoSum += pairAO[j].r * aoWeight; aoVarSum += pairAO[j].g * (aoWeight * aoWeight); aoWeightSum += aoWeight;
                    giSum += pairGI[j].rgb * giWeight; giVarSum += pairGI[j].a * (giWeight * giWeight); giWeightSum += giWeight;
                }
            }
            //the share the last lvl reads: this lvl's own crease, else a tap's a quarter as strong
            shareOut = max(anyCut * (0.25 + 0.75 * ownShare), 0.25 * tapShare);
        }
        else
        {
            [unroll] for (int i = 0; i < 8; i++) {
                float2 tapTexel = texel + TAPS8[i] * dilation;
                float tapCut, share;
                float tapGeoLog2 = TapGeoCrease(centerGeo, centerPos, centerRayDotN + dot(TAPS8[i], rayDotNStep), planeOffset, planeScale,
                                                tapTexel, input, tapCut, share);
                shareOut = max(shareOut, share);
                float2 tapAO = tex2Dlod(aoSampler, float4(TexelUV(tapTexel), 0, 0)).rg;
                float aoDiff = centerAO.r - tapAO.r;
                float aoRange = aoDiff * aoDiff * aoRangeScale;
                float aoWeight = exp2(tapGeoLog2 - (moments ? aoRange : aoRange * aoRange));
                float4 tapGI = tex2Dlod(giSampler, float4(TexelUV(tapTexel), 0, 0));
                float4 tapRatio = tapGI;
                float tapOcc = 1.0;
                if (moments)
                {
                    tapOcc = (1.0 - tapAO.r) / max(AO_INTENSITY, 0.05);
                    float tapScale = tapOcc / max(tapOcc * tapOcc, RCV_FLOOR * RCV_FLOOR); //as the center's
                    tapRatio.rgb = min(tapRatio.rgb * tapScale, 255.0);
                    tapRatio.a *= tapScale * tapScale;
                }
                float tapLuma = GetLuminance(tapRatio.rgb);
                float lumaDiff = centerLuma - tapLuma;
                float tapGIVar = moments ? max(0.0, tapRatio.a - tapLuma * tapLuma) : tapRatio.a;
                float giWeight = exp2(tapGeoLog2 - GIRange(lumaDiff, centerGIVar, moments ? 1.0 : VAR_SCALE_A, moments ? GI_FLOOR : GI_FLOOR_A,
                                                           centerLuma, tapLuma, moments));
                aoSum += tapAO.r * aoWeight;
                aoVarSum += (moments ? max(0.0, tapAO.g - tapAO.r * tapAO.r) : tapAO.g) * (aoWeight * aoWeight);
                aoWeightSum += aoWeight;
                giSum += tapGI.rgb * giWeight; giVarSum += tapGIVar * (giWeight * giWeight); giWeightSum += giWeight;
                occSum += tapOcc * giWeight;
            }
        }
        float aoNorm = 1.0 / (aoWeightSum + EPSILON), giNorm = 1.0 / (giWeightSum + EPSILON);
        //under half a tap's weight on its surface (a thin feature), the txl keeps its own value
        float trustAO = saturate((aoWeightSum - 1.0) * 2.0), trustGI = saturate((giWeightSum - 1.0) * 2.0);
        aoResult = lerp(float2(centerAO.r, centerAOVar), float2(aoSum * aoNorm, aoVarSum * aoNorm * aoNorm), trustAO);
        float occFloor = RCV_FLOOR * giWeightSum;
        float3 giMean = moments ? min(giSum * occSum / max(occSum * occSum, occFloor * occFloor), 255.0) : giSum * giNorm; //as the center's
        giResult = lerp(float4(centerRatio.rgb, centerGIVar), float4(giMean, giVarSum * giNorm * giNorm), trustGI);
        if (!moments) aoResult.g = PackShare(aoResult.g, shareOut);
    }
}

//last lvl on the 4 straight neighbors (rgb: the bounce, a: the AO)
float4 ATrousBothLast(sampler aoSampler, sampler giSampler, float2 texel, float dilation, VSOUT input)
{
    float4 centerGeo = TexelGeo(texel);
    float4 result = float4(0.0, 0.0, 0.0, 1.0);
    [branch] if (!(centerGeo.a == 0 || centerGeo.a >= DEPTH_BOUNDARY))
    {
        float3 centerPos = UVToViewSpace(TexelPixelUV(texel), centerGeo.a, input);
        float planeScale = GAUSS_LOG2 / (centerGeo.a * PLANE_TOL);
        float planeOffset, centerRayDotN; float2 rayDotNStep;
        GetPlaneTerms(centerGeo, centerPos, texel, dilation, input, planeOffset, centerRayDotN, rayDotNStep);
        float2 centerAO = tex2Dlod(aoSampler, float4(TexelUV(texel), 0, 0)).rg;
        float4 centerGI = tex2Dlod(giSampler, float4(TexelUV(texel), 0, 0));
        float centerLuma = GetLuminance(centerGI.rgb);
        float aoVar = max(centerAO.g * VAR_SCALE, 0.0001);
        float aoRangeScale = GAUSS_LOG2 / (aoVar + 0.0001);
        float aoSum = centerAO.r; float aoWeightSum = 1.0;
        float4 giSum = centerGI; float giWeightSum = 1.0;
        //straight neighbors: the k-th and the (3 - k)-th mirror each other
        static const float2 TAPS4[4] = { float2(0, -1), float2(-1, 0), float2(1, 0), float2(0, 1) };
        float motion = MotionAmount(input.uv);
        float centerShare = UnpackShare(centerAO.g);
        float geoLog2[4]; float creaseCut[4];
        [unroll] for (int i = 0; i < 4; i++) {
            float share;
            geoLog2[i] = TapGeoCrease(centerGeo, centerPos, centerRayDotN + dot(TAPS4[i], rayDotNStep), planeOffset, planeScale,
                                      texel + TAPS4[i] * dilation, input, creaseCut[i], share);
        }
        [unroll] for (int k = 0; k < 2; k++) {
            float2 pairAO[2]; float4 pairGI[2]; float pairReach[2];
            [unroll] for (int j = 0; j < 2; j++) {
                int i = (j == 0) ? k : 3 - k;
                float2 tapTexel = texel + TAPS4[i] * dilation;
                pairAO[j] = tex2Dlod(aoSampler, float4(TexelUV(tapTexel), 0, 0)).rg;
                pairGI[j] = tex2Dlod(giSampler, float4(TexelUV(tapTexel), 0, 0));
                pairReach[j] = (creaseCut[i] > 0.0) ? 2.0 : UnpackShare(pairAO[j].g) * step(-1.0, geoLog2[i]);
            }
            float fade = 1.0 - motion * saturate(max(pairReach[0], pairReach[1]) - centerShare);
            float pairGeoLog2 = min(geoLog2[k], geoLog2[3 - k]);
            [unroll] for (int j = 0; j < 2; j++) {
                float aoDiff = centerAO.r - pairAO[j].r;
                float aoRange = aoDiff * aoDiff * aoRangeScale;
                float aoWeight = exp2(pairGeoLog2 - aoRange * aoRange) * fade;
                aoSum += pairAO[j].r * aoWeight; aoWeightSum += aoWeight;
                float tapLuma = GetLuminance(pairGI[j].rgb);
                float lumaDiff = centerLuma - tapLuma;
                float giWeight = exp2(pairGeoLog2 - GIRange(lumaDiff, centerGI.a, VAR_SCALE, GI_FLOOR_C, centerLuma, tapLuma, false));
                giSum += pairGI[j] * giWeight; giWeightSum += giWeight;
            }
        }
        result = lerp(centerGI, giSum / (giWeightSum + EPSILON), saturate((giWeightSum - 1.0) * 2.0));
        result.a = lerp(centerAO.r, aoSum / (aoWeightSum + EPSILON), saturate((aoWeightSum - 1.0) * 2.0));
    }
    return result;
}

float4 UpsampleAOGI(float2 uv, float4 pixelGeo, VSOUT input)
{
    float2 halfPos   = floor(input.vpos.xy) * 0.5;
    float2 baseTexel = floor(halfPos);
    float2 texelFrac = halfPos - baseTexel;
    float3 pixelPos  = UVToViewSpace(uv, pixelGeo.a, input);
    float planeScale = GAUSS_LOG2 / (pixelGeo.a * PLANE_TOL);
    float planeOffset, baseRayDotN; float2 rayDotNStep;
    GetPlaneTerms(pixelGeo, pixelPos, baseTexel, 1.0, input, planeOffset, baseRayDotN, rayDotNStep);
    static const float2 CORNERS[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
    float4 edgeSum = 0.0;
    float edgeWeightSum = 0.0;
    float4 bilinearSum = 0.0;
    float4 depthSum = 0.0; float depthWeightSum = 0.0;
    [unroll] for (int k = 0; k < 4; k++) {
        float2 tapTexel = baseTexel + CORNERS[k];
        float2 bilinear = lerp(1.0 - texelFrac, texelFrac, CORNERS[k]);
        float geoWeight = exp2(TapGeoLog2(pixelGeo, baseRayDotN + dot(CORNERS[k], rayDotNStep), planeOffset, planeScale,
                                          tapTexel, input));
        float4 value = tex2Dlod(sGI3Point, float4(TexelUV(tapTexel), 0, 0));
        //a little weight for the farther txls, which an edge may need
        float weight = geoWeight * (bilinear.x * bilinear.y + 0.01);
        edgeSum += value * weight;
        edgeWeightSum += weight;
        bilinearSum += value * (bilinear.x * bilinear.y);
        float depthDiff = (TexelGeo(tapTexel).a - pixelGeo.a) / (pixelGeo.a * 0.03);
        float depthWeight = exp2(-depthDiff * depthDiff) * (bilinear.x * bilinear.y + 0.01);
        depthSum += value * depthWeight; depthWeightSum += depthWeight;
    }
    float4 fallback = lerp(bilinearSum, depthSum / max(depthWeightSum, 1e-6), saturate(depthWeightSum / 0.01));
    return lerp(fallback, edgeSum / max(edgeWeightSum, 1e-6), saturate(edgeWeightSum / 0.01));
}

float TraceRay(VSOUT input, float2 pixelUV, float4 gbuffer, out float3 bounce)
{
    float3 normal = gbuffer.rgb;
    float depth = gbuffer.a;
    float occlusion = 0.0;
    bounce = 0.0;
    [branch] if (!(depth == 0 || depth >= DEPTH_BOUNDARY))
    {
        float3 startPos = UVToViewSpace(pixelUV, depth, input);
        float3 tangent, bitangent;
        BuildOrthonormalBasis(normal, tangent, bitangent);
        float2 noise = GetStratifiedNoise(input.vpos.xy);
        float3 rayDir = GenerateHemisphereDirection(normal, noise, tangent, bitangent);
        const float globalMaxDistance = 1.0;
        float frustumDist = CalculateDistanceToFrustum(startPos, rayDir);
        float totalRayLength = min(frustumDist, globalMaxDistance);
        float stepSize = startPos.z * 0.005;
        float t = stepSize * NEAR_STEP; //(near) first sample a quarter step out
        float3 currentPos = startPos + rayDir * t;
        //blk vals kept per blk and full-screen depth read only where a hit can pass <- DXVK fix
        int2 texel32 = int2(-1, -1); float HiZDepth = 0.0;
        int2 texel8 = int2(-1, -1); float2 bounds8 = 0.0;
        [loop] for (int step = 0; step < 100; step++) {
            if (t >= totalRayLength) break;

            float2 hitPos = ViewSpaceToUV(currentPos, input);
            if (IsOOB(hitPos)) break;

            //32x32 blk's nearest (the txl point sample at hitPos selects)
            int2 at32 = min(int2(hitPos * float2(BUFFER_WIDTH / 32, BUFFER_HEIGHT / 32)), int2(BUFFER_WIDTH / 32, BUFFER_HEIGHT / 32) - 1);
            [branch] if (any(at32 != texel32)) { texel32 = at32; HiZDepth = tex2Dfetch(sHiZMip5, at32).r; }
            bool nearStep = step < NEAR_STEPS; //(near) the first steps finer
            float currentStepSize = stepSize * (nearStep ? 2.5 * NEAR_STEP : 2.5);

            //skip some empty space
            if (currentPos.z < HiZDepth && (HiZDepth - currentPos.z) > currentStepSize) {
                float leap = max(currentStepSize, (HiZDepth - currentPos.z) * 0.065);
                currentPos += rayDir * leap;
                t += leap;
                continue;
            }

            //no hit possible in front of the 8x8 blk's nearest or past its farthest's band: skip the depth read, step on
            int2 at8 = min(int2(hitPos * BUFFER_SCREEN_SIZE), int2(BUFFER_WIDTH, BUFFER_HEIGHT) - 1) / 8;
            [branch] if (any(at8 != texel8)) { texel8 = at8; bounds8 = tex2Dfetch(sHiZ8, at8).gb; }
            [branch] if (!(currentPos.z <= bounds8.x || bounds8.y < currentPos.z * 0.9))
            {
                float sceneDepth = tex2Dlod(Kernel::sDepth, float4(hitPos, 0, 0)).r;
                float depthDiff = currentPos.z - sceneDepth;
                if (depthDiff > (currentPos.z * (nearStep ? 0.0025 : 0.005)) && depthDiff < (currentPos.z * 0.1)) {
                    float2 sceneUV = hitPos;
                    float3 scenePos = UVToViewSpace(sceneUV, sceneDepth, input);
                    float hitDistance = length(scenePos - startPos);
                    float normalizedDist = hitDistance / globalMaxDistance;
                    occlusion = saturate(1.0 - normalizedDist);
                    occlusion = occlusion * occlusion;
                    //(near) contact band
                    float nearFall = saturate(1.0 - hitDistance / (startPos.z * NEAR_RADIUS));
                    occlusion = saturate(occlusion + NEAR_BOOST * nearFall * nearFall);
                    //from faces turned toward the ray: hit's lit color + last frame's indirect light there (infinite bounce)
                    float3 hitNormal = tex2Dlod(Kernel::sNormals, float4(sceneUV, 0, 0)).rgb;
                    float facing = saturate(dot(hitNormal, -rayDir) * 4.0);
                    float3 hitColor = GetLinearColor(sceneUV, false);
                    float4 hitPrev = tex2Dlod(sFinalPoint, float4(sceneUV, 0, 0)); //last frame's final (blended over the frames)
                    float3 hitIndirect = hitPrev.rgb * (saturate(1.0 - hitPrev.a) / max(AO_INTENSITY, 0.05));
                    bounce = (EstimateDirectLighting(hitColor) + EstimateHitAlbedo(hitColor) * (hitIndirect * INFINITE_BOUNCE))
                           * (occlusion * facing);
                    break;
                }
            }

            currentPos += rayDir * currentStepSize;
            t += currentStepSize;
        }
    }
    return 1.0 - saturate(occlusion * AO_INTENSITY);
}

/*--------------.
| :: SHADERS :: |
'--------------*/
//nearest depth over 8x8 px
float4 PS_HiZ8(VSOUT input) : SV_Target
{
    int2 first = int2(input.vpos.xy) * 8;
    float minDepth = 1.0, ringMin = 1.0, ringMax = 0.0;
    [unroll] for (int y = -1; y <= 8; y++)
        [unroll] for (int x = -1; x <= 8; x++)
        {
            int2 at = clamp(first + int2(x, y), 0, int2(BUFFER_WIDTH, BUFFER_HEIGHT) - 1);
            float d = tex2Dfetch(Kernel::sDepth, at).r;
            bool inner = x >= 0 && x < 8 && y >= 0 && y < 8;
            minDepth = inner ? min(minDepth, d) : minDepth;
            ringMin = min(ringMin, d); ringMax = max(ringMax, d);
        }
    return float4(minDepth, ringMin, ringMax, 0.0);
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

//each txl's geo (nearest pxl)
void PS_TexelGeo(VSOUT input, out float4 geo : SV_Target0)
{
    float2 pixelUV = TexelPixelUV(floor(input.vpos.xy));
    float4 geo0 = tex2Dlod(sGeoPoint, float4(pixelUV, 0, 0));
    float4 geo1 = tex2Dlod(sGeoPoint, float4(pixelUV + float2(BUFFER_PIXEL_SIZE.x, 0.0), 0, 0));
    float4 geo2 = tex2Dlod(sGeoPoint, float4(pixelUV + float2(0.0, BUFFER_PIXEL_SIZE.y), 0, 0));
    float4 geo3 = tex2Dlod(sGeoPoint, float4(pixelUV + BUFFER_PIXEL_SIZE, 0, 0));
    float depth0 = (geo0.a > 0.0) ? geo0.a : 2.0; //no depth counts as farthest
    float depth1 = (geo1.a > 0.0) ? geo1.a : 2.0;
    float depth2 = (geo2.a > 0.0) ? geo2.a : 2.0;
    float depth3 = (geo3.a > 0.0) ? geo3.a : 2.0;
    geo = geo0; float minDepth = depth0;
    [flatten] if (depth1 < minDepth) { geo = geo1; minDepth = depth1; }
    [flatten] if (depth2 < minDepth) { geo = geo2; minDepth = depth2; }
    [flatten] if (depth3 < minDepth) { geo = geo3; }
}

void PS_RayTracer(VSOUT input, out float4 aoOut : SV_Target0, out float4 giOut : SV_Target1)
{
    float2 texel = floor(input.vpos.xy);
    float4 gbuffer = TexelGeo(texel);
    float depth = gbuffer.a;
    //overwrite noise at boundary with clean White, prevents gaps
    aoOut = float4(1.0, 1.0, 0.0, 0.0); //1.0 AO, 1.0 Moment
    giOut = 0.0;
    if (depth >= DEPTH_BOUNDARY) return;
    if (depth == 0) discard;
    //trace from the pxl the txl's geometry was taken from (PS_TexelGeo)
    float2 pixelUV = TexelPixelUV(texel);
    [branch] if (tex2Dlod(sGeoPoint, float4(pixelUV, 0, 0)).a != depth)
    {
        [unroll] for (int k = 1; k < 4; k++)
        {
            float2 candidateUV = TexelPixelUV(texel) + float2(k & 1, k >> 1) * BUFFER_PIXEL_SIZE;
            [flatten] if (tex2Dlod(sGeoPoint, float4(candidateUV, 0, 0)).a == depth) pixelUV = candidateUV;
        }
    }
    float3 bounce;
    float ao = TraceRay(input, pixelUV, gbuffer, bounce);
    float depthFade = CalculateDepthFade(depth);
    ao = lerp(1.0, ao, depthFade);
    bounce *= depthFade;
    float moment = ao * ao;
    float2 flow = GetSurfaceFlow(input.uv, depth);
    float flowMag = length(flow);
    float confidence = tex2D(Kernel::sConfidence, input.uv).x;
    float pixelMag = length(BUFFER_PIXEL_SIZE);
    float kernelPenalty = (flowMag <= pixelMag) ? 1.0 : rcp((flowMag / pixelMag) * 0.05 + 1.0);
    confidence = saturate(confidence / max(kernelPenalty, 0.1));
    confidence = saturate(confidence + log2(2.0 - confidence) * 0.5);
    float keep = confidence * SpeedKeep(flow);
    //the history where this txl's point was, kept only on its surface
    float3 rawHistory; float4 prevGI; float same;
    SampleHistory(input.uv + flow, depth + GetDepthDrift(), rawHistory, prevGI, same);
    if (any(input.uv + flow < 0.0) || any(input.uv + flow > 1.0)) same = 0.0;
    float prevAO = 1.0 - rawHistory.r;
    float prevMoment = 1.0 - rawHistory.g;
    float count = min(rawHistory.b * keep * same + 1.0, 50.0);
    float blendVal = (1.0 - rcp(count)) * same;
    ao = lerp(ao, prevAO, blendVal);
    //a txl starting afresh gets a prior variance, so filter smooths its 1-ray
    moment = lerp(moment, prevMoment, blendVal) + (1.0 - same) * 0.1;
    //max(..., 0.001) to ensure we NEVER write exactly 0.0 again
    //this tells the next frame "I contain data"
    aoOut = float4(max(ao, 0.001), max(moment, 0.001), count, 0.0);
    float bounceLuma = GetLuminance(bounce);
    giOut = float4(lerp(bounce, prevGI.rgb, blendVal), lerp(bounceLuma * bounceLuma, prevGI.a, blendVal) + (1.0 - same) * 0.01);
}

//first level (step 2, on the acc. moments); also keeps this frame's acc. & depth for the next
void PS_ATrousPass1(VSOUT input, out float2 filtered : SV_Target0, out float4 history : SV_Target1,
                    out float4 giFiltered : SV_Target2, out float4 giHistory : SV_Target3, out float prevZ : SV_Target4)
{
    prevZ = TexelGeo(floor(input.vpos.xy)).a;
    float2 centerAO;
    ATrousBoth(sAO1, sGI1, floor(input.vpos.xy), 2.0, true, false, input, filtered, giFiltered, centerAO, giHistory);
    //the variance handed on, widened as far as the txl moves (MotionWiden)
    float motionWiden = MotionWiden(input.uv);
    filtered.g *= motionWiden;
    giFiltered.a *= motionWiden;
    //stored inverted - never exactly 0.0, which the next frame reads as no history
    history = float4(max(1.0 - centerAO.r, 0.0001), max(1.0 - centerAO.g, 0.0001),
                     tex2Dlod(sAO1, float4(TexelUV(floor(input.vpos.xy)), 0, 0)).b, 0.0);
}

//lvls A and B (steps 3 and 9), AO also on same taps
void PS_GIATrousA(VSOUT input, out float2 ao : SV_Target0, out float4 gi : SV_Target1)
{
    float2 centerAO; float4 centerGI;
    ATrousBoth(sAO2Point, sGI2Point, floor(input.vpos.xy), 3.0, false, false, input, ao, gi, centerAO, centerGI);
}

void PS_GIATrousB(VSOUT input, out float2 ao : SV_Target0, out float4 gi : SV_Target1)
{
    float2 centerAO; float4 centerGI;
    ATrousBoth(sAO3Point, sGI3Point, floor(input.vpos.xy), 9.0, false, true, input, ao, gi, centerAO, centerGI);
}

//view's motion along its axis at this block:
//last frame's depth there minus this frame's, where they are close
float2 PS_DepthDrift(VSOUT input) : SV_Target
{
    float2 texel = floor(input.vpos.xy) * 4.0 + 2.0;
    float depth = TexelGeo(texel).a;
    float2 uv = TexelUV(texel);
    float2 prevUV = uv + tex2Dlod(Kernel::sFlow, float4(input.uv, 0, 0)).xy;
    float prevDepth = tex2Dlod(sPrevZ, float4(prevUV, 0, 0)).r;
    bool valid = (depth > 0.0) && (prevDepth > 0.0) && all(prevUV >= 0.0) && all(prevUV <= 1.0)
              && (abs(prevDepth - depth) < 0.25 * min(depth, prevDepth));
    return valid ? float2(prevDepth - depth, 1.0) : 0.0;
}

//last lvl (step 18), AO is on its taps too
float4 PS_GIATrousC(VSOUT input) : SV_Target
{
    return ATrousBothLast(sAO2Point, sGI4Point, floor(input.vpos.xy), 18.0, input);
}

//last frame's final where the pxl's point was
float4 FinalHistory(float2 uv)
{
    float2 pos = uv * BUFFER_SCREEN_SIZE;
    float2 centerPos = floor(pos - 0.5) + 0.5;
    float2 f = pos - centerPos;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 offset12 = w2 / (w12 + 0.00001);
    float2 uv0 = (centerPos - float2(1.0, 0.0) + float2(0.0, offset12.y)) * BUFFER_PIXEL_SIZE;
    float2 uv1 = (centerPos + float2(2.0, 0.0) + float2(0.0, offset12.y)) * BUFFER_PIXEL_SIZE;
    float2 uv2 = (centerPos + float2(offset12.x, -1.0)) * BUFFER_PIXEL_SIZE;
    float2 uv3 = (centerPos + float2(offset12.x, 2.0)) * BUFFER_PIXEL_SIZE;
    float2 uv4 = (centerPos + offset12) * BUFFER_PIXEL_SIZE;
    float k0 = w0.x * w12.y, k1 = w3.x * w12.y, k2 = w12.x * w0.y, k3 = w12.x * w3.y, k4 = w12.x * w12.y;
    float ks = max(k0 + k1 + k2 + k3 + k4, 0.0001);
    float4 c0 = tex2Dlod(sFinalPrev, float4(uv0, 0, 0));
    float4 c1 = tex2Dlod(sFinalPrev, float4(uv1, 0, 0));
    float4 c2 = tex2Dlod(sFinalPrev, float4(uv2, 0, 0));
    float4 c3 = tex2Dlod(sFinalPrev, float4(uv3, 0, 0));
    float4 c4 = tex2Dlod(sFinalPrev, float4(uv4, 0, 0));
    float4 r = (c0 * k0 + c1 * k1 + c2 * k2 + c3 * k3 + c4 * k4) / ks;
    return clamp(r, min(min(min(c0, c1), min(c2, c3)), c4), max(max(max(c0, c1), max(c2, c3)), c4));
}

float4 LineBoxClip(float4 history, float4 mean, float4 lo, float4 hi)
{
    float4 dir = mean - history;
    dir = (abs(dir) < 0.0001) ? 0.0001 : dir;
    float4 tMin = (lo - history) / dir;
    float4 tMax = (hi - history) / dir;
    float4 t1 = min(tMin, tMax);
    float4 t2 = max(tMin, tMax);
    float tEnter = max(max(t1.x, t1.y), max(t1.z, t1.w));
    float tExit = min(min(t2.x, t2.y), min(t2.z, t2.w));
    float t = (tEnter > tExit) ? 1.0 : clamp(tEnter, 0.0, 1.0);
    return history + dir * t;
}

//final FULL-res pass: upsample & TRAA style filter
float4 PS_Final(VSOUT input) : SV_Target
{
    float4 geo = tex2Dlod(sGeoPoint, float4(input.uv, 0, 0));
    float depth = geo.a;
    [branch] if (depth == 0 || depth >= DEPTH_BOUNDARY) return float4(0.0, 0.0, 0.0, 1.0);
    float4 cur = UpsampleAOGI(input.uv, geo, input);
    float2 texel = floor(floor(input.vpos.xy) * 0.5);
    float4 sum = 0.0; float4 sum2 = 0.0;
    [unroll] for (int y = -1; y <= 1; y++)
        [unroll] for (int x = -1; x <= 1; x++)
        {
            float4 v = tex2Dlod(sGI3Point, float4(TexelUV(texel + float2(x, y)), 0, 0));
            sum += v; sum2 += v * v;
        }
    float4 mean = sum / 9.0;
    float4 sigma = sqrt(max(sum2 / 9.0 - mean * mean, 0.0));
    float4 margin = float4(FINAL_MARGIN_GI * max(mean.rgb, 0.0), FINAL_MARGIN_AO);
    float4 lo = mean - 1.25 * sigma - margin;
    float4 hi = mean + 1.25 * sigma + margin;
    float2 flow = tex2Dlod(sFlowLinear, float4(input.uv, 0, 0)).xy;
    float2 prevUV = input.uv + flow;
    float weight = (all(prevUV >= 0.0) && all(prevUV <= 1.0)) ? 0.9 * SpeedKeep(flow) : 0.0; //0.9 = MOTION_STABILIZER
    float confidence = tex2Dlod(Kernel::sConfidence, float4(input.uv, 0, 0)).x;
    weight *= saturate(confidence + log2(2.0 - confidence) * 0.5);
    float4 history = LineBoxClip(FinalHistory(prevUV), mean, lo, hi);
    return lerp(cur, history, weight);
}

//kept for the next frame
float4 PS_FinalKeep(VSOUT input) : SV_Target
{
    return tex2Dlod(sFinalPoint, float4(input.uv, 0, 0));
}

float4 PS_ToDisplay(VSOUT input) : SV_Target
{
    float4 geo = tex2Dlod(sGeoPoint, float4(input.uv, 0, 0));
    float depth = geo.a;
    float4 aoGI = tex2Dlod(sFinalPoint, float4(input.uv, 0, 0));
    float ao = aoGI.a;
    //the bounce back from its ratio (RCV) x the occlusion the filtered AO stands for
    float3 gi = aoGI.rgb * (saturate(1.0 - ao) / max(AO_INTENSITY, 0.05)) * GI_INTENSITY * 9.0; //9.0 = GI_INTENSITY_SCALER
    gi += sRGBtoLinearAccurate(AMBIENT_COLOR) * (AMBIENT_INTENSITY * ao);
    if (DEBUG_VIEW == 1) {
        #if BUFFER_COLOR_SPACE > 1
            return float4(ToOutputColorspace(ao.xxx, true), 1.0);
        #else
            return float4(ao.xxx, 1.0);
        #endif
    }
    float3 albedo = EstimateAlbedo(input.uv);
    if (DEBUG_VIEW == 2) return float4(ToOutputColorspace(gi, false), 1.0);
    if (DEBUG_VIEW == 3) return float4(ToOutputColorspace(albedo, false), 1.0);
    if (DEBUG_VIEW == 4) return float4(ToOutputColorspace(albedo * gi, false), 1.0);
    if (depth == 0 || depth >= DEPTH_BOUNDARY) discard;
    float localMean = DecodeKernelLuma(tex2Dlod(Kernel::sCurrLuma, float4(input.uv, 0, 3)).r);
    float aoLit = lerp(ao, 1.0, smoothstep(0.35, 0.70, localMean));
    float3 base = GetLinearColor(input.uv, false);
    float fogBlock = GetFogBlock(input.uv, base);
    aoLit = lerp(aoLit, 1.0, fogBlock);
    gi *= 1.0 - fogBlock;
    #if TONEMAPPER == 1
        base /= max(1.0 - GetLuminance(base), 0.001);
    #endif
    base *= aoLit;
    base += albedo * gi;
    #if TONEMAPPER == 1
        base /= 1.0 + GetLuminance(base);
    #endif
    return float4(ToOutputColorspace(base, false), 1.0);
}

/*----------------.
| :: TECHNIQUE :: |
'----------------*/
technique Lumenite_LSGI <
    ui_label = "LUMENITE: LSGI";
    ui_tooltip = "Large-Scale Ray Traced Global Illumination (Screen Space).";
>
{
    pass { VertexShader = VS; PixelShader = PS_HiZ8;        RenderTarget  = tHiZ8; }
    pass { VertexShader = VS; PixelShader = PS_HiZ32;       RenderTarget  = tHiZMip5; }
    pass { VertexShader = VS; PixelShader = PS_TexelGeo;    RenderTarget  = tGeoHalf; }

    pass { VertexShader = VS; PixelShader = PS_DepthDrift;  RenderTarget  = tDrift; }
    pass { VertexShader = VS; PixelShader = PS_RayTracer;   RenderTarget0 = tAO1; RenderTarget1 = tGI1; }
    pass { VertexShader = VS; PixelShader = PS_ATrousPass1; RenderTarget0 = tAO2; RenderTarget1 = tPrevAO; RenderTarget2 = tGI2; RenderTarget3 = tPrevGI; RenderTarget4 = tPrevZ; }
    pass { VertexShader = VS; PixelShader = PS_GIATrousA;   RenderTarget0 = tAO3; RenderTarget1 = tGI3; }
    pass { VertexShader = VS; PixelShader = PS_GIATrousB;   RenderTarget0 = tAO2; RenderTarget1 = tGI4; }
    pass { VertexShader = VS; PixelShader = PS_GIATrousC;   RenderTarget  = tGI3; }
    pass { VertexShader = VS; PixelShader = PS_Final;       RenderTarget  = tFinal; }
    pass { VertexShader = VS; PixelShader = PS_ToDisplay;                          }
    pass { VertexShader = VS; PixelShader = PS_FinalKeep;   RenderTarget  = tFinalPrev; }
}

}
