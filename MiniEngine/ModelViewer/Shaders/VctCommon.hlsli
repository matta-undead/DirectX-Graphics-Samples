
// common defines

// Anisotropic swtich must match define in VoxelConeTracing.h
#define VCT_USE_ANISOTROPIC_VOXELS              1
#define VCT_INDIRECT_LIGHT_NEEDS_ONE_OVER_PI    0

#if VCT_INDIRECT_LIGHT_NEEDS_ONE_OVER_PI
    #define CONE_WEIGHT_UP      (5.0/20.0)
    #define CONE_WEIGHT_SIDE    (3.0/20.0)
#else
    #define CONE_WEIGHT_UP      ((5.0*3.14159)/20.0)
    #define CONE_WEIGHT_SIDE    ((3.0*3.14159)/20.0)
#endif

#define CONE_DIR_0      float3(0.0, 1.0, 0.0)
#define CONE_DIR_1      float3(0.0, 0.5, 0.866025)
#define CONE_DIR_2      float3(0.823639, 0.5, 0.267617)
#define CONE_DIR_3      float3(0.509037, 0.5, -0.700629)
#define CONE_DIR_4      float3(-0.509037, 0.5, -0.700629)
#define CONE_DIR_5      float3(-0.823639, 0.5, 0.267617)

// Taking a fifth sample, at least with current doubling step sizes
// introduces an almost global ambient value thanks to light bleed.
// Might be fixed / reduced with anisotropic voxels. Might actually
// be desired look. But for now, nicer looking contribution from 4.
#define CONE_STEPS      4

// Storing light values in 8-bits per channel. Would rather not
// saturate. Prefer to have a better way to handle this or have
// some HDR accumulation via multiple targets.
#define VOXEL_UNPACK_SCALE       (4.0)
#define VOXEL_PACK_SCALE         (1.0/VOXEL_UNPACK_SCALE)


// shared functions

float3 TraceCone(
    in Texture3D<float4> voxelTex,
    in SamplerState voxelSmp,
    float3 voxelPos,
    float3 voxelStep,
    float normalizedConeDiameter
)
{
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
    float distanceScalar = length(voxelStep) * (128.0 * normalizedConeDiameter);

    float opacity        = 0.0;
    float transmitted    = 1.0;
    float coneStep       = 2.0;
    float3 indirectLight = float3(0.0, 0.0, 0.0);

    for (uint i = 0; (i < CONE_STEPS) && (transmitted > 0.0); ++i)
    {
        // Sample from cone and accumulate indirect light
        float4 voxelSample = voxelTex.SampleLevel(
            voxelSmp,
            coneStep * voxelStep + voxelPos,
            log2(coneStep * distanceScalar)
        );
        indirectLight += voxelSample.xyz * transmitted;

        // Update opacity and transmission from previous sample
        opacity += voxelSample.w * transmitted;
        transmitted = saturate(1.0 - opacity);

        // Step along cone
        coneStep = 2.0 * coneStep;
    }

    return indirectLight;
}

float3 TraceConeAniso(
    in Texture3D<float4> voxelTexX,
    in Texture3D<float4> voxelTexY,
    in Texture3D<float4> voxelTexZ,
    in SamplerState voxelSmp,
    float3 voxelPos,
    float3 voxelStep,
    float normalizedConeDiameter
)
{
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
    float distanceScalar = length(voxelStep) * (128.0 * normalizedConeDiameter);

    float opacity        = 0.0;
    float transmitted    = 1.0;
    float coneStep       = 2.0;
    float3 indirectLight = float3(0.0, 0.0, 0.0);

    // Need weights to blend three voxel faces
    float3 weights = abs(normalize(voxelStep));

    for (uint i = 0; (i < CONE_STEPS) && (transmitted > 0.0); ++i)
    {
        // Sample from cone and accumulate indirect light
        float3 voxelCoord = coneStep * voxelStep + voxelPos;
        float voxelMip = log2(coneStep * distanceScalar);

        float4 voxelSampleX = voxelTexX.SampleLevel(voxelSmp, voxelCoord, voxelMip);
        float4 voxelSampleY = voxelTexY.SampleLevel(voxelSmp, voxelCoord, voxelMip);
        float4 voxelSampleZ = voxelTexZ.SampleLevel(voxelSmp, voxelCoord, voxelMip);

        float4 voxelSample = weights.x * voxelSampleX
            + weights.y * voxelSampleY
            + weights.z * voxelSampleZ;

        indirectLight += voxelSample.xyz * transmitted;

        // Update opacity and transmission from previous sample
        opacity += voxelSample.w * transmitted;
        transmitted = saturate(1.0 - opacity);

        // Step along cone
        coneStep = 2.0 * coneStep;
    }

    return indirectLight;
}

