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

#include "stdafx.h"
#include "Denoiser.h"
#include "GameInput.h"
#include "EngineTuning.h"
#include "EngineProfiling.h"
#include "GpuTimeManager.h"
#include "Denoiser.h"
#include "D3D12RaytracingAmbientOcclusion.h"

// ToDo prune unused
using namespace std;
using namespace DX;
using namespace DirectX;
using namespace SceneEnums;

namespace Denoiser
{
    // Singleton instance.
    Denoiser* g_pDenoiser;      // ToDo remove?
    UINT Denoiser::s_numInstances = 0;

    namespace Args
    {
        // ToDo standardize capitalization
        // ToDo naming down/ up
        const WCHAR* DownsamplingBilateralFilters[GpuKernels::DownsampleValueNormalDepthBilateralFilter::Count] = { L"Point Sampling", L"Depth Weighted", L"Depth Normal Weighted" };
        EnumVar DownsamplingBilateralFilter(L"Render/AO/RTAO/Down/Upsampling/Downsampled Value Filter", GpuKernels::DownsampleValueNormalDepthBilateralFilter::FilterDepthNormalWeighted2x2, GpuKernels::DownsampleValueNormalDepthBilateralFilter::Count, DownsamplingBilateralFilters, OnRecreateRaytracingResources, nullptr);
        BoolVar DownAndUpsamplingUseBilinearWeights(L"Render/AO/RTAO/Down/Upsampling/Bilinear weighted", true);
        BoolVar DownAndUpsamplingUseDepthWeights(L"Render/AO/RTAO/Down/Upsampling/Depth weighted", true);
        BoolVar DownAndUpsamplingUseNormalWeights(L"Render/AO/RTAO/Down/Upsampling/Normal weighted", true);
        BoolVar DownAndUpsamplingUseDynamicDepthThreshold(L"Render/AO/RTAO/Down/Upsampling/Dynamic depth threshold", true);        // ToDO rename to adaptive


        // Temporal Cache.
        // ToDo rename cache to accumulation/supersampling?
        BoolVar RTAO_UseTemporalSupersampling(L"Render/AO/RTAO/Temporal Cache/Enabled", true);
        BoolVar RTAO_TemporalSupersampling_CacheRawAOValue(L"Render/AO/RTAO/Temporal Cache/Cache Raw AO Value", true);
        NumVar RTAO_TemporalSupersampling_MinSmoothingFactor(L"Render/AO/RTAO/Temporal Cache/Min Smoothing Factor", 0.03f, 0, 1.f, 0.01f);
        NumVar RTAO_TemporalSupersampling_DepthTolerance(L"Render/AO/RTAO/Temporal Cache/Depth tolerance [%%]", 0.05f, 0, 1.f, 0.001f);
        BoolVar RTAO_TemporalSupersampling_UseWorldSpaceDistance(L"Render/AO/RTAO/Temporal Cache/Use world space distance", false);    // ToDo test / remove
        BoolVar RTAO_TemporalSupersampling_PerspectiveCorrectDepthInterpolation(L"Render/AO/RTAO/Temporal Cache/Depth testing/Use perspective correct depth interpolation", false);    // ToDo remove
        BoolVar RTAO_TemporalSupersampling_UseDepthWeights(L"Render/AO/RTAO/Temporal Cache/Use depth weights", true);    // ToDo remove
        BoolVar RTAO_TemporalSupersampling_UseNormalWeights(L"Render/AO/RTAO/Temporal Cache/Use normal weights", true);
        BoolVar RTAO_TemporalSupersampling_ForceUseMinSmoothingFactor(L"Render/AO/RTAO/Temporal Cache/Force min smoothing factor", false);


        // ToDo remove
        BoolVar RTAO_KernelStepRotateShift0(L"Render/AO/RTAO/Kernel Step Shifts/Rotate 0:", true);
        IntVar RTAO_KernelStepShift0(L"Render/AO/RTAO/Kernel Step Shifts/0", 3, 0, 10, 1);
        IntVar RTAO_KernelStepShift1(L"Render/AO/RTAO/Kernel Step Shifts/1", 1, 0, 10, 1);
        IntVar RTAO_KernelStepShift2(L"Render/AO/RTAO/Kernel Step Shifts/2", 0, 0, 10, 1);
        IntVar RTAO_KernelStepShift3(L"Render/AO/RTAO/Kernel Step Shifts/3", 0, 0, 10, 1);
        IntVar RTAO_KernelStepShift4(L"Render/AO/RTAO/Kernel Step Shifts/4", 0, 0, 10, 1);

        const WCHAR* VarianceBilateralFilters[GpuKernels::CalculateVariance::FilterType::Count] = { L"Square Bilateral", L"Separable Bilateral", L"Separable" };
        EnumVar VarianceBilateralFilter(L"Render/GpuKernels/CalculateVariance/Filter", GpuKernels::CalculateVariance::Separable, GpuKernels::CalculateVariance::Count, VarianceBilateralFilters);

        IntVar VarianceBilateralFilterKernelWidth(L"Render/GpuKernels/CalculateVariance/Kernel width", 9, 3, 11, 2);    // ToDo find lowest good enough width


        // ToDo rename to temporal supersampling
        // ToDo address: Clamping causes rejection of samples in low density areas - such as on ground plane at the end of max ray distance from other objects.
        BoolVar RTAO_TemporalSupersampling_CacheDenoisedOutput(L"Render/AO/RTAO/Temporal Cache/Cache denoised output", true);
        IntVar RTAO_TemporalSupersampling_CacheDenoisedOutputPassNumber(L"Render/AO/RTAO/Temporal Cache/Cache denoised output - pass number", 0, 0, 10, 1);
        BoolVar RTAO_TemporalSupersampling_ClampCachedValues_UseClamping(L"Render/AO/RTAO/Temporal Cache/Clamping/Enabled", true);
        BoolVar RTAO_TemporalSupersampling_CacheSquaredMean(L"Render/AO/RTAO/Temporal Cache/Cached SquaredMean", false);
        NumVar RTAO_TemporalSupersampling_ClampCachedValues_StdDevGamma(L"Render/AO/RTAO/Temporal Cache/Clamping/Std.dev gamma", 1.0f, 0.1f, 20.f, 0.1f);
        NumVar RTAO_TemporalSupersampling_ClampCachedValues_MinStdDevTolerance(L"Render/AO/RTAO/Temporal Cache/Clamping/Minimum std.dev", 0.04f, 0.0f, 1.f, 0.01f);   // ToDo finetune
        NumVar RTAO_TemporalSupersampling_ClampDifferenceToFrameAgeScale(L"Render/AO/RTAO/Temporal Cache/Clamping/Frame Age scale", 4.00f, 0, 10.f, 0.05f);
        NumVar RTAO_TemporalSupersampling_ClampCachedValues_AbsoluteDepthTolerance(L"Render/AO/RTAO/Temporal Cache/Depth threshold/Absolute depth tolerance", 1.0f, 0.0f, 100.f, 1.f);
        NumVar RTAO_TemporalSupersampling_ClampCachedValues_DepthBasedDepthTolerance(L"Render/AO/RTAO/Temporal Cache/Depth threshold/Depth based depth tolerance", 1.0f, 0.0f, 100.f, 1.f);
        BoolVar RTAO_TemporalSupersampling_TestFlag(L"Render/AO/RTAO/Temporal Cache/Test flag", false);

        // Todo revise comment
        // Setting it lower than 0.9 makes cache values to swim...
        NumVar RTAO_TemporalSupersampling_ClampCachedValues_DepthSigma(L"Render/AO/RTAO/Temporal Cache/Depth threshold/Depth sigma", 1.0f, 0.0f, 10.f, 0.01f);



