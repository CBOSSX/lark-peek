import AppKit
import Testing
import LarkPeekCore
@testable import LarkPeek

extension PeekPanelTests {
    @Test func ambiguousTopicsShowDistinctChoicesAndOpenTheChosenRealRoot() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadPanel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "ThreadPanel-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: .now)
        let rootText = "本周接口设计方案已经更新"
        let replyText = "可以参考我给的那个设计文档"
        func row(_ index: Int, reply: Bool) -> [String: Any] {
            ["message_id": "om_\(reply ? "reply" : "root")\(index)", "chat_id": "oc_group\(index)",
             "chat_name": index == 1 ? "产品设计讨论群" : "接口开发协作群", "thread_id": "omt_topic\(index)",
             "thread_message_position": reply ? "0" : "-1", "sender": ["name": reply ? "李四" : "张三"],
             "content": reply ? replyText : rootText, "create_time": date + (reply ? " 16:46" : " 16:41")]
        }
        func write(_ name: String, _ rows: [[String: Any]]) throws {
            try JSONSerialization.data(withJSONObject: ["ok": true, "data": ["messages": rows, "has_more": false]])
                .write(to: directory.appendingPathComponent(name))
        }
        try write("search.json", [row(1, reply: false), row(2, reply: false), row(1, reply: true), row(2, reply: true)])
        try write("roots.json", [row(1, reply: false), row(2, reply: false)])
        try write("reply1.json", [row(1, reply: true)])
        try write("reply2.json", [row(2, reply: true)])
        let cli = directory.appendingPathComponent("lark-cli")
        let script = """
        #!/bin/sh
        case " $* " in
          *" +messages-search "*) /bin/cat '\(directory.path)/search.json' ;;
          *" +messages-mget "*) /bin/cat '\(directory.path)/roots.json' ;;
          *" --thread omt_topic1 "*) /bin/cat '\(directory.path)/reply1.json' ;;
          *" --thread omt_topic2 "*) /bin/cat '\(directory.path)/reply2.json' ;;
          *) exit 1 ;;
        esac
        """
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        defaults.set(cli.path, forKey: "selectedLarkCLIPath")
        let model = PeekModel(defaults: defaults, workingDirectory: directory)
        let conversation = HoveredConversation(name: "张三: " + rootText, rowFrame: .zero,
            rowTexts: ["张三: " + rootText, "16:46", "李四: " + replyText], hasThreadAvatar: true)
        await model.peek(conversation)
        guard case let .threadCandidates(_, candidates, complete) = model.state else {
            Issue.record("Expected ambiguity, got \(model.state)"); return
        }
        #expect(complete)
        #expect(candidates.count == 2)
        let controller = PeekPanelController(model: model)
        controller.show(anchor: CGRect(x: 80, y: 120, width: 350, height: 60), triggerID: "thread-choice-test")
        defer { controller.close() }
        let window = try #require(NSApp.windows.first { $0.title == "Lark Peek" && $0.isVisible })
        for _ in 0..<8 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let host = try #require(window.contentView)
        let rect = host.convert(window.convertFromScreen(controller.frame), from: nil)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: rect))
        host.cacheDisplay(in: rect, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/larkpeek-thread-candidates.png"))
        await model.selectThread(candidates[1], conversation: conversation)
        guard case let .messages(_, chat, messages, _) = model.state else {
            Issue.record("Expected chosen thread"); return
        }
        #expect(chat.id == candidates[1].chat.id)
        #expect(messages.first?.id == candidates[1].root.id)
        #expect(messages.first?.threadReplies.first?.threadID == candidates[1].root.threadID)
    }
}
