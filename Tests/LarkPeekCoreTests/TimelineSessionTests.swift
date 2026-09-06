import Foundation
import Testing
@testable import LarkPeekCore

@MainActor
struct TimelineSessionTests {
    private let conversation = HoveredConversation(name: "Test", rowFrame: .zero, rowTexts: ["Test"])
    private let chat = LarkChat(id: "oc_test", name: "Test", kind: .group)

    @Test func lateNamesAndImagesCannotReplacePrependedMessagesOrReplies() throws {
        let session = TimelineSession()
        var root = message(2)
        root.sharedChatID = "oc_shared"
        root.threadID = "omt_test"
        root.isThreadRoot = true
        root.images = [MessageImage(key: "img_test")]
        session.install(conversation: conversation, chat: chat, messages: [root], cursor: "page1", sessionID: session.id)
        let request = try #require(session.beginPage(sessionID: session.id, automatic: false))
        session.applyReplies([message(3)], threadID: "omt_test", hasMore: false, sessionID: session.id)
        session.receivePage(.init(messages: [message(1), root], nextPageToken: nil), requestID: request.id, sessionID: session.id, nextState: .exhausted)
        session.applyNames(["oc_shared": "Resolved"], sessionID: session.id)
        session.applyImage(messageID: root.id, key: "img_test", data: Data([1]), sessionID: session.id)
        #expect(session.messages.map(\.id) == ["om_1", "om_2"])
        #expect(session.messages[1].sharedChatName == "Resolved")
        #expect(session.messages[1].images[0].data == Data([1]))
        #expect(session.messages[1].threadReplies.map(\.id) == ["om_3"])
    }

    @Test func sameChatReopeningRejectsEveryKindOfLateResult() throws {
        let session = TimelineSession()
        session.install(conversation: conversation, chat: chat, messages: [message(1)], cursor: "old", sessionID: session.id)
        let oldID = session.id
        let request = try #require(session.beginPage(sessionID: oldID, automatic: false))
        session.reset()
        session.install(conversation: conversation, chat: chat, messages: [message(2)], cursor: "new", sessionID: session.id)
        let before = session.revision
        session.install(conversation: conversation, chat: chat, messages: [message(0)], cursor: nil, sessionID: oldID)
        session.receivePage(.init(messages: [message(0)], nextPageToken: nil), requestID: request.id, sessionID: oldID, nextState: .exhausted)
        session.finishPage(.failed("old", "stale"), requestID: request.id, sessionID: oldID)
        session.applyNames(["oc_shared": "stale"], sessionID: oldID)
        session.applyImage(messageID: "om_2", key: "img_test", data: Data([1]), sessionID: oldID)
        session.applyReplies([message(0)], threadID: "omt_test", hasMore: false, sessionID: oldID)
        session.failReplies(threadID: "omt_test", error: "stale", sessionID: oldID)
        #expect(session.messages.map(\.id) == ["om_2"])
        #expect(session.pagination == .ready("new"))
        #expect(session.revision == before)
    }

    @Test func failedAndPausedPagesRequireExplicitRetry() throws {
        let session = TimelineSession()
        session.install(conversation: conversation, chat: chat, messages: [message(1)], cursor: "page", sessionID: session.id)
        let request = try #require(session.beginPage(sessionID: session.id, automatic: true))
        #expect(session.beginPage(sessionID: session.id, automatic: false) == nil)
        session.finishPage(.failed("page", "network"), requestID: request.id, sessionID: session.id)
        #expect(session.beginPage(sessionID: session.id, automatic: true) == nil)
        let retry = try #require(session.beginPage(sessionID: session.id, automatic: false))
        session.finishPage(.paused("next", "empty"), requestID: retry.id, sessionID: session.id)
        #expect(session.beginPage(sessionID: session.id, automatic: true) == nil)
        #expect(session.beginPage(sessionID: session.id, automatic: false)?.cursor == "next")
        #expect(session.messages.count == 1)
    }

    @Test func closingFreezesTheDisplayedSnapshotWhileRejectingAllWriters() throws {
        let session = TimelineSession()
        session.install(conversation: conversation, chat: chat, messages: [message(1)], cursor: "page", sessionID: session.id)
        let id = session.id
        let revision = session.revision
        let messages = session.messages
        session.invalidateRequests()
        session.install(conversation: conversation, chat: chat, messages: [message(2)], cursor: nil, sessionID: id)
        session.failReplies(threadID: "omt_test", error: "late", sessionID: id)
        #expect(session.id == id)
        #expect(session.revision == revision)
        #expect(session.messages == messages)
        #expect(session.pagination == .ready("page"))
        #expect(session.beginPage(sessionID: id, automatic: false) == nil)
    }

    @Test func lateFailureCannotDowngradeAnImageAndReplyImagesArePatchedByID() {
        let session = TimelineSession()
        var reply = message(2)
        reply.images = [MessageImage(key: "img_reply")]
        var root = message(1)
        root.threadReplies = [reply]
        session.install(conversation: conversation, chat: chat, messages: [root], cursor: nil, sessionID: session.id)
        session.applyImage(messageID: reply.id, key: "img_reply", data: Data([4]), sessionID: session.id)
        session.applyImage(messageID: reply.id, key: "img_reply", data: nil, sessionID: session.id)
        #expect(session.messages[0].threadReplies[0].images[0].data == Data([4]))
    }

    @Test func oldTaskCleanupCannotRemoveTheReplacementTask() async {
        let session = TimelineSession()
        let oldGate = Gate()
        let newGate = Gate()
        var starts = 0
        let old = session.schedule(key: "images") { await oldGate.wait() }
        await oldGate.waitUntilEntered()
        session.reset()
        let replacement = session.schedule(key: "images") {
            starts += 1
            await newGate.wait()
        }
        await newGate.waitUntilEntered()
        oldGate.open()
        await old.value
        let duplicate = session.schedule(key: "images") { starts += 1 }
        newGate.open()
        await replacement.value
        await duplicate.value
        #expect(starts == 1)
    }

    private func message(_ index: Int) -> LarkMessage {
        LarkMessage(id: "om_\(index)", chatID: chat.id, createTime: Date(timeIntervalSince1970: Double(index)), sender: MessageSender(name: "Test"), content: "Message \(index)")
    }
}

@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered?.resume()
            entered = nil
        }
    }

    func waitUntilEntered() async {
        if continuation != nil { return }
        await withCheckedContinuation { entered = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
