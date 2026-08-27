import Foundation
import Testing
@testable import LarkPeekCore

@Test @MainActor func ordinaryPreviewDefersDeduplicatesAndCachesThreadRequests() async throws {
    let fixture = try ThreadLoadingFixture(threadDelaySeconds: 0)
    defer { fixture.remove() }
    let model = PeekModel(defaults: fixture.defaults, workingDirectory: fixture.directory)

    await model.peek(fixture.conversation)

    #expect(try fixture.requestCount() == 0)
    guard case let .messages(_, _, messages, _) = model.state else {
        Issue.record("Expected ordinary message preview")
        return
    }
    #expect(messages.count == 3)
    #expect(messages.first(where: { $0.id == "om_root_1" })?.isThreadRoot == true)
    #expect(messages.first(where: { $0.id == "om_root_2" })?.isThreadRoot == true)
    #expect(messages.first(where: { $0.id == "om_reply_shape" })?.isThreadRoot == false)

    async let first: Void = model.loadThreadReplies(for: "om_root_1")
    async let duplicate: Void = model.loadThreadReplies(for: "om_root_2")
    _ = await (first, duplicate)

    #expect(try fixture.requestCount() == 1)
    await model.loadThreadReplies(for: "om_root_1")
    await model.loadThreadReplies(for: "om_root_2")
    #expect(try fixture.requestCount() == 1)

    guard case let .messages(_, _, hydrated, _) = model.state else {
        Issue.record("Expected hydrated message preview")
        return
    }
    let firstRoot = try #require(hydrated.first(where: { $0.id == "om_root_1" }))
    let secondRoot = try #require(hydrated.first(where: { $0.id == "om_root_2" }))
    #expect(firstRoot.threadRepliesLoaded)
    #expect(secondRoot.threadRepliesLoaded)
    #expect(firstRoot.threadReplies.map(\.id) == ["om_reply"])
}

@Test @MainActor func dismissCancelsAnUnfinishedLazyThreadRequest() async throws {
    let fixture = try ThreadLoadingFixture(threadDelaySeconds: 10)
    defer { fixture.remove() }
    let model = PeekModel(defaults: fixture.defaults, workingDirectory: fixture.directory)
    await model.peek(fixture.conversation)

    let startedAt = Date()
    let task = Task { await model.loadThreadReplies(for: "om_root_1") }
    try await fixture.waitUntilThreadRequestStarts()
    model.dismiss()
    await task.value

    #expect(Date().timeIntervalSince(startedAt) < 3)
    #expect(try fixture.requestCount() == 1)
    #expect(model.state == .waiting)
}

@MainActor
private struct ThreadLoadingFixture {
    let directory: URL
    let counter: URL
    let marker: URL
    let suiteName: String
    let defaults: UserDefaults

    let conversation = HoveredConversation(
        name: "Lazy Group",
        rowFrame: .zero,
        rowTexts: ["Lazy Group", "19:19", "Alice: latest message"]
    )

    init(threadDelaySeconds: Int) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PeekModelThreadLoadingTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        counter = directory.appendingPathComponent("thread-count")
        marker = directory.appendingPathComponent("thread-started")
        try Data().write(to: counter)

        let cli = directory.appendingPathComponent("lark-cli")
        let script = """
        #!/bin/sh
        case " $* " in
          *" +chat-list "*)
            printf '%s' '{"ok":true,"data":{"chats":[{"chat_id":"oc_lazy","name":"Lazy Group","chat_mode":"group"}],"has_more":false}}'
            ;;
          *" +chat-messages-list "*)
            printf '%s' '{"ok":true,"data":{"messages":[{"message_id":"om_root_1","chat_id":"oc_lazy","thread_id":"omt_shared","thread_message_position":"-1","sender":{"name":"Alice"},"content":"root one"},{"message_id":"om_root_2","chat_id":"oc_lazy","thread_id":"omt_shared","thread_message_position":"-1","sender":{"name":"Bob"},"content":"duplicate root"},{"message_id":"om_reply_shape","chat_id":"oc_lazy","thread_id":"omt_reply_only","thread_message_position":"0","sender":{"name":"Carol"},"content":"reply-shaped"}],"has_more":false}}'
            ;;
          *" +threads-messages-list "*)
            printf 'x\n' >> '\(counter.path)'
            : > '\(marker.path)'
            if [ \(threadDelaySeconds) -gt 0 ]; then exec /bin/sleep \(threadDelaySeconds); fi
            printf '%s' '{"ok":true,"data":{"messages":[{"message_id":"om_reply","chat_id":"oc_lazy","thread_id":"omt_shared","thread_message_position":"0","sender":{"name":"Carol"},"content":"loaded reply"}],"has_more":false}}'
            ;;
          *)
            printf '%s' '{"ok":false,"error":{"type":"unexpected","message":"unexpected command"}}' >&2
            exit 1
            ;;
        esac
        """
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        suiteName = "PeekModelThreadLoadingDefaults-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(cli.path, forKey: "selectedLarkCLIPath")
    }

    func requestCount() throws -> Int {
        let data = try Data(contentsOf: counter)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").count
    }

    func waitUntilThreadRequestStarts() async throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: marker.path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Thread request did not start")
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
