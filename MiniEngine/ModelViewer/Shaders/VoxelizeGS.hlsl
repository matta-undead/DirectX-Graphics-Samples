
#include "ModelViewerRS.hlsli"

struct VSOutput
{
    sample float4 position : SV_Position;
    sample float3 worldPos : WorldPos;
    sample float2 uv : TexCoord0;
    sample float3 viewDir : TexCoord1;
    sample float3 shadowCoord : TexCoord2;
    sample float3 normal : Normal;
    sample float3 tangent : Tangent;
    sample float3 bitangent : Bitangent;
};

struct GSOutput
{
    sample float4 position : SV_Position;
    sample float3 worldPos : WorldPos;
    sample float2 uv : TexCoord0;
    sample float3 viewDir : TexCoord1;
    sample float3 shadowCoord : TexCoord2;
    sample float3 normal : Normal;
    sample float3 tangent : Tangent;
    sample float3 bitangent : Bitangent;
    sample float2 swizzle : TexCoord3;
};

void GSOutputFromVS(in VSOutput vso, inout GSOutput gso)
{
    gso.position = vso.position;
    gso.worldPos = vso.worldPos;
    gso.uv = vso.uv;
    gso.viewDir = vso.viewDir;
    gso.shadowCoord = vso.shadowCoord;
    gso.normal = vso.normal;
    gso.tangent = vso.tangent;
    gso.bitangent = vso.bitangent;
    // leave target swizzle unaffected.
}

//[RootSignature(ModelViewer_RootSig)]
[maxvertexcount(3)]
void main(triangle VSOutput vsOutput[3], inout TriangleStream<GSOutput> triStream)
{
    // dominant axis selection
    float3 v0 = normalize(vsOutput[1].worldPos - vsOutput[0].worldPos);
    float3 v1 = normalize(vsOutput[2].worldPos - vsOutput[0].worldPos);
    float3 geometricNormal = cross(v0, v1);
    float xSwizzle = 0.0;
    float ySwizzle = 0.0;
    if ((geometricNormal.x > geometricNormal.z) && (geometricNormal.x > geometricNormal.y))
    {
        xSwizzle = 1.0;
    }
    else if ((geometricNormal.y > geometricNormal.z) && (geometricNormal.y > geometricNormal.x))
    {
        ySwizzle = 1.0;
    }

    // triangle projection
    if (0.0 < xSwizzle)
    {
        vsOutput[0].position.xyz = vsOutput[0].position.zyx;
        vsOutput[1].position.xyz = vsOutput[1].position.zyx;
        vsOutput[2].position.xyz = vsOutput[2].position.zyx;
    }
    else if (0.0 < ySwizzle)
    {
        vsOutput[0].position.xyz = vsOutput[0].position.xzy;
        vsOutput[0].position.xyz = vsOutput[0].position.xzy;
        vsOutput[0].position.xyz = vsOutput[0].position.xzy;
    }

    // edge shifting ?
    {
    }
    
    // Output
    GSOutput v;
    v.swizzle = float2(xSwizzle, ySwizzle);
    GSOutputFromVS(vsOutput[0], v);
    triStream.Append(v);
    GSOutputFromVS(vsOutput[1], v);
    triStream.Append(v);
    GSOutputFromVS(vsOutput[2], v);
    triStream.Append(v);
}
