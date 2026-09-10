import AppKit
import SwiftUI
import Testing
import LarkPeekCore
import ImageIO
import UniformTypeIdentifiers
@testable import LarkPeekTimeline

@Suite(.serialized) @MainActor
struct MessageTimelineTests {
    @Test func forwardedAndTopicCardsAnimateTheirRealHeightsWithoutMovingTheHeader() throws {
        let forwarded = LarkMessage(id: "om_forward", chatID: "oc_test", createTime: Date(), sender: MessageSender(name: "Alice"),
            content: "合并消息", forwardedMessages: (0..<5).map {
                ForwardedMessageItem(senderName: "同事 \($0)", content: "这是一条合并转发消息。\n展开时内容逐渐显示，收起时高度平滑回缩。")
            })
        let replies = (0..<5).map { LarkMessage(id: "om_reply_\($0)", chatID: "oc_test", createTime: Date(),
            sender: MessageSender(name: "同事 \($0)"), content: "这里是话题讨论的回复。\n查看时保持标题位置稳定。") }
        let topic = LarkMessage(id: "om_topic", chatID: "oc_test", createTime: Date(), sender: MessageSender(name: "Alice"),
            content: "讨论下一步安排", threadID: "omt_test", threadReplies: replies, threadRepliesLoaded: true)
        for message in [forwarded, topic] {
            let fixture = WindowFixture()
            defer { fixture.close() }
            fixture.controller.reduceMotionOverride = false
            fixture.controller.view.wantsLayer = true
            fixture.controller.view.layer?.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1).cgColor
            func content(expanded: Bool) -> [TimelineRow] {
                let card = MessageContentView(message: message, expandThreadByDefault: false,
                    expandedCards: .constant([message.id: expanded]), replyError: nil,
                    onLoadThreadReplies: {}, onOpenImage: { _ in })
                return rows(0..<5) + [TimelineRow(id: message.id, version: expanded,
                    content: AnyView(card.preferredColorScheme(.dark)), expansionVersion: expanded)] + rows(6..<12)
            }
            fixture.controller.update(sessionID: fixture.id, rows: content(expanded: false))
            fixture.layout()
            fixture.scroll(to: fixture.controller.timelineLayout.frames[5].minY - 40)
            let headerY = fixture.screenY(at: 5)
            let collapsedHeight = fixture.controller.timelineLayout.frames[5].height
            fixture.controller.update(sessionID: fixture.id, rows: content(expanded: true), interactionAnchor: message.id, interactionRevision: 1)
            #expect(fixture.controller.isAnimatingExpansion)
            #expect(fixture.controller.timelineLayout.frames[5].height == collapsedHeight)
            let url = URL(fileURLWithPath: "/tmp/lark-peek-\(message.id)-animation.gif")
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 14, nil))
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            var intermediateHeight: CGFloat = 0
            for progress in [0.0, 0.08, 0.18, 0.32, 0.5, 0.75, 1.0] {
                fixture.controller.advanceExpansionAnimation(to: progress)
                fixture.layout()
                #expect(abs(fixture.screenY(at: 5) - headerY) <= 0.5)
                if progress == 0.5 { intermediateHeight = fixture.controller.timelineLayout.frames[5].height }
                try appendAnimationFrame(fixture.controller.view, to: destination, delay: progress == 1 ? 0.6 : 0.05)
            }
            let expandedHeight = fixture.controller.timelineLayout.frames[5].height
            #expect(collapsedHeight < intermediateHeight && intermediateHeight < expandedHeight)
            #expect(!fixture.controller.isAnimatingExpansion)
            fixture.controller.update(sessionID: fixture.id, rows: content(expanded: false), interactionAnchor: message.id, interactionRevision: 2)
            #expect(fixture.controller.isAnimatingExpansion)
            for progress in [0.0, 0.08, 0.18, 0.32, 0.5, 0.75, 1.0] {
                fixture.controller.advanceExpansionAnimation(to: progress)
                fixture.layout()
                #expect(abs(fixture.screenY(at: 5) - headerY) <= 0.5)
                try appendAnimationFrame(fixture.controller.view, to: destination, delay: progress == 1 ? 0.6 : 0.05)
            }
            #expect(CGImageDestinationFinalize(destination))
            #expect(abs(fixture.controller.timelineLayout.frames[5].height - collapsedHeight) <= 0.5)
        }
    }

    @Test func lateRepliesAnimateAndInterruptedAnimationsCannotRewriteANewSession() {
        let fixture = WindowFixture()
        defer { fixture.close() }
        fixture.controller.reduceMotionOverride = false
        func content(_ loaded: Bool) -> [TimelineRow] {
            rows(0..<10, enlarged: loaded ? 5 : nil).enumerated().map { index, row in
                TimelineRow(id: row.id, version: row.version, content: row.content, expansionVersion: index == 5 ? loaded : false)
            }
        }
        fixture.controller.update(sessionID: fixture.id, rows: content(false))
        fixture.layout()
        fixture.scroll(to: fixture.controller.timelineLayout.frames[5].minY - 40)
        // Lazy replies arrived after expansion; there is no new click/revision.
        fixture.controller.update(sessionID: fixture.id, rows: content(true))
        #expect(fixture.controller.isAnimatingExpansion)
        fixture.controller.advanceExpansionAnimation(to: 0.2)
        let intermediate = fixture.controller.timelineLayout.frames[5].height
        fixture.controller.update(sessionID: fixture.id, rows: content(false), interactionAnchor: "message-5", interactionRevision: 1)
        #expect(fixture.controller.timelineLayout.frames[5].height == intermediate)
        fixture.controller.scrollView.onUserInput?()
        #expect(!fixture.controller.isAnimatingExpansion)
        fixture.controller.update(sessionID: fixture.id, rows: content(true), interactionAnchor: "message-5", interactionRevision: 2)
        #expect(fixture.controller.isAnimatingExpansion)
        fixture.controller.update(sessionID: UUID(), rows: rows(30..<40))
        let frames = fixture.controller.timelineLayout.frames
        fixture.controller.advanceExpansionAnimation(to: 1)
        #expect(!fixture.controller.isAnimatingExpansion)
        #expect(fixture.controller.timelineLayout.frames == frames)
    }

    @Test func reduceMotionUsesImmediateLayoutAndTheTimedAnimationFinishes() async throws {
        let fixture = WindowFixture()
        defer { fixture.close() }
        fixture.controller.reduceMotionOverride = true
        fixture.controller.update(sessionID: fixture.id, rows: rows(0..<10))
        fixture.layout()
        fixture.controller.update(sessionID: fixture.id, rows: rows(0..<10, enlarged: 5), interactionAnchor: "message-5", interactionRevision: 1)
        #expect(!fixture.controller.isAnimatingExpansion)
        let expanded = fixture.controller.timelineLayout.frames[5].height
        fixture.controller.reduceMotionOverride = false
        fixture.controller.update(sessionID: fixture.id, rows: rows(0..<10), interactionAnchor: "message-5", interactionRevision: 2)
        #expect(fixture.controller.isAnimatingExpansion)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!fixture.controller.isAnimatingExpansion)
        #expect(fixture.controller.timelineLayout.frames[5].height < expanded)
    }

    private func appendAnimationFrame(_ view: NSView, to destination: CGImageDestination, delay: Double) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
    }

    @Test func presentationProtectsTheOriginalAnchorUntilCompletionOrUserInput() throws {
        let fixture = WindowFixture()
        defer { fixture.close() }
        let saved = TimelineReadingPosition(messageID: "message-6", screenY: -21, isAtBottom: false)
        var written: TimelineReadingPosition?
        fixture.controller.onPositionChange = { written = $0 }
        fixture.controller.update(sessionID: fixture.id, rows: rows(0..<20), initialPosition: saved, isPresenting: true)
        fixture.layout()
        fixture.scroll(to: 900)
        #expect(abs(fixture.screenY(at: 6) - saved.screenY) <= 0.5)
        #expect(written == nil)
        fixture.controller.update(sessionID: fixture.id, rows: rows(0..<20), initialPosition: saved, isPresenting: false)
        #expect(written?.messageID == saved.messageID)
        #expect(abs(try #require(written).screenY - saved.screenY) <= 0.5)

        let next = UUID()
        fixture.controller.update(sessionID: next, rows: rows(0..<20), initialPosition: saved, isPresenting: true)
        fixture.controller.scrollView.onUserInput?()
        fixture.scroll(to: 900)
        let userPosition = try #require(written)
        fixture.controller.update(sessionID: next, rows: rows(0..<20), initialPosition: saved, isPresenting: false)
        #expect(written == userPosition)
        #expect(abs(fixture.controller.scrollView.contentView.bounds.minY - 900) <= 0.5)
    }

    @Test func cachedConversationRestoresItsOwnAnchorAndExpansionGeometry() throws {
        let fixture = WindowFixture()
        defer { fixture.close() }
        var position: TimelineReadingPosition?
        fixture.controller.onPositionChange = { position = $0 }
        fixture.controller.update(sessionID: fixture.id, rows: rows(0..<20, enlarged: 6))
        fixture.layout()
        fixture.scroll(to: fixture.controller.timelineLayout.frames[6].minY + 210)
        let saved = try #require(position)
        #expect(saved.messageID == "message-6")
        #expect(abs(saved.screenY + 210) < 0.5)
        #expect(!saved.isAtBottom)
        fixture.controller.update(sessionID: UUID(), rows: rows(30..<50))
        fixture.layout()
        fixture.controller.update(sessionID: UUID(), rows: rows(0..<20, enlarged: 6), initialPosition: saved)
        fixture.layout()
        #expect(abs(fixture.screenY(at: 6) - saved.screenY) <= 0.5)
    }

    @Test func cachedBottomStaysAtBottomWhenTheNoticeChangesViewportHeight() {
        let fixture = WindowFixture()
        defer { fixture.close() }
        let saved = TimelineReadingPosition(messageID: "message-19", screenY: -100, isAtBottom: true)
        fixture.controller.update(sessionID: fixture.id, rows: rows(0..<20, enlarged: 19), initialPosition: saved)
        fixture.layout()
        fixture.window.setContentSize(CGSize(width: 420, height: 470))
        fixture.layout()
        #expect(abs(fixture.controller.scrollView.documentVisibleRect.maxY - fixture.controller.timelineLayout.collectionViewContentSize.height) <= 1)
    }

    @Test func indicatorsStayHiddenAfterContentScrollingAndWindowResizing() {
        for style in [NSScroller.Style.legacy, .overlay] {
            let fixture = WindowFixture()
            defer { fixture.close() }
            fixture.controller.scrollView.scrollerStyle = style
            fixture.controller.update(sessionID: fixture.id, rows: rows(0..<20))
            fixture.layout()
            fixture.scroll(to: 100)
            fixture.controller.update(sessionID: fixture.id, rows: rows(-20..<20))
            fixture.window.setContentSize(CGSize(width: 480, height: 550))
            fixture.layout()
            let scroll = fixture.controller.scrollView
            #expect(!scroll.hasVerticalScroller)
            #expect(!scroll.hasHorizontalScroller)
            #expect(scroll.verticalScroller == nil || scroll.verticalScroller?.isHidden == true)
            #expect(abs(scroll.contentView.frame.width - scroll.bounds.width) <= 0.5)
            #expect(scroll.contentView.bounds.minY > 0)
        }
    }

    @Test func actualMessageCardsRenderInTheNativeContainer() async throws {
        _ = NSApplication.shared
        let suite = "TimelineVisualTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PeekModel(defaults: defaults)
        model.showPreviewFixture()
        guard case let .messages(_, _, messages, _) = model.state else { return }
        let host = NSHostingView(rootView: MessageTimelineView(model: model, messages: messages, expandThreadsByDefault: false, onOpenImage: { _ in })
            .preferredColorScheme(.dark)
            .background(Color(red: 0.12, green: 0.13, blue: 0.16)))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 460, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await Task.yield()
        }
        func findCollection(in view: NSView) -> NSCollectionView? {
            if let collection = view as? NSCollectionView { return collection }
            return view.subviews.lazy.compactMap { findCollection(in: $0) }.first
        }
        let collection = try #require(findCollection(in: host))
        let scrollView = try #require(collection.enclosingScrollView)
        #expect(!scrollView.hasVerticalScroller)
        #expect(!scrollView.hasHorizontalScroller)
        #expect(abs(scrollView.contentView.frame.width - scrollView.bounds.width) <= 0.5)
        let layout = try #require(collection.collectionViewLayout as? MessageTimelineLayout)
        #expect(layout.frames.count == messages.count + 1)
        #expect(layout.frames.dropFirst().allSatisfy { $0.height > 30 })
        #expect(collection.visibleItems().count > 0)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/lark-peek-timeline-preview.png"))
    }

    @Test func prependingPreservesThePartiallyVisibleMessageInAWindow() throws {
        let fixture = WindowFixture()
        defer { fixture.close() }
        let original = rows(20..<40)
        fixture.controller.update(sessionID: fixture.id, rows: original)
        fixture.layout()
        let index = 4
        fixture.scroll(to: fixture.controller.timelineLayout.frames[index].minY + 13)
        let before = fixture.screenY(at: index)
        fixture.controller.update(sessionID: fixture.id, rows: rows(0..<40))
        fixture.layout()
        #expect(abs(fixture.screenY(at: index + 20) - before) <= 0.5)
        #expect(fixture.controller.collectionView.numberOfItems(inSection: 0) == 40)
        #expect(fixture.controller.timelineLayout.frames.allSatisfy { $0.height >= 60 })
    }

    @Test func geometryChangesBelowTheReaderDoNotMoveTheViewport() {
        let fixture = WindowFixture()
        defer { fixture.close() }
        fixture.controller.update(sessionID: fixture.id, rows: rows(0..<20))
        fixture.layout()
        fixture.scroll(to: 140)
        let before = fixture.controller.scrollView.contentView.bounds.minY
        fixture.controller.update(sessionID: fixture.id, rows: rows(0..<20, enlarged: 18))
        fixture.layout()
        #expect(abs(fixture.controller.scrollView.contentView.bounds.minY - before) <= 0.5)
    }

    @Test func expandingTheLastCardPreservesItsHeaderInsteadOfFollowingTheBottom() async {
        let fixture = WindowFixture()
        defer { fixture.close() }
        fixture.controller.update(sessionID: fixture.id, rows: rows(0..<10))
        fixture.layout()
        let before = fixture.screenY(at: 9)
        fixture.controller.update(sessionID: fixture.id, rows: rows(0..<10, enlarged: 9), interactionAnchor: "message-9", interactionRevision: 1)
        for _ in 0..<8 {
            fixture.layout()
            #expect(abs(fixture.screenY(at: 9) - before) <= 0.5)
            await Task.yield()
        }
    }

    @Test func mixedInsertionAndUpdatesRemainStableAcrossDisplayPasses() async {
        let fixture = WindowFixture()
        defer { fixture.close() }
        fixture.controller.update(sessionID: fixture.id, rows: rows(20..<40))
        fixture.layout()
        fixture.scroll(to: 100)
        let before = fixture.screenY(at: 2)
        fixture.controller.update(sessionID: fixture.id, rows: rows(0..<40, enlarged: 39))
        for _ in 0..<8 {
            fixture.layout()
            #expect(abs(fixture.screenY(at: 22) - before) <= 0.5)
            if let item = fixture.controller.collectionView.item(at: IndexPath(item: 22, section: 0)) {
                #expect(abs(item.view.frame.minY - fixture.controller.timelineLayout.frames[22].minY) <= 0.5)
            }
            await Task.yield()
        }
    }

    @Test func latestReadingPositionAndShortInitialContentArePreserved() {
        let fixture = WindowFixture()
        defer { fixture.close() }
        fixture.controller.update(sessionID: fixture.id, rows: rows(20..<21))
        fixture.layout()
        #expect(abs(fixture.controller.timelineLayout.frames[0].maxY - 492) <= 1)
        let before = fixture.screenY(at: 0)
        fixture.controller.update(sessionID: fixture.id, rows: rows(0..<21))
        fixture.layout()
        #expect(abs(fixture.screenY(at: 20) - before) <= 0.5)
        fixture.scroll(to: 400)
        let current = fixture.screenY(at: 5)
        fixture.controller.update(sessionID: fixture.id, rows: rows(-20..<21))
        fixture.layout()
        #expect(abs(fixture.screenY(at: 25) - current) <= 0.5)
    }

    @Test func longFirstPageStartsAtTheBottomAndOnlyUserInputLoadsHistory() {
        let fixture = WindowFixture()
        defer { fixture.close() }
        var requests = 0
        fixture.controller.onLoadOlder = { requests += 1 }
        fixture.controller.update(sessionID: fixture.id, rows: rows(0..<20, enlarged: 19))
        fixture.layout()
        #expect(abs(fixture.controller.scrollView.documentVisibleRect.maxY - fixture.controller.timelineLayout.collectionViewContentSize.height) <= 1)
        fixture.scroll(to: 0)
        fixture.controller.update(sessionID: fixture.id, rows: rows(0..<20, enlarged: 0))
        fixture.layout()
        #expect(requests == 0)
        fixture.scroll(to: 0)
        fixture.controller.scrollView.onUpwardInput?()
        #expect(requests == 1)
    }

    @Test func downwardWheelLoadsOnlyAtBottomAndAppendingKeepsTheAnchor() throws {
        let fixture = WindowFixture()
        defer { fixture.close() }
        var requests = 0
        fixture.controller.onLoadNewer = { requests += 1 }
        fixture.controller.update(sessionID: fixture.id, rows: rows(0..<20))
        fixture.layout()
        #expect(requests == 0)
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil,
            units: .pixel, wheelCount: 1, wheel1: -10, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        fixture.scroll(to: 100)
        fixture.controller.scrollView.scrollWheel(with: event)
        #expect(requests == 0)
        fixture.scroll(to: fixture.controller.timelineLayout.collectionViewContentSize.height)
        fixture.controller.scrollView.scrollWheel(with: event)
        #expect(requests == 1)
        let before = fixture.screenY(at: 19)
        fixture.controller.update(sessionID: fixture.id, rows: rows(0..<40))
        fixture.layout()
        #expect(abs(fixture.screenY(at: 19) - before) <= 1)
        #expect(requests == 1)
    }

    @Test func aThousandLoadedMessagesKeepTheVisibleViewCountBounded() throws {
        let fixture = WindowFixture()
        defer { fixture.close() }
        let started = Date()
        fixture.controller.update(sessionID: fixture.id, rows: rows(0..<1000))
        fixture.layout()
        let initialMilliseconds = Date().timeIntervalSince(started) * 1000
        fixture.scroll(to: fixture.controller.timelineLayout.frames[500].minY + 15)
        fixture.layout()
        let before = fixture.screenY(at: 500)
        let prependStarted = Date()
        fixture.controller.update(sessionID: fixture.id, rows: rows(-20..<1000))
        fixture.layout()
        let prependMilliseconds = Date().timeIntervalSince(prependStarted) * 1000
        #expect(abs(fixture.screenY(at: 520) - before) <= 0.5)
        #expect(fixture.controller.collectionView.visibleItems().count < 20)
        let metrics: [String: Any] = [
            "rows": 1020,
            "visibleItems": fixture.controller.collectionView.visibleItems().count,
            "initialMilliseconds": initialMilliseconds,
            "prependMilliseconds": prependMilliseconds,
            "anchorErrorPoints": fixture.screenY(at: 520) - before
        ]
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "/tmp/lark-peek-native-metrics.json"))
    }

    private func rows(_ range: Range<Int>, enlarged: Int? = nil) -> [TimelineRow] {
        range.map { index in
            let height: CGFloat = index == enlarged ? 800 : 60 + CGFloat(abs(index) % 3) * 15
            return TimelineRow(id: "message-\(index)", version: height, content: AnyView(
                Text("消息 \(index) · 原生时间线测试")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: height)
                    .background(Color.blue.opacity(0.15))
            ))
        }
    }
}

@MainActor
private struct WindowFixture {
    let controller = MessageTimelineController()
    let id = UUID()
    let window: NSWindow

    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 420, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 500)
        window.orderFront(nil)
        layout()
    }

    func layout() {
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        window.displayIfNeeded()
    }

    func scroll(to y: CGFloat) {
        controller.scrollView.contentView.scroll(to: CGPoint(x: 0, y: y))
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
    }

    func screenY(at index: Int) -> CGFloat {
        controller.timelineLayout.frames[index].minY - controller.scrollView.contentView.bounds.minY
    }

    func close() { window.close() }
}
