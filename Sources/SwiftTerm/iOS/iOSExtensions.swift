//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 6/29/21.
//
#if os(iOS) || os(visionOS)
import Foundation
import UIKit

extension UIColor {
    func getTerminalColor () -> Color {
        var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
        self.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        
        func clamp (_ v: CGFloat) -> CGFloat {
            return min (max (v, 0.0), 1.0)
        }
        return Color(red: UInt16 (clamp (red)*65535), green: UInt16(clamp (green)*65535), blue: UInt16(clamp (blue)*65535))
    }

    func inverseColor() -> UIColor {
        var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
        self.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return UIColor (red: 1.0 - red, green: 1.0 - green, blue: 1.0 - blue, alpha: alpha)
    }

    /// Returns a dimmed version of the color (SGR 2 faint/dim attribute) by
    /// blending 50 % toward `background`. The result is fully opaque so that
    /// adjacent box-drawing characters tile without visible seams.
    func dimmedColor (towards background: UIColor) -> UIColor {
        var fRed: CGFloat = 0.0, fGreen: CGFloat = 0.0, fBlue: CGFloat = 0.0, fAlpha: CGFloat = 1.0
        self.getRed(&fRed, green: &fGreen, blue: &fBlue, alpha: &fAlpha)
        var bRed: CGFloat = 0.0, bGreen: CGFloat = 0.0, bBlue: CGFloat = 0.0, bAlpha: CGFloat = 1.0
        background.getRed(&bRed, green: &bGreen, blue: &bBlue, alpha: &bAlpha)
        return UIColor (red: (fRed + bRed) * 0.5,
                        green: (fGreen + bGreen) * 0.5,
                        blue: (fBlue + bBlue) * 0.5,
                        alpha: fAlpha)
    }

    /// Euclidean distance between two colors in sRGB 0..255 space. Used
    /// by the subtle-background policy to decide when a cell tint is
    /// close enough to the native background to flatten.
    func srgbDistance (to other: UIColor) -> CGFloat {
        var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 1
        self.getRed(&lr, green: &lg, blue: &lb, alpha: &la)
        var rr: CGFloat = 0, rg: CGFloat = 0, rb: CGFloat = 0, ra: CGFloat = 1
        other.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)
        let dr = (lr - rr) * 255
        let dg = (lg - rg) * 255
        let db = (lb - rb) * 255
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    static func make (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> TTColor
    {

        return UIColor(red: red,
                       green: green,
                       blue: blue,
                       alpha: 1.0)
    }
  
    static func make (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) -> TTColor
    {
        return UIColor(hue: hue,
                       saturation: saturation,
                       brightness: brightness,
                       alpha: alpha)
    }
    
    static func make (color: Color) -> UIColor
    {
        UIColor (red: CGFloat (color.red) / 65535.0,
                 green: CGFloat (color.green) / 65535.0,
                 blue: CGFloat (color.blue) / 65535.0,
                 alpha: 1.0)
    }
    
    static func transparent () -> UIColor {
        return UIColor.clear
    }
}

extension UIImage {
    public convenience init (cgImage: CGImage, size: CGSize) {
        self.init (cgImage: cgImage, scale: -1, orientation: .up)
        //self.init (cgImage: cgImage)
    }
}

extension NSAttributedString {
    func fuzzyHasSelectionBackground (_ ret: Bool) -> Bool
    {
        return ret
    }
}
#endif

