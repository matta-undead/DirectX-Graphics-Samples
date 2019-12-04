// Below is copyright notice from original ModelViewerPS.hlsl,
// from MiniEngine. Modifying to add voxel cone tracing. Did
// not receive feedback :)

#define VCT_APPLY_DIRECTIONAL_LIGHT             1
#define VCT_APPLY_AMBIENT_LIGHT                 0
#define VCT_APPLY_ADDITIONAL_LIGHTS             0
#define VCT_APPLY_INDIRECT_LIGHT                1
#define VCT_APPLY_SSAO_TO_INDIRECT              1
#define VCT_APPLY_INDIRECT_LIGHT_SPECULAR       0
#define VCT_INDIRECT_LIGHT_NEEDS_ONE_OVER_PI    0

#define CONE_DIR_0      float3(0.0, 1.0, 0.0)
#define CONE_DIR_1      float3(0.0, 0.5, 0.866025)
#define CONE_DIR_2      float3(0.823639, 0.5, 0.267617)
#define CONE_DIR_3      float3(0.509037, 0.5, -0.700629)
#define CONE_DIR_4      float3(-0.509037, 0.5, -0.700629)
#define CONE_DIR_5      float3(-0.823639, 0.5, 0.267617)

#if VCT_INDIRECT_LIGHT_NEEDS_ONE_OVER_PI
    #define CONE_WEIGHT_UP      (5.0/(20.0*3.14159))
    #define CONE_WEIGHT_SIDE    (3.0/(20.0*3.14159))
#else
    #define CONE_WEIGHT_UP      (5.0/20.0)
    #define CONE_WEIGHT_SIDE    (3.0/20.0)
#endif


//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the MIT License (MIT).
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
// Developed by Minigraph
//
// Author(s):    James Stanard
//                Alex Nankervis
//
// Thanks to Michal Drobot for his feedback.

#include "VctModelViewerRS.hlsli"
#include "LightGrid.hlsli"

// outdated warning about for-loop variable scope
#pragma warning (disable: 3078)
// single-iteration loop
#pragma warning (disable: 3557)

struct VSOutput
{
    sample float4 position : SV_Position;
    sample float3 worldPos : WorldPos;
    sample float2 uv : TexCoord0;
    sample float3 viewDir : TexCoord1;
    sample float3 shadowCoord : TexCoord2;
    sample float3 normal : Normal;
    sample float3 tangent : Tangent;
    sample float3 bitangent : Bitangent;
};

Texture2D<float3> texDiffuse        : register(t0);
Texture2D<float3> texSpecular        : register(t1);
//Texture2D<float4> texEmissive        : register(t2);
Texture2D<float3> texNormal            : register(t3);
//Texture2D<float4> texLightmap        : register(t4);
//Texture2D<float4> texReflection    : register(t5);
Texture2D<float> texSSAO            : register(t64);
Texture2D<float> texShadow            : register(t65);

StructuredBuffer<LightData> lightBuffer : register(t66);
Texture2DArray<float> lightShadowArrayTex : register(t67);
ByteAddressBuffer lightGrid : register(t68);
ByteAddressBuffer lightGridBitMask : register(t69);

Texture3D<float4> texVoxel : register(t70);

cbuffer PSConstants : register(b0)
{
    float3 SunDirection;
    float3 SunColor;
    float3 AmbientColor;
    float4 ShadowTexelSize;

    float4 InvTileDim;
    uint4 TileCount;
    uint4 FirstLightIndex;
}

SamplerState sampler0 : register(s0);
SamplerComparisonState shadowSampler : register(s1);
SamplerState sampler2 : register(s2);

void AntiAliasSpecular( inout float3 texNormal, inout float gloss )
{
    float normalLenSq = dot(texNormal, texNormal);
    float invNormalLen = rsqrt(normalLenSq);
    texNormal *= invNormalLen;
    gloss = lerp(1, gloss, rcp(invNormalLen));
}

// Apply fresnel to modulate the specular albedo
void FSchlick( inout float3 specular, inout float3 diffuse, float3 lightDir, float3 halfVec )
{
    float fresnel = pow(1.0 - saturate(dot(lightDir, halfVec)), 5.0);
    specular = lerp(specular, 1, fresnel);
    diffuse = lerp(diffuse, 0, fresnel);
}

