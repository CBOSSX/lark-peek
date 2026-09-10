import Foundation

public enum ThreadAvatarEvidence {
    // A positive signal only: Feishu can rename or omit this internal class.
    public static func matches(classes: [String]) -> Bool {
        classes.contains("avatarWithBadge__mThread--avatar")
    }
}

/// Matching text is deliberately separate from message rendering. Mentions stay
/// present on both sides; query generation never stitches across a removed mention.
public enum ThreadText {
    public static func displayText(_ text: String) -> String {
        var value = text.replacingOccurrences(of: #"</?(?:p|div|span|br|strong|b|em|i|a|code|pre)(?:\s[^>]*)?/?>"#, with: "", options: .regularExpression)
        for (entity, replacement) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            value = value.replacingOccurrences(of: entity, with: replacement)
        }
        return value
    }

    public static func normalized(_ text: String) -> String {
        ConversationText.normalize(displayText(text))
    }

    public static func matches(excerpt: String, content: String) -> Bool {
        let expected = normalized(excerpt)
        let actual = normalized(content)
        guard !expected.isEmpty, !actual.isEmpty else { return false }
        if expected == actual { return true }
        // Only permit truncation when the UI explicitly indicated it.
        return (excerpt.hasSuffix("…") || excerpt.hasSuffix("..."))
            && expected.count >= 8 && actual.hasPrefix(expected)
    }

