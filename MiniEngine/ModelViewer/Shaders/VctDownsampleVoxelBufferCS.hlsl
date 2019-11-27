
#define WORK_GROUP_SIZE_X   4
#define WORK_GROUP_SIZE_Y   4
#define WORK_GROUP_SIZE_Z   4


RWTexture3D<float4> voxelBuffer : register(u0);
RWTexture3D<float4> outMip1     : register(u1);
RWTexture3D<float4> outMip2     : register(u2);
RWTexture3D<float4> outMip3     : register(u3);

cbuffer CB0 : register(b0)
{
    uint SourceMipLevel;
    uint NumMipLevels;
}

// From 'GenerateMipsCS.hlsli'
// The reason for separating channels is to reduce bank conflicts in the
// local data memory controller.  A large stride will cause more threads
// to collide on the same memory bank.
groupshared float gs_R[64];
groupshared float gs_G[64];
groupshared float gs_B[64];
groupshared float gs_A[64];

void StoreColor( uint Index, float4 Color )
{
    gs_R[Index] = Color.r;
    gs_G[Index] = Color.g;
    gs_B[Index] = Color.b;
    gs_A[Index] = Color.a;
}

float4 LoadColor( uint Index )
{
    return float4( gs_R[Index], gs_G[Index], gs_B[Index], gs_A[Index]);
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

    // Take 8 samples of higher res voxel buffer
    float4 color = voxelBuffer[sourceIdx];
    color += voxelBuffer[sourceIdx + uint3(1, 0, 0)];
    color += voxelBuffer[sourceIdx + uint3(0, 1, 0)];
    color += voxelBuffer[sourceIdx + uint3(1, 1, 0)];
    color += voxelBuffer[sourceIdx + uint3(0, 0, 1)];
    color += voxelBuffer[sourceIdx + uint3(1, 0, 1)];
    color += voxelBuffer[sourceIdx + uint3(0, 1, 1)];
    color += voxelBuffer[sourceIdx + uint3(1, 1, 1)];

    // Store average weight
    outMip1[globalID] = color * 0.125;

    if (NumMipLevels == 1)
    {
        return;
    }

    // Store 4^3 values
    StoreColor(threadIndex, color);
    GroupMemoryBarrierWithGroupSync();

    // This bit mask (binary: 010101) checks for corners in 2x2 blocks
    if ((threadIndex & 0x15) == 0)
    {
        float4 color1 = LoadColor(threadIndex + 1);
        float4 color2 = LoadColor(threadIndex + 4);
        float4 color3 = LoadColor(threadIndex + 5);

        float4 color4 = LoadColor(threadIndex + 16);
        float4 color5 = LoadColor(threadIndex + 17);
        float4 color6 = LoadColor(threadIndex + 20);
        float4 color7 = LoadColor(threadIndex + 21);

        color = 0.125 * (color + color1 + color2 + color3 + color4 + color5 + color6 + color7);
        outMip2[globalID / 2] = color;
        StoreColor(threadIndex, color);
    }

    if (NumMipLevels == 2)
    {
        return;
    }

    GroupMemoryBarrierWithGroupSync();

    if (threadIndex == 0)
    {
        float4 color1 = LoadColor(threadIndex + 2);
        float4 color2 = LoadColor(threadIndex + 8);
        float4 color3 = LoadColor(threadIndex + 10);

        float4 color4 = LoadColor(threadIndex + 32);
        float4 color5 = LoadColor(threadIndex + 34);
        float4 color6 = LoadColor(threadIndex + 40);
        float4 color7 = LoadColor(threadIndex + 42);

        color = 0.125 * (color + color1 + color2 + color3 + color4 + color5 + color6 + color7);
        outMip3[globalID / 4] = color;
    }
}
