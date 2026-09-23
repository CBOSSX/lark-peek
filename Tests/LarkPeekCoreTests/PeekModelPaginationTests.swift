import Foundation
import Testing
@testable import LarkPeekCore

@MainActor
struct PeekModelPaginationTests {
    @Test func dismissingDuringInitialBackfillKeepsThePreviewDismissed() async throws {
        let fixture = try PaginationFixture()
        defer { fixture.remove() }
        try fixture.page("initial", ids: [5], next: "p1")
        try fixture.page("p1", ids: [4], next: nil)
        try Data().write(to: fixture.directory.appendingPathComponent("delay-p1"))
        let model = fixture.model()
        let load = Task { await model.peek(fixture.conversation) }
        defer { load.cancel(); model.dismiss() }
        for _ in 0..<200 {
            if (try? fixture.requests().contains("p1")) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try fixture.requests() == ["initial", "p1"])
        #expect(model.timeline.messages.map(\.id) == ["om_5"])
        model.dismiss()
        await load.value
        #expect(model.state == .waiting)
        #expect(model.timeline.messages.isEmpty)
    }

    @Test func shortInitialPagesFillToTwentyUniqueMessagesAndReuseTheCache() async throws {
        let fixture = try PaginationFixture()
        defer { fixture.remove() }
        try fixture.page("initial", ids: [20], next: "p1")
        try fixture.page("p1", ids: [16, 17, 18, 19, 20], next: "p2")
        try fixture.page("p2", ids: Array(1...15), next: "p3")
        let model = fixture.model()
        defer { model.dismiss() }
        await model.peek(fixture.conversation)
        #expect(model.timeline.messages.map(\.id) == (1...20).map { "om_\($0)" })
        #expect(model.timeline.pagination == .ready("p3"))
        #expect(try fixture.requests() == ["initial", "p1", "p2"])
        model.dismiss()
        await model.peek(fixture.conversation)
        #expect(model.isCachedPreview)
        #expect(model.timeline.messages.count == 20)
        #expect(try fixture.requests().count == 3)
    }

    @Test func initialBackfillSkipsEmptyPagesAndStopsAtItsRequestBudget() async throws {
        let fixture = try PaginationFixture()
        defer { fixture.remove() }
        try fixture.page("initial", ids: [10], next: "p1")
        try fixture.page("p1", ids: [], next: "p2")
        try fixture.page("p2", ids: [10], next: "p3")
        try fixture.page("p3", ids: [9], next: "p4")
        try fixture.page("p4", ids: [8], next: "p5")
        try fixture.page("p5", ids: [7], next: nil)
        let model = fixture.model()
        defer { model.dismiss() }
        await model.peek(fixture.conversation)
        #expect(model.timeline.messages.map(\.id) == ["om_8", "om_9", "om_10"])
        #expect(model.timeline.pagination == .ready("p5"))
        #expect(try fixture.requests() == ["initial", "p1", "p2", "p3", "p4"])
        await model.loadOlderMessages()
        #expect(model.timeline.messages.map(\.id) == ["om_7", "om_8", "om_9", "om_10"])
        #expect(model.timeline.pagination == .exhausted)
    }

    @Test func paginationCompletesWhileAnImageRequestIsStillRunning() async throws {
        let fixture = try PaginationFixture()
        defer { fixture.remove() }
        try fixture.page("initial", ids: [5], next: "p1", image: true)
        try fixture.page("p1", ids: [4], next: nil)
        let model = fixture.model()
        defer { model.dismiss() }
        await model.peek(fixture.conversation)
        try await fixture.waitForImageRequest()
        await model.loadOlderMessages()
        #expect(model.timeline.pagination == .exhausted)
        #expect(model.timeline.messages.map(\.id) == ["om_4", "om_5"])
        #expect(model.timeline.messages.last?.images.first?.attempted == false)
    }

    @Test func emptyPagesAreBoundedAndRequireExplicitContinuation() async throws {
        let fixture = try PaginationFixture()
        defer { fixture.remove() }
        try fixture.page("initial", ids: Array(5...24), next: "p1")
        try fixture.page("p1", ids: [5], next: "p2")
        try fixture.page("p2", ids: [], next: "p3")
        try fixture.page("p3", ids: [5], next: "p4")
        try fixture.page("p4", ids: [4], next: nil)
        let model = fixture.model()
        defer { model.dismiss() }
        await model.peek(fixture.conversation)
        await model.loadOlderMessages(automatic: true)
        #expect(model.timeline.pagination == .paused("p4", "本次未读到更早消息"))
        #expect(try fixture.requests() == ["initial", "p1", "p2", "p3"])
        await model.loadOlderMessages(automatic: true)
        #expect(try fixture.requests().count == 4)
        await model.loadOlderMessages()
        #expect(model.timeline.messages.map(\.id) == (4...24).map { "om_\($0)" })
        #expect(model.timeline.pagination == .exhausted)
    }

