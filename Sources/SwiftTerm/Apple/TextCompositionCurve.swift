//
//  TextCompositionCurve.swift
//
//  The single source of truth for the "text composition curve" (Kitty's
//  text_composition_strategy) shared by both SwiftTerm render paths so glyph
//  weight matches between hardware-acceleration ON (Metal) and OFF (CoreGraphics).
//
//  The Metal grayscale text shader (`Shaders.metal:terminal_text_fragment_gray`)
//  remaps a per-pixel glyph *coverage* value:
//
//      mixFactor = clamp((1 - L_fg + L_bg) * 0.5, 0, 1)
//      adjusted  = clamp(mix(coverage, pow(coverage, 1/gamma), mixFactor) * contrast, 0, 1)
//      out       = (color.rgb * adjusted, color.a * adjusted)        // premultiplied
//
//  so dark-on-light text is dilated toward Apple Terminal's weight while
//  light-on-dark stays near identity. The CoreGraphics path reproduces this by
//  rasterizing coverage offscreen and applying the same curve per pixel (see
//  `TextCompositionCompositor`).
//
//  This file has two parts:
//    • Cross-platform pure math (`CompositionParams`, the curve functions). Both
//      render paths call `params(for:)`, so the curve parameters live in exactly
//      one place — `MetalTerminalRenderer.textCompositionParams` builds its
//      uniform from this too. No view/AppKit state, so the curve is unit-testable.
//    • macOS-only helpers (`luminance(of:)`, `ColorFontDetector`) used by the
//      CoreGraphics compositor; gated because they depend on AppKit.
//

import Foundation
#if os(macOS)
import AppKit
import CoreText
#endif

/// The `(1/gamma, contrast)` pair the curve operates with, mirroring the Metal
/// renderer's `textCompositionParams` uniform.
struct CompositionParams: Equatable {
    /// Reciprocal of the gamma the shader applies (`pow(coverage, gammaInv)`).
    let gammaInv: Float
    /// Coverage multiplier applied after the gamma mix.
    let contrast: Float
}

/// Pure math for the text-composition curve, shared by the Metal and
/// CoreGraphics render paths. Every function mirrors a specific piece of
/// `Shaders.metal` so the two paths agree.
enum TextCompositionCurve {
    /// Maps a `TextCompositionStrategy` to its `(gammaInv, contrast)` pair. This
    /// is the single source of truth for the curve parameters:
    /// `MetalTerminalRenderer.textCompositionParams` builds its `SIMD2<Float>`
    /// uniform from this, and the CoreGraphics path reads it directly.
    /// `.identity` is a no-op `(1, 1)`; `.appleApprox` is Kitty's macOS default
    /// `1.7 / 30` → `(1/1.7, 1.30)`; `.custom(gamma, contrastPercent)` →
    /// `(1/gamma, 1 + contrastPercent/100)`.
    static func params(for strategy: TextCompositionStrategy) -> CompositionParams {
        switch strategy {
        case .identity:
            return CompositionParams(gammaInv: 1, contrast: 1)
        case .appleApprox:
            return CompositionParams(gammaInv: 1.0 / 1.7, contrast: 1.30)
        case .custom(let gamma, let contrastPercent):
            let safeGamma = gamma > 0 ? gamma : 1.0
            // Clamp contrast to >= 0: a contrastPercent below -100 would
            // otherwise yield a negative multiplier (the curve only ever
            // attenuates or amplifies coverage, never inverts it).
            let contrast = max(0, 1.0 + contrastPercent * 0.01)
            return CompositionParams(gammaInv: 1.0 / safeGamma, contrast: contrast)
        }
    }

    /// The shader's per-cell mix term: `1` for dark-on-light (where the gamma
    /// dilation applies fully) and `0` for light-on-dark (near identity).
    /// `fgLum`/`bgLum` are Rec-709 luminances in display gamma (see
    /// `luminance(of:)`). Mirrors `Shaders.metal:terminal_text_fragment_gray`.
    static func mixFactor(fgLum: Float, bgLum: Float) -> Float {
        return min(max((1 - fgLum + bgLum) * 0.5, 0), 1)
    }

    /// The curve itself, applied to a single coverage value in `[0, 1]`:
    /// `clamp(mix(cov, pow(cov, gammaInv), mixFactor) * contrast, 0, 1)`.
    /// For `.identity` params (`gammaInv == 1`, `contrast == 1`) this is the
    /// identity (coverage passes through unchanged).
    static func adjustedCoverage(_ coverage: Float,
                                 mixFactor: Float,
                                 params: CompositionParams) -> Float {
        let curved = coverage + (powf(coverage, params.gammaInv) - coverage) * mixFactor
        let adjusted = curved * params.contrast
        return min(max(adjusted, 0), 1)
    }