float3 ApplyAmbientLight(
    float3    diffuse,    // Diffuse albedo
    float    ao,            // Pre-computed ambient-occlusion
    float3    lightColor    // Radiance of ambient light
    )
{
    return ao * diffuse * lightColor;
}

float GetShadow( float3 ShadowCoord )
{
#ifdef SINGLE_SAMPLE
    float result = texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy, ShadowCoord.z );
#else
    const float Dilation = 2.0;
    float d1 = Dilation * ShadowTexelSize.x * 0.125;
    float d2 = Dilation * ShadowTexelSize.x * 0.875;
    float d3 = Dilation * ShadowTexelSize.x * 0.625;
    float d4 = Dilation * ShadowTexelSize.x * 0.375;
    float result = (
        2.0 * texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy, ShadowCoord.z ) +
        texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy + float2(-d2,  d1), ShadowCoord.z ) +
        texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy + float2(-d1, -d2), ShadowCoord.z ) +
        texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy + float2( d2, -d1), ShadowCoord.z ) +
        texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy + float2( d1,  d2), ShadowCoord.z ) +
        texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy + float2(-d4,  d3), ShadowCoord.z ) +
        texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy + float2(-d3, -d4), ShadowCoord.z ) +
        texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy + float2( d4, -d3), ShadowCoord.z ) +
        texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy + float2( d3,  d4), ShadowCoord.z )
        ) / 10.0;
#endif
    return result * result;
}

float GetShadowConeLight(uint lightIndex, float3 shadowCoord)
{
    float result = lightShadowArrayTex.SampleCmpLevelZero(
        shadowSampler, float3(shadowCoord.xy, lightIndex), shadowCoord.z);
    return result * result;
}

float3 ApplyLightCommon(
    float3    diffuseColor,    // Diffuse albedo
    float3    specularColor,    // Specular albedo
    float    specularMask,    // Where is it shiny or dingy?
    float    gloss,            // Specular power
    float3    normal,            // World-space normal
    float3    viewDir,        // World-space vector from eye to point
    float3    lightDir,        // World-space vector from point to light
    float3    lightColor        // Radiance of directional light
    )
{
    float3 halfVec = normalize(lightDir - viewDir);
    float nDotH = saturate(dot(halfVec, normal));

    FSchlick( diffuseColor, specularColor, lightDir, halfVec );

    float specularFactor = specularMask * pow(nDotH, gloss) * (gloss + 2) / 8;

    float nDotL = saturate(dot(normal, lightDir));

    return nDotL * lightColor * (diffuseColor + specularFactor * specularColor);
}

float3 ApplyDirectionalLight(
    float3    diffuseColor,    // Diffuse albedo
    float3    specularColor,    // Specular albedo
    float    specularMask,    // Where is it shiny or dingy?
    float    gloss,            // Specular power
    float3    normal,            // World-space normal
    float3    viewDir,        // World-space vector from eye to point
    float3    lightDir,        // World-space vector from point to light
    float3    lightColor,        // Radiance of directional light
    float3    shadowCoord        // Shadow coordinate (Shadow map UV & light-relative Z)
    )
{
    float shadow = GetShadow(shadowCoord);

    return shadow * ApplyLightCommon(
        diffuseColor,
        specularColor,
        specularMask,
        gloss,
        normal,
        viewDir,
        lightDir,
        lightColor
        );
}

float3 ApplyPointLight(
    float3    diffuseColor,    // Diffuse albedo
    float3    specularColor,    // Specular albedo
    float    specularMask,    // Where is it shiny or dingy?
    float    gloss,            // Specular power
    float3    normal,            // World-space normal
    float3    viewDir,        // World-space vector from eye to point
    float3    worldPos,        // World-space fragment position
    float3    lightPos,        // World-space light position
    float    lightRadiusSq,
    float3    lightColor        // Radiance of directional light
    )
{
    float3 lightDir = lightPos - worldPos;
    float lightDistSq = dot(lightDir, lightDir);
    float invLightDist = rsqrt(lightDistSq);
    lightDir *= invLightDist;

    // modify 1/d^2 * R^2 to fall off at a fixed radius
    // (R/d)^2 - d/R = [(1/d^2) - (1/R^2)*(d/R)] * R^2
    float distanceFalloff = lightRadiusSq * (invLightDist * invLightDist);
    distanceFalloff = max(0, distanceFalloff - rsqrt(distanceFalloff));

    return distanceFalloff * ApplyLightCommon(
        diffuseColor,
        specularColor,
        specularMask,
        gloss,
        normal,
        viewDir,
        lightDir,
        lightColor
        );
}