    @Test func failurePreservesMessagesAndCursorForRetry() async throws {
        let fixture = try PaginationFixture()
        defer { fixture.remove() }
        try fixture.page("initial", ids: [5], next: "p1")
        let model = fixture.model()
        defer { model.dismiss() }
        await model.peek(fixture.conversation)
        guard case let .failed(cursor, _) = model.timeline.pagination else {
            Issue.record("Missing page must produce an explicit failure")
            return
        }
        #expect(cursor == "p1")
        #expect(model.timeline.messages.map(\.id) == ["om_5"])
        try fixture.page("p1", ids: [4], next: nil)
        await model.loadOlderMessages()
        #expect(model.timeline.messages.map(\.id) == ["om_4", "om_5"])
        #expect(model.timeline.pagination == .exhausted)
    }

    @Test func cyclicCursorStopsWithoutClaimingTheHistoryEnded() async throws {
        let fixture = try PaginationFixture()
        defer { fixture.remove() }
        try fixture.page("initial", ids: [5], next: "p1")
        try fixture.page("p1", ids: [], next: "p2")
        try fixture.page("p2", ids: [5], next: "p1")
        let model = fixture.model()
        defer { model.dismiss() }
        await model.peek(fixture.conversation)
        await model.loadOlderMessages()
        guard case .paused(nil, _) = model.timeline.pagination else {
            Issue.record("Cycle must pause, not report exhausted")
            return
        }
        #expect(try fixture.requests() == ["initial", "p1", "p2"])
    }

    @Test func cursorCyclesAcrossSuccessfulRequestsAreAlsoStopped() async throws {
        let fixture = try PaginationFixture()
        defer { fixture.remove() }
        try fixture.page("initial", ids: Array(5...24), next: "p1")
        try fixture.page("p1", ids: [4], next: "p2")
        try fixture.page("p2", ids: [3], next: "p1")
        let model = fixture.model()
        defer { model.dismiss() }
        await model.peek(fixture.conversation)
        await model.loadOlderMessages()
        #expect(model.timeline.pagination == .ready("p2"))
        await model.loadOlderMessages()
        guard case .paused(nil, _) = model.timeline.pagination else {
            Issue.record("Cursor history must span successful requests")
            return
        }
        #expect(model.timeline.messages.map(\.id) == (3...24).map { "om_\($0)" })
    }
}

@MainActor
private struct PaginationFixture {
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    let conversation = HoveredConversation(name: "Pagination", rowFrame: .zero, rowTexts: ["Pagination"])

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaginationFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "PaginationDefaults-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        let script = """
        #!/bin/sh
        case " $* " in
          *" +chat-list "*)
            printf '%s' '{"ok":true,"data":{"chats":[{"chat_id":"oc_pages","name":"Pagination","chat_mode":"group"}],"has_more":false}}'
            ;;
          *" +chat-messages-list "*)
            token=initial
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "--page-token" ]; then shift; token="$1"; fi
              shift
            done
            printf '%s\\n' "$token" >> '\(directory.path)/requests'
            if [ -f '\(directory.path)/delay-'"$token" ]; then /bin/sleep 1; fi
            /bin/cat '\(directory.path)/'"$token".json
            ;;
          *" +messages-resources-download "*)
            : > '\(directory.path)/image-started'
            exec /bin/sleep 10
            ;;
          *) exit 1 ;;
        esac
        """
        let cli = directory.appendingPathComponent("lark-cli")
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        defaults.set(cli.path, forKey: "selectedLarkCLIPath")
    }

    func page(_ token: String, ids: [Int], next: String?, image: Bool = false) throws {
        let messages: [[String: Any]] = ids.map { ["message_id": "om_\($0)", "chat_id": "oc_pages", "msg_type": image ? "image" : "text", "create_time": "\(1_786_400_000_000 + $0)", "content": image ? "[Image: img_test_\($0)]" : "Message \($0)"] }
        var data: [String: Any] = ["messages": messages, "has_more": next != nil]
        if let next { data["page_token"] = next }
        try JSONSerialization.data(withJSONObject: ["ok": true, "data": data]).write(to: directory.appendingPathComponent(token + ".json"))
    }

    func requests() throws -> [String] {
        try String(contentsOf: directory.appendingPathComponent("requests"), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func model() -> PeekModel { PeekModel(defaults: defaults, workingDirectory: directory) }

    func waitForImageRequest() async throws {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("image-started").path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
