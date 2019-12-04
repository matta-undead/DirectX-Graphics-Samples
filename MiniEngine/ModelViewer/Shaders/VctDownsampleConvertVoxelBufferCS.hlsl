
#define WORK_GROUP_SIZE_X   4
#define WORK_GROUP_SIZE_Y   4
#define WORK_GROUP_SIZE_Z   4

#define VCT_USE_ANISOTROPIC_VOXELS      0

RWTexture3D<uint> voxelBuffer : register(u0);
RWTexture3D<float4> outBuffer0 : register(u1);
#if VCT_USE_ANISOTROPIC_VOXELS
RWTexture3D<float4> outBuffer1 : register(u2);
RWTexture3D<float4> outBuffer2 : register(u3);
RWTexture3D<float4> outBuffer3 : register(u4);
RWTexture3D<float4> outBuffer4 : register(u5);
RWTexture3D<float4> outBuffer5 : register(u6);
#endif

#if VCT_USE_ANISOTROPIC_VOXELS
#define kWidthScale     6
#else
#define kWidthScale     1
#endif

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
    sourceIdx.x *= kWidthScale;

    // Take 8 samples of higher res voxel buffer,
    // unpack the uint32 into sRGB color and accumulatedWeight
    // treat non-zero accumulatedWeight as opaque
    uint val = voxelBuffer[sourceIdx];
    float4 color = UnpackValConvertAlpha(val);

    val = voxelBuffer[sourceIdx + uint3(kWidthScale, 0, 0)];
    color += UnpackValConvertAlpha(val);

    val = voxelBuffer[sourceIdx + uint3(0, 1, 0)];
    color += UnpackValConvertAlpha(val);

    val = voxelBuffer[sourceIdx + uint3(kWidthScale, 1, 0)];
    color += UnpackValConvertAlpha(val);

    //..

    val = voxelBuffer[sourceIdx + uint3(0, 0, 1)];
    color += UnpackValConvertAlpha(val);

    val = voxelBuffer[sourceIdx + uint3(kWidthScale, 0, 1)];
    color += UnpackValConvertAlpha(val);

    val = voxelBuffer[sourceIdx + uint3(0, 1, 1)];
    color += UnpackValConvertAlpha(val);

    val = voxelBuffer[sourceIdx + uint3(kWidthScale, 1, 1)];
    color += UnpackValConvertAlpha(val);

    // Store average weight
    outBuffer0[globalID] = color * (1.0/max(1.0, color.w));

#if VCT_USE_ANISOTROPIC_VOXELS
    // Negative X
    uint kOffset = 1;
    uint3 offsetSourceIdx = sourceIdx;
    offsetSourceIdx.x += kOffset;
    sourceIdx.x += 1;
    val = voxelBuffer[offsetSourceIdx];
    color = UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 0, 0)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(0, 1, 0)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 1, 0)];
    color += UnpackValConvertAlpha(val);
    //..
    val = voxelBuffer[offsetSourceIdx + uint3(0, 0, 1)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 0, 1)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(0, 1, 1)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 1, 1)];
    color += UnpackValConvertAlpha(val);
    // Store average weight
    outBuffer1[globalID] = color * (1.0/max(1.0, color.w));

    // Positive Y
    kOffset = 2;
    offsetSourceIdx = sourceIdx;
    offsetSourceIdx.x += kOffset;
    sourceIdx.x += 1;
    val = voxelBuffer[offsetSourceIdx];
    color = UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 0, 0)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(0, 1, 0)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 1, 0)];
    color += UnpackValConvertAlpha(val);
    //..
    val = voxelBuffer[offsetSourceIdx + uint3(0, 0, 1)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 0, 1)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(0, 1, 1)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 1, 1)];
    color += UnpackValConvertAlpha(val);
    // Store average weight
    outBuffer2[globalID] = color * (1.0/max(1.0, color.w));

    // Negative Y
    kOffset = 2;
    offsetSourceIdx = sourceIdx;
    offsetSourceIdx.x += kOffset;
    sourceIdx.x += 1;
    val = voxelBuffer[offsetSourceIdx];
    color = UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 0, 0)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(0, 1, 0)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 1, 0)];
    color += UnpackValConvertAlpha(val);
    //..
    val = voxelBuffer[offsetSourceIdx + uint3(0, 0, 1)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 0, 1)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(0, 1, 1)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 1, 1)];
    color += UnpackValConvertAlpha(val);
    // Store average weight
    outBuffer3[globalID] = color * (1.0/max(1.0, color.w));
    
    // Positive Z
    kOffset = 4;
    offsetSourceIdx = sourceIdx;
    offsetSourceIdx.x += kOffset;
    sourceIdx.x += 1;
    val = voxelBuffer[offsetSourceIdx];
    color = UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 0, 0)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(0, 1, 0)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 1, 0)];
    color += UnpackValConvertAlpha(val);
    //..
    val = voxelBuffer[offsetSourceIdx + uint3(0, 0, 1)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 0, 1)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(0, 1, 1)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 1, 1)];
    color += UnpackValConvertAlpha(val);
    // Store average weight
    outBuffer4[globalID] = color * (1.0/max(1.0, color.w));

    // Negative Z
    kOffset = 5;
    offsetSourceIdx = sourceIdx;
    offsetSourceIdx.x += kOffset;
    sourceIdx.x += 1;
    val = voxelBuffer[offsetSourceIdx];
    color = UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 0, 0)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(0, 1, 0)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 1, 0)];
    color += UnpackValConvertAlpha(val);
    //..
    val = voxelBuffer[offsetSourceIdx + uint3(0, 0, 1)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 0, 1)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(0, 1, 1)];
    color += UnpackValConvertAlpha(val);
    val = voxelBuffer[offsetSourceIdx + uint3(kWidthScale, 1, 1)];
    color += UnpackValConvertAlpha(val);
    // Store average weight
    outBuffer5[globalID] = color * (1.0/max(1.0, color.w));
#endif
}
