
struct GSOutput
{
    float4 position : SV_Position;
    float4 color : TexCoord0;
};

//[RootSignature(ModelViewer_RootSig)]
float3 main(GSOutput vsOutput) : SV_Target0
{
    return vsOutput.color.xyz;
}