        // ToDo add Weights On/OFF - 
        // RTAO Denoising
        IntVar RTAOVarianceFilterKernelWidth(L"Render/AO/RTAO/Denoising/Variance filter/Kernel width", 7, 3, 11, 2);    // ToDo find lowest good enough width
        BoolVar UseSpatialVariance(L"Render/AO/RTAO/Denoising/Use spatial variance", true);

        BoolVar RTAODenoisingPerspectiveCorrectDepthInterpolation(L"Render/AO/RTAO/Denoising/Pespective Correct Depth Interpolation", true); // ToDo test perf impact / visual quality gain at the end. Document.
        BoolVar RTAODenoisingUseAdaptiveKernelSize(L"Render/AO/RTAO/Denoising/AdaptiveKernelSize/Enabled", true);
        IntVar RTAODenoisingFilterMinKernelWidth(L"Render/AO/RTAO/Denoising/AdaptiveKernelSize/Min kernel width", 3, 3, 101);
        NumVar RTAODenoisingFilterMaxKernelWidthPercentage(L"Render/AO/RTAO/Denoising/AdaptiveKernelSize/Max kernel width [%% of screen width]", 1.5f, 0, 100, 0.1f);
        NumVar RTAODenoisingFilterVarianceSigmaScaleOnSmallKernels(L"Render/AO/RTAO/Denoising/AdaptiveKernelSize/Variance sigma scale on small kernels", 2.0f, 1.0f, 20.f, 0.5f);
        NumVar RTAO_Denoising_AdaptiveKernelSize_MinHitDistanceScaleFactor(L"Render/AO/RTAO/Denoising/AdaptiveKernelSize/Hit distance scale factor", 0.07f, 0.001f, 10.f, 0.005f);
        BoolVar RTAODenoising_Variance_UseDepthWeights(L"Render/AO/RTAO/Denoising/Variance/Use normal weights", true);
        BoolVar RTAODenoising_Variance_UseNormalWeights(L"Render/AO/RTAO/Denoising/Variance/Use normal weights", true);
        BoolVar RTAODenoising_ForceDenoisePass(L"Render/AO/RTAO/Denoising/Force denoise pass", false);
        IntVar RTAODenoising_MinFrameAgeToUseTemporalVariance(L"Render/AO/RTAO/Denoising/Min Temporal Variance Frame Age", 4, 1, 40);
        NumVar RTAODenoisingMinVarianceToDenoise(L"Render/AO/RTAO/Denoising/Min Variance to denoise", 0.0f, 0.0f, 1.f, 0.01f);
        BoolVar RTAODenoisingUseSmoothedVariance(L"Render/AO/RTAO/Denoising/Use smoothed variance", false);
        BoolVar RTAODenoisingUseProjectedDepthTest(L"Render/AO/RTAO/Denoising/Use projected depth test", true);

        BoolVar RTAODenoising_LowerWeightForStaleSamples(L"Render/AO/RTAO/Denoising/Scale down stale samples weight", false);


        // TODo This probalby should be false, otherwise the newly disoccluded samples get too biased?
        BoolVar RTAODenoisingFilterWeightByFrameAge(L"Render/AO/RTAO/Denoising/Filter weight by frame age", false);


#define MIN_NUM_PASSES_LOW_TSPP 2 // THe blur writes to the initial input resource and thus must numPasses must be 2+.
#define MAX_NUM_PASSES_LOW_TSPP 6
        BoolVar RTAODenoisingLowTspp(L"Render/AO/RTAO/Denoising/Low tspp filter/enabled", true);
        IntVar RTAODenoisingLowTsppMaxFrameAge(L"Render/AO/RTAO/Denoising/Low tspp filter/Max frame age", 12, 0, 33);
        IntVar RTAODenoisingLowTspBlurPasses(L"Render/AO/RTAO/Denoising/Low tspp filter/Num blur passes", 3, 2, MAX_NUM_PASSES_LOW_TSPP);
        BoolVar RTAODenoisingLowTsppUseUAVReadWrite(L"Render/AO/RTAO/Denoising/Low tspp filter/Use single UAV resource Read+Write", true);
        NumVar RTAODenoisingLowTsppDecayConstant(L"Render/AO/RTAO/Denoising/Low tspp filter/Decay constant", 1.0f, 0.1f, 32.f, 0.1f);
        BoolVar RTAODenoisingLowTsppFillMissingValues(L"Render/AO/RTAO/Denoising/Low tspp filter/Post-TSS fill in missing values", true);
        BoolVar RTAODenoisingLowTsppUseNormalWeights(L"Render/AO/RTAO/Denoising/Low tspp filter/Normal Weights/Enabled", false);
        NumVar RTAODenoisingLowTsppMinNormalWeight(L"Render/AO/RTAO/Denoising/Low tspp filter/Normal Weights/Min weight", 0.25f, 0.0f, 1.f, 0.05f);
        NumVar RTAODenoisingLowTsppNormalExponent(L"Render/AO/RTAO/Denoising/Low tspp filter/Normal Weights/Exponent", 4.0f, 1.0f, 32.f, 1.0f);

        const WCHAR* DenoisingModes[GpuKernels::AtrousWaveletTransformCrossBilateralFilter::FilterType::Count] = { L"EdgeStoppingBox3x3", L"EdgeStoppingGaussian3x3", L"EdgeStoppingGaussian5x5" };
        EnumVar DenoisingMode(L"Render/AO/RTAO/Denoising/Mode", GpuKernels::AtrousWaveletTransformCrossBilateralFilter::FilterType::EdgeStoppingGaussian3x3, GpuKernels::AtrousWaveletTransformCrossBilateralFilter::FilterType::Count, DenoisingModes);
#if    DISABLE_DENOISING
        IntVar AtrousFilterPasses(L"Render/AO/RTAO/Denoising/Num passes", 1, 1, 8, 1);
        NumVar AODenoiseValueSigma(L"Render/AO/RTAO/Denoising/Value Sigma", 0.011f, 0.0f, 30.0f, 0.1f);
#else
        IntVar AtrousFilterPasses(L"Render/AO/RTAO/Denoising/Num passes", 1, 1, 8, 1);
        NumVar AODenoiseValueSigma(L"Render/AO/RTAO/Denoising/Value Sigma", 0.3f, 0.0f, 30.0f, 0.1f);
        BoolVar RTAODenoising_2ndPass_UseVariance(L"Render/AO/RTAO/Denoising/2nd+ pass/Use variance", false);
        NumVar RTAODenoising_2ndPass_NormalSigma(L"Render/AO/RTAO/Denoising/2nd+ pass/Normal Sigma", 2, 1, 256, 2);
        NumVar RTAODenoising_2ndPass_DepthSigma(L"Render/AO/RTAO/Denoising/2nd+ pass/Depth Sigma", 1.0f, 0.0f, 10.0f, 0.02f);
#endif
        IntVar RTAODenoising_MaxFrameAgeToDenoiseAfter1stPass(L"Render/AO/RTAO/Denoising/Max Frame Age To Denoise 2nd+ pass", 33, 1, 34, 1);
        IntVar RTAODenoising_MaxFrameAgeToDenoiseOn1stPass(L"Render/AO/RTAO/Denoising/1st pass/Max Frame Age To Denoise", 16, 1, 64, 1);
        IntVar RTAODenoisingExtraRaysToTraceSinceTSSMovement(L"Render/AO/RTAO/Denoising/Heuristics/Num rays to cast since TSS movement", 32, 0, 64);
        IntVar RTAODenoisingnumFramesToDenoiseAfterLastTracedRay(L"Render/AO/RTAO/Denoising/Heuristics/Num frames to denoise after last traced ray", 32, 0, 64);

        BoolVar ReverseFilterOrder(L"Render/AO/RTAO/Denoising/Reverse filter order", false);
        NumVar RTAODenoising_WeightScale(L"Render/AO/RTAO/Denoising/Weight Scale", 1, 0.0f, 5.0f, 0.01f);

