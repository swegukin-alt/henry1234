import SwiftUI
import UIKit

/// The script itself. Words are laid out once; the only thing that moves every
/// frame is the offset applied by the caller, which keeps scrolling cheap.
struct ScriptText: View {
    let body_: String
    let fontSize: Double
    let lineHeight: Double
    let highlightIndex: Int?

    var body: some View {
        Text(attributed)
            .font(.custom("Pretendard Variable", size: fontSize).weight(.medium))
            // CSS line-height is an absolute line box. SwiftUI lineSpacing is
            // extra space after the font's native line box, so compensate for
            // Pretendard's real metrics to reproduce the web app's 1.5 value.
            .lineSpacing(max(0, fontSize * lineHeight - nativeFontLineHeight))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Without this SwiftUI proposes the viewport height to Text and
            // silently clips the tail of long scripts.
            .fixedSize(horizontal: false, vertical: true)
    }

    private var nativeFontLineHeight: CGFloat {
        UIFont(name: "Pretendard Variable", size: fontSize)?.lineHeight
            ?? UIFont.systemFont(ofSize: fontSize, weight: .medium).lineHeight
    }

    private var attributed: AttributedString {
        var text = AttributedString(body_)
        text.foregroundColor = Color.white
        guard let highlightIndex else { return text }
        let words = ScriptText.wordRanges(in: body_)
        guard highlightIndex >= 0, highlightIndex < words.count else { return text }
        let range = words[highlightIndex]
        if let lower = AttributedString.Index(range.lowerBound, within: text),
           let upper = AttributedString.Index(range.upperBound, within: text) {
            // Match the web reader: text remains white and the current word
            // receives only a faint white wash, never a blue text color.
            text[lower..<upper].foregroundColor = Color.white
            text[lower..<upper].backgroundColor = Color.white.opacity(0.09)
        }
        return text
    }

    /// Word ranges, Korean-safe: splits on whitespace only, so a word is never
    /// broken apart.
    static func wordRanges(in string: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = string.startIndex
        while index < string.endIndex {
            if string[index].isWhitespace {
                index = string.index(after: index)
                continue
            }
            var end = index
            while end < string.endIndex, !string[end].isWhitespace {
                end = string.index(after: end)
            }
            ranges.append(index..<end)
            index = end
        }
        return ranges
    }

    static func words(in string: String) -> [String] {
        wordRanges(in: string).map { String(string[$0]) }
    }
}

struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
