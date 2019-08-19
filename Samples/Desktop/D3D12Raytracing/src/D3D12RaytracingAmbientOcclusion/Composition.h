//*********************************************************
//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the MIT License (MIT).
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
//*********************************************************
#pragma once

// ToDo move to cpp
#include "RaytracingSceneDefines.h"
#include "DirectXRaytracingHelper.h"
#include "RaytracingAccelerationStructure.h"
#include "CameraController.h"
#include "PerformanceTimers.h"
#include "Sampler.h"
#include "GpuKernels.h"
#include "EngineTuning.h"


namespace Composition
{
    namespace Args
    {
        extern EnumVar AntialiasingMode;
    }

    extern std::map<std::wstring, BottomLevelAccelerationStructureGeometry>	g_bottomLevelASGeometries;
    extern std::unique_ptr<RaytracingAccelerationStructureManager> g_accelerationStructure;
    extern GpuResource g_grassPatchVB[UIParameters::NumGrassGeometryLODs][2];      // Two VBs: current and previous frame.
    extern D3D12_GPU_DESCRIPTOR_HANDLE g_nullVertexBufferGPUhandle;

    class Composition
    {
    public:
        // Ctors.
        Composition();

        // Public methods.
        void Setup(std::shared_ptr<DX::DeviceResources> deviceResources, std::shared_ptr<DX::DescriptorHeap> descriptorHeap, UINT maxInstanceContributionToHitGroupIndex);
        void OnUpdate();
        void OnRender(D3D12_GPU_VIRTUAL_ADDRESS accelerationStructure, D3D12_GPU_DESCRIPTOR_HANDLE rayOriginSurfaceHitPositionResource, D3D12_GPU_DESCRIPTOR_HANDLE rayOriginSurfaceNormalDepthResource, D3D12_GPU_DESCRIPTOR_HANDLE rayOriginSurfaceAlbedoResource, D3D12_GPU_DESCRIPTOR_HANDLE frameAgeResource);
        void ReleaseDeviceDependentResources();
        void ReleaseWindowSizeDependentResources() {}; // ToDo

    private:
        void CreateDeviceDependentResources(UINT maxInstanceContributionToHitGroupIndex);
        void CreateConstantBuffers();
        void CreateAuxilaryDeviceResources();
        void CreateTextureResources();
        void CreateResolutionDependentResources();

        static UINT s_numInstances;
        std::shared_ptr<DX::DeviceResources> m_deviceResources;
        std::shared_ptr<DX::DescriptorHeap> m_cbvSrvUavHeap;

        ConstantBuffer<RNGConstantBuffer>   m_csHemisphereVisualizationCB;
    };
}