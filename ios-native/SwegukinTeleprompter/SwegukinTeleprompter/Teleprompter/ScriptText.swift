import SwiftUI
import UIKit

/// One breath group — the native equivalent of the web reader's chunked line.
struct ScriptLine: Identifiable {
    let id: Int
    let text: String
    let firstWordIndex: Int
    let wordRanges: [Range<String.Index>]
    /// True when the web tokenizer would emit a soft break after this group,
    /// which renders as a 0.55em spacer.
    let breakAfter: Bool
}

struct ScriptBlock: Identifiable {
    let id: Int
    let lines: [ScriptLine]
    let firstWordIndex: Int
    let wordCount: Int
}

/// Immutable layout data created once when a prompter opens. Breath groups are
/// produced with the same rules as the web tokenizer (`src/lib/chunk-script.ts`)
/// and then packed into paragraph-sized blocks so a single native text layer
/// never exceeds iOS's height ceiling.
struct ScriptDocument {
    let blocks: [ScriptBlock]
    let words: [String]

    init(_ source: String, chunking: Bool = false) {
        let groups = Self.breathGroups(source, chunking: chunking)
        var words: [String] = []
        var blocks: [ScriptBlock] = []
        var currentLines: [ScriptLine] = []
        var currentChars = 0
        var currentFirstWord = 0
        var lineID = 0
        var blockID = 0

        func flush() {
            guard !currentLines.isEmpty else { return }
            let count = currentLines.reduce(0) { $0 + $1.wordRanges.count }
            blocks.append(ScriptBlock(id: blockID, lines: currentLines, firstWordIndex: currentFirstWord, wordCount: count))
            blockID += 1
            currentLines = []
            currentChars = 0
            currentFirstWord = words.count
        }

        for group in groups {
            let ranges = ScriptText.wordRanges(in: group.text)
            let line = ScriptLine(
                id: lineID,
                text: group.text,
                firstWordIndex: words.count,
                wordRanges: ranges,
                breakAfter: group.breakAfter
            )
            lineID += 1
            if currentLines.isEmpty { currentFirstWord = words.count }
            currentLines.append(line)
            currentChars += group.text.count
            words.append(contentsOf: ranges.map { String(group.text[$0]) })
            if currentChars >= 1_200 { flush() }
        }
        flush()

        if blocks.isEmpty {
            blocks = [ScriptBlock(
                id: 0,
                lines: [ScriptLine(id: 0, text: "", firstWordIndex: 0, wordRanges: [], breakAfter: false)],
                firstWordIndex: 0,
                wordCount: 0
            )]
        }
        self.blocks = blocks
        self.words = words
    }

    // MARK: - Breath grouping (mirrors the web tokenizer)

    private struct Group { let text: String; let breakAfter: Bool }

    private static let koParticleEndings = [
        "습니다", "니다", "면서", "지만", "라서", "니까", "에서", "으로",
        "은", "는", "이", "가", "을", "를", "에", "로", "와", "과",
        "도", "만", "요", "다", "죠", "네", "고", "며", "면",
    ]

    private static let koClauseStarters: Set<String> = [
        "그리고", "하지만", "그런데", "그래서", "그러나", "또한", "또", "즉",
        "따라서", "결국", "그러면", "그럼", "먼저", "다음", "마지막으로",
    ]

    private static let enConjunctions: Set<String> = [
        "and", "but", "so", "because", "or", "yet", "for", "nor",
        "while", "although", "though", "since", "unless", "when", "if",
    ]

