//

#include "pch.h"
#include "VoxelConeTracing.h"
#include "RootSignature.h"
#include "PipelineState.h"
#include "CommandContext.h"
#include "ColorBuffer.h"
#include "Utility.h"

#include "CompiledShaders/VctDownsampleConvertVoxelBufferCS.h"
#include "CompiledShaders/VctDownsampleVoxelBufferCS.h"

using namespace Graphics;

namespace VoxelConeTracing
{
    RootSignature s_RootSignature;

    ComputePSO s_VctDownsampleConvertPSO;

    ColorBuffer s_VoxelBuffer;

#if VCT_USE_ANISOTROPIC_VOXELS
    constexpr uint32_t kVoxelMipsCount = 6;
#else
    constexpr uint32_t kVoxelMipsCount = 1;
#endif
    constexpr uint32_t kVoxelMipsFrameCount = 2;
    ColorBuffer s_VoxelMips[kVoxelMipsCount * kVoxelMipsFrameCount];
    uint32_t s_VoxelMipsCurrent = 0;

    RootSignature s_GenerateMipsRS;
    ComputePSO s_VctDownsamplePSO;

    constexpr float kVoxelWorldSize = float(kVoxelDims * 8u);
}

void VoxelConeTracing::Initialize( void )
{
    s_RootSignature.Reset(2, 2);
    s_RootSignature.InitStaticSampler(0, SamplerPointBorderDesc);
    s_RootSignature.InitStaticSampler(1, SamplerLinearClampDesc);
    s_RootSignature[0].InitAsConstantBuffer(0);
    s_RootSignature[1].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 0, kVoxelMipsCount+1);
    s_RootSignature.Finalize(L"Voxel Cone Tracing");

    s_GenerateMipsRS.Reset(2, 0);
    s_GenerateMipsRS[0].InitAsConstants(0, 2);
    s_GenerateMipsRS[1].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 0, 4);
    s_GenerateMipsRS.Finalize(L"Voxel Generate Mips");

    s_VctDownsampleConvertPSO.SetRootSignature(s_RootSignature);
    s_VctDownsampleConvertPSO.SetComputeShader(g_pVctDownsampleConvertVoxelBufferCS, sizeof(g_pVctDownsampleConvertVoxelBufferCS) );
    s_VctDownsampleConvertPSO.Finalize();
 
    s_VctDownsamplePSO.SetRootSignature(s_GenerateMipsRS);
    s_VctDownsamplePSO.SetComputeShader(g_pVctDownsampleVoxelBufferCS, sizeof(g_pVctDownsampleVoxelBufferCS));
    s_VctDownsamplePSO.Finalize();

    // format as uint32_t to allow interlocked atomics in shader
    const uint32_t initialDims = GetVoxelBufferDims(BufferType::InitialVoxelization);
    s_VoxelBuffer.Create3D( L"Voxel Buffer", kVoxelMipsCount*initialDims, initialDims, initialDims, 1, DXGI_FORMAT_R32_UINT );

    const uint32_t filteredDims = GetVoxelBufferDims(BufferType::FilteredVoxels);
    for (uint32_t i = 0; i < kVoxelMipsCount; ++i)
    {
        s_VoxelMips[i].Create3D( L"Voxel Mips", filteredDims, filteredDims, filteredDims, 0, DXGI_FORMAT_R8G8B8A8_UNORM );
        if constexpr (kVoxelMipsFrameCount > 1) {
            s_VoxelMips[i + kVoxelMipsCount].Create3D(
                L"Voxel Mips Alt",
                filteredDims,
                filteredDims,
                filteredDims,
                0,
                DXGI_FORMAT_R8G8B8A8_UNORM
            );
        }
    }
}

void VoxelConeTracing::Shutdown( void )
{
    s_VoxelBuffer.Destroy();

    for (uint32_t i = 0; i < (kVoxelMipsCount * kVoxelMipsFrameCount); ++i)
    {
        s_VoxelMips[i].Destroy();
    }
}

ColorBuffer& VoxelConeTracing::GetVoxelBuffer(VoxelConeTracing::BufferType type, uint32_t idx)
{
    uint32_t frameOffsetCurrent = s_VoxelMipsCurrent * kVoxelMipsCount;
    uint32_t frameOffsetPrevious = (1-s_VoxelMipsCurrent) * kVoxelMipsCount;

    switch (type)
    {
    case VoxelConeTracing::BufferType::InitialVoxelization:
        return s_VoxelBuffer;

    case VoxelConeTracing::BufferType::FilteredVoxels:
        return s_VoxelMips[idx + frameOffsetCurrent];

    case VoxelConeTracing::BufferType::FilteredVoxelsPrevious:
        return s_VoxelMips[idx + frameOffsetPrevious];

    default:
        ASSERT(false, "Invalid voxel buffer type or cases need updating.");
    }

    // should fail on default assert.
    return s_VoxelBuffer;
}

uint32_t VoxelConeTracing::GetVoxelBufferDims(VoxelConeTracing::BufferType type)
{
    uint32_t retVal = 0;

    switch (type)
    {
    case BufferType::InitialVoxelization:
        return kVoxelDims;

    case BufferType::FilteredVoxels:
    case BufferType::FilteredVoxelsPrevious:
        return (kVoxelDims / 2);

    default:
        ASSERT(false, "Invalid voxel buffer type or cases need updating.");
    }

    return retVal;
}

