import AppKit
import SwiftUI
import Testing
import LarkPeekCore
@testable import LarkPeekTimeline

@Suite(.serialized) @MainActor
struct MessageTimelineTests {
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
