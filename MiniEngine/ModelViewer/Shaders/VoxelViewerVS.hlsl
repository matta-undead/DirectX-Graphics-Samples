#include "VctCommon.hlsli"

#define VCT_DEBUG_SHOW_ANISO_VOXEL_FACES    0

cbuffer VSConstants : register(b0)
{
    float4x4 worldToProjection;
    float3 viewerPosition;
    float3 positionMul;
    float3 positionAdd;
}

struct VSOutput
{
    float4 position : SV_Position;
    float3 worldPos : WorldPos;
    float4 color : TexCoord0;
    float3 viewDir : TexCoord1;
#if VCT_USE_ANISOTROPIC_VOXELS
    float4 colorY : TexCoord2;
    float4 colorZ : TexCoord3;
#endif
};

Texture3D<float4> voxelBuffer0 : register(t0);
#if VCT_USE_ANISOTROPIC_VOXELS
Texture3D<float4> voxelBuffer1 : register(t1);
Texture3D<float4> voxelBuffer2 : register(t2);
Texture3D<float4> voxelBuffer3 : register(t3);
Texture3D<float4> voxelBuffer4 : register(t4);
Texture3D<float4> voxelBuffer5 : register(t5);
#endif

#define DRAW_COUNT  256

VSOutput main(
    in uint vertexId : SV_VertexID,
    in uint instanceId : SV_InstanceID
)
{
    // vertex id as integer index of flattened 3D array.
    // transform back into x,y,z indicies for texture lookup
    uint kWidth = 128;
    uint kPageSize = (128*128);
    uint flatIndex = ((kWidth*kPageSize/DRAW_COUNT)*instanceId) + vertexId;

    uint3 index3dFromFlatArray = uint3(
        flatIndex % kWidth,
        (flatIndex % kPageSize) / kWidth,
        flatIndex / kPageSize
    );

#if 0
    // read value from 3D voxel texture and convert to color
    // load instead of sample to avoid filtering, want mip 0
    uint val = voxelBuffer0.Load(uint4(index3dFromFlatArray, 0));
    float4 valF = float4(
        float((val & 0x000000ff)),
        float((val & 0x0000ff00) >> 8u),
        float((val & 0x00ff0000) >> 16u),
        float((val & 0xff000000) >> 24u)
    );
    valF *= (1.0/255.0);
#endif
    float4 valF = voxelBuffer0.Load(uint4(index3dFromFlatArray, 0));

#if VCT_USE_ANISOTROPIC_VOXELS
    float4 valNegX = voxelBuffer1.Load(uint4(index3dFromFlatArray, 0));
    float4 valPosY = voxelBuffer2.Load(uint4(index3dFromFlatArray, 0));
    float4 valNegY = voxelBuffer3.Load(uint4(index3dFromFlatArray, 0));
    float4 valPosZ = voxelBuffer4.Load(uint4(index3dFromFlatArray, 0));
    float4 valNegZ = voxelBuffer5.Load(uint4(index3dFromFlatArray, 0));
#endif

    // translate voxel grid position into world
    float3 gridPosition = float3(index3dFromFlatArray);

    // positionMul is step from one voxel center to the next
    // positionAdd is shift to 0th voxel. both in world space.
    float3 worldPosition = gridPosition * positionMul + positionAdd;

    VSOutput vsOutput;
    vsOutput.position = mul(worldToProjection, float4(worldPosition, 1.0));
    vsOutput.worldPos = worldPosition;
    vsOutput.color = valF;
    vsOutput.viewDir = viewerPosition - worldPosition;

#if VCT_USE_ANISOTROPIC_VOXELS

    if (vsOutput.viewDir.x < 0.0)
    {
        vsOutput.color = valNegX;
    }
    vsOutput.colorY = (vsOutput.viewDir.y < 0.0) ? valNegY : valPosY;
    vsOutput.colorZ = (vsOutput.viewDir.z < 0.0) ? valNegZ : valPosZ;

#if VCT_DEBUG_SHOW_ANISO_VOXEL_FACES
    // preserve .w value for opacity
    float3 viewDir  = vsOutput.viewDir.xyz;
    vsOutput.color.xyz  = viewDir.x < 0.0 ? float3(0.0, 0.5, 0.5) : float3(1.0, 0.5, 0.5);
    vsOutput.colorY.xyz = viewDir.y < 0.0 ? float3(0.5, 0.0, 0.5) : float3(0.5, 1.0, 0.5);
    vsOutput.colorZ.xyz = viewDir.z < 0.0 ? float3(0.5, 0.5, 0.0) : float3(0.5, 0.5, 1.0);
#endif // VCT_DEBUG_SHOW_ANISO_VOXEL_FACES

#endif

    return vsOutput;
}
