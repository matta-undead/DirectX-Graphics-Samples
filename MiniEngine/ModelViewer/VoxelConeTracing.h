//

#pragma once

class ColorBuffer;
class CommandContext;
namespace Math { class Vector3; }

// Anisotropic switch must match define in VctCommon.hlsli
#define VCT_USE_ANISOTROPIC_VOXELS  0

namespace VoxelConeTracing
{
    enum { kVoxelDims = 256 };

    void Initialize( void );

    void Shutdown( void );

    enum class BufferType {
        InitialVoxelization,
        FilteredVoxels,
        FilteredVoxelsPrevious
    };

    ColorBuffer& GetVoxelBuffer (BufferType type, uint32_t idx = 0);

    uint32_t GetVoxelBufferDims (BufferType type);

    void DownsampleVoxelBuffer( CommandContext& BaseContext );

    void SwapCurrentVoxelBuffer ();

    void GetVoxelWorldDims (
        const Math::Vector3& position,
        const Math::Vector3& boundsMin,
        const Math::Vector3& boundsMax,
        Math::Vector3 * voxelMin,
        Math::Vector3 * voxelMax
    );
}
