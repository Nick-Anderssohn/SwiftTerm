//
//  TextCompositionCompositor.swift
//
//  Stateful glue that applies the Metal text-composition curve
//  (`TextCompositionCurve`) on the CoreGraphics draw path. The pure curve math
//  lives in `TextCompositionCurve`; this type owns the rendering machinery: an
//  offscreen rasterization of each glyph run (mirroring the Metal atlas
//  rasterizer), a per-pixel LUT application, and the composite back into the
//  view's context.
//
//  Lifetime: create one per `drawTerminalContents` pass. Within a pass it caches
//  one LUT per quantized `mixFactor` bucket and reuses a grow-only scratch
//  buffer across runs — that within-frame reuse is where the performance comes
//  from. Recreating it each frame costs only a few LUT rebuilds (256 `pow` each,
//  a handful of buckets) and one buffer grow, so no view-level state is needed.
//

#if os(macOS)
import Foundation
import AppKit
import CoreText

final class TextCompositionCompositor {
    /// Number of quantized `mixFactor` buckets. Coverage adjustment varies
    /// smoothly with `mixFactor`, so quantizing to 1/32 steps is visually
    /// indistinguishable while bounding the LUT cache to 33 entries.
    private static let bucketCount = 33

    private let params: CompositionParams
    private let scale: CGFloat
    private let fontSmoothing: Bool

    /// LUT per `mixFactor` bucket; built lazily.
    private var lutCache: [Int: [UInt8]] = [:]
    /// Grow-only BGRA scratch backing the offscreen render, reused across runs.
    private var scratch: [UInt8] = []

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
        | CGImageAlphaInfo.premultipliedFirst.rawValue

    /// - Parameters:
    ///   - params: the active curve parameters (from
    ///     `TextCompositionCurve.params(for:)`), constant for this pass.
    ///   - scale: the view's backing scale (e.g. 2 on Retina) so coverage is
    ///     rasterized at device resolution.
    ///   - fontSmoothing: mirror the view's font-smoothing setting so coverage
    ///     matches the Metal atlas rasterization.
    init(params: CompositionParams, scale: CGFloat, fontSmoothing: Bool) {
        self.params = params
        self.scale = max(1, scale)
        self.fontSmoothing = fontSmoothing
    }

    /// Draws a glyph run with the composition curve applied: rasterizes coverage
    /// offscreen, remaps it through the curve, tints by `foreground`, and
    /// composites over `context`. Falls back to a plain `CTFontDrawGlyphs` (so
    /// text always renders) when the run has no drawable bounds or an offscreen
    /// context can't be created.
    ///
    /// `positions` are in `context`'s coordinate space (the same array a direct
    /// `CTFontDrawGlyphs` would use). The fallback path is self-contained — it
    /// sets the fill color itself, so the caller need not pre-set it.
    func draw(glyphs: [CGGlyph],
              positions: [CGPoint],
              font: CTFont,
              foreground: NSColor,
              background: NSColor,
              in context: CGContext) {
        let count = glyphs.count
        guard count > 0, positions.count == count else { return }

        guard let rawBounds = runBounds(glyphs: glyphs, positions: positions, font: font) else {
            fallbackDraw(font, glyphs, positions, foreground: foreground, in: context)
            return
        }

        // Snap to the device-pixel grid so the offscreen composites 1:1 onto the
        // framebuffer. Without this the image lands at a fractional pixel and CG
        // resamples it — softening edges, fattening dark-on-light stems, and
        // dimming light-on-dark text. Glyph subpixel positions are preserved
        // inside the offscreen (only the bitmap origin is aligned).
        let bounds = snapToDevicePixels(rawBounds)
        let pxW = Int((bounds.width * scale).rounded())
        let pxH = Int((bounds.height * scale).rounded())
        guard pxW > 0, pxH > 0 else {
            fallbackDraw(font, glyphs, positions, foreground: foreground, in: context)
            return
        }

        let lut = lookupTable(foreground: foreground, background: background)
        let fg = Self.components(of: foreground)

        let bytesPerRow = pxW * 4
        let needed = bytesPerRow * pxH
        if scratch.count < needed {
            scratch = [UInt8](repeating: 0, count: needed)
        }

        let image: CGImage? = scratch.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress else { return nil }
            memset(base, 0, needed)
            guard let ctx = CGContext(data: base,
                                      width: pxW,
                                      height: pxH,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: Self.colorSpace,
                                      bitmapInfo: Self.bitmapInfo) else {
                return nil
            }
            configure(ctx)
            // Map a main-context point p to the device pixel (p - origin)·scale.
            // Both contexts are y-up, so no flip is needed.
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

            var pos = positions
            CTFontDrawGlyphs(font, glyphs, &pos, count, ctx)

            TextCompositionCurve.applyCurve(base.assumingMemoryBound(to: UInt8.self),
                                            pixelCount: pxW * pxH,
                                            lut: lut,
                                            foreground: fg)
            return ctx.makeImage()
        }

