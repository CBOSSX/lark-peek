import Foundation

public enum MessageMarkdown {
    public enum ContentPart: Equatable, Sendable {
        case text(String)
        case image(key: String)
    }

    public struct Block: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case paragraph
            case heading(level: Int)
            case unordered(level: Int)
            case ordered(number: Int, level: Int)
            case quote(level: Int)
            case code
        }

        public let kind: Kind
        public let content: String

        public init(kind: Kind, content: String) {
            self.kind = kind
            self.content = content
        }
    }

    /// Parses Markdown received at runtime while preserving the message's original
    /// whitespace. Invalid input remains visible as plain text.
    public static func attributedString(from source: String) -> AttributedString {
        let source = normalizeHTMLParagraphs(in: source)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
    }

    public static func blocks(from source: String) -> [Block] {
        let source = normalizeHTMLParagraphs(in: source)
        var blocks: [Block] = []
        var codeLines: [String] = []
        var isInsideCodeFence = false

        for line in source.components(separatedBy: .newlines) {
            if line.range(of: #"^\s*```"#, options: .regularExpression) != nil {
                if isInsideCodeFence {
                    blocks.append(Block(kind: .code, content: codeLines.joined(separator: "\n")))
                    codeLines = []
                }
                isInsideCodeFence.toggle()
                continue
            }
            if isInsideCodeFence {
                codeLines.append(line)
                continue
            }
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

            if let values = captures(in: line, pattern: #"^\s*(#{1,6})\s+(.+)$"#),
               let marks = values.first {
                blocks.append(Block(kind: .heading(level: marks.count), content: values[1]))
            } else if let values = captures(in: line, pattern: #"^(\s*)[-+*]\s+(.+)$"#) {
                blocks.append(Block(
                    kind: .unordered(level: indentationLevel(values[0])),
                    content: values[1]
                ))
            } else if let values = captures(in: line, pattern: #"^(\s*)(\d+)[.)]\s+(.+)$"#),
                      let number = Int(values[1]) {
                blocks.append(Block(
                    kind: .ordered(number: number, level: indentationLevel(values[0])),
                    content: values[2]
                ))
            } else if let values = captures(in: line, pattern: #"^\s*(>+)\s?(.*)$"#) {
                blocks.append(Block(kind: .quote(level: values[0].count - 1), content: values[1]))
            } else {
                blocks.append(Block(kind: .paragraph, content: line))
            }
        }
        if isInsideCodeFence || !codeLines.isEmpty {
            blocks.append(Block(kind: .code, content: codeLines.joined(separator: "\n")))
        }
        return blocks
    }

    /// Splits message text and its downloaded resources into display order.
    /// Images without an inline marker are appended as a compatibility fallback.
    public static func contentParts(from source: String, imageKeys: [String]) -> [ContentPart] {
        let knownKeys = Set(imageKeys)
        let pattern = #"!\[Image\]\((img_[A-Za-z0-9_-]+)\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return fallbackContentParts(source: source, imageKeys: imageKeys)
        }

        var parts: [ContentPart] = []
        var usedKeys: Set<String> = []
        var cursor = source.startIndex
        let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))

        for match in matches {
            guard let markerRange = Range(match.range(at: 0), in: source),
                  let keyRange = Range(match.range(at: 1), in: source) else { continue }
            let key = String(source[keyRange])
            guard knownKeys.contains(key) else { continue }
            appendText(String(source[cursor..<markerRange.lowerBound]), to: &parts)
            parts.append(.image(key: key))
            usedKeys.insert(key)
            cursor = markerRange.upperBound
        }
        appendText(String(source[cursor...]), to: &parts)
        for key in imageKeys where !usedKeys.contains(key) {
            parts.append(.image(key: key))
        }
        return parts
    }

    static func normalizeHTMLParagraphs(in source: String) -> String {
        guard source.range(of: #"<\s*/?\s*p(?:\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) != nil
                || source.range(of: #"<\s*br\s*/?\s*>"#, options: [.regularExpression, .caseInsensitive]) != nil
        else { return source }

        var normalized = source
            .replacingOccurrences(of: #"<\s*br\s*/?\s*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<\s*/\s*p\s*>"#, with: "\n\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<\s*p(?:\s[^>]*)?>"#, with: "", options: [.regularExpression, .caseInsensitive])
        while normalized.hasSuffix("\n\n") { normalized.removeLast(2) }
        return normalized
            .replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&#39;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    }

    private static func captures(in text: String, pattern: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        var values: [String] = []
        for index in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            values.append(String(text[range]))
        }
        return values
    }

    private static func indentationLevel(_ whitespace: String) -> Int {
        whitespace.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
    }

    private static func fallbackContentParts(source: String, imageKeys: [String]) -> [ContentPart] {
        var parts: [ContentPart] = []
        appendText(source, to: &parts)
        parts.append(contentsOf: imageKeys.map { .image(key: $0) })
        return parts
    }

    private static func appendText(_ source: String, to parts: inout [ContentPart]) {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "[图片]" else { return }
        parts.append(.text(text))
    }
}
