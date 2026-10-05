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


        Filename   : lumenite_Kernel.fx
        Version    : 2026.10.05
        Author     : Afzaal (Kaidō)
        Description: Pre-effect for various LumeniteFX shaders.
        License    : AGNYA License (https://github.com/nvb-uy/AGNYA-License)

        ========================================================================
*/

/*------------------.
| :: DEFINITIONS :: |
'------------------*/
#define FOV 60.0
#define NEAR_PLANE 0.01

#ifndef IMAGE_SPACE
    #define IMAGE_SPACE 0
#endif

#ifndef DEBUG_KERNEL
    #define DEBUG_KERNEL 0
#endif

#ifndef SMOOTH_NORMALS
    #define SMOOTH_NORMALS 0
#endif

#define RES_SCALE ((BUFFER_HEIGHT) / 2160.0) //DO NOT modify this

#ifndef FOG_MASK
    #define FOG_MASK 0
#endif

#ifndef CEIL_DIV
    #define CEIL_DIV(x, g) (((x) + (g) - 1) / (g))
#endif

//1/4 working grid and the 4x4 reduction chain built on it
#define FOG_GRID_W  CEIL_DIV(BUFFER_WIDTH, 4)
#define FOG_GRID_H  CEIL_DIV(BUFFER_HEIGHT, 4)
#define REDUCE1_W   CEIL_DIV(FOG_GRID_W, 4)
#define REDUCE1_H   CEIL_DIV(FOG_GRID_H, 4)
#define REDUCE2_W   CEIL_DIV(REDUCE1_W, 4)
#define REDUCE2_H   CEIL_DIV(REDUCE1_H, 4)
#define REDUCE3_W   CEIL_DIV(REDUCE2_W, 4)
#define REDUCE3_H   CEIL_DIV(REDUCE2_H, 4)
#define REDUCE4_W   CEIL_DIV(REDUCE3_W, 4) //<= 8 up to 8K, read whole by the final pass
#define REDUCE4_H   CEIL_DIV(REDUCE3_H, 4)

/*--------------.
| :: HEADERS :: |
'--------------*/
#include "ReShade.fxh"
// #if DEBUG_KERNEL
//     #include "DrawText.fxh"
// #endif
#include "./include/lumenite_ColorManagement.fxh"
#include "./include/lumenite_Projections.fxh"
#include "./include/lumenite_Helpers.fxh"
#include "./include/lumenite_Compute.fxh"

/*---------------.
| :: UNIFORMS :: |
'---------------*/
#if DEBUG_KERNEL
    uniform int DEBUG_VIEW <
        ui_type = "combo";
        ui_items = "Split View\0"
                   "Normals/Depth\0"
                   "Optical Flow\0"
                   "Motion Vectors\0"
                   "Motion Confidence\0"
                   "Fog Mask\0"
                   "Dehaze Preview\0"
                   ;
        ui_label = "Debug View";
        ui_category = "Kernel";
    > = 0;
#endif

#if IMAGE_SPACE == 0
    #if SMOOTH_NORMALS
        uniform float LUMA_DETAIL <
            ui_type = "drag";
            ui_min = -2.0; ui_max = 2.0;
            ui_label = "Surface Relief";
            ui_tooltip = "How much texture gets carved into smoothed normals. sign inverts the relief.";
        > = 0.0;

        uniform int LUMA_DETAIL_LOD <
            ui_type = "slider";
            ui_min = 0; ui_max = 4; ui_step = 1;
            ui_label = "Texture LOD";
            ui_tooltip = "1 = finest carving, 2 = fine relief, 4 = broad folds";
        > = 2;
    #endif
#endif

namespace Kernel {

/*---------------------.
| :: RENDER TARGETS :: |
'---------------------*/

texture2D tFlow { Width = BUFFER_WIDTH/8; Height = BUFFER_HEIGHT/8; Format = RG16F; };
sampler2D sFlow { Texture = tFlow; MagFilter = POINT; MinFilter = POINT; };

texture2D tConfidence { Width = BUFFER_WIDTH/8; Height = BUFFER_HEIGHT/8; Format = R16F; };
sampler2D sConfidence { Texture = tConfidence; };

texture tNormals { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; MipLevels = 4; };
sampler sNormals { Texture = tNormals; };

#if IMAGE_SPACE == 0
    #if SMOOTH_NORMALS
        texture tGuideNormals { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
        sampler sGuideNormals { Texture = tGuideNormals; };

        texture texHRAN_H0 { Width = BUFFER_WIDTH/2; Height = BUFFER_HEIGHT/2; Format = RGBA16F; };
        sampler sHRAN_H0   { Texture = texHRAN_H0; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
        texture texHRAN_HA { Width = BUFFER_WIDTH/2; Height = BUFFER_HEIGHT/2; Format = RGBA16F; };
        sampler sHRAN_HA   { Texture = texHRAN_HA; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
        texture texHRAN_HB { Width = BUFFER_WIDTH/2; Height = BUFFER_HEIGHT/2; Format = RGBA16F; };
        sampler sHRAN_HB   { Texture = texHRAN_HB; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
    #endif
#endif

texture2D tDepth { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16F; MipLevels = 4; };
sampler2D sDepth { Texture = tDepth; };

texture2D tCurrLuma { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16F; MipLevels = 8; };
sampler2D sCurrLuma { Texture = tCurrLuma; MagFilter = LINEAR; MinFilter = LINEAR; MipFilter = LINEAR; AddressU = CLAMP; AddressV = CLAMP; AddressW = CLAMP; };

texture2D tPrevLuma { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16F; MipLevels = 8; };
sampler2D sPrevLuma { Texture = tPrevLuma; MagFilter = LINEAR; MinFilter = LINEAR; MipFilter = LINEAR; AddressU = CLAMP; AddressV = CLAMP; AddressW = CLAMP; };

texture2D tFlow128 { Width = BUFFER_WIDTH/128; Height = BUFFER_HEIGHT/128; Format = RG16F; };
sampler2D sFlow128 { Texture = tFlow128; MagFilter = POINT; MinFilter = POINT; AddressU = CLAMP; AddressV = CLAMP; AddressW = CLAMP; };

texture2D tFlow64A { Width = BUFFER_WIDTH/64; Height = BUFFER_HEIGHT/64; Format = RG16F; };
sampler2D sFlow64A { Texture = tFlow64A; MagFilter = POINT; MinFilter = POINT; AddressU = CLAMP; AddressV = CLAMP; AddressW = CLAMP; };
texture2D tFlow64B { Width = BUFFER_WIDTH/64; Height = BUFFER_HEIGHT/64; Format = RG16F; };
sampler2D sFlow64B { Texture = tFlow64B; MagFilter = POINT; MinFilter = POINT; AddressU = CLAMP; AddressV = CLAMP; AddressW = CLAMP; };

texture2D tFlow32A { Width = BUFFER_WIDTH/32; Height = BUFFER_HEIGHT/32; Format = RG16F; };
sampler2D sFlow32A { Texture = tFlow32A; MagFilter = POINT; MinFilter = POINT; AddressU = CLAMP; AddressV = CLAMP; AddressW = CLAMP; };
texture2D tFlow32B { Width = BUFFER_WIDTH/32; Height = BUFFER_HEIGHT/32; Format = RG16F; };
sampler2D sFlow32B { Texture = tFlow32B; MagFilter = POINT; MinFilter = POINT; AddressU = CLAMP; AddressV = CLAMP; AddressW = CLAMP; };

texture2D tFlow16A { Width = BUFFER_WIDTH/16; Height = BUFFER_HEIGHT/16; Format = RG16F; };
sampler2D sFlow16A { Texture = tFlow16A; MagFilter = POINT; MinFilter = POINT; AddressU = CLAMP; AddressV = CLAMP; AddressW = CLAMP; };
texture2D tFlow16B { Width = BUFFER_WIDTH/16; Height = BUFFER_HEIGHT/16; Format = RG16F; };
sampler2D sFlow16B { Texture = tFlow16B; MagFilter = POINT; MinFilter = POINT; AddressU = CLAMP; AddressV = CLAMP; AddressW = CLAMP; };

texture2D tFlow8 { Width = BUFFER_WIDTH/8; Height = BUFFER_HEIGHT/8; Format = RG16F; };
sampler2D sFlow8 { Texture = tFlow8; MagFilter = POINT; MinFilter = POINT; AddressU = CLAMP; AddressV = CLAMP; AddressW = CLAMP; };

texture2D tPrevFrameFlow { Width = BUFFER_WIDTH/8; Height = BUFFER_HEIGHT/8; Format = RG16F; };
sampler2D sPrevFrameFlow { Texture = tPrevFrameFlow; MagFilter = POINT; MinFilter = POINT; };

texture2D tPrevConfidence { Width = BUFFER_WIDTH/8; Height = BUFFER_HEIGHT/8; Format = R16F; };
sampler2D sPrevConfidence { Texture = tPrevConfidence; };

//r: dark channel of color (working space), g: raw dark channel (display-linear, airlight key)
texture2D tDarkChannel         { Width = FOG_GRID_W; Height = FOG_GRID_H; Format = RG16F; };
sampler2D sDarkChannel         { Texture = tDarkChannel; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
//brightest pixel of each 4x4 block (display-linear), the airlight candidate color
texture2D tBrightestColor      { Width = FOG_GRID_W; Height = FOG_GRID_H; Format = RGBA16F; };
sampler2D sBrightestColor      { Texture = tBrightestColor; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
texture2D tDarkChannelRowMin   { Width = FOG_GRID_W; Height = FOG_GRID_H; Format = RG16F; };
sampler2D sDarkChannelRowMin   { Texture = tDarkChannelRowMin; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
//r: transmission after temporal (guided filter input), g: patch-min airlight key
texture2D tTransmission        { Width = FOG_GRID_W; Height = FOG_GRID_H; Format = RG16F; };
sampler2D sTransmission        { Texture = tTransmission; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
//guided filter moments (I, p, I*I, I*p): 32F tex was necessary here
texture2D tGuideMoments        { Width = FOG_GRID_W; Height = FOG_GRID_H; Format = RGBA32F; };
sampler2D sGuideMoments        { Texture = tGuideMoments; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
texture2D tGuideMomentsRowMean { Width = FOG_GRID_W; Height = FOG_GRID_H; Format = RGBA32F; };
sampler2D sGuideMomentsRowMean { Texture = tGuideMomentsRowMean; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
//guided filter coefficients (a, b)
texture2D tGuideCoeffs         { Width = FOG_GRID_W; Height = FOG_GRID_H; Format = RG16F; };
sampler2D sGuideCoeffs         { Texture = tGuideCoeffs; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
texture2D tGuideCoeffsRowMean  { Width = FOG_GRID_W; Height = FOG_GRID_H; Format = RG16F; };
sampler2D sGuideCoeffsRowMean  { Texture = tGuideCoeffsRowMean; AddressU = CLAMP; AddressV = CLAMP; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
texture2D tGuideCoeffsMean     { Width = FOG_GRID_W; Height = FOG_GRID_H; Format = RG16F; };
sampler2D sGuideCoeffsMean     { Texture = tGuideCoeffsMean; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; MipFilter = LINEAR; };
//reduction chain: rgba = (candidate color, key), rg = (sum of haze, count)
texture2D tReduceBest1         { Width = REDUCE1_W; Height = REDUCE1_H; Format = RGBA16F; };
sampler2D sReduceBest1         { Texture = tReduceBest1; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
texture2D tReduceSum1          { Width = REDUCE1_W; Height = REDUCE1_H; Format = RG32F; };
sampler2D sReduceSum1          { Texture = tReduceSum1; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
texture2D tReduceBest2         { Width = REDUCE2_W; Height = REDUCE2_H; Format = RGBA16F; };
sampler2D sReduceBest2         { Texture = tReduceBest2; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
texture2D tReduceSum2          { Width = REDUCE2_W; Height = REDUCE2_H; Format = RG32F; };
sampler2D sReduceSum2          { Texture = tReduceSum2; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
texture2D tReduceBest3         { Width = REDUCE3_W; Height = REDUCE3_H; Format = RGBA16F; };
sampler2D sReduceBest3         { Texture = tReduceBest3; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
texture2D tReduceSum3          { Width = REDUCE3_W; Height = REDUCE3_H; Format = RG32F; };
sampler2D sReduceSum3          { Texture = tReduceSum3; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
texture2D tReduceBest4         { Width = REDUCE4_W; Height = REDUCE4_H; Format = RGBA16F; };
sampler2D sReduceBest4         { Texture = tReduceBest4; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
texture2D tReduceSum4          { Width = REDUCE4_W; Height = REDUCE4_H; Format = RG32F; };
sampler2D sReduceSum4          { Texture = tReduceSum4; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
//texel 0: airlight (display-linear rgb) + mean haze D, texel 1: frame stamp + airlight-was-valid flag
texture2D tFogState            { Width = 2; Height = 1; Format = RGBA32F; };
sampler2D sFogState            { Texture = tFogState; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
texture2D tPrevFogState        { Width = 2; Height = 1; Format = RGBA32F; };
sampler2D sPrevFogState        { Texture = tPrevFogState; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };

texture2D tPrevHaze            { Width = FOG_GRID_W; Height = FOG_GRID_H; Format = R16F; };
sampler2D sPrevHaze            { Texture = tPrevHaze; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; MipFilter = LINEAR; };

texture2D tFogMask             { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16F; };
sampler2D sFogMask             { Texture = tFogMask; };

/*--------------.
| :: HELPERS :: |
'--------------*/
float3 GetColor(float2 uv)
{
    return tex2Dlod(ReShade::BackBuffer, float4(uv, 0, 0)).rgb;
}

float3 DepthGradient(float t, float2 uv)
{
    //grayscale: close=dark, far=bright
    float3 depth = saturate(t).xxx;
    const float ditherBit = 8.0;
    float gridPos = frac(dot(uv, (BUFFER_SCREEN_SIZE * float2(1.0 / 16.0, 10.0 / 36.0)) + 0.25));
    float ditherShift = 0.25 * (1.0 / (pow(2.0, ditherBit) - 1.0));
    float3 ditherShiftRGB = float3(ditherShift, -ditherShift, ditherShift); //subpixel dithering
    ditherShiftRGB = lerp(2.0 * ditherShiftRGB, -2.0 * ditherShiftRGB, gridPos);
    return depth + ditherShiftRGB;
}

float3 MotionToColor(float2 motion)
{
    float angle = atan2(-motion.y, -motion.x) / 6.283 + 0.5;
    float rawLength = length(motion) / (15.0 * BUFFER_PIXEL_SIZE.x);
    float compressed = rawLength / (1.0 + rawLength * 1.4);  //asymptotic squash
    float boosted = pow(compressed, 0.5);  //lift shadows
    float magnitude = saturate(lerp(compressed, boosted, saturate(rawLength * 3.0)));
    float3 hsv = float3(angle, 1, magnitude);
    float4 K = float4(1, 2/3.0, 1/3.0, 3);
    float3 p = abs(frac(hsv.xxx + K.xyz) * 6 - K.www);
    return hsv.z * lerp(K.xxx, clamp(p - K.xxx, 0, 1), hsv.y) + 0.1;
}

float SegmentDist(float2 p, float2 a, float2 b) //anti-aliased distance from point p to segment a-b
{
    float2 pa = p - a;
    float2 ba = b - a;
    float  h  = saturate(dot(pa, ba) / (dot(ba, ba) + EPSILON));
    return length(pa - ba * h);
}

float4 DrawMotionVectors(float2 uv)
{
    static const int    GATHER          = 2;    //cell radius searched (5x5); always MAX_LENGTH <= GATHER*GRID_SPACING
    static const float  GRID_SPACING    = 16.0; //px between grid nodes
    static const float  DOT_RADIUS      = 2.0;  //px radius of node dots
    static const float  GRID_OPACITY    = 0.20; //0..1 lattice visibility
    static const float3 GRID_TINT       = float3(0.55, 0.55, 0.60);

    static const float SHAFT_THICKNESS = 1.5;   //px half-width of shaft (larger)
    static const float HEAD_LENGTH     = 6.0;   //px length of arrowhead (larger)
    static const float HEAD_HALF_WIDTH = 4.0;   //px half-width of head base (larger)
    static const float MIN_LENGTH      = 7.0;   //px shortest arrow
    static const float MAX_LENGTH      = 30.0;  //px longest arrow (<= GATHER*GRID_SPACING)
    static const float LENGTH_SCALE    = 2.5;   //arrow px per motion px (elongation gain)
    static const float AA              = 0.9;   //px edge softness

    float3 baseColor = GetColor(uv);
    float2 pixelPos  = uv * BUFFER_SCREEN_SIZE;

    //dotted grid
    float2 g       = pixelPos / GRID_SPACING;
    float2 nearest = round(g) * GRID_SPACING;           //nearest node centre, px
    float  dDot    = length(pixelPos - nearest);        //px distance to that node
    float  gridCov = (1.0 - smoothstep(DOT_RADIUS - AA, DOT_RADIUS + AA, dDot)) * GRID_OPACITY;

    float  bestCov   = 0.0;
    float3 bestColor = float3(0.0, 0.0, 0.0);

    //union of arrows from the (2*GATHER+1)^2 nearest nodes (roots on grid crossings)
    float2 baseNode = round(g);
    [unroll] for (int ny = -GATHER; ny <= GATHER; ny++)
    [unroll] for (int nx = -GATHER; nx <= GATHER; nx++)
    {
        float2 rootPx   = (baseNode + float2(nx, ny)) * GRID_SPACING; //node sits on a crossing
        float2 rootUV   = rootPx * BUFFER_PIXEL_SIZE;

        float2 motion   = tex2Dlod(sFlow, float4(rootUV, 0, 0)).xy;
        float2 motionPx = motion * BUFFER_SCREEN_SIZE;
        float  magPx    = length(motionPx);
        bool   valid    = (magPx >= 0.4) && (tex2Dlod(sDepth, float4(rootUV, 0, 0)).r < 0.999);

        float  len      = clamp(magPx * LENGTH_SCALE, MIN_LENGTH, MAX_LENGTH); //elongates with this node's motion
        float2 fwd      = -motionPx / (magPx + EPSILON); //negate for forward motion
        float2 tip      = rootPx + fwd * len;
        float2 perp     = float2(-fwd.y, fwd.x);

        //shaft
        float2 shaftEnd = rootPx + fwd * max(len - HEAD_LENGTH, 0.0);
        float  dShaft   = SegmentDist(pixelPos, rootPx, shaftEnd);
        float  covShaft = 1.0 - smoothstep(SHAFT_THICKNESS - AA, SHAFT_THICKNESS + AA, dShaft);

        //head
        float2 toTip    = pixelPos - tip;
        float  along    = dot(toTip, -fwd);
        float  side     = abs(dot(toTip, perp));
        float  halfW    = HEAD_HALF_WIDTH * saturate(along / HEAD_LENGTH);
        float  covAlong = smoothstep(-AA, AA, along) * (1.0 - smoothstep(HEAD_LENGTH - AA, HEAD_LENGTH + AA, along));
        float  covHead  = covAlong * (1.0 - smoothstep(halfW - AA, halfW + AA, side));

        float  cov      = max(covShaft, covHead) * (valid ? 1.0 : 0.0);
        if (cov > bestCov) { bestCov = cov; bestColor = MotionToColor(motion); }
    }

    float3 outColor = lerp(baseColor, GRID_TINT, gridCov); //lattice underneath
    outColor        = lerp(outColor, bestColor, bestCov);  //arrows on top
    return float4(outColor, 1.0);
}

float ZMSAD(sampler2D currLumaSrc, sampler2D prevLumaSrc, float2 posA, float2 posB, float2 texelSize, uint mip)
{
    static const int2 offsets[9] = {
                                int2(0, 3),
                                int2(0, 1),
        int2(-3,0), int2(-1,0), int2(0, 0), int2(1,0), int2(3,0),
                                int2(0,-1),
                                int2(0,-3)
    };

    //gather samples and calculate the mean for each patch
    float samplesA[9], samplesB[9];
    float meanA = 0.0, meanB = 0.0;

    [unroll] for(int i = 0; i < 9; i++) {
        float2 offset = float2(offsets[i]) * texelSize;
        samplesA[i] = tex2Dlod(currLumaSrc, float4(posA + offset, 0, mip)).r;
        samplesB[i] = tex2Dlod(prevLumaSrc, float4(posB + offset, 0, mip)).r;
        meanA += samplesA[i];
        meanB += samplesB[i];
    }
    meanA /= 9.0;
    meanB /= 9.0;

    //SAD on the normalized samples
    float err = 0.0;
    [unroll] for(int i = 0; i < 9; i++)
        err += abs((samplesA[i] - meanA) - (samplesB[i] - meanB));

    return ((err / 9.0) + EPSILON);
}

float2 Median9(sampler2D flowSrc, float2 uv, float2 texelSize, uint mip)
{
    float2 v[9];
    int idx = 0;
    [unroll] for(int dy = -1; dy <= 1; dy++) for(int dx = -1; dx <= 1; dx++)
            v[idx++] = tex2Dlod(flowSrc, float4(uv + float2(dx, dy) * texelSize, 0, mip)).xy;

    //bubble sort ensures the Median lands in v[4], only needs 5 passes
    //indices 4,5,6,7,8 contain the 5 largest items, so v[4] is the median
    [unroll] for(int k = 0; k < 5; k++) for(int i = 0; i < 8 - k; i++) { //checks decrease as right side gets sorted
            float2 a = v[i];
            float2 b = v[i+1];
            v[i]   = min(a, b);
            v[i+1] = max(a, b);
    }

    return v[4];
}

float2 BilateralMedian9(sampler2D flowSrc, float2 uv, float2 texelSize, uint mip)
{
    static const int2 DENSE_3X3[9] = {
        int2(-1,-1), int2(0,-1), int2(1,-1),
        int2(-1, 0), int2(0, 0), int2(1, 0),
        int2(-1, 1), int2(0, 1), int2(1, 1)
    };
    float lumaC = tex2Dlod(sCurrLuma, float4(uv,                                 0, mip)).x;
    float lumaW = tex2Dlod(sCurrLuma, float4(uv + float2(-1.0, 0.0) * texelSize, 0, mip)).x;
    float lumaE = tex2Dlod(sCurrLuma, float4(uv + float2( 1.0, 0.0) * texelSize, 0, mip)).x;
    float lumaN = tex2Dlod(sCurrLuma, float4(uv + float2( 0.0,-1.0) * texelSize, 0, mip)).x;
    float lumaS = tex2Dlod(sCurrLuma, float4(uv + float2( 0.0, 1.0) * texelSize, 0, mip)).x;
    //central-difference gradient, wider baseline than quad ddx/ddy, derived from real samples
    float dxLuma = (lumaE - lumaW) * 0.5;
    float dyLuma = (lumaS - lumaN) * 0.5;
    float2 v[9];
    uint validCount = 0;
    [unroll] for (int i = 0; i < 9; i++) {
        int2 off = DENSE_3X3[i];
        float2 sampleUV = uv + float2(off) * texelSize;
        //cardinals + center use sampled luma; diagonals get linear prediction
        float sampleLuma = lumaC; //covers (0,0)
        if      (off.x == -1 && off.y ==  0) sampleLuma = lumaW;
        else if (off.x ==  1 && off.y ==  0) sampleLuma = lumaE;
        else if (off.x ==  0 && off.y == -1) sampleLuma = lumaN;
        else if (off.x ==  0 && off.y ==  1) sampleLuma = lumaS;
        else if (off.x != 0 && off.y != 0)   sampleLuma = lumaC + float(off.x) * dxLuma + float(off.y) * dyLuma;
        bool isValid = abs(lumaC - sampleLuma) <= 0.05;
        v[i] = isValid ? tex2Dlod(flowSrc, float4(sampleUV, 0, 0)).xy : float2(1e38, 1e38);
        validCount += uint(isValid);
    }
    if(validCount < 3u) return v[4];
    //right-to-left bubble: smallest reaches v[0] per pass; after 5 passes, v[0..4] sorted ascending
    [unroll] for(int k = 0; k < 5; k++) for(int j = 7; j >= k; j--) {
            float2 a = v[j];
            float2 b = v[j+1];
            v[j]   = min(a, b);
            v[j+1] = max(a, b);
    }
    uint medianIdx = validCount / 2u;
    float2 result = v[1]; //fallback for validCount == 3 (medianIdx 1)
    if (medianIdx == 2u) result = v[2];
    if (medianIdx == 3u) result = v[3];
    if (medianIdx == 4u) result = v[4];
    return result;
}

float2 ATrousFilter(sampler2D motionSrc, float2 uv, uint dilation, uint mip)
{
    static const int2 offsets[8] = { int2(-1,-1), int2(0,-1), int2(1,-1),
                                     int2(-1, 0),             int2(1, 0),
                                     int2(-1, 1), int2(0, 1), int2(1, 1) };
    float centerLuma  = tex2Dlod(sCurrLuma, float4(uv, 0, mip)).r;
    #if IMAGE_SPACE == 0
        float centerDepth = tex2Dlod(sDepth, float4(uv, 0, mip)).r;
    #endif
    float2 centerFlow = tex2Dlod(motionSrc, float4(uv, 0, 0)).xy;
    float  centerConf = max(tex2Dlod(sConfidence, float4(uv, 0, 0)).r, 0.01); //0.01 floor prevents NaN if conf hits 0
    float2 sum = centerFlow * centerConf;
    float  totalWeight = centerConf;
    [unroll] for (int i = 0; i < 8; i++) {
        float2 sampleUV     = uv + float2(offsets[i]) * dilation * BUFFER_PIXEL_SIZE * 8.0; //*8 = stride of flow grid
        float2 sampleFlow   = tex2Dlod(motionSrc, float4(sampleUV, 0, 0)).xy;

        float  sampleConf   = tex2Dlod(sConfidence, float4(sampleUV, 0, 0)).r;
        float  confWeight   = pow(sampleConf, 3.0);

        float discontinuityGate;
        #if IMAGE_SPACE == 0
            float  sampleDepth  = tex2Dlod(sDepth, float4(sampleUV, 0, mip)).r;
            float absDepthDiff  = abs(centerDepth - sampleDepth);
            float depthWeight   = (absDepthDiff < 0.003) ? 1.0 : 0.0;
            discontinuityGate = depthWeight;
        #else
            float2 flowDeltaPx = (sampleFlow - centerFlow) * BUFFER_SCREEN_SIZE; //measure flow disagreement in full-res px
            float rawMotionGate = exp2(-dot(flowDeltaPx, flowDeltaPx) / (0.01 + EPSILON));
            float motionGate = lerp(1.0, rawMotionGate, saturate(centerConf)); //if center flow is unreliable; relax gate so confident neighbors repair it
            discontinuityGate = motionGate;
        #endif

        float  sampleLuma   = tex2Dlod(sCurrLuma, float4(sampleUV, 0, mip)).r;
        float absLumaDiff   = abs(centerLuma - sampleLuma);
        float lumaWeight    = saturate(1.0 - absLumaDiff * 10.0); //10.0: scale, 4.0: sharpness

        float weight        = confWeight * lumaWeight * discontinuityGate;
        sum                += sampleFlow * weight;
        totalWeight        += weight;
    }
    return sum / (totalWeight + EPSILON);
}

float2 UpscaleFlow(sampler2D coarseSrc, sampler2D currLumaSrc, sampler2D prevLumaSrc, float2 uv, float2 texelSize, uint mip)
{
    if(FRAME_COUNT == 0) return float2(0, 0);

    float2 coarseTexelSize = rcp(float2(tex2Dsize(coarseSrc, 0)));
    //pool candidates for tournament selection. order matters here
    float2 candidates[10];
    candidates[0]  = tex2D(coarseSrc, uv).xy ;
    candidates[1]  = tex2D(coarseSrc, uv + float2(0, -coarseTexelSize.y)).xy ;
    candidates[2]  = tex2D(coarseSrc, uv + float2(0,  coarseTexelSize.y)).xy ;
    candidates[3]  = tex2D(coarseSrc, uv - float2(coarseTexelSize.x, 0)).xy ;
    candidates[4]  = tex2D(coarseSrc, uv + float2(coarseTexelSize.x, 0)).xy ;
    candidates[5]  = tex2D(coarseSrc, uv + float2(-coarseTexelSize.x, -coarseTexelSize.y)).xy ;
    candidates[6]  = tex2D(coarseSrc, uv + float2( coarseTexelSize.x, -coarseTexelSize.y)).xy ;
    candidates[7]  = tex2D(coarseSrc, uv + float2(-coarseTexelSize.x,  coarseTexelSize.y)).xy ;
    candidates[8]  = tex2D(coarseSrc, uv + float2(coarseTexelSize.x, coarseTexelSize.y)).xy ;
    candidates[9] = tex2D(sPrevFrameFlow, uv).xy;

    float minCost = 1e6;
    float2 prediction = candidates[0];
    [loop] for (int i = 0; i < 10; i++) {
        float cost = ZMSAD(currLumaSrc, prevLumaSrc, uv, uv + candidates[i], texelSize, mip);
        if (cost < minCost) {
            minCost = cost;
            prediction = candidates[i];
        }
    }

    //refinement with parabolic fitting
    float costLeft   = ZMSAD(currLumaSrc, prevLumaSrc, uv, uv + prediction - float2(texelSize.x, 0), texelSize, mip);
    float costRight  = ZMSAD(currLumaSrc, prevLumaSrc, uv, uv + prediction + float2(texelSize.x, 0), texelSize, mip);
    float costDown   = ZMSAD(currLumaSrc, prevLumaSrc, uv, uv + prediction - float2(0, texelSize.y), texelSize, mip);
    float costUp     = ZMSAD(currLumaSrc, prevLumaSrc, uv, uv + prediction + float2(0, texelSize.y), texelSize, mip);
    //sub-pixel offset (parabolic fitting)
    float2 subpixelOffset;
    subpixelOffset.x = (costLeft - costRight) / (4.0 * (costLeft + costRight - 2.0 * minCost) + EPSILON); //EPSILON for flat surface handling
    subpixelOffset.y = (costDown - costUp)    / (4.0 * (costDown + costUp    - 2.0 * minCost) + EPSILON);
    //clamp offset to a reasonable range
    subpixelOffset = clamp(subpixelOffset, -0.5, 0.5);

    return (prediction+subpixelOffset*texelSize);
}



static const int    PATCH_RADIUS = (9 * BUFFER_HEIGHT + 1080) / 2160;
static const int    GUIDE_RADIUS = (27 * BUFFER_HEIGHT + 1080) / 2160;
static const float2 GRID_SIZE    = float2(FOG_GRID_W, FOG_GRID_H);
static const float2 GRID_TEXEL   = 1.0 / float2(FOG_GRID_W, FOG_GRID_H);
static const float2 FULL_TO_GRID = BUFFER_SCREEN_SIZE / (4.0 * float2(FOG_GRID_W, FOG_GRID_H)); //block centers line up when W, H are not multiples of 4
static const float  HIGHLIGHT_CLIP_LEVEL = 0.98; //display-linear level above which a block can never be the airlight

float MinComponent(float3 value) { return min(value.x, min(value.y, value.z)); }
float MaxComponent(float3 value) { return max(value.x, max(value.y, value.z)); }

float2 GridToFullUV(float2 gridPos) { return (floor(gridPos) * 4.0 + 2.0) * BUFFER_PIXEL_SIZE; } //center of the 4x4
float2 FullToGridUV(float2 uv)   { return uv * FULL_TO_GRID; }

//frame stamps: (frame & 0xFFFFF) + 1 is exact in fp32 and never 0
float FrameStamp(uint frame) { return float((frame & 0xFFFFFu) + 1u); }

float4 ReadFogState(sampler2D stateSource, int texel)
{
    return tex2Dlod(stateSource, float4((float(texel) + 0.5) * 0.5, 0.5, 0, 0));
}

bool IsStateFromLastFrame()
{
    return ReadFogState(sFogState, 1).x == FrameStamp(FRAME_COUNT - 1u);
}

bool IsHistoryUsable()
{
    float4 stampTexel = ReadFogState(sFogState, 1);
    return (stampTexel.x == FrameStamp(FRAME_COUNT - 1u)) && (stampTexel.y > 0.5); //trust history only if last frame ran AND its dark channel was normalized by a real airlight
}

float3 GetAirlight()
{
    float4 state    = ReadFogState(sFogState, 0);
    bool   isFresh  = IsStateFromLastFrame() && (MaxComponent(state.rgb) > 0.0);
    float3 airlight = isFresh ? state.rgb : float3(1.0, 1.0, 1.0);
    airlight = min(airlight, HIGHLIGHT_CLIP_LEVEL * GetMaxColorValue()); //keeps the inverse tonemap finite
    return max(airlight, 0.001);
}

float ComputeTransmission(float2 uv)
{
    float2 coeffs       = tex2Dlod(sGuideCoeffsMean, float4(FullToGridUV(uv), 0, 0)).xy;
    float  guideLuma    = tex2Dlod(Kernel::sCurrLuma, float4(uv, 0, 0)).r;
    float  transmission = saturate(mad(coeffs.x, guideLuma, coeffs.y));
    return transmission;
}

void ReduceBlock(sampler2D bestSource, sampler2D sumSource, int2 sourceSize, float2 gridPos, out float4 best, out float2 total)
{
    best  = float4(0.0, 0.0, 0.0, -1.0);
    total = float2(0.0, 0.0);
    int2 blockOrigin = int2(gridPos) * 4;
    [unroll] for (int y = 0; y < 4; y++)
    [unroll] for (int x = 0; x < 4; x++)
    {
        int2   tapPos     = blockOrigin + int2(x, y);
        bool   isValid    = all(tapPos < sourceSize);
        float2 tapUV      = (float2(tapPos) + 0.5) / float2(sourceSize);
        float4 candidate  = tex2Dlod(bestSource, float4(tapUV, 0, 0));
        float2 partialSum = tex2Dlod(sumSource, float4(tapUV, 0, 0)).xy;
        bool   isBetter   = isValid && (candidate.a > best.a);
        best   = isBetter ? candidate : best;
        total += isValid ? partialSum : float2(0.0, 0.0);
    }
}

/*--------------.
| :: SHADERS :: |
'--------------*/

float PS_PackFeatures(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 color = GetColor(uv);
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    return luma * rcp(1.0 + luma);
}

#if IMAGE_SPACE == 0
    void PS_ReconstructNormals(VSOUT input, out float4 gbuffer : SV_Target0, out float depthC : SV_Target1)
    {
        depthC = GetDepth(input.uv);

        const float2 offsetX = float2(BUFFER_PIXEL_SIZE.x, 0);
        const float2 offsetY = float2(0, BUFFER_PIXEL_SIZE.y);

        float3 pC = UVToViewSpace(input.uv, depthC, input);
        float3 pL = UVToViewSpace(input.uv - offsetX, GetDepth(input.uv - offsetX), input);
        float3 pR = UVToViewSpace(input.uv + offsetX, GetDepth(input.uv + offsetX), input);
        float3 pT = UVToViewSpace(input.uv - offsetY, GetDepth(input.uv - offsetY), input);
        float3 pB = UVToViewSpace(input.uv + offsetY, GetDepth(input.uv + offsetY), input);

        float3 diffX2 = pR - pC;
        float3 diffX1 = pC - pL;
        float3 diffY2 = pB - pC;
        float3 diffY1 = pC - pT;

        float lenSqX2 = dot(diffX2, diffX2);
        float lenSqX1 = dot(diffX1, diffX1);
        float lenSqY2 = dot(diffY2, diffY2);
        float lenSqY1 = dot(diffY1, diffY1);

        float3 ddx = lenSqX2 < lenSqX1 ? diffX2 : diffX1;
        float3 ddy = lenSqY2 < lenSqY1 ? diffY2 : diffY1;
        float3 geoNormal = normalize(cross(ddx, ddy));
        gbuffer = float4(geoNormal, depthC);
    }

    #if SMOOTH_NORMALS
        static const float2 HRAN_SIZE = float2(BUFFER_WIDTH/2, BUFFER_HEIGHT/2);
        static const float2 HRAN_PX = float2(2.0, 2.0) / float2(BUFFER_WIDTH, BUFFER_HEIGHT);
        static const float  HRAN_TOL_SLOPE = 0.005 / RES_SCALE;
        static const float  HRAN_TOL_FLOOR = 0.00005 / RES_SCALE;
        static const float  CURV_LO = 0.0;
        static const float  CURV_HI = 0.475;
        static const float  MERGE_CENTER_WEIGHT = 1.0;
        static const float  CURV_OPEN_WINDOW = 1.3333333;
        static const float  COHERENCE_LO = 0.86;
        static const float  COHERENCE_HI = 0.85;
        static const float  STRIDE_NEAR_REF = 0.12 * RES_SCALE;
        static const float  STRIDE_MAX = 24.0 * RES_SCALE;
        static const float  DETAIL_GAIN = 1.25 * RES_SCALE;
        static const float  DEPTH_TOL_SLOPE = 0.005;

        float4 PS_HRAN_Half(VSOUT input) : SV_Target
        {
            float2 hc  = floor(input.uv * HRAN_SIZE);
            float2 uvC = (hc * 2.0 + 0.5) * BUFFER_PIXEL_SIZE;
            float  zC  = GetDepth(uvC);
            if (zC >= 0.999) return float4(0.0, 0.0, -1.0, zC); //sky

            float  b = clamp(STRIDE_NEAR_REF * rcp(max(zC, 1e-5)), RES_SCALE, STRIDE_MAX) * 2.0; //half-px -> full px
            //border guard
            float2 pxPos = uvC * BUFFER_SCREEN_SIZE;
            float  bx = max(min(floor(b + 0.5), min(pxPos.x, BUFFER_SCREEN_SIZE.x - 1.0 - pxPos.x)), 1.0);
            float  by = max(min(floor(b + 0.5), min(pxPos.y, BUFFER_SCREEN_SIZE.y - 1.0 - pxPos.y)), 1.0);
            float2 offX = float2(bx, 0.0) * BUFFER_PIXEL_SIZE.x;
            float2 offY = float2(0.0, by) * BUFFER_PIXEL_SIZE.y;

            float3 pC = UVToViewSpace(uvC,        zC,                  input);
            float3 pL = UVToViewSpace(uvC - offX, GetDepth(uvC - offX), input);
            float3 pR = UVToViewSpace(uvC + offX, GetDepth(uvC + offX), input);
            float3 pT = UVToViewSpace(uvC - offY, GetDepth(uvC - offY), input);
            float3 pB = UVToViewSpace(uvC + offY, GetDepth(uvC + offY), input);

            //best-fit selection
            float3 dX2 = pR - pC, dX1 = pC - pL;
            float3 dY2 = pB - pC, dY1 = pC - pT;
            float3 ddxV = dot(dX2, dX2) < dot(dX1, dX1) ? dX2 : dX1;
            float3 ddyV = dot(dY2, dY2) < dot(dY1, dY1) ? dY2 : dY1;

            float3 n = cross(ddxV, ddyV);
            n *= rsqrt(max(dot(n, n), 1e-30)); //scale-safe normalize

            return float4(n, zC);
        }

        float4 ATrousNormalsH(sampler2D gbufferSrc, float2 uv, uint dilation)
        {
            static const int2 offsets[4] = {              int2(0,-1),
                                             int2(-1, 0),             int2(1, 0),
                                                          int2(0, 1) };

            float4 centerGeo = tex2Dlod(gbufferSrc, float4(uv, 0, 0));
            float  detail = saturate(dot(fwidth(centerGeo.rgb), float3(1,1,1)) * DETAIL_GAIN); //0 = facet interior/flat, 1 = dense variation
            if (centerGeo.a >= 0.999) return centerGeo; //sky/far
            float  strideScale = clamp(STRIDE_NEAR_REF * exp2(-detail) / max(centerGeo.a, 1e-5), RES_SCALE, STRIDE_MAX); //world-locked footprint
            float  ringR = dilation * strideScale; //hoist: shared by rotation gate and every tap
            float  rotAng  = (ringR > 1.5) ? frac(GetStratifiedNoise(uv * HRAN_SIZE).x + float(dilation) * 0.6180339887) * 1.5707963268 : 0.0; //rotate cross: scrambles band phase into grain the next pass averages away
            float  rotS, rotC; sincos(rotAng, rotS, rotC);
            float  invDepthTol = 1.0 / (centerGeo.a * DEPTH_TOL_SLOPE * sqrt(strideScale / RES_SCALE) + EPSILON); //slope term ~ z*sqrt(stride) covers curvature headroom
            float  invDepthTolL2 = invDepthTol * 1.4426950408; //log2(e) prefold: exp(-x)==exp2(-x*log2e)
            float3 armSum      = 0.0; //arms accumulate FIRST; the centre's weight is decided after,
            float  armWeight   = 0.0; //once we know how many of them actually survived the gates
            float4 geo[4];
            [unroll] for (int i = 0; i < 2; i++) {
                float2 offIdeal = float2(offsets[i]) * ringR; //full-res grid stride, depth-adaptive
                float2 offPx    = float2(offIdeal.x * rotC - offIdeal.y * rotS, offIdeal.x * rotS + offIdeal.y * rotC);
                offPx           = floor(offPx + 0.5); //texel snap
                //border guard: scale the MIRRORED pair down so both taps stay on the half grid
                float2 hcPos = uv * HRAN_SIZE;
                float2 avail = max(min(hcPos, HRAN_SIZE - 1.0 - hcPos), 0.0);
                float  bsc   = min(1.0, min(avail.x / max(abs(offPx.x), 1e-3), avail.y / max(abs(offPx.y), 1e-3)));
                offPx        = floor(offPx * bsc + 0.5);
                float2 sampleUV = uv + offPx * HRAN_PX;
                geo[i]     = tex2Dlod(gbufferSrc, float4(sampleUV, 0, 0)); //one fetch = signal + both guides
                geo[3 - i] = tex2Dlod(gbufferSrc, float4(uv - offPx * HRAN_PX, 0, 0)); //mirrored partner, same snapped offset
            }

            //curvature consistency
            float3 d2x = geo[1].rgb + geo[2].rgb - 2.0 * centerGeo.rgb;
            float3 d2y = geo[0].rgb + geo[3].rgb - 2.0 * centerGeo.rgb;
            float  curv = (length(d2x) + length(d2y)) * 0.5;
            bool   ringValid = (geo[0].a < 0.999) && (geo[1].a < 0.999) && (geo[2].a < 0.999) && (geo[3].a < 0.999);
            float  curvGate  = ringValid ? (1.0 - smoothstep(CURV_LO, CURV_HI, curv)) : 0.0;
            float  tapWindow = lerp(1.3333333, CURV_OPEN_WINDOW, curvGate);
            //planar depth prediction
            float dzdxF = geo[2].a - centerGeo.a, dzdxB = centerGeo.a - geo[1].a; //E-C, C-W
            float dzdyF = geo[3].a - centerGeo.a, dzdyB = centerGeo.a - geo[0].a; //S-C, C-N
            float dzdx  = abs(dzdxF) < abs(dzdxB) ? dzdxF : dzdxB;
            float dzdy  = abs(dzdyF) < abs(dzdyB) ? dzdyF : dzdyB;
            float gradCap = 6.0 / invDepthTol;
            dzdx = clamp(dzdx, -gradCap, gradCap);
            dzdy = clamp(dzdy, -gradCap, gradCap);
            [unroll] for (int i = 0; i < 4; i++) {
                float4 sampleGeo    = geo[i];
                float  planeResid   = sampleGeo.a - (centerGeo.a + dzdx * float(offsets[i].x) + dzdy * float(offsets[i].y));
                float  depthWeight  = exp2(-abs(planeResid) * invDepthTolL2); //point-to-plane: slanted floors and gentle kinks pass, depth discontinuities fail
                float  nAlign       = saturate(dot(centerGeo.rgb, sampleGeo.rgb));
                float  normalWeight = saturate(nAlign * tapWindow - (tapWindow - 1.0)); //angular window
                float  weight       = depthWeight * normalWeight * 2.0; //uniform arm weight
                weight              = sampleGeo.a >= 0.999 ? 0.0 : weight; //skip skylines
                armSum             += sampleGeo.rgb * weight;
                armWeight          += weight;
            }

            //adaptive center weight to the flicker on small geometry
            float  armConf     = saturate(armWeight * 0.125); //8.0 = four arms x 2.0 max
            float  centerW     = lerp(4.0, MERGE_CENTER_WEIGHT, armConf);
            float3 sum         = centerGeo.rgb * centerW + armSum;
            float  totalWeight = centerW + armWeight;

            float  filteredLen = length(sum);
            float3 mergedDir   = (filteredLen > EPSILON) ? sum / filteredLen : centerGeo.rgb;

            //coherence gate
            float coherence     = filteredLen / max(totalWeight, EPSILON);
            float coherenceGate = smoothstep(COHERENCE_LO, COHERENCE_HI, coherence);

            float mergeStrength = max(coherenceGate, curvGate);
            float3 filtered    = normalize(lerp(centerGeo.rgb, mergedDir, mergeStrength));

            return float4(filtered, centerGeo.a); //depth rides through untouched
        }

        float4 PS_HRAN_A(float4 vp : SV_Position, float2 uv : TEXCOORD) : SV_Target { return ATrousNormalsH(sHRAN_H0, uv, 2); }
        float4 PS_HRAN_B(float4 vp : SV_Position, float2 uv : TEXCOORD) : SV_Target { return ATrousNormalsH(sHRAN_HA, uv, 4); }
        float4 PS_HRAN_C(float4 vp : SV_Position, float2 uv : TEXCOORD) : SV_Target { return ATrousNormalsH(sHRAN_HB, uv, 8); }

        float4 PS_HRAN_Up(float4 vp : SV_Position, float2 uv : TEXCOORD) : SV_Target
        {   //joint-bilateral upsample
            float4 g = tex2Dlod(sGuideNormals, float4(uv, 0, 0));
            if (g.a >= 0.999) return g; //sky/far
            //center-relative one-sided guide slopes at FULL res (min-mag guard: silhouette on one side can't poison the other)
            float zE = tex2Dlod(sGuideNormals, float4(uv + float2(BUFFER_PIXEL_SIZE.x, 0), 0, 0)).a;
            float zW = tex2Dlod(sGuideNormals, float4(uv - float2(BUFFER_PIXEL_SIZE.x, 0), 0, 0)).a;
            float zS = tex2Dlod(sGuideNormals, float4(uv + float2(0, BUFFER_PIXEL_SIZE.y), 0, 0)).a;
            float zN = tex2Dlod(sGuideNormals, float4(uv - float2(0, BUFFER_PIXEL_SIZE.y), 0, 0)).a;
            float dxF = zE - g.a, dxB = g.a - zW;
            float dzdx = abs(dxF) < abs(dxB) ? dxF : dxB;
            float dyF = zS - g.a, dyB = g.a - zN;
            float dzdy = abs(dyF) < abs(dyB) ? dyF : dyB;
            float invTol   = 1.0 / (g.a * HRAN_TOL_SLOPE + HRAN_TOL_FLOOR); //span ~1-2 full px -> no stride coupling needed
            float invTolL2 = invTol * 1.4426950408; //log2(e) prefold
            float gradCap  = 3.0 / invTol; //cut-poisoned-fit cap, same job as always
            dzdx = clamp(dzdx, -gradCap, gradCap);
            dzdy = clamp(dzdy, -gradCap, gradCap);
            float2 hc   = uv * HRAN_SIZE - 0.5;
            float2 hb   = min(max(floor(hc), 0.0), HRAN_SIZE - 2.0); //border guard: the 2x2 always reads real texels
            float2 fr   = hc - hb;
            float2 frw  = smoothstep(0.0, 1.0, fr);
            float2 base = (hb + 0.5) * HRAN_PX;
            float3 nsum = 0.0;  float ws = 0.0;
            [unroll] for (int j = 0; j < 2; j++)
            [unroll] for (int i = 0; i < 2; i++) {
                float4 hg    = tex2Dlod(sHRAN_HA, float4(base + float2(i, j) * HRAN_PX, 0, 0));
                float2 dFull = 2.0 * (float2(i, j) - fr); //tap offset in FULL-res px (one half-px = two full-px)
                float  resid = hg.a - (g.a + dzdx * dFull.x + dzdy * dFull.y); //point-to-plane vs the pristine full-res guide
                float  bi    = (i == 0 ? 1.0 - frw.x : frw.x) * (j == 0 ? 1.0 - frw.y : frw.y);
                float  w     = exp2(-abs(resid) * invTolL2) * saturate(saturate(dot(g.rgb, hg.rgb)) * 1.3333333 - 0.3333333) * bi; //75deg window
                w            = hg.a >= 0.999 ? 0.0 : w;
                nsum        += hg.rgb * w;  ws += w;
            }
            if (ws < 1e-4) return g; //never blend on the wrong-side, let raw normal through, unsmoothed but correct here
            float3 n = nsum / ws;  float len = length(n);
            float3 outN = (len > EPSILON) ? n / len : g.rgb;

            //luma micro-relief
            [branch] if (abs(LUMA_DETAIL) > 1e-4)
            {
                float  lodEff = LUMA_DETAIL_LOD + log2(RES_SCALE);
                float  lodPx = exp2(lodEff);
                float2 lr    = BUFFER_PIXEL_SIZE * lodPx;
                float lE = tex2Dlod(sCurrLuma, float4(uv + float2(lr.x, 0), 0, lodEff)).r;
                float lW = tex2Dlod(sCurrLuma, float4(uv - float2(lr.x, 0), 0, lodEff)).r;
                float lS = tex2Dlod(sCurrLuma, float4(uv + float2(0, lr.y), 0, lodEff)).r;
                float lN = tex2Dlod(sCurrLuma, float4(uv - float2(0, lr.y), 0, lodEff)).r;
                float2 lg = float2(lE - lW, lS - lN) * 0.5;
                lg = sign(lg) * min(abs(lg), 0.08); //cap: residual hard edges emboss boundedly
                outN = normalize(outN + float3(-lg.x, -lg.y, 0.0) * (LUMA_DETAIL * 8.0));
            }
            return float4(outN, g.a); //full-res depth rides through
        }

    #endif
#endif

float2 PS_ComputeFlow128(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    if(FRAME_COUNT == 0) return float2(0, 0);

    static const int SEARCH_RADIUS = 3;
    static const uint mip = 5;
    float2 texelSize = BUFFER_PIXEL_SIZE * exp2(mip);

    //candidate seeds for the coarsest level for tournament selection
    float2 prevSeed   = tex2D(sPrevFrameFlow, uv).xy;
    float2 zeroSeed   = float2(0, 0);
    float prevCost   = ZMSAD(sCurrLuma, sPrevLuma, uv, uv + prevSeed,   texelSize, mip);
    float zeroCost   = ZMSAD(sCurrLuma, sPrevLuma, uv, uv + zeroSeed,   texelSize, mip);

    float2 seed = (zeroCost < prevCost) ? zeroSeed : prevSeed; //pick better candidate as seed
    float2 bestFlow = seed;
    float minCost = ZMSAD(sCurrLuma, sPrevLuma, uv, uv+seed, texelSize, mip);
    //search in a grid AROUND the seed
    for (int y = -SEARCH_RADIUS; y <= SEARCH_RADIUS; ++y) for (int x = -SEARCH_RADIUS; x <= SEARCH_RADIUS; ++x) {
            if (x == 0 && y == 0) continue;
            float2 candidateFlow = seed + float2(x, y) * texelSize;
            float cost = ZMSAD(sCurrLuma, sPrevLuma, uv, uv + candidateFlow, texelSize, mip);
            if (cost < minCost) {
                minCost = cost;
                bestFlow = candidateFlow;
                if (minCost < 0.01) //near-perfect match found
                    return bestFlow;
            }
    }
    return bestFlow;
}

float2 PS_UpscaleFlow64(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return UpscaleFlow(sFlow128, sCurrLuma, sPrevLuma, uv, BUFFER_PIXEL_SIZE*16.0, 4);
}

float2 PS_MedianPass64(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return Median9(sFlow64A, uv, BUFFER_PIXEL_SIZE*64.0, 6);
}

float2 PS_UpscaleFlow32(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return UpscaleFlow(sFlow64B, sCurrLuma, sPrevLuma, uv, BUFFER_PIXEL_SIZE*8.0, 3);
}

float2 PS_MedianPass32(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return Median9(sFlow32A, uv, BUFFER_PIXEL_SIZE*32.0, 5);
}

float2 PS_UpscaleFlow16(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return UpscaleFlow(sFlow32B, sCurrLuma, sPrevLuma, uv, BUFFER_PIXEL_SIZE*4.0, 2);
}

float2 PS_MedianPass16(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return Median9(sFlow16A, uv, BUFFER_PIXEL_SIZE*16.0, 4);
}

float2 PS_UpscaleFlow8(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return UpscaleFlow(sFlow16B, sCurrLuma, sPrevLuma, uv, BUFFER_PIXEL_SIZE*2.0, 1);
}

float2 PS_MedianPass8A(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return BilateralMedian9(sFlow, uv, BUFFER_PIXEL_SIZE*8.0, 3);
}

float2 PS_MedianPass8B(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return BilateralMedian9(sFlow8, uv, BUFFER_PIXEL_SIZE*8.0, 3);
}

float2 PS_ATrousPassA(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target //stride 1
{
    return ATrousFilter(sFlow, uv, 2, 3);
}

float2 PS_ATrousPassB(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target //stride 2
{
    float2 flow = ATrousFilter(sFlow8, uv, 4, 1);
    //kill sub-pixel noise
    float flowPixelMag = length(flow / BUFFER_PIXEL_SIZE);
    float gate = saturate(1.0 - pow(1.0 - saturate(saturate(flowPixelMag) - 0.2), 10.0)); //SNAP TO REALITY
    return flow*gate;
}

float PS_Confidence(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    if(FRAME_COUNT == 0) return 0.0; //no confidence

    float2 flow = tex2D(sFlow, uv).xy;
    float2 prevUV = uv + flow; //warp prev frame forward
    if(IsOOB(prevUV)) return 0.0;

    //look at local contrast for pattern confidence
    float sumX = 0, sumX2 = 0, sumY = 0, sumY2 = 0;
    float2 lumaTexSize = BUFFER_PIXEL_SIZE * 4.0;
    static const float2 offsets[5] = {
                      float2(0, 1),
        float2(-1,0), float2(0, 0), float2(1,0),
                      float2(0,-1)
    };
    [unroll] for(int i = 0; i < 5; i++) {
        float valCurr = tex2Dlod(sCurrLuma, float4(uv + offsets[i] * lumaTexSize, 0, 2)).r;
        float valPrev = tex2Dlod(sPrevLuma, float4(prevUV + offsets[i] * lumaTexSize, 0, 2)).r;
        sumX += valCurr; sumX2 += valCurr * valCurr;
        sumY += valPrev; sumY2 += valPrev * valPrev;
    }
    float varCurr = max(0.0, (sumX2 / 5.0) - (sumX / 5.0 * sumX / 5.0));
    float varPrev = max(0.0, (sumY2 / 5.0) - (sumY / 5.0 * sumY / 5.0));
    float patternConf = 1.0 - saturate(abs(sqrt(varCurr) - sqrt(varPrev)) / (sqrt(varCurr) + 0.01));

    //look at neighborhood for flow consistency
    float flowMagnitude = length(flow);
    float2 flowTexelSize = BUFFER_PIXEL_SIZE * 8.0;
    float2 flowN = tex2Dlod(sFlow, float4(uv + float2(0, -flowTexelSize.y), 0, 0)).xy;
    float2 flowS = tex2Dlod(sFlow, float4(uv + float2(0,  flowTexelSize.y), 0, 0)).xy;
    float2 flowE = tex2Dlod(sFlow, float4(uv + float2( flowTexelSize.x, 0), 0, 0)).xy;
    float2 flowW = tex2Dlod(sFlow, float4(uv + float2(-flowTexelSize.x, 0), 0, 0)).xy;
    float2 avgNeighborFlow = (flowN + flowS + flowE + flowW) * 0.25;
    float spatialDiff = distance(flow, avgNeighborFlow);
    float spatialThreshold = flowMagnitude * 0.5 + BUFFER_PIXEL_SIZE.x;
    float spatialConfidence = saturate(1.0 - (spatialDiff / (spatialThreshold + EPSILON)));

    //motion length penalty
    float subpixelThreshold = length(BUFFER_PIXEL_SIZE);
    float lengthConfidence = (flowMagnitude <= subpixelThreshold) ? 1.0 : rcp((flowMagnitude / subpixelThreshold) * 0.05 + 1.0);
    //float panThreshold = BUFFER_PIXEL_SIZE.x * 30.0;
    //float lengthConfidence = (flowMagnitude <= panThreshold) ? 1.0 : rcp(((flowMagnitude - panThreshold) / panThreshold) * 0.1 + 1.0);

    //current frame final confidence
    float currentConf = spatialConfidence * lengthConfidence * patternConf;

    //temporal filter
    float historyConf = tex2D(sPrevConfidence, prevUV).r;

    //DEPRECATED: linear EMA (a=0.15) 15% new + 85% history every frame
    //unbiased (settles at the true mean), very stable but distrusts a real drop only as slowly as it trusts a rise
    //return lerp(historyConf, currentConf, 0.15); //higher makes it react to changes quickly

    //Asymmetric EMA; a=0.5 only on a genuine drop (>0.05 below history) fast distrust, else a reasonable a=0.1
    //0.05 deadband keeps calm-region jitter on 0.1; only true occlusion/disocclusion bleeds confidence fast
    float alpha = (currentConf < historyConf - 0.05) ? 0.5 : 0.1;
    return lerp(historyConf, currentConf, alpha);
}

void PS_StoreFlow(float4 pos : SV_Position, float2 uv : TEXCOORD, out float2 flow : SV_Target0, out float confidence : SV_Target1)
{
    flow = tex2D(sFlow, uv).xy;
    confidence = tex2D(sConfidence, uv).r;
}

float PS_StoreLuma(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return tex2D(sCurrLuma, uv).r;
}




void PS_DarkChannel(float4 pos : SV_Position, float2 uv : TEXCOORD, out float2 darkChannel : SV_Target0, out float4 brightest : SV_Target1)
{
    float2 blockOrigin    = floor(pos.xy) * 4.0;
    float3 minColor       = 1e6;
    float3 brightestColor = 0.0;
    float  brightestLuma  = -1.0;
    [unroll] for (int y = 0; y < 4; y++)
    [unroll] for (int x = 0; x < 4; x++)
    {
        float2 tapUV    = (blockOrigin + float2(x, y) + 0.5) * BUFFER_PIXEL_SIZE;
        float3 tapColor = tex2Dlod(ReShade::BackBuffer, float4(tapUV, 0, 0)).rgb;
        minColor = min(minColor, tapColor);
        float tapLuma    = dot(tapColor, float3(0.2126, 0.7152, 0.0722));
        bool  isBrighter = tapLuma > brightestLuma;
        brightestColor = isBrighter ? tapColor : brightestColor;
        brightestLuma = isBrighter ? tapLuma : brightestLuma;
    }
    float3 minLinear       = max(ToLinearColorspace(minColor, false), 0.0);
    float3 brightestLinear = max(ToLinearColorspace(brightestColor, false), 0.0);
    float3 airlight        = GetAirlight();
    float  rawDark         = MinComponent(minLinear);
    float  airlightKey     = (rawDark >= HIGHLIGHT_CLIP_LEVEL * GetMaxColorValue()) ? 0.0 : rawDark; //clipped highlights never become airlight
    darkChannel   = float2(MinComponent(minLinear / airlight), airlightKey); //dark channel of I/A
    brightest = float4(brightestLinear, 1.0);
}

float2 PS_PatchMinHorizontal(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float2 patchMin = tex2Dlod(sDarkChannel, float4(uv, 0, 0)).rg;
    [unroll] for (int i = 1; i <= PATCH_RADIUS; i++)
    {
        float2 tapOffset = float2(float(i) * GRID_TEXEL.x, 0.0);
        patchMin = min(patchMin, min(tex2Dlod(sDarkChannel, float4(uv + tapOffset, 0, 0)).rg, tex2Dlod(sDarkChannel, float4(uv - tapOffset, 0, 0)).rg));
    }
    return patchMin;
}

void PS_PatchMinVertical(float4 pos : SV_Position, float2 uv : TEXCOORD, out float2 transmissionOut : SV_Target0, out float4 moments : SV_Target1)
{
    float2 patchMin = tex2Dlod(sDarkChannelRowMin, float4(uv, 0, 0)).rg;
    [unroll] for (int i = 1; i <= PATCH_RADIUS; i++)
    {
        float2 tapOffset = float2(0.0, float(i) * GRID_TEXEL.y);
        patchMin = min(patchMin, min(tex2Dlod(sDarkChannelRowMin, float4(uv + tapOffset, 0, 0)).rg, tex2Dlod(sDarkChannelRowMin, float4(uv - tapOffset, 0, 0)).rg));
    }
    float haze          = saturate(0.95 * patchMin.x); //HAZE_RETENTION = 0.95 per He et al.
    float2 blockUV      = GridToFullUV(pos.xy);
    float2 flow         = tex2Dlod(Kernel::sFlow, float4(blockUV, 0, 0)).xy;
    float  confidence   = tex2Dlod(Kernel::sConfidence, float4(blockUV, 0, 0)).x;
    float2 prevUV       = blockUV + flow;
    float  historyHaze  = tex2Dlod(sPrevHaze, float4(FullToGridUV(prevUV), 0, 0)).x;
    bool   historyValid = !IsOOB(prevUV) && (historyHaze > 0.0) && IsHistoryUsable();
    haze = lerp(haze, historyHaze, historyValid ? 0.9 * saturate(confidence) : 0.0); //TEMPORAL_STABILITY = 0.9

    float transmission = 1.0 - haze;
    float guideLuma    = tex2Dlod(Kernel::sCurrLuma, float4(blockUV, 0, 2)).r; //mip 2 = 4x4 box mean = guide on the 1/4 grid
    transmissionOut    = float2(transmission, patchMin.y);
    moments = float4(guideLuma, transmission, guideLuma * guideLuma, guideLuma * transmission);
}

void PS_ReduceAirlight1(float4 pos : SV_Position, float2 uv : TEXCOORD, out float4 best : SV_Target0, out float2 total : SV_Target1)
{
    best  = float4(0.0, 0.0, 0.0, -1.0);
    total = float2(0.0, 0.0);
    int2 blockOrigin = int2(pos.xy) * 4;
    [unroll] for (int y = 0; y < 4; y++)
    [unroll] for (int x = 0; x < 4; x++)
    {
        int2   tapPos          = blockOrigin + int2(x, y);
        bool   isValid         = all(tapPos < int2(FOG_GRID_W, FOG_GRID_H));
        float2 tapUV           = (float2(tapPos) + 0.5) * GRID_TEXEL;
        float2 transmissionKey = tex2Dlod(sTransmission, float4(tapUV, 0, 0)).xy;
        float3 candidateColor  = tex2Dlod(sBrightestColor, float4(tapUV, 0, 0)).rgb;
        bool   isBetter        = isValid && (transmissionKey.y > best.a);
        best   = isBetter ? float4(candidateColor, transmissionKey.y) : best;
        total += isValid ? float2(1.0 - transmissionKey.x, 1.0) : float2(0.0, 0.0);
    }
}

void PS_ReduceAirlight2(float4 pos : SV_Position, float2 uv : TEXCOORD, out float4 best : SV_Target0, out float2 total : SV_Target1)
{
    ReduceBlock(sReduceBest1, sReduceSum1, int2(REDUCE1_W, REDUCE1_H), pos.xy, best, total);
}

void PS_ReduceAirlight3(float4 pos : SV_Position, float2 uv : TEXCOORD, out float4 best : SV_Target0, out float2 total : SV_Target1)
{
    ReduceBlock(sReduceBest2, sReduceSum2, int2(REDUCE2_W, REDUCE2_H), pos.xy, best, total);
}

void PS_ReduceAirlight4(float4 pos : SV_Position, float2 uv : TEXCOORD, out float4 best : SV_Target0, out float2 total : SV_Target1)
{
    ReduceBlock(sReduceBest3, sReduceSum3, int2(REDUCE3_W, REDUCE3_H), pos.xy, best, total);
}

float4 PS_ResolveFogState(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float4 prevStampTexel   = ReadFogState(sPrevFogState, 1);
    bool   isFresh          = prevStampTexel.x == FrameStamp(FRAME_COUNT - 1u);
    bool   prevDensityValid = isFresh && (prevStampTexel.y > 0.5); //last frame's density came from a real airlight
    if (pos.x >= 1.0) return float4(FrameStamp(FRAME_COUNT), isFresh ? 1.0 : 0.0, 0.0, 0.0); //texel 1: stamp, airlight-was-valid

    float4 best  = float4(0.0, 0.0, 0.0, -1.0);
    float2 total = float2(0.0, 0.0);
    [unroll] for (int y = 0; y < 8; y++)
    [unroll] for (int x = 0; x < 8; x++)
    {
        int2   tapPos     = int2(x, y);
        bool   isValid    = all(tapPos < int2(REDUCE4_W, REDUCE4_H));
        float2 tapUV      = (float2(tapPos) + 0.5) / float2(REDUCE4_W, REDUCE4_H);
        float4 candidate  = tex2Dlod(sReduceBest4, float4(tapUV, 0, 0));
        float2 partialSum = tex2Dlod(sReduceSum4, float4(tapUV, 0, 0)).xy;
        bool   isBetter   = isValid && (candidate.a > best.a);
        best   = isBetter ? candidate : best;
        total += isValid ? partialSum : float2(0.0, 0.0);
    }
    float3 airlight = (best.a >= 0.0) ? best.rgb : float3(1.0, 1.0, 1.0);
    airlight = min(airlight, HIGHLIGHT_CLIP_LEVEL * GetMaxColorValue());
    float  density = total.x / max(total.y, 1.0);

    float4 prevState     = ReadFogState(sPrevFogState, 0);
    float  smoothing     = 1.0 - exp(-FRAME_TIME / 500.0); //Airlight Adaptation (ms) = 500.0
    float  airlightAlpha = isFresh ? smoothing : 1.0; //airlight key does not depend on A: valid from the first frame
    float  densityAlpha  = prevDensityValid ? smoothing : 1.0; //density does: restart once a real airlight is in use
    return float4(lerp(prevState.rgb, airlight, airlightAlpha), lerp(prevState.a, density, densityAlpha));
}

float4 PS_GuideMomentsHorizontal(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float4 momentSum = 0.0;
    float  tapCount  = 0.0;
    [unroll] for (int i = -GUIDE_RADIUS; i <= GUIDE_RADIUS; i++)
    {
        float  tapX       = pos.x + float(i);
        bool   isValid    = (tapX > 0.0) && (tapX < GRID_SIZE.x);
        float4 tapMoments = tex2Dlod(sGuideMoments, float4(tapX * GRID_TEXEL.x, uv.y, 0, 0));
        momentSum += isValid ? tapMoments : float4(0.0, 0.0, 0.0, 0.0);
        tapCount  += isValid ? 1.0 : 0.0;
    }
    return momentSum / tapCount;
}

float2 PS_GuideCoeffs(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float4 momentSum = 0.0;
    float  tapCount  = 0.0;
    [unroll] for (int i = -GUIDE_RADIUS; i <= GUIDE_RADIUS; i++)
    {
        float  tapY       = pos.y + float(i);
        bool   isValid    = (tapY > 0.0) && (tapY < GRID_SIZE.y);
        float4 tapMoments = tex2Dlod(sGuideMomentsRowMean, float4(uv.x, tapY * GRID_TEXEL.y, 0, 0));
        momentSum += isValid ? tapMoments : float4(0.0, 0.0, 0.0, 0.0);
        tapCount  += isValid ? 1.0 : 0.0;
    }
    float4 meanMoments     = momentSum / tapCount;
    float  guideVariance   = max(meanMoments.z - meanMoments.x * meanMoments.x, 0.0);
    float  guideCovariance = meanMoments.w - meanMoments.x * meanMoments.y;
    float  slope           = guideCovariance / (guideVariance + 0.00025); //GUIDE_EPSILON = 0.00025 equals He et al.'s 1e-3 on Kernel's luma range
    return float2(slope, meanMoments.y - slope * meanMoments.x);
}

float2 PS_GuideCoeffsHorizontal(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float2 coeffSum = 0.0;
    float  tapCount = 0.0;
    [unroll] for (int i = -GUIDE_RADIUS; i <= GUIDE_RADIUS; i++)
    {
        float  tapX      = pos.x + float(i);
        bool   isValid   = (tapX > 0.0) && (tapX < GRID_SIZE.x);
        float2 tapCoeffs = tex2Dlod(sGuideCoeffs, float4(tapX * GRID_TEXEL.x, uv.y, 0, 0)).xy;
        coeffSum += isValid ? tapCoeffs : float2(0.0, 0.0);
        tapCount += isValid ? 1.0 : 0.0;
    }
    return coeffSum / tapCount;
}

float2 PS_GuideCoeffsVertical(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float2 coeffSum = 0.0;
    float  tapCount = 0.0;
    [unroll] for (int i = -GUIDE_RADIUS; i <= GUIDE_RADIUS; i++)
    {
        float  tapY      = pos.y + float(i);
        bool   isValid   = (tapY > 0.0) && (tapY < GRID_SIZE.y);
        float2 tapCoeffs = tex2Dlod(sGuideCoeffsRowMean, float4(uv.x, tapY * GRID_TEXEL.y, 0, 0)).xy;
        coeffSum += isValid ? tapCoeffs : float2(0.0, 0.0);
        tapCount += isValid ? 1.0 : 0.0;
    }
    return coeffSum / tapCount;
}

float PS_FogMask(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float transmission = ComputeTransmission(uv);
    return (1.0 - transmission);
}

float PS_StoreHaze(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return max(1.0 - tex2Dlod(sTransmission, float4(uv, 0, 0)).x, 0.0001); //never 0: 0 is empty history
}

float4 PS_StoreFogState(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return tex2Dlod(sFogState, float4(uv, 0, 0));
}




#if DEBUG_KERNEL
    float4 PS_Debug(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
    {
        float3 sceneColor = GetColor(uv);
        switch(DEBUG_VIEW)
        {
            case 0: {
                static const float  LINE_PX   = 1.5;                //divider half-width, px
                static const float3 LINE_TINT = float3(0.0, 0.0, 0.0);
                static const float2 BOX_HALF  = float2(0.16, 0.18); //centre inset half-extents, uv

                float2 pixelPos  = uv * BUFFER_SCREEN_SIZE;
                float2 centrePx  = BUFFER_SCREEN_SIZE * 0.5;
                float2 boxHalfPx = BOX_HALF * BUFFER_SCREEN_SIZE;

                //axis-aligned box distance
                float2 dd     = abs(pixelPos - centrePx) - boxHalfPx;
                float  boxSDF = length(max(dd, 0.0)) + min(max(dd.x, dd.y), 0.0);

                float3 view;
                if (boxSDF < 0.0)
                {
                    float2 boxUV = (uv - (0.5 - BOX_HALF)) / (2.0 * BOX_HALF); //full frame mapped into inset
                    view = DrawMotionVectors(boxUV).rgb;                       //centre: motion vectors
                }
                else
                {
                    float2 quadUV = frac(uv * 2.0); //flow/confidence remap to full [0,1] frame
                    if (uv.y < 0.5)
                        view = (uv.x < 0.5)
                             ? tex2Dlod(sNormals, float4(uv, 0, 0)).rgb * 0.5 + 0.5     //TL: normals (spatial, raw uv)
                             : DepthGradient(tex2Dlod(sDepth, float4(uv, 0, 0)).r, uv); //TR: depth (spatial, raw uv)
                    else if (uv.x < 0.5)
                        view = MotionToColor(tex2Dlod(sFlow, float4(quadUV, 0, 0)).xy); //BL: optical flow field
                    else
                    {
                        float  confidence      = tex2Dlod(sConfidence, float4(quadUV, 0, 0)).x; //BR: motion confidence field
                        float3 confidenceColor = (confidence < 0.5)
                            ? lerp(float3(1.0, 0.0, 0.0), float3(1.0, 1.0, 0.0), confidence * 2.0)
                            : lerp(float3(1.0, 1.0, 0.0), float3(0.0, 1.0, 0.0), (confidence - 0.5) * 2.0);
                        view = lerp(GetColor(quadUV), confidenceColor, 0.9);
                    }

                    //black dividers
                    float dCross = min(abs(pixelPos.x - centrePx.x), abs(pixelPos.y - centrePx.y));
                    view = lerp(view, LINE_TINT, 1.0 - smoothstep(LINE_PX - 0.9, LINE_PX + 0.9, dCross));
                }

                //centre inset border
                view = lerp(view, LINE_TINT, 1.0 - smoothstep(LINE_PX - 0.9, LINE_PX + 0.9, abs(boxSDF)));
                //window labels
                // float2 texcoord  = uv;  //alias: the DrawText macro declares its own internal 'uv'
                // float  labelMask = 0.0;
                // float  labelSize = max(BUFFER_HEIGHT * 0.025, 12.0); //label height, px
                // int lblNormals[21]    = { __R, __e, __c, __o, __n, __s, __t, __r, __u, __c, __t, __e, __d, __Space, __N, __o, __r, __m, __a, __l, __s };
                // int lblDepth[16]      = { __L, __i, __n, __e, __a, __r, __i, __z, __e, __d, __Space, __D, __e, __p, __t, __h };
                // int lblFlow[10]       = { __F, __l, __o, __w, __Space, __F, __i, __e, __l, __d };
                // int lblConfidence[16] = { __C, __o, __n, __f, __i, __d, __e, __n, __c, __e, __Space, __F, __i, __e, __l, __d };
                // int lblVectors[14]    = { __M, __o, __t, __i, __o, __n, __Space, __V, __e, __c, __t, __o, __r, __s };
                //
                // labelMask = 0.0; DrawText_String(float2(BUFFER_WIDTH * 0.25 - 21.0 * labelSize * 0.25, BUFFER_HEIGHT * 0.03),                     labelSize, 1.0, texcoord, lblNormals,    21, labelMask); view = lerp(view, float3(1.00, 1.00, 1.00), saturate(labelMask)); //TL  white
                // labelMask = 0.0; DrawText_String(float2(BUFFER_WIDTH * 0.75 - 16.0 * labelSize * 0.25, BUFFER_HEIGHT * 0.03),                     labelSize, 1.0, texcoord, lblDepth,      16, labelMask); view = lerp(view, float3(0.55, 0.85, 1.00), saturate(labelMask)); //TR  blue
                // labelMask = 0.0; DrawText_String(float2(BUFFER_WIDTH * 0.25 - 10.0 * labelSize * 0.25, BUFFER_HEIGHT * 0.53),                     labelSize, 1.0, texcoord, lblFlow,       10, labelMask); view = lerp(view, float3(1.00, 1.00, 1.00), saturate(labelMask)); //BL  white
                // labelMask = 0.0; DrawText_String(float2(BUFFER_WIDTH * 0.75 - 16.0 * labelSize * 0.25, BUFFER_HEIGHT * 0.53),                     labelSize, 1.0, texcoord, lblConfidence, 16, labelMask); view = lerp(view, float3(1.00, 1.00, 1.00), saturate(labelMask)); //BR  white
                // labelMask = 0.0; DrawText_String(float2(BUFFER_WIDTH * 0.50 - 14.0 * labelSize * 0.25, BUFFER_HEIGHT * (0.5 - BOX_HALF.y) + 8.0), labelSize, 1.0, texcoord, lblVectors,    14, labelMask); view = lerp(view, float3(1.00, 1.00, 1.00), saturate(labelMask)); //centre  white
                //
                // view = lerp(view, float3(1.0, 1.0, 1.0), saturate(labelMask)); //white labels
                return float4(view, 1.0);
            }

            case 1: {
                float4 gbuffer = tex2D(sNormals, uv);
                float3 normal = gbuffer.rgb;
                float depth = gbuffer.a;
                bool isLeftHalf = uv.x < 0.5;
                float4 dbg;
                if (isLeftHalf)
                    dbg = float4(normal * 0.5 + 0.5, 1.0); //left: normals
                else
                    dbg = float4(DepthGradient(depth, uv), 1.0); //right: depth gradient
                return dbg;
            }

            case 2:  return float4(MotionToColor(tex2D(sFlow, uv).xy), 1);

            case 3:  return DrawMotionVectors(uv);

            case 4:
            {
                float confidence = tex2D(sConfidence, uv).x;
                float3 confidenceColor;
                if (confidence < 0.5)
                    confidenceColor = lerp(float3(1.0, 0.0, 0.0), float3(1.0, 1.0, 0.0), confidence * 2.0);
                else
                    confidenceColor = lerp(float3(1.0, 1.0, 0.0), float3(0.0, 1.0, 0.0), (confidence - 0.5) * 2.0);
                return float4(lerp(sceneColor, confidenceColor, 0.9), 1.0);
            }

            case 5: return float4(tex2Dlod(sFogMask, float4(uv, 0, 0)).rrr, 1.0);

            case 6:
            {
                float3 airlight     = max(min(ReadFogState(sFogState, 0).rgb, HIGHLIGHT_CLIP_LEVEL * GetMaxColorValue()), 0.001);
                float3 workingColor = max(ToLinearColorspace(sceneColor, false), 0.0);
                float  transmission = ComputeTransmission(uv);
                float3 dehazed      = max((workingColor - airlight) / max(transmission, 0.1) + airlight, 0.0);
                return float4(ToOutputColorspace(dehazed, false), 1.0);
            }

            default: return float4(sceneColor, 1.0);
        }
    }
#endif

/*----------------.
| :: TECHNIQUE :: |
'----------------*/
technique Lumenite_Kernel <
    ui_label = "LUMENITE: Kernel 2.0";
    ui_tooltip = "Pre-effect for LumeniteFX shaders.";
>
{
    //features
    pass { VertexShader = PostProcessVS; PixelShader = PS_PackFeatures;    RenderTarget  = tCurrLuma; }

    //normals
    #if IMAGE_SPACE == 0
        #if SMOOTH_NORMALS == 0
            pass { VertexShader = VS;            PixelShader = PS_ReconstructNormals; RenderTarget0 = tNormals;      RenderTarget1 = tDepth;   }
        #else
            pass { VertexShader = VS;            PixelShader = PS_ReconstructNormals; RenderTarget0 = tGuideNormals; RenderTarget1 = tDepth;   }
            pass { VertexShader = VS;            PixelShader = PS_HRAN_Half;          RenderTarget  = texHRAN_H0;                              }
            pass { VertexShader = PostProcessVS; PixelShader = PS_HRAN_A;             RenderTarget  = texHRAN_HA;                              }
            pass { VertexShader = PostProcessVS; PixelShader = PS_HRAN_B;             RenderTarget  = texHRAN_HB;                              }
            pass { VertexShader = PostProcessVS; PixelShader = PS_HRAN_C;             RenderTarget  = texHRAN_HA;                              }
            pass { VertexShader = PostProcessVS; PixelShader = PS_HRAN_Up;            RenderTarget  = tNormals;                                }
        #endif
    #endif

    //optical flow
    pass { VertexShader = PostProcessVS; PixelShader = PS_ComputeFlow128;  RenderTarget  = tFlow128;    }
    pass { VertexShader = PostProcessVS; PixelShader = PS_UpscaleFlow64;   RenderTarget  = tFlow64A;    }
    pass { VertexShader = PostProcessVS; PixelShader = PS_MedianPass64;    RenderTarget  = tFlow64B;    }
    pass { VertexShader = PostProcessVS; PixelShader = PS_UpscaleFlow32;   RenderTarget  = tFlow32A;    }
    pass { VertexShader = PostProcessVS; PixelShader = PS_MedianPass32;    RenderTarget  = tFlow32B;    }
    pass { VertexShader = PostProcessVS; PixelShader = PS_UpscaleFlow16;   RenderTarget  = tFlow16A;    }
    pass { VertexShader = PostProcessVS; PixelShader = PS_MedianPass16;    RenderTarget  = tFlow16B;    }

    pass { VertexShader = PostProcessVS; PixelShader = PS_UpscaleFlow8;    RenderTarget  = tFlow;       }
    pass { VertexShader = PostProcessVS; PixelShader = PS_MedianPass8A;    RenderTarget  = tFlow8;      }
    pass { VertexShader = PostProcessVS; PixelShader = PS_MedianPass8B;    RenderTarget  = tFlow;       }
    pass { VertexShader = PostProcessVS; PixelShader = PS_Confidence;      RenderTarget  = tConfidence; }
    pass { VertexShader = PostProcessVS; PixelShader = PS_ATrousPassA;     RenderTarget  = tFlow8;      }
    pass { VertexShader = PostProcessVS; PixelShader = PS_ATrousPassB;     RenderTarget  = tFlow;       }

    pass { VertexShader = PostProcessVS; PixelShader = PS_StoreFlow; RenderTarget0 = tPrevFrameFlow; RenderTarget1 = tPrevConfidence; }
    pass { VertexShader = PostProcessVS; PixelShader = PS_StoreLuma; RenderTarget  = tPrevLuma;                                       }

    //dcp fog mask
    #if FOG_MASK
        pass { VertexShader = PostProcessVS;  PixelShader = PS_DarkChannel;             RenderTarget0 = tDarkChannel;          RenderTarget1 = tBrightestColor; }
        pass { VertexShader = PostProcessVS;  PixelShader = PS_PatchMinHorizontal;      RenderTarget  = tDarkChannelRowMin; }
        pass { VertexShader = PostProcessVS;  PixelShader = PS_PatchMinVertical;        RenderTarget0 = tTransmission;         RenderTarget1 = tGuideMoments; }

        pass { VertexShader = PostProcessVS;  PixelShader = PS_ReduceAirlight1;         RenderTarget0 = tReduceBest1;          RenderTarget1 = tReduceSum1; }
        pass { VertexShader = PostProcessVS;  PixelShader = PS_ReduceAirlight2;         RenderTarget0 = tReduceBest2;          RenderTarget1 = tReduceSum2; }
        pass { VertexShader = PostProcessVS;  PixelShader = PS_ReduceAirlight3;         RenderTarget0 = tReduceBest3;          RenderTarget1 = tReduceSum3; }
        pass { VertexShader = PostProcessVS;  PixelShader = PS_ReduceAirlight4;         RenderTarget0 = tReduceBest4;          RenderTarget1 = tReduceSum4; }
        pass { VertexShader = PostProcessVS;  PixelShader = PS_ResolveFogState;         RenderTarget  = tFogState; }

        pass { VertexShader = PostProcessVS;  PixelShader = PS_GuideMomentsHorizontal;  RenderTarget  = tGuideMomentsRowMean; }
        pass { VertexShader = PostProcessVS;  PixelShader = PS_GuideCoeffs;             RenderTarget  = tGuideCoeffs; }
        pass { VertexShader = PostProcessVS;  PixelShader = PS_GuideCoeffsHorizontal;   RenderTarget  = tGuideCoeffsRowMean; }
        pass { VertexShader = PostProcessVS;  PixelShader = PS_GuideCoeffsVertical;     RenderTarget  = tGuideCoeffsMean; }

        pass { VertexShader = PostProcessVS;  PixelShader = PS_FogMask;                 RenderTarget  = tFogMask; }
        pass { VertexShader = PostProcessVS;  PixelShader = PS_StoreHaze;               RenderTarget  = tPrevHaze; }
        pass { VertexShader = PostProcessVS;  PixelShader = PS_StoreFogState;           RenderTarget  = tPrevFogState; }
    #endif

    //debug views
#if DEBUG_KERNEL
    pass { VertexShader = PostProcessVS; PixelShader = PS_Debug; }
#endif
}

}
