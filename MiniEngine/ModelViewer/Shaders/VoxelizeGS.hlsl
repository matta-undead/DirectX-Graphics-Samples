
#include "ModelViewerRS.hlsli"

#define USE_SMALL_TRIANGLE_CULLING      1

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

struct GSOutput : VSOutput
{
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
    // cull out-of-bounds triangles
    float3 maxNormalizedPos = max(vsOutput[0].position.xyz, max(vsOutput[1].position.xyz, vsOutput[2].position.xyz));
    if (all(maxNormalizedPos < 0.0))
    {
        return;
    }
    float3 minNormalizedPos = min(vsOutput[0].position.xyz, min(vsOutput[1].position.xyz, vsOutput[2].position.xyz));
    if (all(minNormalizedPos > 1.0))
    {
        return;
    }

    // dominant axis selection
    float3 v0 = normalize(vsOutput[1].worldPos - vsOutput[0].worldPos);
    float3 v1 = normalize(vsOutput[2].worldPos - vsOutput[0].worldPos);
    float3 geometricNormal = abs(cross(v0, v1));
    float xSwizzle = 0.0;
    float ySwizzle = 0.0;
    if ((geometricNormal.x > geometricNormal.z) && (geometricNormal.x > geometricNormal.y))
    {
        xSwizzle = 1.0;
        vsOutput[0].position.xz = vsOutput[0].position.zx;
        vsOutput[1].position.xz = vsOutput[1].position.zx;
        vsOutput[2].position.xz = vsOutput[2].position.zx;
    }
    else if ((geometricNormal.y > geometricNormal.z) && (geometricNormal.y > geometricNormal.x))
    {
        ySwizzle = 1.0;
        vsOutput[0].position.yz = vsOutput[0].position.zy;
        vsOutput[1].position.yz = vsOutput[1].position.zy;
        vsOutput[2].position.yz = vsOutput[2].position.zy;
    }

    // edge shifting ?
    // https://developer.nvidia.com/gpugems/GPUGems2/gpugems2_chapter42.html
    {
    }

    // cull axis-projected, out-of-bounds triangles
    float2 aabbMin = min(vsOutput[0].position.xy, min(vsOutput[1].position.xy, vsOutput[2].position.xy));
    float2 aabbMax = max(vsOutput[0].position.xy, max(vsOutput[1].position.xy, vsOutput[2].position.xy));
    if (any(aabbMax < 0.0))
    {
        return;
    }
    if (any(aabbMin > 1.0))
    {
        return;
    }

#if USE_SMALL_TRIANGLE_CULLING
    // small triangle culling
    // Optimizing the Graphics Pipeline with Compute - Frostbite - GDC 2016
    // slide 53/59
    // if bounding box enclosing 2D projection of triangle does not touch
    // pixel center, nothing will be rasterized. may be some false positives
    // but that's probaly ok. use that test to skip outputting the triangle.
    // from vertex shader and swizzle above, we have normalized output position
    // from (0, 1) in xy. scale by voxel dims (hardcoded here to 256 for now)
    // and round to get integer coords suitable for comparison.
    aabbMin = aabbMin * 256.0;
    aabbMax = aabbMax * 256.0;
    if (any(round(aabbMin) == round(aabbMax)))
    {
        return;
    }
#endif

    // position currently in (0, 1), want clip space xy in (-1, 1)
    vsOutput[0].position.xy = vsOutput[0].position.xy * 2.0 - 1.0;
    vsOutput[1].position.xy = vsOutput[1].position.xy * 2.0 - 1.0;
    vsOutput[2].position.xy = vsOutput[2].position.xy * 2.0 - 1.0;
    
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
