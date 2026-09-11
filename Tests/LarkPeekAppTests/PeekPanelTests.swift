import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import LarkPeekCore
import ImageIO
import UniformTypeIdentifiers
@testable import LarkPeek

@Suite(.serialized) @MainActor
struct PeekPanelTests {
    @Test(arguments: [false, true])
    func runtimeAuthorizationPromptRendersInThePanel(initialFailure: Bool) async throws {
        _ = NSApplication.shared
        let model = PeekModel()
        let controller = PeekPanelController(model: model)
        if initialFailure { model.presentError("登录凭证已过期") }
        else { model.showPreviewFixture() }
        model.handleAuthorizationFailure(.authorization(message: "登录凭证已过期", missingScopes: []))
        controller.show(anchor: CGRect(x: 50, y: 100, width: 300, height: 60), triggerID: "auth-test")
        controller.setPinned(true)
        defer { controller.close() }
        try await Task.sleep(for: .milliseconds(500))
        let host = try #require(controller.window.contentView)
        host.layoutSubtreeIfNeeded()
        controller.window.displayIfNeeded()
        #expect(model.authStatus.state == .needsLogin)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let filename = initialFailure ? "lark-peek-initial-authorization.png" : "lark-peek-runtime-authorization.png"
        try png.write(to: URL(fileURLWithPath: "/tmp/" + filename))
    }