        // ToDo why large depth sigma is needed?
        // ToDo the values don't scale to QuarterRes - see ImportaceMap viz
        NumVar AODenoiseDepthSigma(L"Render/AO/RTAO/Denoising/Depth Sigma", 0.5f, 0.0f, 10.0f, 0.02f); // ToDo Fine tune. 1 causes moire patterns at angle under the car

         // ToDo Fine tune. 1 causes moire patterns at angle under the car
        // aT LOW RES 1280X768. causes depth disc lines down to 0.8 cutoff at long ranges
        NumVar AODenoiseDepthWeightCutoff(L"Render/AO/RTAO/Denoising/Depth Weight Cutoff", 0.2f, 0.0f, 2.0f, 0.01f);

        NumVar AODenoiseNormalSigma(L"Render/AO/RTAO/Denoising/Normal Sigma", 64, 0, 256, 4);   // ToDo rename sigma as sigma in depth/var means tolernace. here its an exponent.


    }
    Denoiser::Denoiser()
    {
        ThrowIfFalse(++s_numInstances == 1, L"There can be only one Denoiser instance.");
        g_pDenoiser = this;
    }

    void Denoiser::Setup(shared_ptr<DeviceResources> deviceResources, shared_ptr<DX::DescriptorHeap> descriptorHeap, UINT maxInstanceContributionToHitGroupIndex)
    {
        m_deviceResources = deviceResources;
        m_cbvSrvUavHeap = descriptorHeap;

        CreateDeviceDependentResources(maxInstanceContributionToHitGroupIndex);
    }

    void Denoiser::ReleaseDeviceDependentResources()
    {
    }

    // Create resources that depend on the device.
    void Denoiser::CreateDeviceDependentResources(UINT maxInstanceContributionToHitGroupIndex)
    {
        CreateAuxilaryDeviceResources();

    }


    // ToDo rename
    void Denoiser::CreateAuxilaryDeviceResources()
    {
        auto device = m_deviceResources->GetD3DDevice();
        m_temporalCacheReverseReprojectKernel.Initialize(device, Sample::FrameCount);
        m_temporalCacheBlendWithCurrentFrameKernel.Initialize(device, Sample::FrameCount);
        m_atrousWaveletTransformFilter.Initialize(device, ATROUS_DENOISER_MAX_PASSES, Sample::FrameCount, MaxAtrousWaveletTransformFilterInvocationsPerFrame);
        m_calculateVarianceKernel.Initialize(device, Sample::FrameCount, MaxCalculateVarianceKernelInvocationsPerFrame);
        m_calculateMeanVarianceKernel.Initialize(device, Sample::FrameCount, 5 * MaxCalculateVarianceKernelInvocationsPerFrame); // ToDo revise the ount
    }


    void Denoiser::OnUpdate()
    {

    }

    void Denoiser::CreateResolutionDependentResources()
    {
    }


    void Denoiser::SetResolution(UINT width, UINT height)
    {
    }
    

    void Denoiser::CreateTextureResources()
    {
        auto device = m_deviceResources->GetD3DDevice();
        D3D12_RESOURCE_STATES initialResourceState = D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;

        // Full-res Temporal Cache resources.
        {
            for (UINT i = 0; i < 2; i++)
            {
                // Preallocate subsequent descriptor indices for both SRV and UAV groups.
                m_temporalCache[i][0].uavDescriptorHeapIndex = m_cbvSrvUavHeap->AllocateDescriptorIndices(TemporalSupersampling::Count);
                m_temporalCache[i][0].srvDescriptorHeapIndex = m_cbvSrvUavHeap->AllocateDescriptorIndices(TemporalSupersampling::Count);
                for (UINT j = 0; j < TemporalSupersampling::Count; j++)
                {
                    m_temporalCache[i][j].rwFlags = GpuResource::RWFlags::AllowWrite | GpuResource::RWFlags::AllowRead;
                    m_temporalCache[i][j].uavDescriptorHeapIndex = m_temporalCache[i][0].uavDescriptorHeapIndex + j;
                    m_temporalCache[i][j].srvDescriptorHeapIndex = m_temporalCache[i][0].srvDescriptorHeapIndex + j;
                }

                // ToDo cleanup raytracing resolution - twice for coefficient.
                CreateRenderTargetResource(device, DXGI_FORMAT_R8G8_UINT, m_width, m_height, m_cbvSrvUavHeap.get(), &m_temporalCache[i][TemporalSupersampling::FrameAge], initialResourceState, L"Temporal Cache: Frame Age");
                CreateRenderTargetResource(device, RTAO::AOCoefficientFormat(), m_width, m_height, m_cbvSrvUavHeap.get(), &m_temporalCache[i][TemporalSupersampling::CoefficientSquaredMean], initialResourceState, L"Temporal Cache: Coefficient Squared Mean");
                CreateRenderTargetResource(device, DXGI_FORMAT_R16_FLOAT, m_width, m_height, m_cbvSrvUavHeap.get(), &m_temporalCache[i][TemporalSupersampling::RayHitDistance], initialResourceState, L"Temporal Cache: Ray Hit Distance");


                m_TSSAOCoefficient[i].rwFlags = GpuResource::RWFlags::AllowWrite | GpuResource::RWFlags::AllowRead;
                CreateRenderTargetResource(device, RTAO::AOCoefficientFormat(), m_width, m_height, m_cbvSrvUavHeap.get(), &m_TSSAOCoefficient[i], initialResourceState, L"Render/AO Temporally Supersampled Coefficient");
            }
        }

        for (UINT i = 0; i < 2; i++)
        {
            m_temporalSupersampling_blendedAOCoefficient[i].rwFlags = GpuResource::RWFlags::AllowWrite | GpuResource::RWFlags::AllowRead;
            CreateRenderTargetResource(device, RTAO::AOCoefficientFormat(), m_width, m_height, m_cbvSrvUavHeap.get(), &m_temporalSupersampling_blendedAOCoefficient[i], initialResourceState, L"Temporal Supersampling: AO coefficient current frame blended with the cache.");
        }
        m_cachedFrameAgeValueSquaredValueRayHitDistance.rwFlags = GpuResource::RWFlags::AllowWrite | GpuResource::RWFlags::AllowRead;
        CreateRenderTargetResource(device, DXGI_FORMAT_R16G16B16A16_UINT, m_width, m_height, m_cbvSrvUavHeap.get(), &m_cachedFrameAgeValueSquaredValueRayHitDistance, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, L"Temporal Supersampling intermediate reprojected Frame Age, Value, Squared Mean Value, Ray Hit Distance");




        // Variance resources
        DXGI_FORMAT varianceTexFormat = RTAO::AOCoefficientFormat();       // ToDo 8 bit suffers from loss of precision and clamps too much.
        {
            DXGI_FORMAT meanVarianceTexFormat = DXGI_FORMAT_R16G16_FLOAT;       // ToDo 8 bit suffers from loss of precision and clamps too much.
            // HiRes
            // ToDo specialize formats instead of using a common one?
            {
                m_varianceResources[AOVarianceResource::Raw].rwFlags = GpuResource::RWFlags::AllowWrite | GpuResource::RWFlags::AllowRead;
                CreateRenderTargetResource(device, varianceTexFormat, m_width, m_height, m_cbvSrvUavHeap.get(), &m_varianceResources[AOVarianceResource::Raw], initialResourceState, L"Post Temporal Reprojection Variance");

                m_varianceResources[AOVarianceResource::Smoothed].rwFlags = GpuResource::RWFlags::AllowWrite | GpuResource::RWFlags::AllowRead;
                CreateRenderTargetResource(device, varianceTexFormat, m_width, m_height, m_cbvSrvUavHeap.get(), &m_varianceResources[AOVarianceResource::Smoothed], initialResourceState, L"Smoothed Post Temporal Reprojection Variance");

                m_localMeanVarianceResources[AOVarianceResource::Raw].rwFlags = GpuResource::RWFlags::AllowWrite | GpuResource::RWFlags::AllowRead;
                CreateRenderTargetResource(device, meanVarianceTexFormat, m_width, m_height, m_cbvSrvUavHeap.get(), &m_localMeanVarianceResources[AOVarianceResource::Raw], initialResourceState, L"Local Mean Variance");

                m_localMeanVarianceResources[AOVarianceResource::Smoothed].rwFlags = GpuResource::RWFlags::AllowWrite | GpuResource::RWFlags::AllowRead;
                CreateRenderTargetResource(device, meanVarianceTexFormat, m_width, m_height, m_cbvSrvUavHeap.get(), &m_localMeanVarianceResources[AOVarianceResource::Smoothed], initialResourceState, L"Smoothed Local Mean Variance");
            }
        }
    }


