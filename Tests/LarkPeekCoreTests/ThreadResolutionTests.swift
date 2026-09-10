import Foundation
import Testing
@testable import LarkPeekCore

@Test func threadAvatarIsPositiveEvidenceAndDoesNotGuessFromBadge() {
    #expect(ThreadAvatarEvidence.matches(classes: ["avatarWithBadge__mThread--avatar"]))
    #expect(!ThreadAvatarEvidence.matches(classes: ["avatarWithBadge", "ud__badge-red-filled"]))
    #expect(!ThreadAvatarEvidence.matches(classes: ["avatarWithBadge__mThread--avatar-other"]))
}

@Test func structuredThreadHintKeepsClocksInsideRootAndReply() throws {
    let hint = try #require(ThreadRowHeuristics.hint(title: "Alice: 明天 10:30 讨论方案", activity: "16:46",
        replyTexts: ["Bob", ":", "约到 11:00 可以吗"]))
    #expect(hint.rootExcerpt == "明天 10:30 讨论方案")
    #expect(hint.latestReplyExcerpt == "约到 11:00 可以吗")
    #expect(hint.activityMarker == "16:46")
}

@Test func threadMatchingNormalizesHTMLWithoutDeletingMentionIdentity() {
    #expect(ThreadText.matches(excerpt: "此外@曹博淳 scripts需要吗？", content: "<p>此外@曹博淳 scripts需要吗？</p>"))
    #expect(!ThreadText.matches(excerpt: "此外@曹博淳 scripts需要吗？", content: "此外@其他人 scripts需要吗？"))
    #expect(!ThreadText.matches(excerpt: "", content: "anything"))
    #expect(!ThreadText.matches(excerpt: "项目", content: "项目完全不同"))
    #expect(ThreadText.matches(excerpt: "项目规划今天已经确认…", content: "项目规划今天已经确认，明天实施"))
    #expect(!ThreadText.queries("此外@曹博淳 scripts下的docx_citations.py是要的对吧").contains { $0.contains("此外") })
}

@Test func messageDetailsCommandIsRestrictedToOneValidatedMessage() throws {
    #expect(try ReadOnlyCommand.messageDetails(messageID: "om_root").arguments() == [
        "im", "+messages-mget", "--as", "user", "--message-ids", "om_root", "--no-reactions", "--format", "json"
    ])
    for value in ["om_a,om_b", "om_a --yes", "om_a\n", "omt_thread", "om_a;cmd"] {
        #expect(throws: (any Error).self) { try ReadOnlyCommand.messageDetails(messageID: value).arguments() }
    }
}

@Test func threadResolutionRecoversRealRootFromReplyWithoutRootID() async throws {
    let fixture = ThreadTransport(mode: .replyOnly)
    let result = try await ThreadResolver(run: { try await fixture.run($0) }).resolve(threadHint(), now: testDate())
    let candidate = try #require(result.candidates.first)
    #expect(result.complete)
    #expect(candidate.replyVerified)
    #expect(candidate.root.id == "om_root")
    #expect(candidate.root.content == "<p>讨论@Alice 本周接口设计方案</p>")
    #expect(await fixture.historyRequests == 1)
}

@Test func threadResolutionUsesRootRelationshipWhenAvailable() async throws {
    let fixture = ThreadTransport(mode: .withRootID)
    let result = try await ThreadResolver(run: { try await fixture.run($0) }).resolve(threadHint(), now: testDate())
    #expect(result.candidates.first?.root.id == "om_root")
    #expect(await fixture.historyRequests == 0)
}

@Test func identicalTextInDifferentChatsRemainsAmbiguous() async throws {
    let fixture = ThreadTransport(mode: .ambiguous)
    let result = try await ThreadResolver(run: { try await fixture.run($0) }).resolve(threadHint(), now: testDate())
    #expect(result.candidates.count == 2)
    #expect(Set(result.candidates.map(\.id)).count == 2)
    #expect(result.candidates.allSatisfy { $0.replyVerified })
}

@Test func incompleteSearchNeverBecomesAnAutomaticUniqueMatch() async throws {
    let fixture = ThreadTransport(mode: .incomplete)
    let result = try await ThreadResolver(run: { try await fixture.run($0) }).resolve(threadHint(), now: testDate())
    #expect(!result.complete)
    #expect(result.candidates.count == 1)
    #expect(await fixture.searchRequests <= 6)
}

@Test func missingCursorWithHasMoreDoesNotClaimCompleteDiscovery() async throws {
    let fixture = ThreadTransport(mode: .missingCursor)
    let result = try await ThreadResolver(run: { try await fixture.run($0) }).resolve(threadHint(), now: testDate())
    #expect(!result.complete)
}