    @Test func presentationScaleKeepsTheMouseStationaryWithTheActualHostingLayerAnchor() async throws {
        _ = NSApplication.shared
        let model = PeekModel()
        let controller = PeekPanelController(model: model)
        let cursor = CGPoint(x: 150, y: 500)
        model.showPreviewFixture()
        controller.show(anchor: CGRect(x: 50, y: 100, width: 300, height: 60), triggerID: "pivot-test", cursorLocation: cursor)
        let window = controller.window
        let host = try #require(window.contentView)
        host.layoutSubtreeIfNeeded()
        let layer = try #require(host.layer)
        layer.transform = CATransform3DIdentity
        let localCursor = host.convertToLayer(host.convert(window.convertPoint(fromScreen: cursor), from: nil))
        // Let Core Animation perform the actual transform around AppKit's backing-layer anchor.
        let parent = CALayer()
        let probe = CALayer()
        probe.bounds = layer.bounds
        probe.position = layer.position
        probe.anchorPoint = layer.anchorPoint
        probe.isGeometryFlipped = layer.isGeometryFlipped
        parent.addSublayer(probe)
        let before = probe.convert(localCursor, to: parent)
        probe.transform = controller.presentationTransform()
        let after = probe.convert(localCursor, to: parent)
        #expect(abs(after.x - before.x) <= 0.01)
        #expect(abs(after.y - before.y) <= 0.01)
        // The card must be exactly one fifth its size around that fixed point.
        let corner = CGPoint(x: localCursor.x + 100, y: localCursor.y + 150)
        let scaled = probe.convert(corner, to: parent)
        #expect(abs(abs(scaled.x - after.x) - 20) <= 0.01)
        #expect(abs(abs(scaled.y - after.y) - 30) <= 0.01)
        controller.close()
        try await Task.sleep(for: .milliseconds(300))
    }

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
        let window = controller.window
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
        for _ in 0..<100 where model.isPresentingPreview {
            try await Task.sleep(for: .milliseconds(10))
            await layout()
        }
        #expect(!model.isPresentingPreview)
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
        // Exercise actual fly-out/fly-in, including the cached bottom flag.
        for atBottom in [false, true] {
            let currentScroll = try #require(collection(in: host)?.enclosingScrollView)
            let bottomY = max(0, (currentScroll.documentView?.frame.height ?? 0) - currentScroll.contentView.bounds.height)
            currentScroll.contentView.scroll(to: CGPoint(x: 0, y: atBottom ? bottomY : 340))
            currentScroll.reflectScrolledClipView(currentScroll.contentView)
            let original = try #require(model.readingState.position)
            #expect(original.isAtBottom == atBottom)
            for _ in 0..<3 {
                let beforeClose = model.readingState.position
                controller.close()
                try await Task.sleep(for: .milliseconds(300))
                #expect(model.readingState.position == beforeClose, "Closing animation cannot rewrite the cached anchor")
                controller.show(anchor: CGRect(x: 50, y: 100, width: 300, height: 60), triggerID: "reopen-test")
                await model.peek(a)
                var openingBounds: CGRect?
                for _ in 0..<150 {
                    await layout()
                    if let bounds = collection(in: host)?.enclosingScrollView?.contentView.bounds {
                        if let openingBounds {
                            #expect(abs(bounds.width - openingBounds.width) <= 0.01)
                            #expect(abs(bounds.height - openingBounds.height) <= 0.01)
                            #expect(abs(bounds.minY - openingBounds.minY) <= 0.5)
                        } else {
                            openingBounds = bounds
                        }
                    }
                    if !model.isPresentingPreview { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(!model.isPresentingPreview)
                try await Task.sleep(for: .milliseconds(80))
                await layout()
                let reopened = try #require(model.readingState.position)
                #expect(reopened.isAtBottom == original.isAtBottom)
                if !atBottom {
                    #expect(reopened.messageID == original.messageID)
                    #expect(abs(reopened.screenY - original.screenY) <= 0.5)
                }
            }
        }
        controller.close()
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test func searchNavigationKeepsLargeTimelineGeometryStable() async throws {
        _ = NSApplication.shared
        let model = PeekModel()
        model.showPreviewFixture()
        let chat = try #require(model.timeline.chat)
        let conversation = try #require(model.timeline.conversation)
        let messages = (0..<250).map { index in
            LarkMessage(id: "om_navigation_\(index)", chatID: chat.id, createTime: Date(timeIntervalSince1970: Double(index)),
                sender: MessageSender(name: "测试同事"), content: "第 \(index) 条消息：" + String(repeating: "搜索切换时保持阅读位置。", count: 5))
        }
        model.timeline.install(conversation: conversation, chat: chat, messages: messages, cursor: nil, sessionID: model.timeline.id)
        let controller = PeekPanelController(model: model)
        controller.show(anchor: CGRect(x: 50, y: 100, width: 300, height: 60), triggerID: "search-geometry")
        let host = try #require(controller.window.contentView)
        func layout() {
            host.layoutSubtreeIfNeeded()
            controller.window.displayIfNeeded()
        }
        func collection(in view: NSView) -> NSCollectionView? {
            if let collection = view as? NSCollectionView { return collection }
            return view.subviews.lazy.compactMap { collection(in: $0) }.first
        }
        layout()
        try await Task.sleep(for: .milliseconds(700))
        layout()
        let list = try #require(collection(in: host))
        let scroll = try #require(list.enclosingScrollView)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 340))
        scroll.reflectScrolledClipView(scroll.contentView)
        let bounds = scroll.contentView.bounds
        let position = model.readingState.position
        for _ in 0..<2 {
            controller.showSearch(currentChat: chat, anchor: .zero)
            for _ in 0..<25 {
                layout()
                #expect(scroll.contentView.bounds == bounds)
                try await Task.sleep(for: .milliseconds(16))
            }
            controller.goBack()
            for _ in 0..<25 {
                layout()
                #expect(scroll.contentView.bounds == bounds)
                try await Task.sleep(for: .milliseconds(16))
            }
            #expect(collection(in: host) === list)
            #expect(model.readingState.position == position)
        }
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
        let window = controller.window
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
        let window = controller.window
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

    @Test func scanningMovesTheCardToTheNewRowAndPinningPreservesTheSession() async throws {
        _ = NSApplication.shared
        let model = PeekModel()
        let controller = PeekPanelController(model: model)
        controller.showPreviewFixture(anchor: CGRect(x: 50, y: 100, width: 300, height: 60))
        for _ in 0..<100 where model.isPresentingPreview {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.isPresentingPreview)
        let initialFrame = controller.frame
        let sessionID = model.timeline.id
        controller.show(anchor: CGRect(x: 50, y: 200, width: 300, height: 60), triggerID: "switch")
        #expect(controller.frame == initialFrame)
        try await Task.sleep(for: .milliseconds(70))
        let intermediateFrame = controller.frame
        #expect(intermediateFrame.origin != initialFrame.origin)
        #expect(controller.contains(CGPoint(x: intermediateFrame.midX, y: intermediateFrame.midY)))
        try await Task.sleep(for: .milliseconds(300))
        let switchedFrame = controller.frame
        #expect(intermediateFrame.origin != switchedFrame.origin)
        #expect(switchedFrame.origin != initialFrame.origin)
        #expect(switchedFrame.size == initialFrame.size)
        #expect(controller.isVisible)
        #expect(!model.isPresentingPreview)
        controller.show(anchor: CGRect(x: 50, y: 100, width: 300, height: 60), triggerID: "reverse")
        try await Task.sleep(for: .milliseconds(70))
        let interruptedFrame = controller.frame
        controller.show(anchor: CGRect(x: 50, y: 200, width: 300, height: 60), triggerID: "retarget")
        #expect(controller.frame == interruptedFrame)
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(controller.frame.minY - switchedFrame.minY) < 0.01)
        controller.setPinned(true)
        #expect(controller.isPinned)
        #expect(controller.frame == switchedFrame)
        #expect(model.timeline.id == sessionID)
        #expect(controller.contains(CGPoint(x: switchedFrame.midX, y: switchedFrame.midY)))
        let window = controller.window
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
