
#define WORK_GROUP_SIZE_X   4
#define WORK_GROUP_SIZE_Y   4
#define WORK_GROUP_SIZE_Z   4


RWTexture3D<uint> voxelBuffer : register(u0);
RWTexture3D<float4> outBuffer : register(u1);


float4 UnpackValConvertAlpha(uint val)
{
    float4 valF = float4(
        float((val & 0x000000ff)),
        float((val & 0x0000ff00) >> 8u),
        float((val & 0x00ff0000) >> 16u),
        float((val & 0xff000000) >> 24u)
    );
    valF.xyz *= (1.0 / 255.0);
    valF.w = valF.w > 0.0 ? 1.0 : 0.0;

    // if w is zero, want to zero out xyz, too
    valF.xyz *= valF.w;

    return valF;
}


#define _RootSig \
    "RootFlags(0), " \
    "CBV(b0), " \
    "DescriptorTable(UAV(u0, numDescriptors = 2))"


[RootSignature(_RootSig)]
[numthreads(WORK_GROUP_SIZE_X, WORK_GROUP_SIZE_Y, WORK_GROUP_SIZE_Z)]
void main(
    uint3 globalID : SV_DispatchThreadID,
    uint3 groupID : SV_GroupID,
    uint3 threadID : SV_GroupThreadID,
    uint threadIndex : SV_GroupIndex)
{
    // To filter 256^3 texture into 128^3 texture, launching 128^3 threads.
    // GroupID is (128/4)^3
    // GroupThreadId is (0, 4) in each dimension.
    // ... but I think we can just rely on DispatchThreadID as destination value,
    // and double it for source.
    uint3 sourceIdx = globalID * 2;

    // Take 8 samples of higher res voxel buffer,
    // unpack the uint32 into sRGB color and accumulatedWeight
    // treat non-zero accumulatedWeight as opaque
    uint val = voxelBuffer[sourceIdx];
    float4 color = UnpackValConvertAlpha(val);

    val = voxelBuffer[sourceIdx + uint3(1, 0, 0)];
    color += UnpackValConvertAlpha(val);

    val = voxelBuffer[sourceIdx + uint3(0, 1, 0)];
    color += UnpackValConvertAlpha(val);

    val = voxelBuffer[sourceIdx + uint3(1, 1, 0)];
    color += UnpackValConvertAlpha(val);

    //..

    val = voxelBuffer[sourceIdx + uint3(0, 0, 1)];
    color += UnpackValConvertAlpha(val);

    val = voxelBuffer[sourceIdx + uint3(1, 0, 1)];
    color += UnpackValConvertAlpha(val);

    val = voxelBuffer[sourceIdx + uint3(0, 1, 1)];
    color += UnpackValConvertAlpha(val);

    val = voxelBuffer[sourceIdx + uint3(1, 1, 1)];
    color += UnpackValConvertAlpha(val);

    // Store average weight
    outBuffer[globalID] = color * (1.0/max(1.0, color.w));
}
