import CoreText
import SwiftUI
import UIKit

/// Single source of truth for the rolling-script typeface.
///
/// The web reader locks the prompter text to Pretendard Variable at
/// weight 500, letter-spacing -0.015em and font-feature-settings
/// `"kern" 1, "palt" 1`. A variable font loaded by name defaults to its
/// regular (400) axis value and ships no proportional-Hangul feature, so
/// both have to be applied explicitly here for the native app to match.
enum PrompterFont {
    /// OpenType `wght` axis identifier.
    private static let weightAxis = 0x77676874  // 'wght'
    private static let targetWeight = 500.0

    static func uiFont(size: CGFloat) -> UIFont {
        guard let base = UIFont(name: "Pretendard Variable", size: size) else {
            return UIFont.systemFont(ofSize: size, weight: .medium)
        }
        let descriptor = base.fontDescriptor.addingAttributes([
            kCTFontVariationAttribute as UIFontDescriptor.AttributeName: [
                weightAxis: targetWeight
            ],
            kCTFontFeatureSettingsAttribute as UIFontDescriptor.AttributeName: [
                [
                    kCTFontOpenTypeFeatureTag as UIFontDescriptor.FeatureKey: "palt",
                    kCTFontOpenTypeFeatureValue as UIFontDescriptor.FeatureKey: 1,
                ],
                [
                    kCTFontOpenTypeFeatureTag as UIFontDescriptor.FeatureKey: "kern",
                    kCTFontOpenTypeFeatureValue as UIFontDescriptor.FeatureKey: 1,
                ],
            ],
        ])
        return UIFont(descriptor: descriptor, size: size)
    }

    static func font(size: CGFloat) -> Font {
        Font(uiFont(size: size) as CTFont)
    }

    /// CSS `-0.015em` expressed in points.
    static func tracking(size: CGFloat) -> CGFloat {
        size * -0.015
    }

    static func lineHeight(size: CGFloat) -> CGFloat {
        uiFont(size: size).lineHeight
    }
}
