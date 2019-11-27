//

#pragma once

class ColorBuffer;

namespace VoxelConeTracing
{
    enum { kVoxelDims = 256 };

    void Initialize( void );

    void Shutdown( void );

    enum class BufferType {
        InitialVoxelization,
        FilteredVoxels
    };

    ColorBuffer& GetVoxelBuffer (BufferType type);

    uint32_t GetVoxelBufferDims (BufferType type);

    void DownsampleVoxelBuffer( CommandContext& BaseContext );
}
