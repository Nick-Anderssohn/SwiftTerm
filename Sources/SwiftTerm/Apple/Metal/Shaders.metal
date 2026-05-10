#include <metal_stdlib>
using namespace metal;

struct GlyphVertex {
    float2 position;
    float2 texCoord;
    float4 color;
    float  bgLuminance;
};

struct TextCell {
    float2 position;
    float2 size;
    float2 texOrigin;
    float2 texSize;
    float4 color;
    float  bgLuminance;
};

struct ColorCell {
    float2 position;
    float2 size;
    float4 color;
};

struct GlyphOut {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
    float  bgLuminance;
};

constant float2 kQuadCorners[6] = {
    float2(0.0, 0.0),
    float2(1.0, 0.0),
    float2(0.0, 1.0),
    float2(1.0, 0.0),
    float2(1.0, 1.0),
    float2(0.0, 1.0),
};

// Rec. 709 luminance weights, used for the bg/fg luminance terms in
// the text composition curve so the curve agrees with the CPU side
// (MetalTerminalRenderer.luminance(_:)).
constant float3 kRec709 = float3(0.2126, 0.7152, 0.0722);

// scrollOffset (in pixels, y-up): added to vertex positions before the
// NDC transform so the renderer can pan the rendered content without
// rebuilding any vertex data. Used to apply yDisp + sub-line smooth
// scrolling on the macOS path; iOS binds zero (UIScrollView positions
// the MTKView itself).
vertex GlyphOut terminal_text_vertex(uint vid [[vertex_id]],
                                     const device GlyphVertex *vertices [[buffer(0)]],
                                     constant float2 &viewport [[buffer(1)]],
                                     constant float2 &scrollOffset [[buffer(2)]]) {
    GlyphVertex v = vertices[vid];
    float2 position = v.position + scrollOffset;
    float2 ndc = float2((position.x / viewport.x) * 2.0 - 1.0,
                        (position.y / viewport.y) * 2.0 - 1.0);
    GlyphOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = v.texCoord;
    out.color = v.color;
    out.bgLuminance = v.bgLuminance;
    return out;
}

vertex GlyphOut terminal_cell_text_vertex(uint vid [[vertex_id]],
                                          const device TextCell *cells [[buffer(0)]],
                                          constant float2 &viewport [[buffer(1)]],
                                          constant float2 &scrollOffset [[buffer(2)]]) {
    uint cellIndex = vid / 6;
    uint cornerIndex = vid % 6;
    TextCell cell = cells[cellIndex];
    float2 corner = kQuadCorners[cornerIndex];
    float2 position = cell.position + cell.size * corner + scrollOffset;
    float2 ndc = float2((position.x / viewport.x) * 2.0 - 1.0,
                        (position.y / viewport.y) * 2.0 - 1.0);
    GlyphOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = cell.texOrigin + cell.texSize * corner;
    out.color = cell.color;
    out.bgLuminance = cell.bgLuminance;
    return out;
}

fragment float4 terminal_text_fragment(GlyphOut in [[stage_in]],
                                       texture2d<float> atlas [[texture(0)]],
                                       sampler samp [[sampler(0)]]) {
    float4 tex = atlas.sample(samp, in.texCoord);
    return float4(tex.rgb * in.color.rgb, tex.a * in.color.a);
}

// Grayscale glyph fragment: applies Kitty's text composition curve
// (`text_composition_strategy 1.7 30` on macOS by default) so that
// dark-on-light text reads close to Apple Terminal's heavy stem-darkening
// while light-on-dark stays nearly identity. textCompositionParams =
// (1/gamma, contrastMultiplier); buffer 1 is bound by the renderer once
// per frame from `TerminalOptions.textCompositionStrategy`.
fragment float4 terminal_text_fragment_gray(GlyphOut in [[stage_in]],
                                            texture2d<float> atlas [[texture(0)]],
                                            sampler samp [[sampler(0)]],
                                            constant float2 &textCompositionParams [[buffer(1)]]) {
    float coverage = atlas.sample(samp, in.texCoord).r;
    float fgLum = dot(in.color.rgb, kRec709);
    float bgLum = in.bgLuminance;
    float mixFactor = (1.0 - fgLum + bgLum) * 0.5;
    float gammaInv = textCompositionParams.x;
    float contrast = textCompositionParams.y;
    float adjusted = mix(coverage, pow(coverage, gammaInv), mixFactor) * contrast;
    adjusted = clamp(adjusted, 0.0, 1.0);
    return float4(in.color.rgb * adjusted, in.color.a * adjusted);
}

struct ColorVertex {
    float2 position;
    float4 color;
};

struct ColorOut {
    float4 position [[position]];
    float4 color;
};

vertex ColorOut terminal_color_vertex(uint vid [[vertex_id]],
                                      const device ColorVertex *vertices [[buffer(0)]],
                                      constant float2 &viewport [[buffer(1)]],
                                      constant float2 &scrollOffset [[buffer(2)]]) {
    ColorVertex v = vertices[vid];
    float2 position = v.position + scrollOffset;
    float2 ndc = float2((position.x / viewport.x) * 2.0 - 1.0,
                        (position.y / viewport.y) * 2.0 - 1.0);
    ColorOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = v.color;
    return out;
}

vertex ColorOut terminal_cell_color_vertex(uint vid [[vertex_id]],
                                           const device ColorCell *cells [[buffer(0)]],
                                           constant float2 &viewport [[buffer(1)]],
                                           constant float2 &scrollOffset [[buffer(2)]]) {
    uint cellIndex = vid / 6;
    uint cornerIndex = vid % 6;
    ColorCell cell = cells[cellIndex];
    float2 corner = kQuadCorners[cornerIndex];
    float2 position = cell.position + cell.size * corner + scrollOffset;
    float2 ndc = float2((position.x / viewport.x) * 2.0 - 1.0,
                        (position.y / viewport.y) * 2.0 - 1.0);
    ColorOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = cell.color;
    return out;
}

fragment float4 terminal_color_fragment(ColorOut in [[stage_in]]) {
    return in.color;
}