    private static let minLineChars = 34

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0xAC00...0xD7A3).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v)
    }

    private static func normalized(_ word: String) -> String {
        String(word.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || isHangul($0)
        }.map(Character.init)).lowercased()
    }

    private static func strippedTrailingPunct(_ word: String) -> String {
        var out = word
        while let last = out.unicodeScalars.last,
              !(CharacterSet.alphanumerics.contains(last) || isHangul(last)) {
            out.unicodeScalars.removeLast()
        }
        return out
    }

    private static func endsWithKoreanParticle(_ bare: String) -> Bool {
        guard !bare.isEmpty, bare.unicodeScalars.contains(where: isHangul) else { return false }
        for particle in koParticleEndings where bare.hasSuffix(particle) && bare.count > particle.count {
            return true
        }
        return false
    }

    private static func breathGroups(_ source: String, chunking: Bool) -> [Group] {
        var groups: [Group] = []
        // Hard newlines from the author are always respected.
        for (paragraphIndex, paragraph) in source.components(separatedBy: "\n").enumerated() {
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if paragraphIndex > 0, var last = groups.popLast() {
                    last = Group(text: last.text, breakAfter: true)
                    groups.append(last)
                }
                continue
            }
            guard chunking else {
                groups.append(Group(text: trimmed, breakAfter: false))
                continue
            }
            groups.append(contentsOf: chunkParagraph(trimmed))
        }
        if groups.isEmpty { groups = [Group(text: source, breakAfter: false)] }
        return groups
    }

    private static func chunkParagraph(_ paragraph: String) -> [Group] {
        let words = paragraph.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }

        var groups: [Group] = []
        var current: [String] = []
        var lineLength = 0

        func commit(breakAfter: Bool) {
            guard !current.isEmpty else { return }
            groups.append(Group(text: current.joined(separator: " "), breakAfter: breakAfter))
            current = []
            lineLength = 0
        }

        for (index, word) in words.enumerated() {
            let bare = strippedTrailingPunct(word)
            let norm = normalized(word)
            let strong = word.range(of: #"[.!?…。！？]$"#, options: .regularExpression) != nil
            let soft = !strong && word.range(of: #"[,;:—、，]$"#, options: .regularExpression) != nil
            let starter = enConjunctions.contains(norm) || koClauseStarters.contains(bare)

            // Break BEFORE a conjunction / clause starter, like the web reader.
            if starter, lineLength >= minLineChars { commit(breakAfter: true) }

            current.append(word)
            lineLength += word.count + 1

            let isLast = index == words.count - 1
            if isLast { continue }
            guard lineLength >= minLineChars, strong || soft || endsWithKoreanParticle(bare) else { continue }
            // Don't orphan a very short tail word on its own line.
            let remaining = words.count - index - 1
            if remaining == 1, words[index + 1].count <= 3 { continue }
            commit(breakAfter: true)
        }
        commit(breakAfter: false)
        return groups
    }
}

/// Long scripts are split into stable native text layers; only the line that
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
            && lhs.document.blocks.first?.lines.first?.text == rhs.document.blocks.first?.lines.first?.text
            && lhs.document.blocks.last?.lines.last?.text == rhs.document.blocks.last?.lines.last?.text
            && lhs.fontSize == rhs.fontSize
            && lhs.lineHeight == rhs.lineHeight
            && lhs.highlightIndex == rhs.highlightIndex
            && lhs.foreground == rhs.foreground
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(document.blocks) { block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ScriptBlock) -> some View {
        let highlighted = isHighlighted(block)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(block.lines) { line in
                lineText(line, blockHighlighted: highlighted)
                    .font(.custom("Pretendard Variable", size: fontSize).weight(.medium))
                    .lineSpacing(max(0, fontSize * lineHeight - nativeFontLineHeight))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                // The web reader inserts a 0.55em spacer at each breath break.
                if line.breakAfter {
                    Color.clear.frame(height: fontSize * 0.55)
                }
            }
        }
    }

    private func isHighlighted(_ block: ScriptBlock) -> Bool {
        guard let highlightIndex else { return false }
        return highlightIndex >= block.firstWordIndex && highlightIndex < block.firstWordIndex + block.wordCount
    }

    @ViewBuilder
    private func lineText(_ line: ScriptLine, blockHighlighted: Bool) -> some View {
        if blockHighlighted,
           let highlightIndex,
           highlightIndex >= line.firstWordIndex,
           highlightIndex < line.firstWordIndex + line.wordRanges.count {
            Text(attributed(line))
        } else {
            Text(line.text).foregroundStyle(foreground)
        }
    }

    private var nativeFontLineHeight: CGFloat {
        UIFont(name: "Pretendard Variable", size: fontSize)?.lineHeight
            ?? UIFont.systemFont(ofSize: fontSize, weight: .medium).lineHeight
    }

    private func attributed(_ line: ScriptLine) -> AttributedString {
        var text = AttributedString(line.text)
        text.foregroundColor = foreground
        guard let highlightIndex else { return text }
        let localIndex = highlightIndex - line.firstWordIndex
        guard localIndex >= 0, localIndex < line.wordRanges.count else { return text }
        let range = line.wordRanges[localIndex]
        if let lower = AttributedString.Index(range.lowerBound, within: text),
           let upper = AttributedString.Index(range.upperBound, within: text) {
            // Match the web reader: text stays white and the current word
            // receives only a faint white wash.
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