void VoxelConeTracing::DownsampleVoxelBuffer( CommandContext& BaseContext )
{
    ComputeContext& Context = BaseContext.GetComputeContext();

    uint32_t frameOffsetCurrent = s_VoxelMipsCurrent * kVoxelMipsCount;

    {
        ScopedTimer _prof(L"Vct Downsample Voxel Buffer", BaseContext);

        Context.SetRootSignature(s_RootSignature);

        Context.TransitionResource(s_VoxelBuffer, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);

        Context.SetPipelineState(s_VctDownsampleConvertPSO);
        D3D12_CPU_DESCRIPTOR_HANDLE buffers[] = {
            s_VoxelBuffer.GetUAV(),
            s_VoxelMips[0 + frameOffsetCurrent].GetUAV()
#if VCT_USE_ANISOTROPIC_VOXELS
            , s_VoxelMips[1 + frameOffsetCurrent].GetUAV(),
            s_VoxelMips[2 + frameOffsetCurrent].GetUAV(),
            s_VoxelMips[3 + frameOffsetCurrent].GetUAV(),
            s_VoxelMips[4 + frameOffsetCurrent].GetUAV(),
            s_VoxelMips[5 + frameOffsetCurrent].GetUAV()
#endif
        };
        Context.SetDynamicDescriptors(1, 0, kVoxelMipsCount + 1, buffers);

        const uint32_t dims = GetVoxelBufferDims(BufferType::FilteredVoxels);
        Context.Dispatch3D(dims, dims, dims, 4, 4, 4);
    }


    {
        ScopedTimer _prof(L"Vct Generate Mips of Voxel Buffer", BaseContext);

        Context.SetRootSignature(s_GenerateMipsRS);

        for (uint32_t i = 0; i < kVoxelMipsCount; ++i)
        {
            Context.TransitionResource(s_VoxelMips[i], D3D12_RESOURCE_STATE_UNORDERED_ACCESS);

            {
                const uint32_t sourceMip = 0;
                const uint32_t numMips = 3;

                Context.SetPipelineState(s_VctDownsamplePSO);
                Context.SetConstants(0, sourceMip, numMips);

                D3D12_CPU_DESCRIPTOR_HANDLE mips[] = {
                    s_VoxelMips[i + frameOffsetCurrent].GetUAV(sourceMip + 0),
                    s_VoxelMips[i + frameOffsetCurrent].GetUAV(sourceMip + 1),
                    s_VoxelMips[i + frameOffsetCurrent].GetUAV(sourceMip + 2),
                    s_VoxelMips[i + frameOffsetCurrent].GetUAV(sourceMip + 3),
                };
                Context.SetDynamicDescriptors(1, 0, 4, mips);
                const uint32_t dims = GetVoxelBufferDims(BufferType::FilteredVoxels) / 2;
                Context.Dispatch3D(dims, dims, dims, 4, 4, 4);
            }

            {
                const uint32_t sourceMip = 3;
                const uint32_t numMips = 2;

                Context.SetPipelineState(s_VctDownsamplePSO);
                Context.SetConstants(0, sourceMip, numMips);

                D3D12_CPU_DESCRIPTOR_HANDLE mips[] = {
                    s_VoxelMips[i + frameOffsetCurrent].GetUAV(sourceMip + 0),
                    s_VoxelMips[i + frameOffsetCurrent].GetUAV(sourceMip + 1),
                    s_VoxelMips[i + frameOffsetCurrent].GetUAV(sourceMip + 2),
                    s_VoxelMips[i + frameOffsetCurrent].GetUAV(sourceMip + 3),
                };
                Context.SetDynamicDescriptors(1, 0, 4, mips);
                const uint32_t dims = GetVoxelBufferDims(BufferType::FilteredVoxels) / 16;
                Context.Dispatch3D(dims, dims, dims, 4, 4, 4);
            }

            Context.TransitionResource(s_VoxelMips[i], D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        }
    }
}

void VoxelConeTracing::SwapCurrentVoxelBuffer ()
{
    s_VoxelMipsCurrent = 1 - s_VoxelMipsCurrent;
}

void VoxelConeTracing::GetVoxelWorldDims (
    const Math::Vector3& position,
    const Math::Vector3& boundsMin,
    const Math::Vector3& boundsMax,
    Math::Vector3 * voxelMin,
    Math::Vector3 * voxelMax
)
{
    if ((voxelMin == nullptr) || (voxelMax == nullptr))
    {
        return;
    }

    const Math::Vector3 boundsSpan = boundsMax - boundsMin;
    const bool isEntirelyContained = boundsSpan.GetX() <= kVoxelWorldSize
        && boundsSpan.GetY() <= kVoxelWorldSize
        && boundsSpan.GetZ() <= kVoxelWorldSize;

    if (isEntirelyContained)
    {
        *voxelMin = boundsMin;
        *voxelMax = boundsMax;
        return;
    }

    // quantize position to reduce voxels flicker
    constexpr float quantizeToNVoxels = 16.0f;
    const float voxelSizeInWorldUnits = (quantizeToNVoxels * kVoxelWorldSize) / float(kVoxelDims);
    Math::Vector3 quantizedPosition = position * (1.0f/voxelSizeInWorldUnits);
    quantizedPosition = Math::Round(quantizedPosition);
    quantizedPosition = quantizedPosition * voxelSizeInWorldUnits;

    const Math::Vector3 halfVoxelWorldVec(kVoxelWorldSize * 0.5f);

    *voxelMin = quantizedPosition - halfVoxelWorldVec;
    *voxelMax = quantizedPosition + halfVoxelWorldVec;

}