float3 ApplyConeLight(
    float3    diffuseColor,    // Diffuse albedo
    float3    specularColor,    // Specular albedo
    float    specularMask,    // Where is it shiny or dingy?
    float    gloss,            // Specular power
    float3    normal,            // World-space normal
    float3    viewDir,        // World-space vector from eye to point
    float3    worldPos,        // World-space fragment position
    float3    lightPos,        // World-space light position
    float    lightRadiusSq,
    float3    lightColor,        // Radiance of directional light
    float3    coneDir,
    float2    coneAngles
    )
{
    float3 lightDir = lightPos - worldPos;
    float lightDistSq = dot(lightDir, lightDir);
    float invLightDist = rsqrt(lightDistSq);
    lightDir *= invLightDist;

    // modify 1/d^2 * R^2 to fall off at a fixed radius
    // (R/d)^2 - d/R = [(1/d^2) - (1/R^2)*(d/R)] * R^2
    float distanceFalloff = lightRadiusSq * (invLightDist * invLightDist);
    distanceFalloff = max(0, distanceFalloff - rsqrt(distanceFalloff));

    float coneFalloff = dot(-lightDir, coneDir);
    coneFalloff = saturate((coneFalloff - coneAngles.y) * coneAngles.x);

    return (coneFalloff * distanceFalloff) * ApplyLightCommon(
        diffuseColor,
        specularColor,
        specularMask,
        gloss,
        normal,
        viewDir,
        lightDir,
        lightColor
        );
}

float3 ApplyConeShadowedLight(
    float3    diffuseColor,    // Diffuse albedo
    float3    specularColor,    // Specular albedo
    float    specularMask,    // Where is it shiny or dingy?
    float    gloss,            // Specular power
    float3    normal,            // World-space normal
    float3    viewDir,        // World-space vector from eye to point
    float3    worldPos,        // World-space fragment position
    float3    lightPos,        // World-space light position
    float    lightRadiusSq,
    float3    lightColor,        // Radiance of directional light
    float3    coneDir,
    float2    coneAngles,
    float4x4 shadowTextureMatrix,
    uint    lightIndex
    )
{
    float4 shadowCoord = mul(shadowTextureMatrix, float4(worldPos, 1.0));
    shadowCoord.xyz *= rcp(shadowCoord.w);
    float shadow = GetShadowConeLight(lightIndex, shadowCoord.xyz);

    return shadow * ApplyConeLight(
        diffuseColor,
        specularColor,
        specularMask,
        gloss,
        normal,
        viewDir,
        worldPos,
        lightPos,
        lightRadiusSq,
        lightColor,
        coneDir,
        coneAngles
        );
}

// options for F+ variants and optimizations
#ifdef _WAVE_OP // SM 6.0 (new shader compiler)

// choose one of these:
//# define BIT_MASK
# define BIT_MASK_SORTED
//# define SCALAR_LOOP
//# define SCALAR_BRANCH

// enable to amortize latency of vector read in exchange for additional VGPRs being held
# define LIGHT_GRID_PRELOADING

// configured for 32 sphere lights, 64 cone lights, and 32 cone shadowed lights
# define POINT_LIGHT_GROUPS            1
# define SPOT_LIGHT_GROUPS            2
# define SHADOWED_SPOT_LIGHT_GROUPS    1
# define POINT_LIGHT_GROUPS_TAIL            POINT_LIGHT_GROUPS
# define SPOT_LIGHT_GROUPS_TAIL                POINT_LIGHT_GROUPS_TAIL + SPOT_LIGHT_GROUPS
# define SHADOWED_SPOT_LIGHT_GROUPS_TAIL    SPOT_LIGHT_GROUPS_TAIL + SHADOWED_SPOT_LIGHT_GROUPS


