import SwiftUI
import UIKit

struct ScriptBlock: Identifiable {
    let id: Int
    let text: String
    let firstWordIndex: Int
    let wordRanges: [Range<String.Index>]
}

/// Immutable layout data created once when a prompter opens. Paragraph-sized
/// blocks avoid iOS's single-text-layer height ceiling without dropping text.
struct ScriptDocument {
    let blocks: [ScriptBlock]
    let words: [String]

    init(_ source: String, chunking: Bool = false) {
        let source = chunking ? Self.chunked(source) : source
        var blocks: [ScriptBlock] = []
        var words: [String] = []
        var cursor = source.startIndex
        var id = 0

        while cursor < source.endIndex {
            let target = source.index(cursor, offsetBy: 1_200, limitedBy: source.endIndex) ?? source.endIndex
            var end = target
            if target < source.endIndex {
                var scan = target
                while scan > cursor, !source[scan].isWhitespace { scan = source.index(before: scan) }
                if scan > cursor { end = source.index(after: scan) }
            }
            let text = String(source[cursor..<end])
            let ranges = ScriptText.wordRanges(in: text)
            blocks.append(ScriptBlock(id: id, text: text, firstWordIndex: words.count, wordRanges: ranges))
            words.append(contentsOf: ranges.map { String(text[$0]) })
            cursor = end
            id += 1
        }
        if blocks.isEmpty { blocks = [ScriptBlock(id: 0, text: "", firstWordIndex: 0, wordRanges: [])] }
        self.blocks = blocks
        self.words = words
    }

    private static func chunked(_ source: String) -> String {
        let words = source.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return source }
        var output: [String] = []
        var lineLength = 0
        for (index, word) in words.enumerated() {
            output.append(word)
            lineLength += word.count + 1
            let punctuation = word.range(of: #"[.!?,;:…。！？，、]$"#, options: .regularExpression) != nil
            let koreanEnding = word.range(of: #"(은|는|이|가|을|를|에서|으로|지만|니까|습니다|니다|요|죠|다)[.!?…。！？]?$"#, options: .regularExpression) != nil
            if lineLength >= 34, (punctuation || koreanEnding), index < words.count - 1 {
                output.append("\n")
                lineLength = 0
            } else if index < words.count - 1 {
                output.append(" ")
            }
        }
        return output.joined()
    }
}

/// Long scripts are split into stable native text layers; only the block that
/// owns the current highlight needs an attributed-string update.
struct ScriptText: View, Equatable {
    let document: ScriptDocument
    let fontSize: Double
    let lineHeight: Double
    let highlightIndex: Int?
    var foreground: Color = .white

    static func == (lhs: ScriptText, rhs: ScriptText) -> Bool {
        lhs.document.blocks.count == rhs.document.blocks.count
            && lhs.document.words.count == rhs.document.words.count
            && lhs.document.blocks.first?.text == rhs.document.blocks.first?.text
            && lhs.document.blocks.last?.text == rhs.document.blocks.last?.text
            && lhs.fontSize == rhs.fontSize
            && lhs.lineHeight == rhs.lineHeight
            && lhs.highlightIndex == rhs.highlightIndex
            && lhs.foreground == rhs.foreground
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(document.blocks) { block in
                blockText(block)
                    .font(.custom("Pretendard Variable", size: fontSize).weight(.medium))
                    .lineSpacing(max(0, fontSize * lineHeight - nativeFontLineHeight))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func blockText(_ block: ScriptBlock) -> some View {
        if let highlightIndex,
           highlightIndex >= block.firstWordIndex,
           highlightIndex < block.firstWordIndex + block.wordRanges.count {
            Text(attributed(block))
        } else {
            Text(block.text).foregroundStyle(foreground)
        }
    }

    private var nativeFontLineHeight: CGFloat {
        UIFont(name: "Pretendard Variable", size: fontSize)?.lineHeight
            ?? UIFont.systemFont(ofSize: fontSize, weight: .medium).lineHeight
    }

    private func attributed(_ block: ScriptBlock) -> AttributedString {
        var text = AttributedString(block.text)
        text.foregroundColor = foreground
        guard let highlightIndex else { return text }
        let localIndex = highlightIndex - block.firstWordIndex
        guard localIndex >= 0, localIndex < block.wordRanges.count else { return text }
        let range = block.wordRanges[localIndex]
        if let lower = AttributedString.Index(range.lowerBound, within: text),
           let upper = AttributedString.Index(range.upperBound, within: text) {
            // Match the web reader: text remains white and the current word
            // receives only a faint white wash, never a blue text color.
            text[lower..<upper].foregroundColor = foreground
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
