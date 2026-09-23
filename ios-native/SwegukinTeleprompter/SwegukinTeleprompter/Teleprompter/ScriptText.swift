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
        guard chunking else { return plainGroups(source) }

        // Port of the web tokeniser, including its whitespace handling. Using
        // split/join here changed Korean spacing and removed authored newlines.
        let regex = try? NSRegularExpression(pattern: #"\s+|\S+"#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let parts = regex?.matches(in: source, range: range).compactMap {
            Range($0.range, in: source).map { String(source[$0]) }
        } ?? [source]
        var groups: [Group] = []
        var current = ""
        var lineLength = 0

        func commit(breakAfter: Bool) {
            guard !current.isEmpty else { return }
            groups.append(Group(text: current, breakAfter: breakAfter))
            current = ""
            lineLength = 0
        }

        var index = 0
        while index < parts.count {
            let word = parts[index]
            if word.allSatisfy(\.isWhitespace) {
                current += word
                lineLength = word.contains("\n") ? 0 : lineLength + word.count
                index += 1
                continue
            }

            let bare = strippedTrailingPunct(word)
            let norm = normalized(word)
            let strong = word.range(of: #"[.!?…。！？]$"#, options: .regularExpression) != nil
            let soft = !strong && word.range(of: #"[,;:—、，]$"#, options: .regularExpression) != nil
            let starter = enConjunctions.contains(norm) || koClauseStarters.contains(bare)

            // Break BEFORE a conjunction / clause starter, like the web reader.
            if starter, lineLength >= minLineChars {
                current = current.replacingOccurrences(of: #"[^\S\r\n]+$"#, with: "", options: .regularExpression)
                commit(breakAfter: true)
            }

            current += word
            lineLength += word.count

            if lineLength >= minLineChars, strong || soft || endsWithKoreanParticle(bare) {
                var nextIndex = index + 1
                let whitespaceIndex = nextIndex < parts.count && parts[nextIndex].allSatisfy(\.isWhitespace) ? nextIndex : nil
                if whitespaceIndex != nil { nextIndex += 1 }
                let nextWord = nextIndex < parts.count ? parts[nextIndex] : ""
                let restIsShort = !nextWord.isEmpty && nextWord.count <= 3 && nextIndex == parts.count - 1
                if !restIsShort {
                    commit(breakAfter: true)
                    if let whitespaceIndex, !parts[whitespaceIndex].contains("\n") {
                        index = whitespaceIndex
                    }
                }
            }
            index += 1
        }
        commit(breakAfter: false)
        if groups.isEmpty { groups = [Group(text: source, breakAfter: false)] }
        return groups
    }

    /// Keep unchanged, unchunked text in bounded native text layers. A single
    /// multi-thousand-word SwiftUI Text can exceed iOS's renderable layer height
    /// and disappear even though its layout and scrolling continue normally.
    private static func plainGroups(_ source: String) -> [Group] {
        guard !source.isEmpty else { return [Group(text: "", breakAfter: false)] }
        var groups: [Group] = []
        var current = ""

        for character in source {
            current.append(character)
            if current.count >= 600 && (character == "\n" || current.count >= 900) {
                groups.append(Group(text: current, breakAfter: false))
                current = ""
            }
        }
        if !current.isEmpty { groups.append(Group(text: current, breakAfter: false)) }
        return groups
    }
}

/// Long scripts are split into stable native text layers; only the line that
/// owns the current highlight needs an attributed-string update.
struct ScriptText: View, Equatable {
    let document: ScriptDocument
    let fontSize: Double
    let lineHeight: Double
    var foreground: Color = .white

    static func == (lhs: ScriptText, rhs: ScriptText) -> Bool {
        lhs.document.blocks.count == rhs.document.blocks.count
            && lhs.document.words.count == rhs.document.words.count
            && lhs.document.blocks.first?.lines.first?.text == rhs.document.blocks.first?.lines.first?.text
            && lhs.document.blocks.last?.lines.last?.text == rhs.document.blocks.last?.lines.last?.text
            && lhs.fontSize == rhs.fontSize
            && lhs.lineHeight == rhs.lineHeight
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
        VStack(alignment: .leading, spacing: 0) {
            ForEach(block.lines) { line in
                Text(line.text).foregroundStyle(foreground)
                    .font(PrompterFont.font(size: fontSize))
                    .tracking(PrompterFont.tracking(size: fontSize))
                    .lineSpacing(extraLineLeading)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    // CSS line-height adds leading to every line box. SwiftUI's
                    // lineSpacing only inserts it between wrapped lines, so add
                    // half-leading at both edges to match the web's 1.5 exactly.
                    .padding(.vertical, extraLineLeading / 2)
                // The web reader inserts a 0.55em spacer at each breath break.
                if line.breakAfter {
                    Color.clear.frame(height: fontSize * 0.55)
                }
            }
        }
    }

    private var nativeFontLineHeight: CGFloat {
        PrompterFont.lineHeight(size: fontSize)
    }

    private var extraLineLeading: CGFloat {
        max(0, fontSize * lineHeight - nativeFontLineHeight)
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

/// TextKit-backed reader surface for long scripts. SwiftUI can report the
/// correct height for a very tall Text hierarchy while dropping its glyphs;
/// UITextView lays out only the visible text fragments and remains reliable for
/// scripts containing thousands of Korean words.
struct NativeScriptTextView: UIViewRepresentable {
    let document: ScriptDocument
    let fontSize: Double
    let lineHeight: Double
    let foreground: Color
    let scrollOffset: CGFloat
    let viewportHeight: CGFloat
    let onContentHeight: (CGFloat) -> Void

    final class Coordinator {
        var signature = ""
        var reportedHeight: CGFloat = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isEditable = false
        view.isSelectable = false
        view.isScrollEnabled = true
        view.isUserInteractionEnabled = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        view.textContainerInset = UIEdgeInsets(top: viewportHeight * 0.20, left: 0, bottom: viewportHeight * 0.80, right: 0)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let first = document.blocks.first?.lines.first?.text ?? ""
        let last = document.blocks.last?.lines.last?.text ?? ""
        let signature = "\(document.blocks.count)|\(document.words.count)|\(first)|\(last)|\(fontSize)|\(lineHeight)|\(foreground.description)"

        if context.coordinator.signature != signature {
            let rendered = renderedText()
            view.attributedText = attributedText(rendered)
            context.coordinator.signature = signature
        }

        let inset = UIEdgeInsets(top: viewportHeight * 0.20, left: 0, bottom: viewportHeight * 0.80, right: 0)
        if view.textContainerInset != inset { view.textContainerInset = inset }
        view.layoutManager.ensureLayout(for: view.textContainer)

        let textHeight = max(0, view.contentSize.height - inset.top - inset.bottom)
        if abs(textHeight - context.coordinator.reportedHeight) > 0.5 {
            context.coordinator.reportedHeight = textHeight
            DispatchQueue.main.async { onContentHeight(textHeight) }
        }

        let maximum = max(0, view.contentSize.height - view.bounds.height)
        let target = min(max(0, scrollOffset), maximum)
        if abs(view.contentOffset.y - target) > 0.01 {
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }
    }

    private func renderedText() -> String {
        var result = ""
        for block in document.blocks {
            for line in block.lines {
                result += line.text
                // U+2029 marks only tokenizer-created breath breaks. Authored
                // newlines remain untouched, matching the web's preserved
                // whitespace without receiving an extra chunk gap.
                if line.breakAfter { result += "\u{2029}" }
            }
        }
        return result
    }

    private func attributedText(_ string: String) -> NSAttributedString {
        let font = PrompterFont.uiFont(size: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = fontSize * lineHeight
        paragraph.maximumLineHeight = fontSize * lineHeight
        paragraph.paragraphSpacing = 0
        paragraph.lineBreakMode = .byWordWrapping
        // Web uses `word-break: keep-all` + `line-break: strict`: a Korean word
        // is never split across lines. Hangul word priority is the native
        // equivalent; without it TextKit breaks Hangul at any syllable.
        paragraph.lineBreakStrategy = [.hangulWordPriority]
        paragraph.hyphenationFactor = 0
        let text = NSMutableAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: UIColor(foreground),
            .kern: PrompterFont.tracking(size: fontSize),
            .paragraphStyle: paragraph,
        ])
        let chunkParagraph = paragraph.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        chunkParagraph.minimumLineHeight = fontSize * lineHeight
        chunkParagraph.maximumLineHeight = fontSize * lineHeight
        chunkParagraph.paragraphSpacing = fontSize * 0.55
        let nsString = string as NSString
        var searchRange = NSRange(location: 0, length: nsString.length)
        while searchRange.length > 0 {
            let range = nsString.range(of: "\u{2029}", options: [], range: searchRange)
            if range.location == NSNotFound { break }
            text.addAttribute(.paragraphStyle, value: chunkParagraph, range: range)
            let next = range.location + range.length
            searchRange = NSRange(location: next, length: nsString.length - next)
        }
        return text
    }

}