uint GetGroupBits(uint groupIndex, uint tileIndex, uint lightBitMaskGroups[4])
{
#ifdef LIGHT_GRID_PRELOADING
    return lightBitMaskGroups[groupIndex];
#else
    return lightGridBitMask.Load(tileIndex * 16 + groupIndex * 4);
#endif
}

uint64_t Ballot64(bool b)
{
    uint4 ballots = WaveActiveBallot(b);
    return (uint64_t)ballots.y << 32 | (uint64_t)ballots.x;
}

#endif // _WAVE_OP

// Helper function for iterating over a sparse list of bits.  Gets the offset of the next
// set bit, clears it, and returns the offset.
uint PullNextBit( inout uint bits )
{
    uint bitIndex = firstbitlow(bits);
    bits ^= 1 << bitIndex;
    return bitIndex;
}

float3 TraceCone(float3 voxelPos, float3 voxelStep, float normalizedConeDiameter)
{
    float opacity = 0.0;
    float transmitted = 1.0;
    float3 indirectLight = float3(0.0, 0.0, 0.0);

    // I think voxelSample.w (alpha/opacity) is already factored into
    // voxelSample.xyz from mip filtering and doesn't need to be multiplied
    // against voxelSample.xyz again here, but I could be wrong. And then,
    // what about that factor of PI? In weight or not, pending define above.

    // Handle cone diameter. For example, in the diffuse case,
    // hemisphere is modelled by six cones with a 60 degree
    // opening. Tan(60/2) ~= 0.577350, 2x that ~= 1.154701,
    // this is the scale from cone length to diameter, which
    // should guide mip selection.
    // want log2(dist * 1.154701) -> mip.
    // dist would need to be in relevant units, scale by voxel size.
    float distanceScalar = length(voxelStep) * (128.0 * normalizedConeDiameter);//1.154701);

    voxelPos += 2.0 * voxelStep;
    float4 voxelSample = texVoxel.SampleLevel(sampler2, voxelPos, log2(distanceScalar*2.0) );
    indirectLight = voxelSample.xyz * transmitted;
    opacity += voxelSample.w * transmitted;
    transmitted = saturate(1.0 - opacity);

    voxelPos += 4.0 * voxelStep;
    voxelSample = texVoxel.SampleLevel(sampler2, voxelPos, log2(distanceScalar*4.0) );
    indirectLight += voxelSample.xyz * transmitted;
    opacity += voxelSample.w * transmitted;
    transmitted = saturate(1.0 - opacity);

    voxelPos += 8.0 * voxelStep;
    voxelSample = texVoxel.SampleLevel(sampler2, voxelPos, log2(distanceScalar*8.0) );
    indirectLight += voxelSample.xyz * transmitted;
    opacity += voxelSample.w * transmitted;
    transmitted = saturate(1.0 - opacity);

    voxelPos += 16.0 * voxelStep;
    voxelSample = texVoxel.SampleLevel(sampler2, voxelPos, log2(distanceScalar*16.0) );
    indirectLight += voxelSample.xyz * transmitted;
    opacity += voxelSample.w * transmitted;
    transmitted = saturate(1.0 - opacity);

    voxelPos += 32.0 * voxelStep;
    voxelSample = texVoxel.SampleLevel(sampler2, voxelPos, log2(distanceScalar*32.0) );
    indirectLight += voxelSample.xyz * transmitted;
    //opacity += voxelSample.w * transmitted;
    //transmitted = saturate(1.0 - opacity);

    return indirectLight;
}

float3 TraceConeSpec(float3 voxelPos, float3 voxelStep, float normalizedConeDiameter)
{
    float opacity = 0.0;
    float transmitted = 1.0;
    float3 indirectLight = float3(0.0, 0.0, 0.0);

    float distanceScalar = length(voxelStep) * (128.0 * normalizedConeDiameter);//1.154701);

    float3 initialVoxelPos = voxelPos;

    for (float i = 0.0; i < 10.0; i += 1.0)
    {
        voxelPos += 2.0 * voxelStep;
        float4 voxelSample = texVoxel.SampleLevel(sampler2, voxelPos, log2(length(voxelPos - initialVoxelPos) * distanceScalar));
        indirectLight += voxelSample.xyz * transmitted;
        opacity += voxelSample.w * transmitted;
        transmitted = saturate(1.0 - opacity);
    }

    return indirectLight;
}


