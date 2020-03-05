
#include "VctCommon.hlsli"

// vct per pass defines

// toggle light types on and off
#define APPLY_AMBIENT_LIGHT                     0
#define APPLY_DIRECTIONAL_LIGHT                 1
#define APPLY_FLASHLIGHT                        1
// these are looking wrong right now
#define APPLY_NON_DIRECTIONAL_LIGHTS            0
// sample previous frame's indirect light
#define VCT_APPLY_INDIRECT_LIGHT                0
// colorize secondary bounce
#define VCT_APPLY_DEBUG_TINT_TO_INDIRECT_LIGHT  0



#include "ModelViewerRS.hlsli"
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

struct GSOutput : VSOutput
{
    sample float2 swizzle : TexCoord3;
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

// Source voxel data from previous frame
Texture3D<float4> texVoxel : register(t70);

// Destination voxel data for this frame
RWTexture3D<uint> voxelBuffer : register(u1);

// interlocked average garbage

float4 UnpackFloat4FromUint(uint val)
{
    return float4(
        float((val & 0x000000ff)),
        float((val & 0x0000ff00) >> 8u),
        float((val & 0x00ff0000) >> 16u),
        float((val & 0xff000000) >> 24u)
    );
}

uint PackUintFromFloat4(float4 val)
{
    return (uint(val.w) & 0x000000ff) << 24u
        | (uint(val.z) & 0x000000ff) << 16u
        | (uint(val.y) & 0x000000ff) << 8u
        | (uint(val.x) & 0x000000ff);
}

bool ImageAtomicCompareHelper(uint3 coords, uint previousStoredVal, uint newVal, inout uint currentStoredVal)
{
    InterlockedCompareExchange(voxelBuffer[coords], previousStoredVal, newVal, currentStoredVal);
    return (currentStoredVal != previousStoredVal);
}

void ImageAtomicAverage(uint3 coords, float4 val)
{
    val.rgb *= 255.0;
    uint newVal = PackUintFromFloat4(val);
    uint previousStoredVal = 0u;
    uint currentStoredVal = 0u;
    while (ImageAtomicCompareHelper(coords, previousStoredVal, newVal, currentStoredVal))
    {
        previousStoredVal = currentStoredVal;
        float4 rVal = UnpackFloat4FromUint(currentStoredVal);
        rVal.xyz = (rVal.xyz * rVal.w); // Denormalize
        float4 currValF = rVal + val;   // Add new value
        currValF.xyz *= (1.0/currValF.w); // Renormalize
        newVal = PackUintFromFloat4(currValF);
    }
}

void WriteVoxelValue (uint3 voxelPos, float4 color, float3 geometryNormal)
{
#if VCT_USE_ANISOTROPIC_VOXELS

    // Store unique value per +/-x, +/-y, +/-z
    uint3 voxelPosBase = voxelPos;
    voxelPosBase.x *= 6;

    float xWeight = geometryNormal.x;
    float yWeight = geometryNormal.y;
    float zWeight = geometryNormal.z;

    ImageAtomicAverage(voxelPosBase + uint3(0, 0, 0), float4(color.xyz * saturate( xWeight), 1.0) );
    ImageAtomicAverage(voxelPosBase + uint3(1, 0, 0), float4(color.xyz * saturate(-xWeight), 1.0) );
    ImageAtomicAverage(voxelPosBase + uint3(2, 0, 0), float4(color.xyz * saturate( yWeight), 1.0) );
    ImageAtomicAverage(voxelPosBase + uint3(3, 0, 0), float4(color.xyz * saturate(-yWeight), 1.0) );
    ImageAtomicAverage(voxelPosBase + uint3(4, 0, 0), float4(color.xyz * saturate( zWeight), 1.0) );
    ImageAtomicAverage(voxelPosBase + uint3(5, 0, 0), float4(color.xyz * saturate(-zWeight), 1.0) );

#else
    ImageAtomicAverage(voxelPos, color);
#endif
}


cbuffer PSConstants : register(b0)
{
    float3 SunDirection;
    float3 SunColor;
    float3 AmbientColor;
    float4 ShadowTexelSize;

    float4 VctWorldMin;
    float4 VctWorldSpanInverse;

    float4 VctSpotPosRad;
    float4 VctSpotDir;
    float4 VctSpotColor;
    float4 VctSpotAngles;

    float4 InvTileDim;
    uint4 TileCount;
    uint4 FirstLightIndex;
}
#define kWorldMin       (VctWorldMin.xyz)
#define kInvWorldSpan   (VctWorldSpanInverse.xyz)

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

float3 ApplyLightSimple(
    float3 diffuseColor,
    float3 normal,
    float3 lightDir,
    float3 lightColor
)
{
    float nDotL = saturate(dot(normal, lightDir));

    return nDotL * lightColor * diffuseColor;
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

    return shadow * ApplyLightSimple(
        diffuseColor,
        normal,
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


[RootSignature(ModelViewer_RootSig)]
//float3 main(VSOutput vsOutput) : SV_Target0
void main(GSOutput vsOutput)
{
    uint2 pixelPos = vsOutput.position.xy;

    float3 diffuseAlbedo = texDiffuse.Sample(sampler0, vsOutput.uv);
#if VCT_PLACEHOLDER_DIFFUSE
    diffuseAlbedo = float3(0.18, 0.18, 0.18);
    diffuseAlbedo = lerp(diffuseAlbedo, float3(0.2, 0.01, 0.03), smoothstep(0.0, 0.8, dot(vsOutput.normal.x, -1.0)));
    diffuseAlbedo = lerp(diffuseAlbedo, float3(0.03, 0.2, 0.01), smoothstep(0.0, 0.8, dot(vsOutput.normal.x,  1.0)));
#endif

    float3 colorSum = 0;
#if APPLY_AMBIENT_LIGHT
    {
        // ssao looking weird so turn off for now.
        // anyway, probably don't want regular model occlusion applied to voxels?
        float ao = 1.0; // texSSAO[pixelPos];
        colorSum += ApplyAmbientLight( diffuseAlbedo, ao, AmbientColor );
    }
#endif

    float gloss = 128.0;
    float3 normal;
    //{
        normal = texNormal.Sample(sampler0, vsOutput.uv) * 2.0 - 1.0;
        AntiAliasSpecular(normal, gloss);
        float3x3 tbn = float3x3(normalize(vsOutput.tangent), normalize(vsOutput.bitangent), normalize(vsOutput.normal));
        normal = normalize(mul(normal, tbn));
    //}

#if 0
    float3 specularAlbedo = float3( 0.56, 0.56, 0.56 );
    float specularMask = texSpecular.Sample(sampler0, vsOutput.uv).g;
#else
    float3 specularAlbedo = float3(0.0, 0.0, 0.0);
    float specularMask = 0.0;
#endif
    float3 viewDir = normalize(vsOutput.viewDir);
#if APPLY_DIRECTIONAL_LIGHT
    colorSum += ApplyDirectionalLight( diffuseAlbedo, specularAlbedo, specularMask, gloss, normalize(vsOutput.normal), viewDir, SunDirection, SunColor, vsOutput.shadowCoord );
#endif // APPLY_DIRECTIONAL_LIGHT

#if APPLY_FLASHLIGHT
    colorSum += ApplyConeLight(
        diffuseAlbedo,
        specularAlbedo,
        specularMask,
        gloss,
        normal,
        viewDir,
        vsOutput.worldPos,
        VctSpotPosRad.xyz,
        VctSpotPosRad.w,
        VctSpotColor.xyz,
        VctSpotDir.xyz,
        VctSpotAngles.xy
    );
#endif

#if VCT_APPLY_INDIRECT_LIGHT
    {
        float3 worldPos = vsOutput.worldPos.xyz;
        float3 voxelPos = (worldPos - kWorldMin) * kInvWorldSpan;

        // high res voxel step size
        float3 geomNormal = normalize(vsOutput.normal);
        float3 voxelNormal = geomNormal * kInvWorldSpan;
        float3 voxelStep = voxelNormal * (1.0/128.0);

        // step away from surface to avoid self lighting
        // division by magnitude of greatest component to set that
        // component to 1. step 1 voxel away.
        float3 absVN = abs(voxelNormal);
        float maxVN = max(absVN.x, max(absVN.y, max(absVN.z, 1e-5)));
        float3 voxelOffset = voxelNormal * (1.0 / maxVN) * (1.0/128.0);
        voxelPos += voxelOffset;

        // construct tangent frame from normal instead of provided tangent and bitangent.
        // want consistent frame across surface instead of change at mirrored uv boundary
        // and want to support eventually geometry that does not provide tangent or uvs.
        float3x3 tanFrame = BuildTangentFrameFromNormal(geomNormal);

        float3 indirectLight = ApplyIndirectLight(diffuseAlbedo, tanFrame, texVoxel, sampler2, voxelPos, voxelStep);
#if VCT_APPLY_DEBUG_TINT_TO_INDIRECT_LIGHT
        float indirectAvg = dot(indirectLight, float3(0.33, 0.34, 0.33));
        indirectLight = float3(indirectAvg, 0.0, indirectAvg);
#endif
        colorSum += indirectLight * 0.2;
    }
#endif // VCT_APPLY_INDIRECT_LIGHT


#if APPLY_NON_DIRECTIONAL_LIGHTS
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

#endif // APPLY_NON_DIRECTIONAL_LIGHTS
    
    // xy coords are in screen space pixels, offset by +0.5
    // ie: the 0th pixel has a position of (0.5, 0.5)
    float3 svPos = vsOutput.position.xyz;

    // clamp to (0, 255) range
    svPos.xy = max(svPos.xy, 0.0);
    svPos.xy = min(svPos.xy, 255.0);
    
    // z value should probably still be (0, 1)
    svPos.z = saturate(svPos.z) * 255.0;

    // convert to uint3 for sampling
    uint3 voxelPos = uint3(svPos);

    // debug color to identify projected axis
    float3 debugColor = float3(0.0, 0.0, 1.0);

    // Undo geometry shader swizzle for writing voxel data
    if (0.0 < vsOutput.swizzle.x)
    {
        voxelPos.xz = voxelPos.zx;

        debugColor = float3(1.0, 0.0, 0.0);
    }
    else if (0.0 < vsOutput.swizzle.y)
    {
        voxelPos.yz = voxelPos.zy;

        debugColor = float3(0.0, 1.0, 0.0);
    }

    // flip y-dir
    voxelPos.y = 255 - voxelPos.y;

#if 1
    // OR!
    float3 worldPos = vsOutput.worldPos.xyz;
    float3 normalizedWorld = (worldPos - kWorldMin) * kInvWorldSpan;
    normalizedWorld = saturate(normalizedWorld);
    normalizedWorld = normalizedWorld * 255.0;
    voxelPos = uint3(normalizedWorld);
#endif

    float4 newVal = float4(diffuseAlbedo, 1.0);
#if APPLY_AMBIENT_LIGHT || APPLY_DIRECTIONAL_LIGHT || APPLY_NON_DIRECTIONAL_LIGHTS
    newVal.xyz = saturate(colorSum * VOXEL_PACK_SCALE);
#endif

    //ImageAtomicAverage(voxelPos, newVal);
    WriteVoxelValue(voxelPos, newVal, vsOutput.normal);

    return;// colorSum;
}
