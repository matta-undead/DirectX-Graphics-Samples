
// common defines

#define VCT_INDIRECT_LIGHT_NEEDS_ONE_OVER_PI    0
#define VCT_USE_ANISOTROPIC_VOXELS              0

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


// shared functions

float3 TraceCone(
    in Texture3D<float4> voxelTex,
    in SamplerState voxelSmp,
    float3 voxelPos,
    float3 voxelStep,
    float normalizedConeDiameter
)
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
    float4 voxelSample = voxelTex.SampleLevel(voxelSmp, voxelPos, log2(distanceScalar*2.0) );
    indirectLight = voxelSample.xyz * transmitted;
    opacity += voxelSample.w * transmitted;
    transmitted = saturate(1.0 - opacity);

    voxelPos += 4.0 * voxelStep;
    voxelSample = voxelTex.SampleLevel(voxelSmp, voxelPos, log2(distanceScalar*4.0) );
    indirectLight += voxelSample.xyz * transmitted;
    opacity += voxelSample.w * transmitted;
    transmitted = saturate(1.0 - opacity);

    voxelPos += 8.0 * voxelStep;
    voxelSample = voxelTex.SampleLevel(voxelSmp, voxelPos, log2(distanceScalar*8.0) );
    indirectLight += voxelSample.xyz * transmitted;
    opacity += voxelSample.w * transmitted;
    transmitted = saturate(1.0 - opacity);

    voxelPos += 16.0 * voxelStep;
    voxelSample = voxelTex.SampleLevel(voxelSmp, voxelPos, log2(distanceScalar*16.0) );
    indirectLight += voxelSample.xyz * transmitted;
    opacity += voxelSample.w * transmitted;
    transmitted = saturate(1.0 - opacity);

    voxelPos += 32.0 * voxelStep;
    voxelSample = voxelTex.SampleLevel(voxelSmp, voxelPos, log2(distanceScalar*32.0) );
    indirectLight += voxelSample.xyz * transmitted;
    //opacity += voxelSample.w * transmitted;
    //transmitted = saturate(1.0 - opacity);

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
    float opacity = 0.0;
    float transmitted = 1.0;
    float3 indirectLight = float3(0.0, 0.0, 0.0);

    float distanceScalar = length(voxelStep) * (128.0 * normalizedConeDiameter);//1.154701);

    float3 initialVoxelPos = voxelPos;

    for (float i = 0.0; i < 10.0; i += 1.0)
    {
        voxelPos += 2.0 * voxelStep;
        float4 voxelSample = voxelTex.SampleLevel(voxelSmp, voxelPos, log2(length(voxelPos - initialVoxelPos) * distanceScalar));
        indirectLight += voxelSample.xyz * transmitted;
        opacity += voxelSample.w * transmitted;
        transmitted = saturate(1.0 - opacity);
    }

    return indirectLight;
}