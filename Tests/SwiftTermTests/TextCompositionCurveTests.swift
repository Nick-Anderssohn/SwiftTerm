//
//  TextCompositionCurveTests.swift
//
//  Pins the contract of the CoreGraphics port of the Metal text-composition
//  curve (`TextCompositionCurve` + `ColorFontDetector`). These are the pure
//  inputs to the software glyph path: the `(1/γ, contrast)` param mapping, the
//  per-cell `mixFactor`, the coverage curve and its LUT, the premultiplied
//  buffer transform, a Rec-709 luminance that must agree with the Metal shader,
//  and the color-font detector that excludes emoji from the curve.
//

#if os(macOS)
import Foundation
import Testing
import AppKit
import CoreText

@testable import SwiftTerm

@Suite("CoreGraphics text-composition curve")
struct TextCompositionCurveTests {

    private let appleApprox = TextCompositionCurve.params(for: .appleApprox)
    private let identity = TextCompositionCurve.params(for: .identity)

    // MARK: params

    @Test("params map each strategy to (1/γ, contrast)")
    func paramsMapping() {
        #expect(identity == CompositionParams(gammaInv: 1, contrast: 1))

        let apple = TextCompositionCurve.params(for: .appleApprox)
        #expect(abs(apple.gammaInv - Float(1.0 / 1.7)) < 1e-6)
        #expect(abs(apple.contrast - 1.30) < 1e-6)

        let custom = TextCompositionCurve.params(for: .custom(gamma: 2, contrastPercent: 50))
        #expect(abs(custom.gammaInv - 0.5) < 1e-6)
        #expect(abs(custom.contrast - 1.5) < 1e-6)
    }

    @Test("non-positive custom gamma falls back to a no-op gamma")
    func customGammaGuard() {
        let custom = TextCompositionCurve.params(for: .custom(gamma: 0, contrastPercent: 0))
        #expect(custom.gammaInv == 1)
    }

    // MARK: mixFactor

    @Test("mixFactor is 1 for dark-on-light, 0 for light-on-dark, 0.5 for equal")
    func mixFactorPolarities() {
        #expect(TextCompositionCurve.mixFactor(fgLum: 0, bgLum: 1) == 1)
        #expect(TextCompositionCurve.mixFactor(fgLum: 1, bgLum: 0) == 0)
        #expect(TextCompositionCurve.mixFactor(fgLum: 0.5, bgLum: 0.5) == 0.5)
    }

    @Test("mixFactor clamps out-of-range luminances")
    func mixFactorClamps() {
        #expect(TextCompositionCurve.mixFactor(fgLum: -1, bgLum: 5) == 1)
        #expect(TextCompositionCurve.mixFactor(fgLum: 5, bgLum: -1) == 0)
    }

    // MARK: adjustedCoverage

    @Test("identity params pass coverage through unchanged")
    func adjustedIdentityPassthrough() {
        for c in stride(from: Float(0), through: 1, by: 0.1) {
            let out = TextCompositionCurve.adjustedCoverage(c, mixFactor: 0.7, params: identity)
            #expect(abs(out - c) < 1e-6)
        }
    }

    @Test("adjustedCoverage matches the shader formula at a known point")
    func adjustedKnownPoint() {
        // cov=0.5, gammaInv=1/1.7, contrast=1.3, full dilation:
        // pow(0.5, 0.5882) ≈ 0.6653 → ×1.3 ≈ 0.8649.
        let out = TextCompositionCurve.adjustedCoverage(0.5, mixFactor: 1, params: appleApprox)
        #expect(abs(out - 0.8649) < 0.005)
    }

    @Test("adjustedCoverage clamps to [0, 1]")
    func adjustedClamps() {
        #expect(TextCompositionCurve.adjustedCoverage(1, mixFactor: 1, params: appleApprox) == 1)
        #expect(TextCompositionCurve.adjustedCoverage(0, mixFactor: 1, params: appleApprox) == 0)
    }

    @Test("adjustedCoverage is monotonic in coverage")
    func adjustedMonotonic() {
        var previous: Float = -1
        for i in 0...255 {
            let out = TextCompositionCurve.adjustedCoverage(Float(i) / 255,
                                                            mixFactor: 1, params: appleApprox)
            #expect(out >= previous)
            previous = out
        }
    }

    // MARK: coverageLUT

    @Test("LUT entries equal the rounded adjustedCoverage")
    func lutMatchesCurve() {
        let lut = TextCompositionCurve.coverageLUT(mixFactor: 1, params: appleApprox)
        #expect(lut.count == 256)
        for i in 0..<256 {
            let expected = UInt8((TextCompositionCurve.adjustedCoverage(
                Float(i) / 255, mixFactor: 1, params: appleApprox) * 255).rounded())
            #expect(lut[i] == expected)
        }
    }

    @Test("identity LUT is the pass-through table")
    func lutIdentity() {
        let lut = TextCompositionCurve.coverageLUT(mixFactor: 0.3, params: identity)
        for i in 0..<256 {
            #expect(lut[i] == UInt8(i))
        }
    }

    // MARK: applyCurve

