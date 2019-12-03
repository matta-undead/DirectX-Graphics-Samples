//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the MIT License (MIT).
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
// Developed by Minigraph
//
// Author(s):  James Stanard
//             Alex Nankervis
//

#include "VctModelViewerRS.hlsli"

cbuffer VSConstants : register(b0)
{
    float4x4 modelToProjection;
    float4x4 modelToShadow;
    float3 ViewerPos;
};

struct VSInput
{
    float3 position : POSITION;
    float2 texcoord0 : TEXCOORD;
    float3 normal : NORMAL;
    float3 tangent : TANGENT;
    float3 bitangent : BITANGENT;
};

struct VSOutput
{
    float4 position : SV_Position;
    float3 worldPos : WorldPos;
    float2 texCoord : TexCoord0;
    float3 viewDir : TexCoord1;
    float3 shadowCoord : TexCoord2;
    float3 normal : Normal;
    float3 tangent : Tangent;
    float3 bitangent : Bitangent;
};

[RootSignature(ModelViewer_RootSig)]
VSOutput main(VSInput vsInput)
{
    VSOutput vsOutput;

    vsOutput.position = mul(modelToProjection, float4(vsInput.position, 1.0));
    vsOutput.worldPos = vsInput.position;
    vsOutput.texCoord = vsInput.texcoord0;
    vsOutput.viewDir = vsInput.position - ViewerPos;
    vsOutput.shadowCoord = mul(modelToShadow, float4(vsInput.position, 1.0)).xyz;

    vsOutput.normal = vsInput.normal;

    // Getting garbage results out of normalizing these in the pixel shader.
    // Force reasonableish values here.
    vsOutput.tangent = dot(vsInput.tangent, vsInput.tangent) > 0.0 ? vsInput.tangent : float3(1.0, 0.0, 0.0);
    vsOutput.bitangent = dot(vsInput.bitangent, vsInput.bitangent) > 0.0 ? vsInput.bitangent : float3(0.0, 1.0, 0.0);

    return vsOutput;
}