@Test func missingRealRootDoesNotProduceSyntheticContent() async throws {
    let fixture = ThreadTransport(mode: .missingRoot)
    let result = try await ThreadResolver(run: { try await fixture.run($0) }).resolve(threadHint(), now: testDate())
    #expect(result.candidates.isEmpty)
    #expect(!result.complete)
}

@Test func changedRootIsRejectedAfterFreshRead() async throws {
    let fixture = ThreadTransport(mode: .edited)
    let result = try await ThreadResolver(run: { try await fixture.run($0) }).resolve(threadHint(), now: testDate())
    #expect(result.candidates.isEmpty)
}

@Test func wrongReplyTimeNeedsUserConfirmation() async throws {
    let fixture = ThreadTransport(mode: .wrongTime)
    let result = try await ThreadResolver(run: { try await fixture.run($0) }).resolve(threadHint(), now: testDate())
    #expect(result.candidates.count == 1)
    #expect(result.candidates.first?.replyVerified == false)
}

@Test func cancelledResolutionDoesNotReturnCandidates() async throws {
    let fixture = ThreadTransport(mode: .cancelled)
    do {
        _ = try await ThreadResolver(run: { try await fixture.run($0) }).resolve(threadHint(), now: testDate())
        Issue.record("Expected cancellation")
    } catch is CancellationError {}
}

private func testDate() -> Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 17))!
}

private func threadHint() -> ThreadRowHint {
    ThreadRowHint(rootSender: "Alice", rootExcerpt: "讨论@Alice 本周接口设计方案", latestReplySender: "Bob",
                  latestReplyExcerpt: "可以参考我给的那个设计文档", searchQuery: "unused", replySearchQuery: "unused", activityMarker: "16:46")
}

private actor ThreadTransport {
    enum Mode { case replyOnly, withRootID, ambiguous, incomplete, missingCursor, missingRoot, edited, wrongTime, cancelled }
    let mode: Mode
    var historyRequests = 0
    var searchRequests = 0
    init(mode: Mode) { self.mode = mode }

    func run(_ command: ReadOnlyCommand) throws -> CLIResult {
        if mode == .cancelled { throw CancellationError() }
        var rows: [[String: Any]] = []
        var more = false
        switch command {
        case .searchMessages:
            searchRequests += 1
            rows = mode == .replyOnly || mode == .withRootID || mode == .missingRoot ? [reply()] : [root(), reply()]
            if mode == .ambiguous { rows += [root(suffix: "2"), reply(suffix: "2")] }
            more = mode == .incomplete || mode == .missingCursor
        case let .recentMessages(chatID, _, _, _, _):
            historyRequests += 1
            rows = mode == .missingRoot ? [] : [root(suffix: chatID == "oc_chat2" ? "2" : "")]
        case let .messageDetails(id):
            rows = [root(suffix: id == "om_root2" ? "2" : "")]
            if mode == .edited { rows[0]["content"] = "已编辑为完全不同的主题" }
        case let .threadMessages(threadID, _, _):
            rows = [reply(suffix: threadID == "omt_topic2" ? "2" : "")]
        default:
            Issue.record("Unexpected command: \(command)")
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "data": ["messages": rows, "has_more": more, "page_token": more && mode != .missingCursor ? "cycle" : ""]])
        return CLIResult(data: data, stderr: Data(), exitCode: 0)
    }

    private func root(suffix: String = "") -> [String: Any] {
        ["message_id": "om_root" + suffix, "chat_id": "oc_chat" + suffix, "chat_name": "讨论群" + suffix,
         "thread_id": "omt_topic" + suffix, "thread_message_position": "-1", "msg_type": "text",
         "sender": ["name": "Alice"], "content": "<p>讨论@Alice 本周接口设计方案</p>", "create_time": "2026-09-10 16:41"]
    }
    private func reply(suffix: String = "") -> [String: Any] {
        var row: [String: Any] = ["message_id": "om_reply" + suffix, "chat_id": "oc_chat" + suffix, "chat_name": "讨论群" + suffix,
            "thread_id": "omt_topic" + suffix, "thread_message_position": "2", "msg_type": "text",
            "sender": ["name": "Bob"], "content": "可以参考我给的那个设计文档", "create_time": mode == .wrongTime ? "2026-09-10 15:46" : "2026-09-10 16:46"]
        if mode == .withRootID { row["root_id"] = "om_root" + suffix }
        return row
    }
}