float3 TraceConeSpec(
    in Texture3D<float4> voxelTex,
    in SamplerState voxelSmp,
    float3 voxelPos,
    float3 voxelStep,
    float normalizedConeDiameter
)
{
    float distanceScalar = length(voxelStep) * (128.0 * normalizedConeDiameter);

    float opacity        = 0.0;
    float transmitted    = 1.0;
    float coneStep       = 2.0;
    float3 indirectLight = float3(0.0, 0.0, 0.0);

    float3 initialVoxelPos = voxelPos;

    // Taking linear steps for specular, assuming narrower cone
    for (uint i = 0; (i < 10) && (transmitted > 0.0); ++i)
    {
        // Sample from cone and accumulate indirect light
        voxelPos += coneStep * voxelStep;
        float4 voxelSample = voxelTex.SampleLevel(
            voxelSmp,
            voxelPos,
            log2(length(voxelPos - initialVoxelPos) * distanceScalar)
        );

        // Update opacity and transmission from previous sample
        indirectLight += voxelSample.xyz * transmitted;
        opacity += voxelSample.w * transmitted;
        transmitted = saturate(1.0 - opacity);
    }

    return indirectLight;
}

float3 ApplyIndirectLight(
    float3 diffuseAlbedo,
    float3x3 tbn,
    in Texture3D<float4> voxelTex,
    in SamplerState voxelSmp,
    float3 voxelPos,
    float3 voxelStep
)
{
    // 1.154701 is diameter of base of 60 degree cone with height 1.0
    // take tan of half angle, double it. tan(60/2) ~= 0.577350.
    float3 coneDir = normalize(mul(CONE_DIR_1, tbn)) * (1.0/128.0);
    float3 indirectSum = TraceCone(voxelTex, voxelSmp, voxelPos, coneDir, 1.154701);

    coneDir = normalize(mul(CONE_DIR_2, tbn)) * (1.0/128.0);
    indirectSum += TraceCone(voxelTex, voxelSmp, voxelPos, coneDir, 1.154701);

    coneDir = normalize(mul(CONE_DIR_3, tbn)) * (1.0/128.0);
    indirectSum += TraceCone(voxelTex, voxelSmp, voxelPos, coneDir, 1.154701);

    coneDir = normalize(mul(CONE_DIR_4, tbn)) * (1.0/128.0);
    indirectSum += TraceCone(voxelTex, voxelSmp, voxelPos, coneDir, 1.154701);

    coneDir = normalize(mul(CONE_DIR_5, tbn)) * (1.0/128.0);
    indirectSum += TraceCone(voxelTex, voxelSmp, voxelPos, coneDir, 1.154701);

    // all non-up facing cones have same weighting
    indirectSum *= CONE_WEIGHT_SIDE;

    indirectSum += TraceCone(voxelTex, voxelSmp, voxelPos, voxelStep, 1.154701) * CONE_WEIGHT_UP;

    return (indirectSum * diffuseAlbedo) * VOXEL_UNPACK_SCALE;
}

