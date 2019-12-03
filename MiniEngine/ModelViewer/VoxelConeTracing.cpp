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
    ColorBuffer s_VoxelMips;

    RootSignature s_GenerateMipsRS;
    ComputePSO s_VctDownsamplePSO;


}

void VoxelConeTracing::Initialize( void )
{
    s_RootSignature.Reset(2, 2);
    s_RootSignature.InitStaticSampler(0, SamplerPointBorderDesc);
    s_RootSignature.InitStaticSampler(1, SamplerLinearClampDesc);
    s_RootSignature[0].InitAsConstantBuffer(0);
    s_RootSignature[1].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 0, 2);
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
    s_VoxelBuffer.Create3D( L"Voxel Buffer", initialDims, initialDims, initialDims, 1, DXGI_FORMAT_R32_UINT );

    const uint32_t filteredDims = GetVoxelBufferDims(BufferType::FilteredVoxels);
    s_VoxelMips.Create3D( L"Voxel Mips", filteredDims, filteredDims, filteredDims, 0, DXGI_FORMAT_R8G8B8A8_UNORM );
}

void VoxelConeTracing::Shutdown( void )
{
    s_VoxelBuffer.Destroy();
    s_VoxelMips.Destroy();
}

ColorBuffer& VoxelConeTracing::GetVoxelBuffer(VoxelConeTracing::BufferType type)
{
    switch (type)
    {
    case VoxelConeTracing::BufferType::InitialVoxelization:
        return s_VoxelBuffer;

    case VoxelConeTracing::BufferType::FilteredVoxels:
        return s_VoxelMips;

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
        return (kVoxelDims / 2);

    default:
        ASSERT(false, "Invalid voxel buffer type or cases need updating.");
    }

    return retVal;
}

void VoxelConeTracing::DownsampleVoxelBuffer( CommandContext& BaseContext )
{
    ComputeContext& Context = BaseContext.GetComputeContext();

    {
        ScopedTimer _prof(L"Vct Downsample Voxel Buffer", BaseContext);

        Context.SetRootSignature(s_RootSignature);

        Context.TransitionResource(s_VoxelBuffer, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);

        Context.SetPipelineState(s_VctDownsampleConvertPSO);
        D3D12_CPU_DESCRIPTOR_HANDLE buffers[] = {
            s_VoxelBuffer.GetUAV(),
            s_VoxelMips.GetUAV()
        };
        //Context.SetDynamicDescriptor(1, 0, s_VoxelBuffer.GetUAV());
        //Context.SetDynamicDescriptor(1, 1, s_VoxelMips.GetUAV());
        Context.SetDynamicDescriptors(1, 0, 2, buffers);
        const uint32_t dims = GetVoxelBufferDims(BufferType::FilteredVoxels);
        Context.Dispatch3D(dims, dims, dims, 4, 4, 4);
    }


    {
        ScopedTimer _prof(L"Vct Generate Mips of Voxel Buffer", BaseContext);

        Context.SetRootSignature(s_GenerateMipsRS);

        Context.TransitionResource(s_VoxelMips, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);

        {
            const uint32_t sourceMip = 0;
            const uint32_t numMips = 3;

            Context.SetPipelineState(s_VctDownsamplePSO);
            Context.SetConstants(0, sourceMip, numMips);

            D3D12_CPU_DESCRIPTOR_HANDLE mips[] = {
                s_VoxelMips.GetUAV(sourceMip + 0),
                s_VoxelMips.GetUAV(sourceMip + 1),
                s_VoxelMips.GetUAV(sourceMip + 2),
                s_VoxelMips.GetUAV(sourceMip + 3),
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
                s_VoxelMips.GetUAV(sourceMip + 0),
                s_VoxelMips.GetUAV(sourceMip + 1),
                s_VoxelMips.GetUAV(sourceMip + 2),
                s_VoxelMips.GetUAV(sourceMip + 3),
            };
            Context.SetDynamicDescriptors(1, 0, 4, mips);
            const uint32_t dims = GetVoxelBufferDims(BufferType::FilteredVoxels) / 16;
            Context.Dispatch3D(dims, dims, dims, 4, 4, 4);
        }

        Context.TransitionResource(s_VoxelMips, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    }
}