    public static func queries(_ text: String) -> [String] {
        let authored = text.components(separatedBy: "[链接]").first ?? text
        let separated = authored
            .replacingOccurrences(of: #"<[^>]+>|@[^\s@]+|https?://\S+|\[[^\]]+\]"#, with: "\n", options: .regularExpression)
        let clauses = separated.components(separatedBy: CharacterSet(charactersIn: "，。！？；;、&＆\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 6 && $0.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) == nil }
        let parts = clauses.sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count
        }
        var seen = Set<String>()
        return parts.map { String($0.prefix(32)) }.filter { seen.insert($0).inserted }.prefix(2).map { $0 }
    }
}

public struct ThreadCandidate: Equatable, Sendable, Identifiable {
    public let root: LarkMessage
    public let chat: LarkChat
    public let replyVerified: Bool
    public var id: String { chat.id + ":" + (root.threadID ?? root.id) }
}

struct ThreadResolution: Sendable {
    var candidates: [ThreadCandidate]
    var complete: Bool
}

/// Bounded discovery, followed by validation of real messages. No text-to-ID
/// mapping is persisted: identical text in another chat must not reuse identity.
struct ThreadResolver: Sendable {
    let run: @Sendable (ReadOnlyCommand) async throws -> CLIResult
    private let maximumPages = 2
    private let maximumCandidates = 5

    func resolve(_ hint: ThreadRowHint, now: Date = .now) async throws -> ThreadResolution {
        var complete = true
        var hits: [String: MessageSearchHit] = [:]
        let bounds = activityBounds(hint.activityMarker, now: now)
        let rootQueries = ThreadText.queries(hint.rootExcerpt)
        let replyQueries = ThreadText.queries(hint.latestReplyExcerpt)
        // One independent query from each side first, then one alternate root clause.
        let queries = rootQueries.prefix(1).map { ($0, false) }
            + replyQueries.prefix(1).map { ($0, true) }
            + rootQueries.dropFirst().prefix(1).map { ($0, false) }
        for (query, reply) in queries {
            var token: String?
            var seen = Set<String>()
            for _ in 0..<maximumPages {
                try Task.checkCancellation()
                let result = try await run(.searchMessages(query: query, pageToken: token,
                    start: reply ? bounds?.start : nil, end: reply ? bounds?.end : nil, pageSize: 50))
                let page = try LarkCLIParser.messageSearchPage(from: result.data)
                let envelope = try JSONSerialization.jsonObject(with: result.data) as? [String: Any]
                let payload = envelope?["data"] as? [String: Any] ?? envelope
                let rawCount = (payload?["messages"] as? [Any])?.count ?? 0
                if rawCount != page.hits.count
                    || (payload?["has_more"] as? Bool == true && page.nextPageToken == nil) { complete = false }
                let trigger = LarkPeekDiagnostics.triggerID ?? "none"
                LarkPeekDiagnostics.threadMatching.info("event=thread_search_page trigger=\(trigger, privacy: .public) raw=\(rawCount) parsed=\(page.hits.count) hasMore=\(page.nextPageToken != nil)")
                for hit in page.hits where hit.message.threadID != nil && !hit.message.deleted {
                    hits[hit.message.id] = hit
                }
                token = page.nextPageToken
                guard let next = token else { break }
                guard seen.insert(next).inserted else { break }
            }
            if token != nil { complete = false }
        }
        let relevant = hits.values.filter { hit in
            hit.message.isThreadRoot ? rootMatches(hit.message, hint) : replyMatches(hit.message, hint, bounds: bounds)
        }
        let groups = Dictionary(grouping: relevant) { $0.chat.id + ":" + ($0.message.threadID ?? "") }
        if groups.count > maximumCandidates { complete = false }
        var candidates: [ThreadCandidate] = []
        for key in groups.keys.sorted().prefix(maximumCandidates) {
            try Task.checkCancellation()
            guard let group = groups[key], let first = group.first,
                  let threadID = first.message.threadID else { continue }
            var root = group.first(where: { $0.message.isThreadRoot })?.message
            if root == nil, let rootID = group.compactMap({ $0.message.rootID }).first {
                let result = try await run(.messageDetails(messageID: rootID))
                root = try LarkCLIParser.messages(from: result.data, fallbackChatID: first.chat.id)
                    .first { $0.id == rootID && $0.isThreadRoot && $0.threadID == threadID && $0.chatID == first.chat.id }
            }
            if root == nil {
                // Current CLI versions omit root_id. Ordinary chat history carries
                // the real thread root, including image/forwarded-message roots.
                var token: String?
                var seen = Set<String>()
                for _ in 0..<maximumPages {
                    let result = try await run(.recentMessages(chatID: first.chat.id, pageToken: token, pageSize: 50))
                    let page = try LarkCLIParser.messagePage(from: result.data, fallbackChatID: first.chat.id)
                    root = page.messages.first { $0.isThreadRoot && $0.threadID == threadID && $0.chatID == first.chat.id }
                    token = page.nextPageToken
                    if root != nil || token == nil { break }
                    if !seen.insert(token!).inserted { break }
                }
                if root == nil { complete = false; continue }
            }
            guard let discovered = root else { continue }
            // Re-read by message ID; search snapshots and cached summaries can be stale.
            let details = try await run(.messageDetails(messageID: discovered.id))
            guard let fresh = try LarkCLIParser.messages(from: details.data, fallbackChatID: first.chat.id)
                .first(where: { $0.id == discovered.id && $0.chatID == first.chat.id && $0.threadID == threadID && $0.isThreadRoot }),
                  rootMatches(fresh, hint) else { continue }
            var verified = false
            var token: String?
            var seen = Set<String>()
            for _ in 0..<maximumPages {
                let result = try await run(.threadMessages(threadID: threadID, pageToken: token, pageSize: 50))
                let page = try LarkCLIParser.messagePage(from: result.data, fallbackChatID: first.chat.id)
                verified = page.messages.contains { $0.threadID == threadID && $0.chatID == first.chat.id && replyMatches($0, hint, bounds: bounds) }
                token = page.nextPageToken
                if verified || token == nil { break }
                if !seen.insert(token!).inserted { break }
            }
            if !verified && token != nil { complete = false }
            candidates.append(ThreadCandidate(root: fresh, chat: first.chat, replyVerified: verified))
        }
        try Task.checkCancellation()
        return ThreadResolution(candidates: candidates, complete: complete)
    }

    private func rootMatches(_ message: LarkMessage, _ hint: ThreadRowHint) -> Bool {
        guard !message.deleted, message.isThreadRoot,
              ThreadText.normalized(message.sender.name) == ThreadText.normalized(hint.rootSender) else { return false }
        if hint.rootExcerpt == "[会话记录]" { return message.type == "merge_forward" }
        if hint.rootExcerpt == "[图片]" { return message.type == "image" }
        return ThreadText.matches(excerpt: hint.rootExcerpt, content: message.content)
    }

    private func replyMatches(_ message: LarkMessage, _ hint: ThreadRowHint, bounds: ActivityBounds?) -> Bool {
        guard !message.deleted, !message.isThreadRoot,
              ThreadText.matches(excerpt: hint.latestReplyExcerpt, content: message.content) else { return false }
        if let sender = hint.latestReplySender,
           ThreadText.normalized(sender) != ThreadText.normalized(message.sender.name) { return false }
        guard let bounds else { return false }
        return message.createTime >= bounds.lower && message.createTime < bounds.upper
    }

    private struct ActivityBounds {
        let start: String
        let end: String
        let lower: Date
        let upper: Date
    }

    private func activityBounds(_ marker: String, now: Date) -> ActivityBounds? {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        var day = today
        var minute: Int?
        if marker == "昨天" { day = calendar.date(byAdding: .day, value: -1, to: today)! }
        else if marker == "前天" { day = calendar.date(byAdding: .day, value: -2, to: today)! }
        else if marker.contains(":") {
            let parts = marker.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
            minute = parts[0] * 60 + parts[1]
        } else {
            let parts = marker.replacingOccurrences(of: "日", with: "").split(separator: "月").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            var components = calendar.dateComponents([.year], from: now)
            components.month = parts[0]; components.day = parts[1]
            guard let date = calendar.date(from: components) else { return nil }
            day = date > today ? calendar.date(byAdding: .year, value: -1, to: date)! : date
        }
        let end = calendar.date(byAdding: .day, value: 1, to: day)!
        let lower = minute.map { calendar.date(byAdding: .minute, value: $0, to: day)! } ?? day
        let upper = minute == nil ? end : calendar.date(byAdding: .minute, value: 1, to: lower)!
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .autoupdatingCurrent
        return ActivityBounds(start: formatter.string(from: day), end: formatter.string(from: end), lower: lower, upper: upper)
    }
}
