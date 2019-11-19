

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

Texture3D<uint> voxelBuffer : register(t0);

VSOutput main(in uint vertexId : SV_VertexID)
{
    // vertex id as integer index of flattened 3D array.
    // transform back into x,y,z indicies for texture lookup
    uint kWidth = 256;
    uint kPageSize = (256*256);
    uint3 index3dFromFlatArray = uint3(
        vertexId % kWidth,
        (vertexId % kPageSize) / kWidth,
        vertexId / kPageSize
    );

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

    // translate voxel grid position into world
    float3 gridPosition = float3(index3dFromFlatArray);
    //float3 worldPosition = gridPosition * positionMul + positionAdd;

    //float3 worldPosition = gridPosition * 1.0 - float3(31.5,11.5,31.5);
    //worldPosition *= 50.0;

    float3 worldPosition = gridPosition * 1.0 - float3(127.5,31.5,127.5);
    worldPosition *= 5.0;

    VSOutput vsOutput;
    vsOutput.position = mul(worldToProjection, float4(worldPosition, 1.0));
    vsOutput.worldPos = worldPosition;
    vsOutput.color = valF;
    vsOutput.viewDir = viewerPosition - worldPosition;

    return vsOutput;
}