    void Denoiser::RenderPass_TemporalSupersamplingReverseProjection()
    {
        auto commandList = m_deviceResources->GetCommandList();
        auto resourceStateTracker = m_deviceResources->GetGpuResourceStateTracker();

        ScopedTimer _prof(L"Temporal Supersampling p1 (Reverse Reprojection)", commandList);
        
        UINT prevFrameNormalDepthResourceIndex = (m_normalDepthCurrentFrameResourceIndex + 1) % 2;

        // Ping-pong input output indices across frames.
        UINT temporalCachePreviousFrameResourceIndex = m_temporalCacheCurrentFrameResourceIndex;
        m_temporalCacheCurrentFrameResourceIndex = (m_temporalCacheCurrentFrameResourceIndex + 1) % 2;

        UINT temporalCachePreviousFrameTSSAOCoeficientResourceIndex = m_temporalCacheCurrentFrameTSSAOCoefficientResourceIndex;
        m_temporalCacheCurrentFrameTSSAOCoefficientResourceIndex = (m_temporalCacheCurrentFrameTSSAOCoefficientResourceIndex + 1) % 2;

        // ToDo zero out caches on resource reset.

        // ToDo
        // Calculate reverse projection transform T to the previous frame's screen space coordinates.
        //  xy(t-1) = xy(t) * T     // ToDo check mul order
        // The reverse projection transform consists:
        //  1) reverse projecting from current's frame screen space coordinates to world space coordinates
        //  2) projecting from world space coordinates to previous frame's screen space coordinates
        //
        //  T = inverse(P(t)) * inverse(V(t)) * V(t-1) * P(t-1) 
        //      where P is a projection transform and V is a view transform. 
        // Ref: ToDo
        XMMATRIX view, proj, prevView, prevProj;

        m_camera.GetProj(&proj, m_width, m_height);
        m_prevFrameCamera.GetProj(&prevProj, m_width, m_height);

        // ToDO can we remove this or document.
        // Calculate view matrix as if the camera was at (0,0,0) to avoid 
        // precision issues when camera position is too far from (0,0,0).
        // GenerateCameraRay takes this into consideration in the raytracing shader.
        view = XMMatrixLookAtLH(XMVectorSet(0, 0, 0, 1), XMVectorSetW(m_camera.At() - m_camera.Eye(), 1), m_camera.Up());
        prevView = XMMatrixLookAtLH(XMVectorSet(0, 0, 0, 1), XMVectorSetW(m_prevFrameCamera.At() - m_prevFrameCamera.Eye(), 1), m_prevFrameCamera.Up());

        XMMATRIX viewProj = view * proj;
        XMMATRIX prevViewProj = prevView * prevProj;
        XMMATRIX invViewProj = XMMatrixInverse(nullptr, viewProj);
        XMMATRIX prevInvViewProj = XMMatrixInverse(nullptr, prevViewProj);


        // Transition output resource to UAV state.        
        {
            resourceStateTracker->TransitionResource(&m_temporalCache[m_temporalCacheCurrentFrameResourceIndex][TemporalSupersampling::FrameAge], D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            resourceStateTracker->TransitionResource(&m_cachedFrameAgeValueSquaredValueRayHitDistance, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        }

        UINT maxFrameAge = static_cast<UINT>(1 / Args::RTAO_TemporalSupersampling_MinSmoothingFactor);
        resourceStateTracker->FlushResourceBarriers();
        m_temporalCacheReverseReprojectKernel.Execute(
            commandList,
            m_width,
            m_height,
            m_cbvSrvUavHeap->GetHeap(),
            GBufferResources()[GBufferResource::SurfaceNormalDepth].gpuDescriptorReadAccess,
            GBufferResources()[GBufferResource::PartialDepthDerivatives].gpuDescriptorReadAccess,
            GBufferResources()[GBufferResource::ReprojectedNormalDepth].gpuDescriptorReadAccess,
            GBufferResources()[GBufferResource::MotionVector].gpuDescriptorReadAccess,
            m_TSSAOCoefficient[temporalCachePreviousFrameTSSAOCoeficientResourceIndex].gpuDescriptorReadAccess,
            m_prevFrameGBufferNormalDepth.gpuDescriptorReadAccess,
            m_temporalCache[temporalCachePreviousFrameResourceIndex][TemporalSupersampling::FrameAge].gpuDescriptorReadAccess,
            m_temporalCache[temporalCachePreviousFrameResourceIndex][TemporalSupersampling::CoefficientSquaredMean].gpuDescriptorReadAccess,
            m_temporalCache[temporalCachePreviousFrameResourceIndex][TemporalSupersampling::RayHitDistance].gpuDescriptorReadAccess,
            m_temporalCache[m_temporalCacheCurrentFrameResourceIndex][TemporalSupersampling::FrameAge].gpuDescriptorWriteAccess,
            m_cachedFrameAgeValueSquaredValueRayHitDistance.gpuDescriptorWriteAccess,
            Args::RTAO_TemporalSupersampling_MinSmoothingFactor,
            Args::RTAO_TemporalSupersampling_DepthTolerance,
            Args::RTAO_TemporalSupersampling_UseDepthWeights,
            Args::RTAO_TemporalSupersampling_UseNormalWeights,
            Args::RTAO_TemporalSupersampling_ClampCachedValues_AbsoluteDepthTolerance,
            Args::RTAO_TemporalSupersampling_ClampCachedValues_DepthBasedDepthTolerance,
            Args::RTAO_TemporalSupersampling_ClampCachedValues_DepthSigma,
            Args::RTAO_TemporalSupersampling_UseWorldSpaceDistance,
            RTAO::Args::QuarterResAO,
            Args::RTAO_TemporalSupersampling_PerspectiveCorrectDepthInterpolation,
#if !NORMAL_DEPTH_R8G8B16_ENCODING
            static_cast<TextureResourceFormatRGB::Type>(static_cast<UINT>(Args::RTAO_TemporalSupersampling_NormalDepthResourceFormat)),
#endif
            Sample::g_debugOutput,
            invViewProj,
            prevInvViewProj,
            maxFrameAge,
            Args::RTAODenoisingExtraRaysToTraceSinceTSSMovement,
            Args::RTAO_TemporalSupersampling_TestFlag);

        // Transition output resources to SRV state.        
        // ToDo use it as UAV in RTAO?
        // Only the frame age is transitioned out of UAV state as it used in RTAO pass. 
        // All the others are used as input/output UAVs in 2nd stage of Temporal Supersampling.
        {
            resourceStateTracker->TransitionResource(&m_temporalCache[m_temporalCacheCurrentFrameResourceIndex][TemporalSupersampling::FrameAge], D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            resourceStateTracker->TransitionResource(&m_cachedFrameAgeValueSquaredValueRayHitDistance, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            resourceStateTracker->InsertUAVBarrier(&m_temporalCache[m_temporalCacheCurrentFrameResourceIndex][TemporalSupersampling::FrameAge]);
        }
    }

    void  Denoiser::RenderPass_TemporalSupersamplingBlendWithCurrentFrame()
    {
        auto commandList = m_deviceResources->GetCommandList();
        auto resourceStateTracker = m_deviceResources->GetGpuResourceStateTracker();

        ScopedTimer _prof(L"RenderPass_TemporalSupersamplingBlendWithCurrentFrame", commandList);

        GpuResource* AOResources = m_RTAO.AOResources();

        GpuResource* m_TSSAOCoefficient = RTAO::Args::QuarterResAO ? m_lowResTSSAOCoefficient : m_TSSAOCoefficient;

        GpuResource* VarianceResources = RTAO::Args::QuarterResAO ? m_lowResVarianceResource : m_varianceResources;
        GpuResource* LocalMeanVarianceResources = RTAO::Args::QuarterResAO ? m_lowResLocalMeanVarianceResource : m_localMeanVarianceResources;

        // ToDo remove
        if (Args::CompositionMode == CompositionType::AmbientOcclusionOnly_RawOneFrame)
        {
            // ToDo
            //m_temporalCacheFrameAge = 0;
        }

        // ToDo zero out caches on resource reset.

        // ToDo reuse calculated variance for both TAO and denoising.
        // Transition all output resources to UAV state.
        {
            resourceStateTracker->TransitionResource(&LocalMeanVarianceResources[AOVarianceResource::Raw], D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            resourceStateTracker->InsertUAVBarrier(&AOResources[AOResource::Coefficient]);
        }

        bool isCheckerboardSamplingEnabled;
        bool checkerboardLoadEvenPixels;
        m_RTAO.GetRayGenParameters(&isCheckerboardSamplingEnabled, &checkerboardLoadEvenPixels);

        // ToDO Should use separable box filter instead?. Bilateral doesn't work for pixels that don't
        // have anycontribution with bilateral - their variance will be zero. Or set a variance to non-zero in that case?
        // Calculate local mean and variance.
        {
            // ToDo add Separable Bilateral and Square bilateral support how it affects image quality.
            // ToDo checkerboard is same perf ?
            ScopedTimer _prof(L"Calculate Mean and Variance", commandList);
            resourceStateTracker->FlushResourceBarriers();
            m_calculateMeanVarianceKernel.Execute(
                commandList,
                m_cbvSrvUavHeap->GetHeap(),
                m_width,
                m_height,
                //GpuKernels::CalculateMeanVariance::FilterType::Separable_AnyToAnyWaveReadLaneAt,
                GpuKernels::CalculateMeanVariance::FilterType::Separable_CheckerboardSampling_AnyToAnyWaveReadLaneAt,
                AOResources[AOResource::Coefficient].gpuDescriptorReadAccess,
                LocalMeanVarianceResources[AOVarianceResource::Raw].gpuDescriptorWriteAccess,
                Args::VarianceBilateralFilterKernelWidth,
                isCheckerboardSamplingEnabled,
                checkerboardLoadEvenPixels);

            // Interpolate the variance for the inactive cells from the valid checherkboard cells.
            if (isCheckerboardSamplingEnabled)
            {
                bool fillEvenPixels = !checkerboardLoadEvenPixels;
                resourceStateTracker->FlushResourceBarriers();
                m_fillInCheckerboardKernel.Execute(
                    commandList,
                    m_cbvSrvUavHeap->GetHeap(),
                    m_width,
                    m_height,
                    GpuKernels::FillInCheckerboard::FilterType::CrossBox4TapFilter,
                    LocalMeanVarianceResources[AOVarianceResource::Smoothed].gpuDescriptorReadAccess,
                    LocalMeanVarianceResources[AOVarianceResource::Raw].gpuDescriptorWriteAccess,
                    fillEvenPixels);
            }

            resourceStateTracker->TransitionResource(&LocalMeanVarianceResources[AOVarianceResource::Raw], D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            resourceStateTracker->InsertUAVBarrier(&LocalMeanVarianceResources[AOVarianceResource::Raw]);
        }
#if 0 // !VARIABLE_RATE_RAYTRACING
        // ToDo - the filter needs to check for invalid values...
        // ToDo should we be smoothing before temporal?
        // Smoothen the local variance which is prone to error due to undersampled input.
        {
            {
                ScopedTimer _prof(L"Mean Variance Smoothing", commandList);
                resourceStateTracker->FlushResourceBarriers();
                m_gaussianSmoothingKernel.Execute(
                    commandList,
                    m_width,
                    m_height,
                    GpuKernels::GaussianFilter::Filter3x3RG,
                    m_cbvSrvUavHeap->GetHeap(),
                    LocalMeanVarianceResources[AOVarianceResource::Raw].gpuDescriptorReadAccess,
                    LocalMeanVarianceResources[AOVarianceResource::Smoothed].gpuDescriptorWriteAccess);
            }
        }
#endif

        {
            resourceStateTracker->InsertUAVBarrier(&LocalMeanVarianceResources[AOVarianceResource::Smoothed]);
        }


        bool fillInMissingValues = false;   // ToDo fix up barriers if changing this to true
#if 0
        // ToDo?
        Args::RTAODenoisingLowTsppFillMissingValues
            && m_RTAO.GetSpp() < 1;
#endif
        GpuResource* TSSOutCoefficient = fillInMissingValues ? &m_temporalSupersampling_blendedAOCoefficient[0] : &m_TSSAOCoefficient[m_temporalCacheCurrentFrameTSSAOCoefficientResourceIndex];

        // Transition output resource to UAV state.      
        {
            resourceStateTracker->TransitionResource(TSSOutCoefficient, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            resourceStateTracker->TransitionResource(&m_temporalCache[m_temporalCacheCurrentFrameResourceIndex][TemporalSupersampling::FrameAge], D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            resourceStateTracker->TransitionResource(&m_temporalCache[m_temporalCacheCurrentFrameResourceIndex][TemporalSupersampling::CoefficientSquaredMean], D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            resourceStateTracker->TransitionResource(&m_temporalCache[m_temporalCacheCurrentFrameResourceIndex][TemporalSupersampling::RayHitDistance], D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            resourceStateTracker->TransitionResource(&VarianceResources[AOVarianceResource::Raw], D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            resourceStateTracker->TransitionResource(&m_multiPassDenoisingBlurStrength, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            resourceStateTracker->InsertUAVBarrier(&m_cachedFrameAgeValueSquaredValueRayHitDistance);
        }

        resourceStateTracker->FlushResourceBarriers();
        m_temporalCacheBlendWithCurrentFrameKernel.Execute(
            commandList,
            m_width,
            m_height,
            m_cbvSrvUavHeap->GetHeap(),
            AOResources[AOResource::Coefficient].gpuDescriptorReadAccess,
#if VARIABLE_RATE_RAYTRACING
            LocalMeanVarianceResources[AOVarianceResource::Raw].gpuDescriptorReadAccess,
#else
            m_smoothedLocalMeanVarianceResource.gpuDescriptorReadAccess,
#endif
            AOResources[AOResource::RayHitDistance].gpuDescriptorReadAccess,
            TSSOutCoefficient->gpuDescriptorWriteAccess,
            m_temporalCache[m_temporalCacheCurrentFrameResourceIndex][TemporalSupersampling::FrameAge].gpuDescriptorWriteAccess,
            m_temporalCache[m_temporalCacheCurrentFrameResourceIndex][TemporalSupersampling::CoefficientSquaredMean].gpuDescriptorWriteAccess,
            m_temporalCache[m_temporalCacheCurrentFrameResourceIndex][TemporalSupersampling::RayHitDistance].gpuDescriptorWriteAccess,
            m_cachedFrameAgeValueSquaredValueRayHitDistance.gpuDescriptorReadAccess,
            VarianceResources[AOVarianceResource::Raw].gpuDescriptorWriteAccess,
            m_multiPassDenoisingBlurStrength.gpuDescriptorWriteAccess,
            Args::RTAO_TemporalSupersampling_MinSmoothingFactor,
            Args::RTAO_TemporalSupersampling_ForceUseMinSmoothingFactor,
            Args::RTAO_TemporalSupersampling_ClampCachedValues_UseClamping,
            Args::RTAO_TemporalSupersampling_ClampCachedValues_StdDevGamma,
            Args::RTAO_TemporalSupersampling_ClampCachedValues_MinStdDevTolerance,
            Args::RTAODenoising_MinFrameAgeToUseTemporalVariance,
            Args::RTAO_TemporalSupersampling_ClampDifferenceToFrameAgeScale,
            Sample::g_debugOutput,
            Args::RTAODenoisingnumFramesToDenoiseAfterLastTracedRay,
            Args::RTAODenoisingLowTsppMaxFrameAge,
            Args::RTAODenoisingLowTsppDecayConstant,
            isCheckerboardSamplingEnabled,
            checkerboardLoadEvenPixels);

        // Transition output resource to SRV state.        
        {
            resourceStateTracker->TransitionResource(&m_temporalCache[m_temporalCacheCurrentFrameResourceIndex][TemporalSupersampling::FrameAge], D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            resourceStateTracker->TransitionResource(&m_temporalCache[m_temporalCacheCurrentFrameResourceIndex][TemporalSupersampling::CoefficientSquaredMean], D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            resourceStateTracker->TransitionResource(&m_temporalCache[m_temporalCacheCurrentFrameResourceIndex][TemporalSupersampling::RayHitDistance], D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            resourceStateTracker->TransitionResource(&VarianceResources[AOVarianceResource::Raw], D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            resourceStateTracker->TransitionResource(&m_multiPassDenoisingBlurStrength, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        }

        // ToDo remove make condiotional
        // Smoothen the variance.
        {
            {
                resourceStateTracker->TransitionResource(&VarianceResources[AOVarianceResource::Smoothed], D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
                resourceStateTracker->InsertUAVBarrier(&VarianceResources[AOVarianceResource::Raw]);
            }

            // ToDo should we be smoothing before temporal?
            // Smoothen the local variance which is prone to error due to undersampled input.
            {
                {
                    ScopedTimer _prof(L"Mean Variance Smoothing", commandList);
                    resourceStateTracker->FlushResourceBarriers();
                    m_gaussianSmoothingKernel.Execute(
                        commandList,
                        m_width,
                        m_height,
                        GpuKernels::GaussianFilter::Filter3x3,
                        m_cbvSrvUavHeap->GetHeap(),
                        VarianceResources[AOVarianceResource::Raw].gpuDescriptorReadAccess,
                        VarianceResources[AOVarianceResource::Smoothed].gpuDescriptorWriteAccess);
                }
            }

            resourceStateTracker->TransitionResource(&VarianceResources[AOVarianceResource::Smoothed], D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        }

        // ToDo?
        if (fillInMissingValues)
        {
            // Fill in missing/disoccluded values.
            {
#if 1
                // ToDo should we use a wider filter?
                if (isCheckerboardSamplingEnabled)
                {
                    bool fillEvenPixels = !checkerboardLoadEvenPixels;
                    resourceStateTracker->FlushResourceBarriers();
                    m_fillInCheckerboardKernel.Execute(
                        commandList,
                        m_cbvSrvUavHeap->GetHeap(),
                        m_width,
                        m_height,
                        GpuKernels::FillInCheckerboard::FilterType::CrossBox4TapFilter,
                        LocalMeanVarianceResources[AOVarianceResource::Smoothed].gpuDescriptorReadAccess,
                        TSSOutCoefficient->gpuDescriptorWriteAccess,
                        fillEvenPixels);

                }
#else
                ScopedTimer _prof(L"Fill in missing values filter", commandList);
                {
                    resourceStateTracker->TransitionResource(&m_TSSAOCoefficient[m_temporalCacheCurrentFrameResourceIndex], D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
                    resourceStateTracker->InsertUAVBarrier(&TSSOutCoefficient->resource.Get()),
                }

                resourceStateTracker->FlushResourceBarriers();
                m_fillInMissingValuesFilterKernel.Execute(
                    commandList,
                    m_width,
                    m_height,
                    GpuKernels::FillInMissingValuesFilter::DepthAware_GaussianFilter7x7,
                    1,
                    isCheckerboardSamplingEnabled,
                    checkerboardLoadEvenPixels,
                    m_cbvSrvUavHeap->GetHeap(),
                    TSSOutCoefficient->gpuDescriptorReadAccess,
                    GBufferResources()[GBufferResource::Depth].gpuDescriptorReadAccess,
                    m_TSSAOCoefficient[m_temporalCacheCurrentFrameResourceIndex].gpuDescriptorWriteAccess);

                {
                    D3D12_RESOURCE_STATES before = D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
                    D3D12_RESOURCE_STATES after = D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
                    D3D12_RESOURCE_BARRIER barriers[] = {
                        resourceStateTracker->TransitionResource(&m_TSSAOCoefficient[m_temporalCacheCurrentFrameResourceIndex], after);
                    };
                    commandList->ResourceBarrier(ARRAYSIZE(barriers), barriers);
                }
#endif
            }
        }
        resourceStateTracker->TransitionResource(TSSOutCoefficient, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    }

    void Denoiser::MultiPassBlur()
    {
        auto commandList = m_deviceResources->GetCommandList();
        auto resourceStateTracker = m_deviceResources->GetGpuResourceStateTracker();

        ScopedTimer _prof(L"Low-Tspp Multi-pass blur", commandList);

        UINT numPasses = static_cast<UINT>(Args::RTAODenoisingLowTspBlurPasses);

        GpuResource* AOResources = m_RTAO.AOResources();

        GpuResource* resources[2] = {
            &m_temporalSupersampling_blendedAOCoefficient[0],
            &m_temporalSupersampling_blendedAOCoefficient[1],
        };

        GpuResource* m_TSSAOCoefficient = RTAO::Args::QuarterResAO ? m_lowResTSSAOCoefficient : m_TSSAOCoefficient;
        GpuResource* OutResource = &m_TSSAOCoefficient[m_temporalCacheCurrentFrameTSSAOCoefficientResourceIndex];
        //GpuResource* OutResource = &AOResources[AOResource::Smoothed];

        bool readWriteUAV_and_skipPassthrough = false;// (numPasses % 2) == 1;

        if (Args::RTAODenoisingLowTsppUseUAVReadWrite)
        {
            readWriteUAV_and_skipPassthrough = true;
            resourceStateTracker->TransitionResource(OutResource, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        }

        GpuKernels::BilateralFilter::FilterType filter =
            Args::RTAODenoisingLowTsppUseNormalWeights
            ? GpuKernels::BilateralFilter::NormalDepthAware_GaussianFilter5x5
            : GpuKernels::BilateralFilter::DepthAware_GaussianFilter5x5;

        GpuResource* depthResource =
            Args::RTAODenoisingLowTsppUseNormalWeights
            ? &GBufferResources()[GBufferResource::SurfaceNormalDepth]
            : &GBufferResources()[GBufferResource::Depth];

        UINT FilterSteps[4] = {
            1, 4, 8, 16
        };

        UINT filterStep = 1;

        for (UINT i = 0; i < numPasses; i++)
        {
            // filterStep = FilterSteps[i];
            wstring passName = L"Depth Aware Gaussian Blur with a pixel step " + to_wstring(filterStep);
            ScopedTimer _prof(passName.c_str(), commandList);


            if (Args::RTAODenoisingLowTsppUseUAVReadWrite)
            {
                resourceStateTracker->InsertUAVBarrier(OutResource);

                resourceStateTracker->FlushResourceBarriers();
                m_bilateralFilterKernel.Execute(
                    commandList,
                    filter,
                    filterStep,
                    Args::RTAODenoisingLowTsppNormalExponent,
                    Args::RTAODenoisingLowTsppMinNormalWeight,
                    m_cbvSrvUavHeap->GetHeap(),
                    m_temporalSupersampling_blendedAOCoefficient[0].gpuDescriptorReadAccess,
                    depthResource->gpuDescriptorReadAccess,
                    m_multiPassDenoisingBlurStrength.gpuDescriptorReadAccess,
                    OutResource,
                    readWriteUAV_and_skipPassthrough);
            }
            else
            {
                GpuResource* inResource = i > 0 ? resources[i % 2] : OutResource;
                GpuResource* outResource = i < numPasses - 1 ? resources[(i + 1) % 2] : OutResource;

                {
                    resourceStateTracker->TransitionResource(outResource, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
                    resourceStateTracker->InsertUAVBarrier(inResource);
                }

                resourceStateTracker->FlushResourceBarriers();
                m_bilateralFilterKernel.Execute(
                    commandList,
                    filter,
                    filterStep,
                    Args::RTAODenoisingLowTsppNormalExponent,
                    Args::RTAODenoisingLowTsppMinNormalWeight,
                    m_cbvSrvUavHeap->GetHeap(),
                    inResource->gpuDescriptorReadAccess,
                    GBufferResources()[GBufferResource::SurfaceNormalDepth].gpuDescriptorReadAccess,
                    m_multiPassDenoisingBlurStrength.gpuDescriptorReadAccess,
                    outResource,
                    readWriteUAV_and_skipPassthrough);

                {
                    resourceStateTracker->TransitionResource(outResource, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
                    resourceStateTracker->InsertUAVBarrier(outResource);
                }
            }

            filterStep *= 2;
        }


        if (Args::RTAODenoisingLowTsppUseUAVReadWrite)
        {
            resourceStateTracker->TransitionResource(OutResource, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            resourceStateTracker->InsertUAVBarrier(OutResource);
        }
    }


    void Denoiser::ApplyAtrousWaveletTransformFilter(bool isFirstPass)
    {
        auto commandList = m_deviceResources->GetCommandList();
        auto resourceStateTracker = m_deviceResources->GetGpuResourceStateTracker();

        auto frameIndex = m_deviceResources->GetCurrentFrameIndex();

        GpuResource* AOResources = m_RTAO.AOResources();

        // ToDO use separate toggles for local and temporal
        GpuResource* VarianceResource = Args::RTAODenoisingUseSmoothedVariance ? &m_varianceResources[AOVarianceResource::Smoothed] : &m_varianceResources[AOVarianceResource::Raw];


        ScopedTimer _prof(L"DenoiseAO", commandList);

        // Transition Resources.
        resourceStateTracker->TransitionResource(&AOResources[AOResource::Smoothed], D3D12_RESOURCE_STATE_UNORDERED_ACCESS);

#if RAYTRACING_MANUAL_KERNEL_STEP_SHIFTS
        static UINT frameID = 0;

        UINT offsets[5] = {
            static_cast<UINT>(Args::RTAO_KernelStepShift0),
            static_cast<UINT>(Args::RTAO_KernelStepShift1),
            static_cast<UINT>(Args::RTAO_KernelStepShift2),
            static_cast<UINT>(Args::RTAO_KernelStepShift3),
            static_cast<UINT>(Args::RTAO_KernelStepShift4) };

        if (isFirstPass)
        {
            offsets[0] = Args::RTAO_KernelStepRotateShift0 ? 1 + (frameID++ % (offsets[0] + 1)) : offsets[0];
        }
        else
        {
            for (UINT i = 1; i < 5; i++)
            {
                offsets[i - 1] = offsets[i];
            }
        }

        UINT newStartId = 0;
        for (UINT i = 1; i < 5; i++)
        {
            offsets[i] = newStartId + offsets[i];
            newStartId = offsets[i] + 1;
        }
#endif

        float ValueSigma;
        float NormalSigma;
        float DepthSigma;
        if (isFirstPass)
        {
            ValueSigma = Args::AODenoiseValueSigma;
            NormalSigma = Args::AODenoiseNormalSigma;
            DepthSigma = Args::AODenoiseDepthSigma;
        }
        else
        {
            ValueSigma = Args::RTAODenoising_2ndPass_UseVariance ? 1.f : 0.f;
            NormalSigma = Args::RTAODenoising_2ndPass_NormalSigma;
            DepthSigma = Args::RTAODenoising_2ndPass_DepthSigma;
        }

#if TWO_PASS_DENOISE
        UINT numFilterPasses = Args::AtrousFilterPasses;// isFirstPass ? 1 : Args::AtrousFilterPasses - 1;
#else
        UINT numFilterPasses = Args::AtrousFilterPasses;
#endif
        bool cacheIntermediateDenoiseOutput =
            Args::RTAO_TemporalSupersampling_CacheDenoisedOutput &&
            static_cast<UINT>(Args::RTAO_TemporalSupersampling_CacheDenoisedOutputPassNumber) < numFilterPasses;

        GpuResource* InputAOCoefficientResource = &m_TSSAOCoefficient[m_temporalCacheCurrentFrameTSSAOCoefficientResourceIndex];
        GpuResource* OutputIntermediateResource = nullptr;
        if (cacheIntermediateDenoiseOutput)
        {
            // ToDo clean this up so that its clear.
            m_temporalCacheCurrentFrameTSSAOCoefficientResourceIndex = (m_temporalCacheCurrentFrameTSSAOCoefficientResourceIndex + 1) % 2;
            OutputIntermediateResource = &m_TSSAOCoefficient[m_temporalCacheCurrentFrameTSSAOCoefficientResourceIndex];
        }

        if (OutputIntermediateResource)
        {
            resourceStateTracker->TransitionResource(OutputIntermediateResource, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        }


        float staleNeighborWeightScale = Args::RTAODenoising_LowerWeightForStaleSamples ? m_RTAO.GetSpp() : 1;
        bool forceDenoisePass = Args::RTAODenoising_ForceDenoisePass;

        if (forceDenoisePass)
        {
            Args::RTAODenoising_ForceDenoisePass.Bang();
        }
        // A-trous edge-preserving wavelet tranform filter
        if (numFilterPasses > 0)
        {
            ScopedTimer _prof(L"AtrousWaveletTransformFilter", commandList);
            resourceStateTracker->FlushResourceBarriers();
            m_atrousWaveletTransformFilter.Execute(
                commandList,
                m_cbvSrvUavHeap->GetHeap(),
                static_cast<GpuKernels::AtrousWaveletTransformCrossBilateralFilter::FilterType>(static_cast<UINT>(Args::DenoisingMode)),
                InputAOCoefficientResource->gpuDescriptorReadAccess,
                GBufferResources()[GBufferResource::SurfaceNormalDepth].gpuDescriptorReadAccess,
                VarianceResource->gpuDescriptorReadAccess,
                m_temporalCache[m_temporalCacheCurrentFrameResourceIndex][TemporalSupersampling::RayHitDistance].gpuDescriptorReadAccess,
                GBufferResources()[GBufferResource::PartialDepthDerivatives].gpuDescriptorReadAccess,
                m_temporalCache[m_temporalCacheCurrentFrameResourceIndex][TemporalSupersampling::FrameAge].gpuDescriptorReadAccess,
                &AOResources[AOResource::Smoothed],
                OutputIntermediateResource,
                &Sample::g_debugOutput[0],
                &Sample::g_debugOutput[1],
                ValueSigma,
                DepthSigma,
                NormalSigma,
                Args::RTAODenoising_WeightScale,
#if !NORMAL_DEPTH_R8G8B16_ENCODING
                // ToDo rename this to be global normalDepth
                static_cast<TextureResourceFormatRGB::Type>(static_cast<UINT>(Args::RTAO_TemporalSupersampling_NormalDepthResourceFormat)),
#endif
                offsets,
                static_cast<UINT>(Args::RTAO_TemporalSupersampling_CacheDenoisedOutputPassNumber),
                numFilterPasses,
                GpuKernels::AtrousWaveletTransformCrossBilateralFilter::Mode::OutputFilteredValue,
                Args::ReverseFilterOrder,
                Args::UseSpatialVariance,
                Args::RTAODenoisingPerspectiveCorrectDepthInterpolation,
                Args::RTAODenoisingUseAdaptiveKernelSize,
                Args::RTAO_Denoising_AdaptiveKernelSize_MinHitDistanceScaleFactor,
                Args::RTAODenoisingFilterMinKernelWidth,
                static_cast<UINT>((Args::RTAODenoisingFilterMaxKernelWidthPercentage / 100) * m_width),
                Args::RTAODenoisingFilterVarianceSigmaScaleOnSmallKernels,
                RTAO::Args::QuarterResAO,
                Args::RTAODenoisingMinVarianceToDenoise,
                staleNeighborWeightScale,
                Args::AODenoiseDepthWeightCutoff,
                Args::RTAODenoisingUseProjectedDepthTest,
                forceDenoisePass,
                Args::RTAODenoisingFilterWeightByFrameAge);
        }

        // ToDo move these right before the call?
        resourceStateTracker->TransitionResource(&AOResources[AOResource::Smoothed], D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        resourceStateTracker->TransitionResource(OutputIntermediateResource, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    }


    // ToDo move out
    void Denoiser::ApplyAtrousWaveletTransformFilter(
        const GpuResource& inValueResource,
        const GpuResource& inNormalDepthResource,
        const GpuResource& inDepthResource,
        const GpuResource& inRayHitDistanceResource,
        const GpuResource& inPartialDistanceDerivativesResource,
        GpuResource* outSmoothedValueResource,
        GpuResource* varianceResource,
        GpuResource* smoothedVarianceResource,
        UINT calculateVarianceTimerId,      // ToDo remove obsolete
        UINT smoothVarianceTimerId,
        UINT atrousFilterTimerId
    )
    {
        ThrowIfFalse(false, L"ToDo");

#if 0
        auto commandList = m_deviceResources->GetCommandList();

        auto desc = inValueResource->GetDesc();
        // ToDo cleanup widths on GPU kernels, it should be the one of input resource.
        UINT width = static_cast<UINT>(desc.Width);
        UINT height = static_cast<UINT>(desc.Height);

#if 0
        // Calculate local variance.
        {
            ScopedTimer _prof(L"CalculateVariance", commandList);
            resourceStateTracker->FlushResourceBarriers();
            m_calculateVarianceKernel.Execute(
                commandList,
                m_cbvSrvUavHeap->GetHeap(),
                width,
                height,
                static_cast<GpuKernels::CalculateVariance::FilterType>(static_cast<UINT>(Args::VarianceBilateralFilter)),
                inValueResource.gpuDescriptorReadAccess,
                inNormalDepthResource.gpuDescriptorReadAccess,
                inDepthResource.gpuDescriptorReadAccess,
                varianceResource->gpuDescriptorWriteAccess,
                CD3DX12_GPU_DESCRIPTOR_HANDLE(),    // unused mean resource output
                Args::AODenoiseDepthSigma,
                Args::AODenoiseNormalSigma,
                false,
                Args::RTAODenoising_Variance_UseDepthWeights,
                Args::RTAODenoising_Variance_UseNormalWeights,
                Args::RTAOVarianceFilterKernelWidth);

            D3D12_RESOURCE_STATES before = D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
            D3D12_RESOURCE_STATES after = D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
            resourceStateTracker->TransitionResource(&varianceResource->resource.Get(), after));
        }

        // ToDo, should the smoothing be applied after each pass?
        // Smoothen the local variance which is prone to error due to undersampled input.
        {
            ScopedTimer _prof(L"VarianceSmoothing", commandList);
            resourceStateTracker->FlushResourceBarriers();
            m_gaussianSmoothingKernel.Execute(
                commandList,
                width,
                height,
                GpuKernels::GaussianFilter::Filter3x3,
                m_cbvSrvUavHeap->GetHeap(),
                varianceResource->gpuDescriptorReadAccess,
                smoothedVarianceResource->gpuDescriptorWriteAccess);
        }

        // Transition Variance resource to shader resource state.
        // Also prepare smoothed AO resource for the next pass and transition it to UAV.
        {
            D3D12_RESOURCE_STATES before = D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
            D3D12_RESOURCE_STATES after = D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
            D3D12_RESOURCE_BARRIER barriers[] = {
                resourceStateTracker->TransitionResource(&smoothedVarianceResource->resource.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE),
                // ToDo Remove      resourceStateTracker->TransitionResource(&outSmoothedValueResource->resource.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS)
            };
            commandList->ResourceBarrier(ARRAYSIZE(barriers), barriers);
        }
#endif

#if RAYTRACING_MANUAL_KERNEL_STEP_SHIFTS
        UINT offsets[5] = {
            static_cast<UINT>(Args::RTAO_KernelStepShift0),
            static_cast<UINT>(Args::RTAO_KernelStepShift1),
            static_cast<UINT>(Args::RTAO_KernelStepShift2),
            static_cast<UINT>(Args::RTAO_KernelStepShift3),
            static_cast<UINT>(Args::RTAO_KernelStepShift4) };

        UINT newStartId = 0;
        for (UINT i = 0; i < 5; i++)
        {
            offsets[i] = newStartId + offsets[i];
            newStartId = offsets[i] + 1;
        }
#endif
        // A-trous edge-preserving wavelet tranform filter.
        {
            ScopedTimer _prof(L"AtrousWaveletTransformFilter", commandList);
            resourceStateTracker->FlushResourceBarriers();
            m_atrousWaveletTransformFilter.Execute(
                commandList,
                m_cbvSrvUavHeap->GetHeap(),
                static_cast<GpuKernels::AtrousWaveletTransformCrossBilateralFilter::FilterType>(static_cast<UINT>(Args::DenoisingMode)),
                inValueResource.gpuDescriptorReadAccess,
                inNormalDepthResource.gpuDescriptorReadAccess,
                inDepthResource.gpuDescriptorReadAccess,
                smoothedVarianceResource->gpuDescriptorReadAccess,
                inRayHitDistanceResource.gpuDescriptorReadAccess,
                inPartialDistanceDerivativesResource.gpuDescriptorReadAccess,
                m_temporalCache[m_temporalCacheCurrentFrameResourceIndex][TemporalSupersampling::FrameAge].gpuDescriptorReadAccess,
                outSmoothedValueResource,
                Args::AODenoiseValueSigma,
                Args::AODenoiseDepthSigma,
                Args::AODenoiseNormalSigma,
                Args::RTAODenoising_WeightScale,
                static_cast<TextureResourceFormatRGB::Type>(static_cast<UINT>(Args::RTAO_TemporalSupersampling_NormalDepthResourceFormat)),
                offsets,
                Args::AtrousFilterPasses,
                GpuKernels::AtrousWaveletTransformCrossBilateralFilter::Mode::OutputFilteredValue,
                Args::ReverseFilterOrder,
                Args::UseSpatialVariance,
                Args::RTAODenoisingPerspectiveCorrectDepthInterpolation,
                Args::RTAODenoisingUseAdaptiveKernelSize,
                Args::RTAO_Denoising_AdaptiveKernelSize_MinHitDistanceScaleFactor,
                Args::RTAODenoisingFilterMinKernelWidth,
                static_cast<UINT>((Args::RTAODenoisingFilterMaxKernelWidthPercentage / 100) * m_width),
                Args::RTAODenoisingFilterVarianceSigmaScaleOnSmallKernels,
                RTAO::Args::QuarterResAO);
        }
#endif
    }

    GpuResource(&Denoiser::GBufferResources())[GBufferResource::Count]
    {
        return Pathtracer::GBufferResources(RTAO::Args::QuarterResAO);
    }

}