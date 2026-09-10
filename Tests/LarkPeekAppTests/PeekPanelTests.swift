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
        controller.showSearchResult()
        #expect(!controller.isSearching && controller.canGoBack)
        controller.goBack()
        #expect(controller.isSearching && controller.canGoBack)
        #expect(search.hits.count == 1)
        controller.goBack()
        #expect(!controller.isSearching)
        #expect(model.timeline.id == sessionID)
        #expect(search.hits.isEmpty)
        #expect(!controller.canGoBack)
        controller.goBack()
        #expect(!controller.isSearching)
        controller.close()
        try await Task.sleep(for: .milliseconds(300))
        #expect(search.hits.isEmpty && !search.hasSearched)
        #expect(search.query.isEmpty)
        #expect(!window.isVisible)
    }

    @Test func searchContextLoadsBothSidesThenAnchorsAndReturnsToTheOriginalChat() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PeekContextUI-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "PeekContextUI-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        for (name, indexes) in [("before", -10..<0), ("after", 1..<11), ("later", 11..<21)] {
            let messages: [[String: Any]] = indexes.map { index in
                ["message_id": "om_context_\(index)", "create_time": "\((1_700_000_000 + index * 60) * 1000)",
                 "content": index < 0 ? "命中之前的消息 \(index)" : "命中之后的消息 \(index)", "sender": ["name": "测试同事"]]
            }
            try JSONSerialization.data(withJSONObject: ["data": ["messages": messages, "has_more": name == "after", "page_token": name == "after" ? "later" : ""]])
                .write(to: directory.appendingPathComponent("\(name).json"))
        }
        let cli = directory.appendingPathComponent("lark-cli")
        let script = """
        #!/bin/sh
        case " $* " in
          *" +chat-messages-list "*)
            sleep 0.15
            case " $* " in
              *" --page-token later "*) /bin/cat '\(directory.path)/later.json' ;;
              *" --order asc "*) /bin/cat '\(directory.path)/after.json' ;;
              *) /bin/cat '\(directory.path)/before.json' ;;
            esac ;;
          *) exit 1 ;;
        esac
        """
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        defaults.set(cli.path, forKey: "selectedLarkCLIPath")
        let model = PeekModel(defaults: defaults, workingDirectory: directory)
        let controller = PeekPanelController(model: model)
        controller.showPreviewFixture(anchor: CGRect(x: 50, y: 100, width: 300, height: 60))
        try await Task.sleep(for: .milliseconds(700))
        let original = try #require(model.timeline.chat)
        let originalIDs = model.timeline.messages.map(\.id)
        controller.showSearch(currentChat: original, anchor: .zero)
        let hit = MessageSearchHit(message: LarkMessage(id: "om_context_hit", chatID: "oc_context",
            createTime: Date(timeIntervalSince1970: 1_700_000_000), sender: MessageSender(name: "测试同事"),
            content: "这条是搜索命中的消息"), chat: LarkChat(id: "oc_context", name: "上下文测试", kind: .group))
        let contextSessionID = controller.prepareSearchResult(hit)
        // No asynchronous hop may expose the old conversation before loading begins.
        guard case .loading = model.state else { Issue.record("Old messages exposed when leaving search"); return }
        #expect(model.timeline.messages.isEmpty)
        #expect(!controller.isSearching)
        let task = Task { await model.loadSearchContext(hit, sessionID: contextSessionID) }
        try await Task.sleep(for: .milliseconds(100))
        guard case .loading = model.state else { Issue.record("Context should stay loading until both sides arrive"); return }
        #expect(model.timeline.messages.isEmpty)
        let window = try #require(NSApp.windows.first { $0.title == "Lark Peek" && $0.isVisible })
        let host = try #require(window.contentView)
        let destination = try #require(CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: "/tmp/lark-peek-search-context.gif") as CFURL, UTType.gif.identifier as CFString, 10, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        func capture() throws {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let rect = host.convert(window.convertFromScreen(controller.frame), from: nil)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: rect))
            host.cacheDisplay(in: rect, to: bitmap)
            let image = try #require(bitmap.cgImage)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/lark-peek-search-context.png"))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.06]] as CFDictionary)
        }
        try capture()
        await task.value
        for _ in 0..<9 {
            try capture()
            try await Task.sleep(for: .milliseconds(60))
        }
        #expect(CGImageDestinationFinalize(destination))
        #expect(model.timeline.messages.count == 21)
        func collection(in view: NSView) -> NSCollectionView? {
            if let collection = view as? NSCollectionView { return collection }
            return view.subviews.lazy.compactMap { collection(in: $0) }.first
        }
        let list = try #require(collection(in: host))
        let scroll = try #require(list.enclosingScrollView)
        let hitIndex = try #require(model.timeline.messages.firstIndex { $0.id == hit.id }) + 1
        let frame = try #require(list.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: hitIndex, section: 0))).frame
        #expect(abs(frame.minY - scroll.contentView.bounds.minY - 100) <= 1)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: list.bounds.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
        scroll.keyDown(with: down)
        for _ in 0..<100 {
            if model.timeline.messages.count == 31 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.timeline.messages.count == 31)
        controller.goBack()
        #expect(controller.isSearching && controller.canGoBack)
        controller.goBack()
        for _ in 0..<100 {
            if model.timeline.chat?.id == original.id { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!controller.isSearching && !controller.canGoBack)
        #expect(model.timeline.chat?.id == original.id)
        #expect(model.timeline.messages.map(\.id) == originalIDs)
        controller.goBack()
        #expect(!controller.isSearching)
        controller.close()
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test func globalSearchIsTheNavigationRoot() async throws {
        _ = NSApplication.shared
        let controller = PeekPanelController(model: PeekModel())
        controller.showSearch(currentChat: nil, anchor: CGRect(x: 50, y: 100, width: 300, height: 60))
        #expect(controller.isSearching && !controller.canGoBack)
        controller.showSearchResult()
        #expect(!controller.isSearching && controller.canGoBack)
        controller.goBack()
        #expect(controller.isSearching && !controller.canGoBack)
        controller.goBack()
        #expect(controller.isSearching && !controller.canGoBack)
        controller.close()
        try await Task.sleep(for: .milliseconds(300))
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
