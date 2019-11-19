
cbuffer VSConstants : register(b0)
{
    float4x4 worldToProjection;
    float3 viewerPosition;
    float3 positionMul;
    float3 positionAdd;
}

struct VSOutput
{
    float4 position : SV_Position;
    float3 worldPos : WorldPos;
    float4 color : TexCoord0;
    float3 viewDir : TexCoord1;
};

struct GSOutput
{
    float4 position : SV_Position;
    float4 color : TexCoord0;
};

[maxvertexcount(12)]
void main(point VSOutput vsOutput[1], inout TriangleStream<GSOutput> triStream)
{
#if 1
    // cull voxels not written to
    if (vsOutput[0].color.w < 1e-4)
    {
        return;
    }
#endif

    // hack, not caring about actual voxel size for a bit
    float3 offset = float3(2.5, 2.5, 2.5);

    float3 worldPosition = vsOutput[0].worldPos;


    /*        , 6 ----- 7
     *      2 ----- 3 ' |
     *      |   |   |   |
     *      |   |   |   |
     *      |   4 --|-- 5
     *      0 ----- 1 '
     */

    float4 wp0, wp1, wp2, wp3, wp4, wp5, wp6, wp7;

    wp0.xyz = float3(-1.0, -1.0, -1.0) * offset + worldPosition;
    wp1.xyz = float3( 1.0, -1.0, -1.0) * offset + worldPosition;
    wp2.xyz = float3(-1.0,  1.0, -1.0) * offset + worldPosition;
    wp3.xyz = float3( 1.0,  1.0, -1.0) * offset + worldPosition;
    wp4.xyz = float3(-1.0, -1.0,  1.0) * offset + worldPosition;
    wp5.xyz = float3( 1.0, -1.0,  1.0) * offset + worldPosition;
    wp6.xyz = float3(-1.0,  1.0,  1.0) * offset + worldPosition;
    wp7.xyz = float3( 1.0,  1.0,  1.0) * offset + worldPosition;

    wp0 = mul(worldToProjection, float4(wp0.xyz, 1.0));
    wp1 = mul(worldToProjection, float4(wp1.xyz, 1.0));
    wp2 = mul(worldToProjection, float4(wp2.xyz, 1.0));
    wp3 = mul(worldToProjection, float4(wp3.xyz, 1.0));
    wp4 = mul(worldToProjection, float4(wp4.xyz, 1.0));
    wp5 = mul(worldToProjection, float4(wp5.xyz, 1.0));
    wp6 = mul(worldToProjection, float4(wp6.xyz, 1.0));
    wp7 = mul(worldToProjection, float4(wp7.xyz, 1.0));

    GSOutput v;
    //v.position = float4(0.0, 0.0, 0.0, 1.0);
    v.color = vsOutput[0].color + float4(0.2, 0.2, 0.02, 0.02);

    // view is vector from world position of voxel towards eye
    float3 view = vsOutput[0].viewDir;

    if (view.x > 0.0)
    {
        // viewer located in positive x half space
        // want face 3, 7, 5, 1
        v.position = wp3;
        triStream.Append(v);
        v.position = wp7;
        triStream.Append(v);
        v.position = wp1;
        triStream.Append(v);
        v.position = wp5;
        triStream.Append(v);
    }
    else {
        // viewer located in negative x half space
        // want face 6, 2, 0, 4
        v.position = wp6;
        triStream.Append(v);
        v.position = wp2;
        triStream.Append(v);
        v.position = wp4;
        triStream.Append(v);
        v.position = wp0;
        triStream.Append(v);
    }

    triStream.RestartStrip();

    if (view.y > 0.0)
    {
        // viewer located in postive y half space
        // want face 6, 7, 3, 2
        v.position = wp6;
        triStream.Append(v);
        v.position = wp7;
        triStream.Append(v);
        v.position = wp2;
        triStream.Append(v);
        v.position = wp3;
        triStream.Append(v);
    }
    else
    {
        // viewer located in negative y half space
        // want face 0, 1, 5, 4
        v.position = wp0;
        triStream.Append(v);
        v.position = wp1;
        triStream.Append(v);
        v.position = wp4;
        triStream.Append(v);
        v.position = wp5;
        triStream.Append(v);
    }

    triStream.RestartStrip();

    if (view.z > 0.0)
    {
        // viewer located in positive z half space
        // want face 7, 6, 4, 5
        v.position = wp7;
        triStream.Append(v);
        v.position = wp6;
        triStream.Append(v);
        v.position = wp5;
        triStream.Append(v);
        v.position = wp4;
        triStream.Append(v);
    }
    else
    {
        // viewer located in negative z half space
        // want face 2, 3, 1, 0
        v.position = wp2;
        triStream.Append(v);
        v.position = wp3;
        triStream.Append(v);
        v.position = wp0;
        triStream.Append(v);
        v.position = wp1;
        triStream.Append(v);
    }
}