float3 ApplyIndirectLightAnisoHelper(
    float3x3 tbn,
    in Texture3D<float4> voxelTexX,
    in Texture3D<float4> voxelTexY,
    in Texture3D<float4> voxelTexZ,
    in SamplerState voxelSmp,
    float3 voxelPos,
    float3 voxelStep
)
{
    // 1.154701 is diameter of base of 60 degree cone with height 1.0
    // take tan of half angle, double it. tan(60/2) ~= 0.577350.
    float3 coneDir = normalize(mul(CONE_DIR_1, tbn)) * (1.0/128.0);
    float3 indirectSum = TraceConeAniso(voxelTexX, voxelTexY, voxelTexZ, voxelSmp, voxelPos, coneDir, 1.154701);

    coneDir = normalize(mul(CONE_DIR_2, tbn)) * (1.0/128.0);
    indirectSum += TraceConeAniso(voxelTexX, voxelTexY, voxelTexZ, voxelSmp, voxelPos, coneDir, 1.154701);

    coneDir = normalize(mul(CONE_DIR_3, tbn)) * (1.0/128.0);
    indirectSum += TraceConeAniso(voxelTexX, voxelTexY, voxelTexZ, voxelSmp, voxelPos, coneDir, 1.154701);

    coneDir = normalize(mul(CONE_DIR_4, tbn)) * (1.0/128.0);
    indirectSum += TraceConeAniso(voxelTexX, voxelTexY, voxelTexZ, voxelSmp, voxelPos, coneDir, 1.154701);

    coneDir = normalize(mul(CONE_DIR_5, tbn)) * (1.0/128.0);
    indirectSum += TraceConeAniso(voxelTexX, voxelTexY, voxelTexZ, voxelSmp, voxelPos, coneDir, 1.154701);

    // all non-up facing cones have same weighting
    indirectSum *= CONE_WEIGHT_SIDE;

    indirectSum += TraceConeAniso(voxelTexX, voxelTexY, voxelTexZ, voxelSmp, voxelPos, voxelStep, 1.154701) * CONE_WEIGHT_UP;
 
    return indirectSum;
}

float3 ApplyIndirectLightAniso(
    float3 diffuseAlbedo,
    float3x3 tbn,
    in Texture3D<float4> px,
    in Texture3D<float4> nx,
    in Texture3D<float4> py,
    in Texture3D<float4> ny,
    in Texture3D<float4> pz,
    in Texture3D<float4> nz,
    in SamplerState voxelSmp,
    float3 voxelPos,
    float3 voxelStep
)
{
    float3 indirectSum = float3(0.0, 0.0, 0.0);

    // Decide on which three textures to trace into
    if (0.0 < voxelStep.x)
    {
        if (0.0 < voxelStep.y)
        {
            if (0.0 < voxelStep.z)
            {
                // step is +x, +y, +z
                indirectSum = ApplyIndirectLightAnisoHelper(tbn, nx, ny, nz, voxelSmp, voxelPos, voxelStep);
            }
            else
            {
                // step is +x, +y, -z
                indirectSum = ApplyIndirectLightAnisoHelper(tbn, nx, ny, pz, voxelSmp, voxelPos, voxelStep);
            }
        }
        else
        {
            if (0.0 < voxelStep.z)
            {
                // step is +x, -y, +z
                indirectSum = ApplyIndirectLightAnisoHelper(tbn, nx, py, nz, voxelSmp, voxelPos, voxelStep);
            }
            else
            {
                // step is +x, -y, -z
                indirectSum = ApplyIndirectLightAnisoHelper(tbn, nx, py, pz, voxelSmp, voxelPos, voxelStep);
            }
        }
    }
    else
    {
        if (0.0 < voxelStep.y)
        {
            if (0.0 < voxelStep.z)
            {
                // step is -x, +y, +z
                indirectSum = ApplyIndirectLightAnisoHelper(tbn, px, ny, nz, voxelSmp, voxelPos, voxelStep);
            }
            else
            {
                // step is -x, +y, -z
                indirectSum = ApplyIndirectLightAnisoHelper(tbn, px, ny, pz, voxelSmp, voxelPos, voxelStep);
            }
        }
        else
        {
            if (0.0 < voxelStep.z)
            {
                // step is -x, -y, +z
                indirectSum = ApplyIndirectLightAnisoHelper(tbn, px, py, nz, voxelSmp, voxelPos, voxelStep);
            }
            else
            {
                // step is -x, -y, -z
                indirectSum = ApplyIndirectLightAnisoHelper(tbn, px, py, pz, voxelSmp, voxelPos, voxelStep);
            }
        }
    }


    return (indirectSum * diffuseAlbedo) * VOXEL_UNPACK_SCALE;
}
