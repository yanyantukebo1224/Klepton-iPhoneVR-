#include <metal_stdlib>
using namespace metal;

struct IQuestVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex IQuestVertexOut iquest_stereo_vertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    constexpr float2 coordinates[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    IQuestVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    // GLES eye textures are bottom-left-origin; Metal display textures are top-left.
    out.uv = float2(coordinates[vertexID].x, 1.0 - coordinates[vertexID].y);
    return out;
}

fragment float4 iquest_stereo_fragment(IQuestVertexOut in [[stage_in]],
                                       texture2d<float> eyeTexture [[texture(0)]],
                                       sampler eyeSampler [[sampler(0)]]) {
    return eyeTexture.sample(eyeSampler, in.uv);
}