        guard let image else {
            fallbackDraw(font, glyphs, positions, foreground: foreground, in: context)
            return
        }

        // `bounds` is device-grid-aligned, so it maps 1:1 to the image's pxW×pxH
        // device pixels. Disable interpolation for a clean blit (no softening).
        context.saveGState()
        context.interpolationQuality = .none
        context.draw(image, in: bounds)
        context.restoreGState()
    }

    // MARK: - Internals

    /// Draws the run directly (no curve) with `foreground` as the fill. Used when
    /// the offscreen path can't run (no drawable bounds, or context creation
    /// fails) so text always renders. Self-contained: sets the fill itself.
    private func fallbackDraw(_ font: CTFont,
                              _ glyphs: [CGGlyph],
                              _ positions: [CGPoint],
                              foreground: NSColor,
                              in context: CGContext) {
        context.setFillColor(foreground.cgColor)
        var pos = positions
        CTFontDrawGlyphs(font, glyphs, &pos, glyphs.count, context)
    }

    /// Tight pixel bounds of the run in `context` coordinates: the union of each
    /// glyph's bounding rect offset by its position, padded for antialiasing
    /// spread. `nil` when nothing is drawable (e.g. all whitespace).
    private func runBounds(glyphs: [CGGlyph], positions: [CGPoint], font: CTFont) -> CGRect? {
        var rects = [CGRect](repeating: .zero, count: glyphs.count)
        var mutableGlyphs = glyphs
        CTFontGetBoundingRectsForGlyphs(font, .default, &mutableGlyphs, &rects, glyphs.count)

        var bounds = CGRect.null
        for i in 0..<glyphs.count {
            let r = rects[i]
            if r.isNull || r.isEmpty { continue }
            bounds = bounds.union(r.offsetBy(dx: positions[i].x, dy: positions[i].y))
        }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
        // Pad to capture the antialiasing ramp at glyph edges.
        return bounds.insetBy(dx: -2, dy: -2)
    }

    /// Expands `rect` outward to the nearest device-pixel boundaries so the
    /// resulting offscreen has an integer device-pixel size and an origin that
    /// composites 1:1 onto the framebuffer (no resampling). `internal` for tests.
    func snapToDevicePixels(_ rect: CGRect) -> CGRect {
        let minX = (rect.minX * scale).rounded(.down) / scale
        let minY = (rect.minY * scale).rounded(.down) / scale
        let maxX = (rect.maxX * scale).rounded(.up) / scale
        let maxY = (rect.maxY * scale).rounded(.up) / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Quantizes a `mixFactor` in `[0, 1]` to a LUT bucket index in
    /// `0..<bucketCount`. Quantizing keeps the LUT cache bounded; 1/32 steps are
    /// visually indistinguishable. `internal` for tests.
    static func bucket(forMixFactor mix: Float) -> Int {
        return Int((min(max(mix, 0), 1) * Float(bucketCount - 1)).rounded())
    }

    /// LUT for the run's quantized `mixFactor` bucket, built lazily and cached.
    private func lookupTable(foreground: NSColor, background: NSColor) -> [UInt8] {
        let mix = TextCompositionCurve.mixFactor(
            fgLum: TextCompositionCurve.luminance(of: foreground),
            bgLum: TextCompositionCurve.luminance(of: background))
        let bucket = Self.bucket(forMixFactor: mix)
        if let cached = lutCache[bucket] { return cached }
        let repMix = Float(bucket) / Float(Self.bucketCount - 1)
        let lut = TextCompositionCurve.coverageLUT(mixFactor: repMix, params: params)
        lutCache[bucket] = lut
        return lut
    }

    /// Mirrors `CoreTextGlyphRasterizer`'s rasterization setup so coverage values
    /// match the Metal atlas.
    private func configure(_ ctx: CGContext) {
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsFontSubpixelQuantization(false)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.setAllowsFontSmoothing(fontSmoothing)
        ctx.setShouldSmoothFonts(fontSmoothing)
    }

    /// 8-bit sRGB components of `color`, clamped to gamut. `internal` for tests.
    static func components(of color: NSColor) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard let c = color.usingColorSpace(.sRGB) else { return (255, 255, 255, 255) }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        return (byte(r), byte(g), byte(b), byte(a))
    }
}
#endif