    @Test("applyCurve writes premultiplied, foreground-tinted pixels")
    func applyCurvePremultiplied() {
        // Identity LUT so adjusted == coverage; isolate the tint/premultiply math.
        let lut = TextCompositionCurve.coverageLUT(mixFactor: 0, params: identity)
        let fg: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (200, 100, 50, 255)

        // Three BGRA pixels (B,G,R,A) with coverage in the red channel: 255, 0, 128.
        var pixels: [UInt8] = [
            0, 0, 255, 0,   // full coverage
            0, 0, 0, 0,     // zero coverage
            0, 0, 128, 0,   // half coverage
        ]
        pixels.withUnsafeMutableBufferPointer { buf in
            TextCompositionCurve.applyCurve(buf.baseAddress!, pixelCount: 3, lut: lut, foreground: fg)
        }

        // Pixel 0: a=255 → exact fg, premultiplied (B,G,R,A).
        #expect(Array(pixels[0..<4]) == [50, 100, 200, 255])
        // Pixel 1: a=0 → fully transparent.
        #expect(Array(pixels[4..<8]) == [0, 0, 0, 0])
        // Pixel 2: a=128 → round(channel·128/255).
        #expect(Array(pixels[8..<12]) == [25, 50, 100, 128])
    }

    @Test("custom contrast clamps at 0 for contrastPercent <= -100")
    func customContrastClamps() {
        #expect(TextCompositionCurve.params(for: .custom(gamma: 1, contrastPercent: -100)).contrast == 0)
        #expect(TextCompositionCurve.params(for: .custom(gamma: 1, contrastPercent: -200)).contrast == 0)
    }

    @Test("at mixFactor 0 the gamma term drops out and contrast can saturate")
    func adjustedMixZeroContrastSaturates() {
        // mix=0 → curved == coverage; appleApprox contrast 1.30 → 0.8*1.30 = 1.04 → clamps to 1.
        #expect(TextCompositionCurve.adjustedCoverage(0.8, mixFactor: 0, params: appleApprox) == 1)
        // A low coverage stays linear: 0.5 * 1.30 = 0.65 (no clamp).
        let low = TextCompositionCurve.adjustedCoverage(0.5, mixFactor: 0, params: appleApprox)
        #expect(abs(low - 0.65) < 1e-5)
    }

    @Test("LUT at an intermediate mixFactor matches adjustedCoverage per entry")
    func lutIntermediateMix() {
        let lut = TextCompositionCurve.coverageLUT(mixFactor: 0.5, params: appleApprox)
        for i in stride(from: 0, through: 255, by: 17) {
            let expected = UInt8((TextCompositionCurve.adjustedCoverage(
                Float(i) / 255, mixFactor: 0.5, params: appleApprox) * 255).rounded())
            #expect(lut[i] == expected)
        }
    }

    @Test("applyCurve remaps coverage through a non-identity LUT before tinting")
    func applyCurveNonIdentityLUT() {
        let lut = TextCompositionCurve.coverageLUT(mixFactor: 1, params: appleApprox)
        let fg: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (255, 255, 255, 255)
        var pixels: [UInt8] = [0, 0, 128, 0] // coverage 128 in red
        pixels.withUnsafeMutableBufferPointer {
            TextCompositionCurve.applyCurve($0.baseAddress!, pixelCount: 1, lut: lut, foreground: fg)
        }
        let expectedA = lut[128]
        // White fg → every channel equals the adjusted alpha (premultiplied white).
        #expect(Array(pixels[0..<4]) == [expectedA, expectedA, expectedA, expectedA])
        // Proves the LUT actually remapped the coverage (didn't pass 128 through).
        #expect(expectedA != 128)
    }

    @Test("applyCurve honors a semi-transparent foreground alpha")
    func applyCurveSemiTransparentForeground() {
        let lut = TextCompositionCurve.coverageLUT(mixFactor: 0, params: identity) // adjusted == coverage
        let fg: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (200, 100, 50, 128)
        var pixels: [UInt8] = [
            0, 0, 255, 0, // full coverage  → a=255
            0, 0, 128, 0, // half coverage  → a=128
        ]
        pixels.withUnsafeMutableBufferPointer {
            TextCompositionCurve.applyCurve($0.baseAddress!, pixelCount: 2, lut: lut, foreground: fg)
        }
        // a=255: premultiply(channel,255)=channel; alpha = premultiply(128,255)=128.
        #expect(Array(pixels[0..<4]) == [50, 100, 200, 128])
        // a=128: premultiply(channel,128) and alpha = premultiply(128,128)=64.
        #expect(Array(pixels[4..<8]) == [25, 50, 100, 64])
    }

    // MARK: luminance

    @Test("luminance matches the Rec-709 weights")
    func luminanceRec709() {
        #expect(abs(TextCompositionCurve.luminance(of: .white) - 1) < 1e-3)
        #expect(abs(TextCompositionCurve.luminance(of: .black) - 0) < 1e-3)
        #expect(abs(TextCompositionCurve.luminance(of: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)) - 0.2126) < 1e-3)
        #expect(abs(TextCompositionCurve.luminance(of: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)) - 0.7152) < 1e-3)
        #expect(abs(TextCompositionCurve.luminance(of: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)) - 0.0722) < 1e-3)
    }

    // MARK: ColorFontDetector

    @Test("a text font is not a color font")
    func textFontIsNotColor() {
        let menlo = NSFont(name: "Menlo", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        #expect(ColorFontDetector.fontHasColorTable(menlo as CTFont) == false)
    }

    @Test("the emoji font is a color font")
    func emojiFontIsColor() throws {
        let emoji = try #require(NSFont(name: "Apple Color Emoji", size: 12))
        #expect(ColorFontDetector.fontHasColorTable(emoji as CTFont) == true)
    }

    @Test("isColorFont caches and agrees with the uncached check")
    func detectorCacheAgrees() throws {
        var detector = ColorFontDetector()
        let menlo = NSFont(name: "Menlo", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let emoji = try #require(NSFont(name: "Apple Color Emoji", size: 12))
        #expect(detector.isColorFont(menlo) == false)
        #expect(detector.isColorFont(menlo) == false)
        #expect(detector.isColorFont(emoji) == true)
        #expect(detector.isColorFont(emoji) == true)
    }
}
#endif