    /// Precomputes a 256-entry lookup table mapping an 8-bit coverage byte to its
    /// adjusted 8-bit value, so the per-pixel hot path is a table lookup rather
    /// than a `pow`. `lut[i] == round(adjustedCoverage(i/255, …) * 255)`.
    static func coverageLUT(mixFactor: Float, params: CompositionParams) -> [UInt8] {
        var lut = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            let adjusted = adjustedCoverage(Float(i) / 255.0,
                                            mixFactor: mixFactor,
                                            params: params)
            lut[i] = UInt8((adjusted * 255).rounded())
        }
        return lut
    }

    /// Applies the coverage curve to a rasterized glyph buffer in place,
    /// producing the premultiplied, foreground-tinted output the shader emits.
    ///
    /// The buffer is 8-bit BGRA in `byteOrder32Little | premultipliedFirst`
    /// layout (byte order B, G, R, A — the same layout
    /// `CoreTextGlyphRasterizer` produces). Coverage is read from the red
    /// channel (what the Metal shader samples), the `lut` maps it to the
    /// adjusted alpha, and each pixel is overwritten with
    /// `(fg.b·a, fg.g·a, fg.r·a, fg.a·a)` where `a = lut[coverage]/255` — the
    /// premultiplied form of `Shaders.metal`'s
    /// `(color.rgb * adjusted, color.a * adjusted)`.
    ///
    /// In place is safe: each output pixel depends only on its own input, and
    /// the red coverage byte is read before the pixel's bytes are rewritten.
    static func applyCurve(_ pixels: UnsafeMutablePointer<UInt8>,
                           pixelCount: Int,
                           lut: [UInt8],
                           foreground fg: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) {
        lut.withUnsafeBufferPointer { lutPtr in
            for i in 0..<pixelCount {
                let base = i * 4
                let coverage = pixels[base + 2]           // red channel
                let a = Int(lutPtr[Int(coverage)])
                pixels[base + 0] = premultiply(fg.b, a)   // B
                pixels[base + 1] = premultiply(fg.g, a)   // G
                pixels[base + 2] = premultiply(fg.r, a)   // R
                pixels[base + 3] = premultiply(fg.a, a)   // A
            }
        }
    }

    /// `round(channel * alpha / 255)` with `channel`, `alpha`, result in `0...255`.
    private static func premultiply(_ channel: UInt8, _ alpha255: Int) -> UInt8 {
        return UInt8((Int(channel) * alpha255 + 127) / 255)
    }
}

#if os(macOS)
extension TextCompositionCurve {
    /// Rec-709 luminance of `color` in `[0, 1]`. Treats the sRGB components as
    /// already in display gamma (NOT linearized) so the value agrees with
    /// `MetalTerminalRenderer.luminance(_:)` and the shader's `kRec709` dot —
    /// keeping the two render paths' `mixFactor` in sync.
    static func luminance(of color: NSColor) -> Float {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Float(r) * 0.2126 + Float(g) * 0.7152 + Float(b) * 0.0722
    }
}

/// Detects whether a font renders color (bitmap / `COLR`) glyphs — e.g. emoji —
/// so the CoreGraphics curve can skip them, mirroring the Metal path's separate
/// color-glyph fragment shader. Caches results by font; instantiate one per draw
/// pass (glyph drawing runs single-threaded on the main thread).
struct ColorFontDetector {
    private var cache: [NSFont: Bool] = [:]

    /// Cached `fontHasColorTable(_:)` keyed on `font`.
    mutating func isColorFont(_ font: NSFont) -> Bool {
        if let cached = cache[font] { return cached }
        let result = Self.fontHasColorTable(font as CTFont)
        cache[font] = result
        return result
    }

    /// Whether `font` carries a color-glyph table (`sbix`, `COLR`, or `CBDT`).
    /// Reads only the available-tables list (no table data is copied), so it is
    /// cheap and pure — safe to unit-test directly.
    static func fontHasColorTable(_ font: CTFont) -> Bool {
        guard let tags = CTFontCopyAvailableTables(font, []) else { return false }
        let count = CFArrayGetCount(tags)
        for i in 0..<count {
            // CTFontCopyAvailableTables stores each tag as its raw integer value
            // reinterpreted as a pointer, not a boxed CFNumber — extract the bits.
            let bits = Int(bitPattern: CFArrayGetValueAtIndex(tags, i))
            let tag = CTFontTableTag(truncatingIfNeeded: bits)
            if tag == kCTFontTableSbix || tag == kCTFontTableCOLR || tag == kCTFontTableCBDT {
                return true
            }
        }
        return false
    }
}

// FourCharCode tags for the color-glyph tables, defined from their FourCharCodes
// to stay portable across SDK spellings of the CoreText constants.
private let kCTFontTableSbix: CTFontTableTag = 0x73626978 // 'sbix'
private let kCTFontTableCOLR: CTFontTableTag = 0x434F4C52 // 'COLR'
private let kCTFontTableCBDT: CTFontTableTag = 0x43424454 // 'CBDT'

#endif
