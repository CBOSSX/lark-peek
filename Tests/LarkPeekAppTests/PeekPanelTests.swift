import AppKit
import SwiftUI
import Testing
import LarkPeekCore
import ImageIO
import UniformTypeIdentifiers
@testable import LarkPeek

@Suite(.serialized) @MainActor
struct PeekPanelTests {
    @Test func fastCachedReturnRestoresReadingPositionInTheActualPanel() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PeekPanelCache-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "PeekPanelCache-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        for name in ["a", "b"] {
            let messages: [[String: Any]] = (0..<20).map { index in
                ["message_id": "om_\(name)_\(index)", "create_time": "\(1_700_000_000 + index)",
                 "content": String(repeating: "第 \(index) 条消息的阅读内容。", count: 6), "sender": ["name": "测试发送者"]]
            }
            try JSONSerialization.data(withJSONObject: ["ok": true, "data": ["messages": messages, "has_more": false]])
                .write(to: directory.appendingPathComponent("\(name).json"))
        }
        let cli = directory.appendingPathComponent("lark-cli")
        let script = """
        #!/bin/sh
        case " $* " in
          *" +chat-list "*) printf '%s' '{"ok":true,"data":{"chats":[{"chat_id":"oc_a","name":"甲群"},{"chat_id":"oc_b","name":"乙群"}],"has_more":false}}' ;;
          *" --chat-id oc_a "*) /bin/cat '\(directory.path)/a.json' ;;
          *" --chat-id oc_b "*) /bin/cat '\(directory.path)/b.json' ;;
          *) exit 1 ;;
        esac
        """
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        defaults.set(cli.path, forKey: "selectedLarkCLIPath")
        let model = PeekModel(defaults: defaults, workingDirectory: directory)
        let controller = PeekPanelController(model: model)
        controller.show(anchor: CGRect(x: 50, y: 100, width: 300, height: 60), triggerID: "cache-test")
        let window = try #require(NSApp.windows.first { $0.title == "Lark Peek" && $0.isVisible })
        func layout() async {
            for _ in 0..<8 {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                await Task.yield()
            }
        }
        func collection(in view: NSView) -> NSCollectionView? {
            if let collection = view as? NSCollectionView { return collection }
            return view.subviews.lazy.compactMap { collection(in: $0) }.first
        }
        let a = HoveredConversation(name: "甲群", rowFrame: .zero, rowTexts: ["甲群"])
        let b = HoveredConversation(name: "乙群", rowFrame: .zero, rowTexts: ["乙群"])
        await model.peek(a)
        await layout()
        let host = try #require(window.contentView)
        let scroll = try #require(collection(in: host)?.enclosingScrollView)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 340))
        scroll.reflectScrolledClipView(scroll.contentView)
        let saved = try #require(model.readingState.position)
        let savedReading = model.readingState
        #expect(!saved.isAtBottom)
        let panelFrame = controller.frame
        let destination = try #require(CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: "/tmp/lark-peek-conversation-switch.gif") as CFURL, UTType.gif.identifier as CFString, 5, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        func captureSwitchFrame(delay: Double) throws {
            let rect = host.convert(window.convertFromScreen(controller.frame), from: nil)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: rect))
            host.cacheDisplay(in: rect, to: bitmap)
            CGImageDestinationAddImage(destination, try #require(bitmap.cgImage),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
            #expect(controller.frame == panelFrame)
        }
        try captureSwitchFrame(delay: 0.6)
        await model.peek(b)
        #expect(savedReading.position == saved, "Position survives the data switch")
        await layout()
        try captureSwitchFrame(delay: 0.06)
        for milliseconds in [60, 70, 140] {
            try await Task.sleep(for: .milliseconds(milliseconds))
            await layout()
            try captureSwitchFrame(delay: milliseconds == 140 ? 0.6 : 0.07)
        }
        #expect(CGImageDestinationFinalize(destination))
        #expect(savedReading.position == saved, "Position survives removal of the previous view")
        await model.peek(a)
        #expect(model.readingState === savedReading)
        #expect(model.readingState.position == saved, "Cached position is intact before mounting")
        await layout()
        #expect(model.isCachedPreview)
        let restored = try #require(model.readingState.position)
        #expect(restored.messageID == saved.messageID)
        #expect(abs(restored.screenY - saved.screenY) <= 1)
        controller.close()
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test func searchResultsRenderAndClosingClearsTheirState() async throws {
        _ = NSApplication.shared
        let chat = LarkChat(id: "oc_qa", name: "周然", kind: .p2p)
        let search = MessageSearchModel { _ in
            MessageSearchPage(hits: [MessageSearchHit(message: LarkMessage(
                id: "om_qa", chatID: chat.id, createTime: Date(timeIntervalSince1970: 1_788_696_000),
                sender: MessageSender(name: "林澈"), content: "发布前请确认：连续预览、固定窗口和消息搜索均已验证。\n检查完成后再发布。"), chat: chat)], nextPageToken: nil)
        }
        let model = PeekModel()
        let controller = PeekPanelController(model: model, search: search)
        controller.showPreviewFixture(anchor: CGRect(x: 50, y: 100, width: 300, height: 60))
        let sessionID = model.timeline.id
        let frame = controller.frame
        let windows = NSApp.windows.filter(\.isVisible).count
        controller.showSearch(currentChat: chat, anchor: .zero)
        #expect(controller.isSearching && controller.isPinned)
        #expect(controller.searchChat == chat)
        #expect(controller.frame == frame)
        #expect(NSApp.windows.filter(\.isVisible).count == windows)
        #expect(model.timeline.id == sessionID)
        search.editQuery("发布")
        search.search("发布")
        for _ in 0..<1000 {
            if !search.isLoading { break }
            await Task.yield()
        }
        #expect(search.hits.count == 1)
        let window = try #require(NSApp.windows.first { $0.title == "Lark Peek" && $0.isVisible })
        let host = try #require(window.contentView)
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await Task.yield()
        }
        let cardRect = host.convert(window.convertFromScreen(controller.frame), from: nil)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: cardRect))
        try await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        host.cacheDisplay(in: cardRect, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/lark-peek-search-preview.png"))
        controller.toggleSearchPage()
        #expect(!controller.isSearching)
        #expect(model.timeline.id == sessionID)
        #expect(search.hits.count == 1)
        controller.toggleSearchPage()
        #expect(controller.isSearching)
        controller.close()
        try await Task.sleep(for: .milliseconds(300))
        #expect(search.hits.isEmpty && !search.hasSearched)
        #expect(search.query.isEmpty)
        #expect(!window.isVisible)
    }

    @Test func scanningKeepsTheCardStationaryAndPinningPreservesTheSession() async throws {
        _ = NSApplication.shared
        let model = PeekModel()
        let controller = PeekPanelController(model: model)
        controller.showPreviewFixture(anchor: CGRect(x: 50, y: 100, width: 300, height: 60))
        await Task.yield()
        let initialFrame = controller.frame
        let sessionID = model.timeline.id
        controller.show(anchor: CGRect(x: 50, y: 200, width: 300, height: 60), triggerID: "switch", preservePosition: true)
        #expect(controller.frame == initialFrame)
        controller.setPinned(true)
        #expect(controller.isPinned)
        #expect(controller.frame == initialFrame)
        #expect(model.timeline.id == sessionID)
        #expect(controller.contains(CGPoint(x: initialFrame.midX, y: initialFrame.midY)))
        let window = try #require(NSApp.windows.first { $0.title == "Lark Peek" && $0.isVisible })
        #expect(!window.styleMask.contains(.resizable))
        #expect(model.timeline.id == sessionID)
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await Task.yield()
        }
        if let host = window.contentView {
            let cardRect = host.convert(window.convertFromScreen(controller.frame), from: nil)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: cardRect))
            host.cacheDisplay(in: cardRect, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/lark-peek-pinned-preview.png"))
        }
        controller.setPinned(false)
        #expect(!controller.isPinned)
        #expect(model.timeline.id == sessionID)
        controller.close()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!controller.isVisible)
    }
}
