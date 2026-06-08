//
//  TextCompositionCompositorTests.swift
//
//  Covers the framebuffer-free logic in `TextCompositionCompositor` — the parts
//  that don't need a real CGContext/glyph rasterization: device-pixel snapping,
//  mixFactor→bucket quantization, and sRGB component extraction. The actual
//  offscreen render/composite path is exercised visually, not here.
//

#if os(macOS)
import Foundation
import Testing
import AppKit

@testable import SwiftTerm

@Suite("CoreGraphics text-composition compositor")
struct TextCompositionCompositorTests {

    private func makeCompositor(scale: CGFloat) -> TextCompositionCompositor {
        TextCompositionCompositor(
            params: CompositionParams(gammaInv: 1, contrast: 1),
            scale: scale,
            fontSmoothing: true)
    }

    // MARK: snapToDevicePixels

    @Test("an already-aligned rect is unchanged at scale 1")
    func snapAlignedScale1() {
        let snapped = makeCompositor(scale: 1).snapToDevicePixels(CGRect(x: 10, y: 20, width: 5, height: 4))
        #expect(snapped == CGRect(x: 10, y: 20, width: 5, height: 4))
    }

    @Test("a sub-pixel rect expands outward to whole pixels at scale 1")
    func snapSubpixelScale1() {
        let snapped = makeCompositor(scale: 1).snapToDevicePixels(CGRect(x: 10.3, y: 20.7, width: 5.4, height: 4.1))
        // minX floor 10.3→10, minY floor 20.7→20, maxX ceil 15.7→16, maxY ceil 24.8→25.
        #expect(snapped == CGRect(x: 10, y: 20, width: 6, height: 5))
    }

    @Test("snapping aligns to half-points at scale 2 and yields integer device pixels")
    func snapScale2() {
        let scale: CGFloat = 2
        let snapped = makeCompositor(scale: scale).snapToDevicePixels(CGRect(x: 10.3, y: 20, width: 5, height: 4))
        // Every edge × scale must be integral (the whole point of snapping).
        for v in [snapped.minX, snapped.minY, snapped.maxX, snapped.maxY] {
            #expect((v * scale).truncatingRemainder(dividingBy: 1) == 0)
        }
        #expect((snapped.width * scale).rounded() == snapped.width * scale)
    }

    // MARK: bucket quantization

    @Test("bucket maps the mixFactor range to 0...32")
    func bucketRange() {
        #expect(TextCompositionCompositor.bucket(forMixFactor: 0) == 0)
        #expect(TextCompositionCompositor.bucket(forMixFactor: 1) == 32)
        #expect(TextCompositionCompositor.bucket(forMixFactor: 0.5) == 16)
    }

    @Test("nearby mixFactors quantize to the same bucket")
    func bucketQuantizes() {
        // 0.50·32 = 16.0, 0.51·32 = 16.32 — both round to bucket 16.
        #expect(TextCompositionCompositor.bucket(forMixFactor: 0.50)
                == TextCompositionCompositor.bucket(forMixFactor: 0.51))
    }

    @Test("bucket clamps out-of-range mixFactors")
    func bucketClamps() {
        #expect(TextCompositionCompositor.bucket(forMixFactor: -1) == 0)
        #expect(TextCompositionCompositor.bucket(forMixFactor: 2) == 32)
    }

    // MARK: components

    @Test("components extracts 8-bit sRGB channels")
    func componentsInGamut() {
        let c = NSColor(srgbRed: 200 / 255.0, green: 100 / 255.0, blue: 50 / 255.0, alpha: 1)
        let (r, g, b, a) = TextCompositionCompositor.components(of: c)
        #expect((r, g, b, a) == (200, 100, 50, 255))
        #expect(TextCompositionCompositor.components(of: .white) == (255, 255, 255, 255))
        #expect(TextCompositionCompositor.components(of: .black) == (0, 0, 0, 255))
    }

    @Test("components clamps an out-of-gamut (wide-gamut) color without overflow")
    func componentsOutOfGamut() {
        // Display P3 pure red lies outside sRGB; conversion can produce
        // out-of-[0,1] channels that must clamp into 0...255, not wrap.
        let p3Red = NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)
        let (r, _, _, a) = TextCompositionCompositor.components(of: p3Red)
        #expect(a == 255)
        #expect(r >= 200) // P3 red maps to a near-max sRGB red, clamped to <= 255
    }
}
#endif
