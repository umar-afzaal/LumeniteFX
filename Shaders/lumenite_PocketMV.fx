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


        Filename   : PocketMV.fx
        Version    : 2026.10.17
        Author     : Afzaal (Kaidō)
        Description: Superfast motion vectors for low-end hardware.
        License    : AGNYA License (https://github.com/nvb-uy/AGNYA-License)

        ========================================================================
*/

/*------------------.
| :: DEFINITIONS :: |
'------------------*/
#define EPSILON 1e-6

#ifndef DEBUG_FLOW
    #define DEBUG_FLOW 0
#endif

/*--------------.
| :: HEADERS :: |
'--------------*/
#include "ReShade.fxh"

/*---------------.
| :: UNIFORMS :: |
'---------------*/
uniform uint FRAME_COUNT < source = "framecount"; >;

namespace PocketMV {

/*---------------------.
| :: RENDER TARGETS :: |
'---------------------*/
texture2D tFlow { Width = BUFFER_WIDTH/8; Height = BUFFER_HEIGHT/8; Format = RG16F; };
sampler2D sFlow { Texture = tFlow; MagFilter = POINT; MinFilter = POINT; };

texture2D tConfidence { Width = BUFFER_WIDTH/8; Height = BUFFER_HEIGHT/8; Format = R16F; };
sampler2D sConfidence { Texture = tConfidence; };

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

/*--------------.
| :: HELPERS :: |
'--------------*/
bool IsOOB(float2 uv) {
    return any(uv < 0.0) || any(uv > 1.0);
}

float3 GetColor(float2 uv)
{
    return tex2Dlod(ReShade::BackBuffer, float4(uv, 0, 0)).rgb;
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
    float lumaC = tex2Dlod(sCurrLuma, float4(uv,                                       0, 0)).x;
    float lumaW = tex2Dlod(sCurrLuma, float4(uv + float2(-1.0, 0.0) * texelSize,        0, 0)).x;
    float lumaE = tex2Dlod(sCurrLuma, float4(uv + float2( 1.0, 0.0) * texelSize,        0, 0)).x;
    float lumaN = tex2Dlod(sCurrLuma, float4(uv + float2( 0.0,-1.0) * texelSize,        0, 0)).x;
    float lumaS = tex2Dlod(sCurrLuma, float4(uv + float2( 0.0, 1.0) * texelSize,        0, 0)).x;
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
        v[i] = isValid ? tex2Dlod(flowSrc, float4(sampleUV, 0, mip)).xy : float2(1e38, 1e38);
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
    float2 centerFlow = tex2Dlod(motionSrc, float4(uv, 0, 0)).xy;
    float  centerConf = max(tex2Dlod(sConfidence, float4(uv, 0, 0)).r, 0.01); //0.01 floor prevents NaN if conf hits 0
    float2 sum = centerFlow * centerConf;
    float  totalWeight = centerConf;
    [unroll] for (int i = 0; i < 8; i++) {
        float2 sampleUV     = uv + float2(offsets[i]) * dilation * BUFFER_PIXEL_SIZE * 8.0; //*8 = stride of flow grid
        float2 sampleFlow   = tex2Dlod(motionSrc, float4(sampleUV, 0, 0)).xy;
        float2 flowDelta    = (sampleFlow - centerFlow) / BUFFER_PIXEL_SIZE * 8.0;
        float  flowWeight   = exp(-dot(flowDelta, flowDelta) * 0.125);
        float weight        = flowWeight;
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
    float2 candidates[6];
    candidates[0]  = tex2D(coarseSrc, uv).xy ;
    candidates[1]  = tex2D(coarseSrc, uv + float2(0, -coarseTexelSize.y)).xy ;
    candidates[2]  = tex2D(coarseSrc, uv + float2(0,  coarseTexelSize.y)).xy ;
    candidates[3]  = tex2D(coarseSrc, uv - float2(coarseTexelSize.x, 0)).xy ;
    candidates[4]  = tex2D(coarseSrc, uv + float2(coarseTexelSize.x, 0)).xy ;
    candidates[5]  = tex2D(sPrevFrameFlow, uv).xy;

    float minCost = 1e6;
    float2 prediction = candidates[0];
    [loop] for (int i = 0; i < 6; i++) {
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

/*--------------.
| :: SHADERS :: |
'--------------*/
float PS_PackFeatures(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float luma = dot(GetColor(uv), float3(0.2126, 0.7152, 0.0722));
    return luma * rcp(1.0 + luma);
}

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

float2 PS_MedianPass8(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
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
    float currLuma = tex2Dlod(sCurrLuma, float4(uv, 0, 3)).r;
    float prevLuma = tex2Dlod(sPrevLuma, float4(prevUV, 0, 3)).r;
    float lumaError = abs(currLuma - prevLuma);
    if(lumaError > 0.1) return 0.0; //no confidence
    float subpixelThreshold = length(BUFFER_PIXEL_SIZE);
    float flowMagnitude = length(flow);
    if (flowMagnitude <= subpixelThreshold) return 0.9; //if flow is subpixel, high confidence
    float motionPenalty = flowMagnitude / subpixelThreshold;
    float lengthConfidence = rcp(motionPenalty * 0.07 + 1.0);
    float photometricConfidence = exp(-lumaError * 8.0 * lengthConfidence);
    //current frame final confidence
    float currentConf = lengthConfidence * photometricConfidence;
    //temporal filter
    float historyConf = tex2D(sPrevConfidence, prevUV).r;
    float alpha = (currentConf < historyConf - 0.05) ? 0.5 : 0.1; //drop fast (kill speckles promptly), regain slowly (stay stable)
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

#if DEBUG_FLOW
float4 PS_Debug(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return float4(MotionToColor(tex2D(sFlow, uv).xy), 1);
}
#endif

/*----------------.
| :: TECHNIQUE :: |
'----------------*/
technique Lumenite_PocketMV <
    ui_label = "LUMENITE: PocketMV";
    ui_tooltip = "Superfast motion vectors for ReShade.";
>
{
    //optical flow
    pass { VertexShader = PostProcessVS; PixelShader = PS_PackFeatures;    RenderTarget  = tCurrLuma;                                       }
    pass { VertexShader = PostProcessVS; PixelShader = PS_ComputeFlow128;  RenderTarget  = tFlow128;                                        }
    pass { VertexShader = PostProcessVS; PixelShader = PS_UpscaleFlow64;   RenderTarget  = tFlow64A;                                        }
    pass { VertexShader = PostProcessVS; PixelShader = PS_MedianPass64;    RenderTarget  = tFlow64B;                                        }
    pass { VertexShader = PostProcessVS; PixelShader = PS_UpscaleFlow32;   RenderTarget  = tFlow32A;                                        }
    pass { VertexShader = PostProcessVS; PixelShader = PS_MedianPass32;    RenderTarget  = tFlow32B;                                        }
    pass { VertexShader = PostProcessVS; PixelShader = PS_UpscaleFlow16;   RenderTarget  = tFlow16A;                                        }
    pass { VertexShader = PostProcessVS; PixelShader = PS_MedianPass16;    RenderTarget  = tFlow16B;                                        }

    pass { VertexShader = PostProcessVS; PixelShader = PS_UpscaleFlow8;    RenderTarget  = tFlow8;                                          }
    pass { VertexShader = PostProcessVS; PixelShader = PS_MedianPass8;     RenderTarget  = tFlow;                                           }
    pass { VertexShader = PostProcessVS; PixelShader = PS_Confidence;      RenderTarget  = tConfidence;                                     }
    pass { VertexShader = PostProcessVS; PixelShader = PS_ATrousPassA;     RenderTarget  = tFlow8;                                          }
    pass { VertexShader = PostProcessVS; PixelShader = PS_ATrousPassB;     RenderTarget  = tFlow;                                           }

    pass { VertexShader = PostProcessVS; PixelShader = PS_StoreFlow;       RenderTarget0 = tPrevFrameFlow; RenderTarget1 = tPrevConfidence; }
    pass { VertexShader = PostProcessVS; PixelShader = PS_StoreLuma;       RenderTarget  = tPrevLuma;                                       }

    //debug views
#if DEBUG_FLOW
    pass { VertexShader = PostProcessVS; PixelShader = PS_Debug; }
#endif
}

}