[RootSignature(ModelViewer_RootSig)]
float3 main(VSOutput vsOutput) : SV_Target0
{
    uint2 pixelPos = vsOutput.position.xy;
    float3 diffuseAlbedo = texDiffuse.Sample(sampler0, vsOutput.uv);
    float3 colorSum = 0;
#if VCT_APPLY_AMBIENT_LIGHT
    {
        float ao = texSSAO[pixelPos];
        colorSum += ApplyAmbientLight( diffuseAlbedo, ao, AmbientColor );
    }
#endif // VCT_APPLY_DIRECTIONAL_LIGHT

    float gloss = 128.0;
    float3 normal;
    //{
        normal = texNormal.Sample(sampler0, vsOutput.uv) * 2.0 - 1.0;
        AntiAliasSpecular(normal, gloss);
        float3x3 tbn = float3x3(normalize(vsOutput.tangent), normalize(vsOutput.bitangent), normalize(vsOutput.normal));
        normal = normalize(mul(normal, tbn));
    //}

    float3 specularAlbedo = float3( 0.56, 0.56, 0.56 );
    float specularMask = texSpecular.Sample(sampler0, vsOutput.uv).g;
    float3 viewDir = normalize(vsOutput.viewDir);
#if VCT_APPLY_DIRECTIONAL_LIGHT
    colorSum += ApplyDirectionalLight( diffuseAlbedo, specularAlbedo, specularMask, gloss, normal, viewDir, SunDirection, SunColor, vsOutput.shadowCoord );
#endif // VCT_APPLY_DIRECTIONAL_LIGHT

    {
        // this is terrible, but i'm having trouble getting started.
        // so anything to make progress forward.
        float3 worldMin = float3(-1920.94592, -126.442497, -1182.80713);
        float3 worldMax = float3(1799.90808, 1429.43323, 1105.42603);

        float3 worldPos = vsOutput.worldPos.xyz;
        float3 voxelPos = (worldPos - worldMin) / (worldMax - worldMin);

        // high res voxel step size
        float3 voxelStep = normalize(vsOutput.normal) * (1.0/128.0);
        // step away from surface to avoid self lighting
        voxelPos += voxelStep;

#if VCT_APPLY_INDIRECT_LIGHT
        // 1.154701 is diameter of base of 60 degree cone with height 1.0
        // take tan of half angle, double it. tan(60/2) ~= 0.577350.
        {
            float3 indirectLight = float3(0.0, 0.0, 0.0);

            float3 coneDir = normalize(mul(CONE_DIR_1, tbn)) * (1.0/128.0);
            indirectLight += TraceCone(voxelPos, coneDir, 1.154701);

            coneDir = normalize(mul(CONE_DIR_2, tbn)) * (1.0/128.0);
            indirectLight += TraceCone(voxelPos, coneDir, 1.154701);

            coneDir = normalize(mul(CONE_DIR_3, tbn)) * (1.0/128.0);
            indirectLight += TraceCone(voxelPos, coneDir, 1.154701);

            coneDir = normalize(mul(CONE_DIR_4, tbn)) * (1.0/128.0);
            indirectLight += TraceCone(voxelPos, coneDir, 1.154701);

            coneDir = normalize(mul(CONE_DIR_5, tbn)) * (1.0/128.0);
            indirectLight += TraceCone(voxelPos, coneDir, 1.154701);

            // all non-up facing cones have same weighting
            indirectLight *= CONE_WEIGHT_SIDE;

            indirectLight += TraceCone(voxelPos, voxelStep, 1.154701) * CONE_WEIGHT_UP;

#if VCT_APPLY_SSAO_TO_INDIRECT
            float ao = texSSAO[pixelPos];
            indirectLight *= ao;
#endif // VCT_APPLY_SSAO_TO_INDIRECT

            colorSum += indirectLight * diffuseAlbedo;
        }
#endif // VCT_APPLY_INDIRECT_LIGHT

#if VCT_APPLY_INDIRECT_LIGHT_SPECULAR
        {
            float3 specConeDir = (normal*2.0 + normalize(viewDir)) * (1.0/128.0);
            float coneHalfAngle = 0.02;//1.0472*0.5; // 10 degree cone? idk... looks like gloss/roughness fixed here.
            float tanCha = tan(coneHalfAngle);
            float3 coneSpec = TraceConeSpec(voxelPos, specConeDir, 2.0*tanCha);

            colorSum += coneSpec * specularAlbedo * specularMask;
        }
#endif // VCT_APPLY_INDIRECT_LIGHT_SPECULAR
    }


#if VCT_APPLY_ADDITIONAL_LIGHTS

    uint2 tilePos = GetTilePos(pixelPos, InvTileDim.xy);
    uint tileIndex = GetTileIndex(tilePos, TileCount.x);
    uint tileOffset = GetTileOffset(tileIndex);

    // Light Grid Preloading setup
    uint lightBitMaskGroups[4] = { 0, 0, 0, 0 };
#if defined(LIGHT_GRID_PRELOADING)
    uint4 lightBitMask = lightGridBitMask.Load4(tileIndex * 16);
    
    lightBitMaskGroups[0] = lightBitMask.x;
    lightBitMaskGroups[1] = lightBitMask.y;
    lightBitMaskGroups[2] = lightBitMask.z;
    lightBitMaskGroups[3] = lightBitMask.w;
#endif

#define POINT_LIGHT_ARGS \
    diffuseAlbedo, \
    specularAlbedo, \
    specularMask, \
    gloss, \
    normal, \
    viewDir, \
    vsOutput.worldPos, \
    lightData.pos, \
    lightData.radiusSq, \
    lightData.color

#define CONE_LIGHT_ARGS \
    POINT_LIGHT_ARGS, \
    lightData.coneDir, \
    lightData.coneAngles

#define SHADOWED_LIGHT_ARGS \
    CONE_LIGHT_ARGS, \
    lightData.shadowTextureMatrix, \
    lightIndex

#if defined(BIT_MASK)
    uint64_t threadMask = Ballot64(tileIndex != ~0); // attempt to get starting exec mask

    for (uint groupIndex = 0; groupIndex < 4; groupIndex++)
    {
        // combine across threads
        uint groupBits = WaveActiveBitOr(GetGroupBits(groupIndex, tileIndex, lightBitMaskGroups));

        while (groupBits != 0)
        {
            uint bitIndex = PullNextBit(groupBits);
            uint lightIndex = 32 * groupIndex + bitIndex;

            LightData lightData = lightBuffer[lightIndex];

            if (lightIndex < FirstLightIndex.x) // sphere
            {
                colorSum += ApplyPointLight(POINT_LIGHT_ARGS);
            }
            else if (lightIndex < FirstLightIndex.y) // cone
            {
                colorSum += ApplyConeLight(CONE_LIGHT_ARGS);
            }
            else // cone w/ shadow map
            {
                colorSum += ApplyConeShadowedLight(SHADOWED_LIGHT_ARGS);
            }
        }
    }

#elif defined(BIT_MASK_SORTED)

    // Get light type groups - these can be predefined as compile time constants to enable unrolling and better scheduling of vector reads
    uint pointLightGroupTail        = POINT_LIGHT_GROUPS_TAIL;
    uint spotLightGroupTail            = SPOT_LIGHT_GROUPS_TAIL;
    uint spotShadowLightGroupTail    = SHADOWED_SPOT_LIGHT_GROUPS_TAIL;

    uint groupBitsMasks[4] = { 0, 0, 0, 0 };
    for (int i = 0; i < 4; i++)
    {
        // combine across threads
        groupBitsMasks[i] = WaveActiveBitOr(GetGroupBits(i, tileIndex, lightBitMaskGroups));
    }

    for (uint groupIndex = 0; groupIndex < pointLightGroupTail; groupIndex++)
    {
        uint groupBits = groupBitsMasks[groupIndex];

        while (groupBits != 0)
        {
            uint bitIndex = PullNextBit(groupBits);
            uint lightIndex = 32 * groupIndex + bitIndex;

            // sphere
            LightData lightData = lightBuffer[lightIndex];
            colorSum += ApplyPointLight(POINT_LIGHT_ARGS);
        }
    }

    for (uint groupIndex = pointLightGroupTail; groupIndex < spotLightGroupTail; groupIndex++)
    {
        uint groupBits = groupBitsMasks[groupIndex];

        while (groupBits != 0)
        {
            uint bitIndex = PullNextBit(groupBits);
            uint lightIndex = 32 * groupIndex + bitIndex;

            // cone
            LightData lightData = lightBuffer[lightIndex];
            colorSum += ApplyConeLight(CONE_LIGHT_ARGS);
        }
    }

    for (uint groupIndex = spotLightGroupTail; groupIndex < spotShadowLightGroupTail; groupIndex++)
    {
        uint groupBits = groupBitsMasks[groupIndex];

        while (groupBits != 0)
        {
            uint bitIndex = PullNextBit(groupBits);
            uint lightIndex = 32 * groupIndex + bitIndex;

            // cone w/ shadow map
            LightData lightData = lightBuffer[lightIndex];
            colorSum += ApplyConeShadowedLight(SHADOWED_LIGHT_ARGS);
        }
    }

#elif defined(SCALAR_LOOP)
    uint64_t threadMask = Ballot64(tileOffset != ~0); // attempt to get starting exec mask
    uint64_t laneBit = 1ull << WaveGetLaneIndex();

    while ((threadMask & laneBit) != 0) // is this thread waiting to be processed?
    { // exec is now the set of remaining threads
        // grab the tile offset for the first active thread
        uint uniformTileOffset = WaveReadLaneFirst(tileOffset);
        // mask of which threads have the same tile offset as the first active thread
        uint64_t uniformMask = Ballot64(tileOffset == uniformTileOffset);

        if (any((uniformMask & laneBit) != 0)) // is this thread one of the current set of uniform threads?
        {
            uint tileLightCount = lightGrid.Load(uniformTileOffset + 0);
            uint tileLightCountSphere = (tileLightCount >> 0) & 0xff;
            uint tileLightCountCone = (tileLightCount >> 8) & 0xff;
            uint tileLightCountConeShadowed = (tileLightCount >> 16) & 0xff;

            uint tileLightLoadOffset = uniformTileOffset + 4;

            // sphere
            for (uint n = 0; n < tileLightCountSphere; n++, tileLightLoadOffset += 4)
            {
                uint lightIndex = lightGrid.Load(tileLightLoadOffset);
                LightData lightData = lightBuffer[lightIndex];
                colorSum += ApplyPointLight(POINT_LIGHT_ARGS);
            }

            // cone
            for (uint n = 0; n < tileLightCountCone; n++, tileLightLoadOffset += 4)
            {
                uint lightIndex = lightGrid.Load(tileLightLoadOffset);
                LightData lightData = lightBuffer[lightIndex];
                colorSum += ApplyConeLight(CONE_LIGHT_ARGS);
            }

            // cone w/ shadow map
            for (uint n = 0; n < tileLightCountConeShadowed; n++, tileLightLoadOffset += 4)
            {
                uint lightIndex = lightGrid.Load(tileLightLoadOffset);
                LightData lightData = lightBuffer[lightIndex];
                colorSum += ApplyConeShadowedLight(SHADOWED_LIGHT_ARGS);
            }
        }

        // strip the current set of uniform threads from the exec mask for the next loop iteration
        threadMask &= ~uniformMask;
    }

#elif defined(SCALAR_BRANCH)

    if (Ballot64(tileOffset == WaveReadLaneFirst(tileOffset)) == ~0ull)
    {
        // uniform branch
        tileOffset = WaveReadLaneFirst(tileOffset);

        uint tileLightCount = lightGrid.Load(tileOffset + 0);
        uint tileLightCountSphere = (tileLightCount >> 0) & 0xff;
        uint tileLightCountCone = (tileLightCount >> 8) & 0xff;
        uint tileLightCountConeShadowed = (tileLightCount >> 16) & 0xff;

        uint tileLightLoadOffset = tileOffset + 4;

        // sphere
        for (uint n = 0; n < tileLightCountSphere; n++, tileLightLoadOffset += 4)
        {
            uint lightIndex = lightGrid.Load(tileLightLoadOffset);
            LightData lightData = lightBuffer[lightIndex];
            colorSum += ApplyPointLight(POINT_LIGHT_ARGS);
        }

        // cone
        for (uint n = 0; n < tileLightCountCone; n++, tileLightLoadOffset += 4)
        {
            uint lightIndex = lightGrid.Load(tileLightLoadOffset);
            LightData lightData = lightBuffer[lightIndex];
            colorSum += ApplyConeLight(CONE_LIGHT_ARGS);
        }

        // cone w/ shadow map
        for (uint n = 0; n < tileLightCountConeShadowed; n++, tileLightLoadOffset += 4)
        {
            uint lightIndex = lightGrid.Load(tileLightLoadOffset);
            LightData lightData = lightBuffer[lightIndex];
            colorSum += ApplyConeShadowedLight(SHADOWED_LIGHT_ARGS);
        }
    }
    else
    {
        // divergent branch
        uint tileLightCount = lightGrid.Load(tileOffset + 0);
        uint tileLightCountSphere = (tileLightCount >> 0) & 0xff;
        uint tileLightCountCone = (tileLightCount >> 8) & 0xff;
        uint tileLightCountConeShadowed = (tileLightCount >> 16) & 0xff;

        uint tileLightLoadOffset = tileOffset + 4;

        // sphere
        for (uint n = 0; n < tileLightCountSphere; n++, tileLightLoadOffset += 4)
        {
            uint lightIndex = lightGrid.Load(tileLightLoadOffset);
            LightData lightData = lightBuffer[lightIndex];
            colorSum += ApplyPointLight(POINT_LIGHT_ARGS);
        }

        // cone
        for (uint n = 0; n < tileLightCountCone; n++, tileLightLoadOffset += 4)
        {
            uint lightIndex = lightGrid.Load(tileLightLoadOffset);
            LightData lightData = lightBuffer[lightIndex];
            colorSum += ApplyConeLight(CONE_LIGHT_ARGS);
        }

        // cone w/ shadow map
        for (uint n = 0; n < tileLightCountConeShadowed; n++, tileLightLoadOffset += 4)
        {
            uint lightIndex = lightGrid.Load(tileLightLoadOffset);
            LightData lightData = lightBuffer[lightIndex];
            colorSum += ApplyConeShadowedLight(SHADOWED_LIGHT_ARGS);
        }
    }

#else // SM 5.0 (no wave intrinsics)

    uint tileLightCount = lightGrid.Load(tileOffset + 0);
    uint tileLightCountSphere = (tileLightCount >> 0) & 0xff;
    uint tileLightCountCone = (tileLightCount >> 8) & 0xff;
    uint tileLightCountConeShadowed = (tileLightCount >> 16) & 0xff;

    uint tileLightLoadOffset = tileOffset + 4;

    // sphere
    for (uint n = 0; n < tileLightCountSphere; n++, tileLightLoadOffset += 4)
    {
        uint lightIndex = lightGrid.Load(tileLightLoadOffset);
        LightData lightData = lightBuffer[lightIndex];
        colorSum += ApplyPointLight(POINT_LIGHT_ARGS);
    }

    // cone
    for (uint n = 0; n < tileLightCountCone; n++, tileLightLoadOffset += 4)
    {
        uint lightIndex = lightGrid.Load(tileLightLoadOffset);
        LightData lightData = lightBuffer[lightIndex];
        colorSum += ApplyConeLight(CONE_LIGHT_ARGS);
    }

    // cone w/ shadow map
    for (uint n = 0; n < tileLightCountConeShadowed; n++, tileLightLoadOffset += 4)
    {
        uint lightIndex = lightGrid.Load(tileLightLoadOffset);
        LightData lightData = lightBuffer[lightIndex];
        colorSum += ApplyConeShadowedLight(SHADOWED_LIGHT_ARGS);
    }
#endif

#endif // VCT_APPLY_ADDITIONAL_LIGHTS

    return colorSum;
}
