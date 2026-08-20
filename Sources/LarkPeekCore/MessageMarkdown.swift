import Foundation

public enum MessageMarkdown {
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
}
