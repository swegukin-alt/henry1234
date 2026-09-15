import SwiftUI

/// The script itself. Words are laid out once; the only thing that moves every
/// frame is the offset applied by the caller, which keeps scrolling cheap.
struct ScriptText: View {
    let body_: String
    let fontSize: Double
    let lineHeight: Double
    let highlightIndex: Int?

    var body: some View {
        Text(attributed)
            .font(.system(size: fontSize, weight: .medium, design: .default))
            .lineSpacing(fontSize * (lineHeight - 1))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            text[lower..<upper].foregroundColor = Theme.accent
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
