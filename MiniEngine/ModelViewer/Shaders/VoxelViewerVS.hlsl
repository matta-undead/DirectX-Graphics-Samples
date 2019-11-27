

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
};

Texture3D<float4> voxelBuffer : register(t0);

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
    uint val = voxelBuffer.Load(uint4(index3dFromFlatArray, 0));
    float4 valF = float4(
        float((val & 0x000000ff)),
        float((val & 0x0000ff00) >> 8u),
        float((val & 0x00ff0000) >> 16u),
        float((val & 0xff000000) >> 24u)
    );
    valF *= (1.0/255.0);
#endif
    float4 valF = voxelBuffer.Load(uint4(index3dFromFlatArray, 0));

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

    return vsOutput;
}
