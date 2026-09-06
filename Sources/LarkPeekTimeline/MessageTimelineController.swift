import AppKit
import LarkPeekCore
import QuartzCore
import SwiftUI

@MainActor
public final class MessageTimelineController: NSViewController, NSCollectionViewDataSource {
    let scrollView = TimelineScrollView()
    let collectionView = TimelineCollectionView()
    let timelineLayout = MessageTimelineLayout()
    private var rows: [TimelineRow] = []
    private var requestedRows: [TimelineRow] = []
    private var sessionID: UUID?
    private var requestedSessionID: UUID?
    private var measuredWidth: CGFloat = 0
    private var measuredViewportHeight: CGFloat = 0
    private var measuredScale: CGFloat = 0
    private var heights: [String: (version: AnyHashable, height: CGFloat)] = [:]
    private var applying = false
    private var interactionAnchor: String?
    private var interactionRevision = 0
    private var appliedInteractionRevision = 0
    private let measurementView = NSHostingView(rootView: AnyView(EmptyView()))
    public var onLoadOlder: (() -> Void)?

    public override func loadView() {
        view = NSView()
        scrollView.drawsBackground = false
        // Keep the preview's margins symmetric regardless of the system scroller preference.
        // Wheel, trackpad and keyboard scrolling are handled by TimelineScrollView.
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.collectionViewLayout = timelineLayout
        collectionView.dataSource = self
        collectionView.register(TimelineItem.self, forItemWithIdentifier: TimelineItem.identifier)
        scrollView.documentView = collectionView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        // Measurement uses the same inherited appearance and SwiftUI environment as display.
        measurementView.isHidden = true
        measurementView.sizingOptions = [.intrinsicContentSize]
        view.addSubview(measurementView)
        scrollView.onUpwardInput = { [weak self] in
            guard let self, !self.applying, self.sessionID != nil,
                  self.scrollView.contentView.bounds.minY <= 24 else { return }
            self.onLoadOlder?()
        }
    }

    public func update(sessionID: UUID, rows: [TimelineRow], interactionAnchor: String? = nil, interactionRevision: Int = 0) {
        requestedSessionID = sessionID
        requestedRows = rows
        self.interactionAnchor = interactionAnchor
        self.interactionRevision = interactionRevision
        loadViewIfNeeded()
        applyPendingRows()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        applyPendingRows()
    }

    private func applyPendingRows() {
        guard !applying, let requestedSessionID else { return }
        let width = scrollView.contentView.bounds.width
        let viewportHeight = scrollView.contentView.bounds.height
        guard width > 28, viewportHeight > 0 else { return }
        let newSession = sessionID != requestedSessionID
        let scale = view.window?.backingScaleFactor ?? 2
        let resized = measuredWidth != width || measuredViewportHeight != viewportHeight || measuredScale != scale
        let changed = newSession || resized || rows.count != requestedRows.count
            || zip(rows, requestedRows).contains { $0.id != $1.id || $0.version != $1.version }
        guard changed else {
            // Keep current actions even when only closure captures changed.
            rows = requestedRows
            return
        }
        applying = true
        defer { applying = false }
        if newSession || measuredWidth != width || measuredScale != scale { heights.removeAll() }

        let newRows = requestedRows
        let rowWidth = width - 28
        let newHeights = newRows.map { row -> CGFloat in
            if let cached = heights[row.id], cached.version == row.version { return cached.height }
            measurementView.rootView = AnyView(row.content.frame(width: rowWidth).fixedSize(horizontal: false, vertical: true))
            measurementView.frame = CGRect(x: 0, y: 0, width: rowWidth, height: 1)
            measurementView.layoutSubtreeIfNeeded()
            let height = max(1, ceil(measurementView.intrinsicContentSize.height * scale) / scale)
            heights[row.id] = (row.version, height)
            return height
        }

        // Capture immediately before committing, after measurement, never before a network await.
        let oldOrigin = scrollView.contentView.bounds.origin
        let oldIDs = rows.map(\.id)
        let newIDs = newRows.map(\.id)
        let newIDSet = Set(newIDs)
        let explicitAnchor = interactionRevision != appliedInteractionRevision
            ? interactionAnchor.flatMap { oldIDs.firstIndex(of: $0) } : nil
        let anchorIndex = explicitAnchor ?? timelineLayout.frames.indices.first {
            timelineLayout.frames[$0].maxY > oldOrigin.y && newIDSet.contains(oldIDs[$0])
                && !oldIDs[$0].hasPrefix("timeline-")
        }
        let anchor = anchorIndex.map { (id: oldIDs[$0], screenY: timelineLayout.frames[$0].minY - oldOrigin.y) }
        let isPrepend = oldIDs.first(where: { !$0.hasPrefix("timeline-") })
            != newIDs.first(where: { !$0.hasPrefix("timeline-") }) && !newSession

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        timelineLayout.prepare(heights: newHeights, width: width, viewportHeight: viewportHeight)
        var targetY = oldOrigin.y
        if newSession {
            targetY = timelineLayout.collectionViewContentSize.height - viewportHeight
        } else if let anchor, let index = newIDs.firstIndex(of: anchor.id) {
            targetY = timelineLayout.frames[index].minY - anchor.screenY
        }
        targetY = max(0, min(targetY, timelineLayout.collectionViewContentSize.height - viewportHeight))
        timelineLayout.updateOrigin = CGPoint(x: 0, y: targetY)
        let oldRows = rows
        rows = newRows
        sessionID = requestedSessionID
        measuredWidth = width
        measuredViewportHeight = viewportHeight
        measuredScale = scale
        appliedInteractionRevision = interactionRevision
        if newSession {
            collectionView.reloadData()
        } else {
            let difference = newIDs.difference(from: oldIDs).inferringMoves()
            let oldByID = Dictionary(uniqueKeysWithValues: oldRows.map { ($0.id, $0.version) })
            let reloaded = Set(newRows.indices.filter {
                oldByID[newRows[$0].id] != nil && (resized || oldByID[newRows[$0].id] != newRows[$0].version)
            }.map { IndexPath(item: $0, section: 0) })
            collectionView.performBatchUpdates {
                for change in difference {
                    switch change {
                    case let .remove(offset, _, associatedWith):
                        if let target = associatedWith {
                            collectionView.moveItem(at: IndexPath(item: offset, section: 0), to: IndexPath(item: target, section: 0))
                        } else {
                            collectionView.deleteItems(at: [IndexPath(item: offset, section: 0)])
                        }
                    case let .insert(offset, _, associatedWith):
                        if associatedWith == nil {
                            collectionView.insertItems(at: [IndexPath(item: offset, section: 0)])
                        }
                    }
                }
            }
            collectionView.reloadItems(at: reloaded)
        }
        timelineLayout.invalidateLayout()
        collectionView.layoutSubtreeIfNeeded()
        // Both geometry and viewport are committed in this display transaction.
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        timelineLayout.updateOrigin = nil
        NSAnimationContext.endGrouping()
        CATransaction.commit()
        heights = heights.filter { newIDSet.contains($0.key) }
        let error = scrollView.contentView.bounds.minY - targetY
        LarkPeekDiagnostics.messageTimeline.info("event=layout_committed rows=\(newRows.count) prepend=\(isPrepend) offsetError=\(Double(error))")
    }

    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    public func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: TimelineItem.identifier, for: indexPath) as! TimelineItem
        item.setContent(rows[indexPath.item].content, id: rows[indexPath.item].id)
        return item
    }
}

@MainActor
final class TimelineItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("MessageTimelineItem")
    private var host: NSHostingView<AnyView>?

    override func loadView() {
        view = NSView()
        view.clipsToBounds = true
    }

    func setContent(_ content: AnyView, id: String) {
        let root = AnyView(content.id(id).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        if let host { host.rootView = root } else {
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            host.autoresizingMask = [.width, .height]
            host.frame = view.bounds
            view.addSubview(host)
            self.host = host
        }
    }
}

@MainActor
final class TimelineScrollView: NSScrollView {
    // NSCollectionView re-enables scrollers when its content or clip bounds change.
    // Indicator visibility is a container policy, not a one-time setup value.
    override var hasVerticalScroller: Bool {
        get { super.hasVerticalScroller }
        set { super.hasVerticalScroller = false }
    }

    override var hasHorizontalScroller: Bool {
        get { super.hasHorizontalScroller }
        set { super.hasHorizontalScroller = false }
    }

    var onUpwardInput: (() -> Void)?
    private var requestedInGesture = false

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        if event.phase.contains(.began) || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            requestedInGesture = false
        }
        super.scrollWheel(with: event)
        if contentView.bounds.minY > 80 { requestedInGesture = false }
        if event.scrollingDeltaY > 0, contentView.bounds.minY <= 24, !requestedInGesture {
            requestedInGesture = true
            onUpwardInput?()
        }
    }

    override func keyDown(with event: NSEvent) {
        let origin = contentView.bounds.origin
        let targetY: CGFloat
        switch event.keyCode {
        case 126: targetY = origin.y - 40
        case 116: targetY = origin.y - contentView.bounds.height
        case 115: targetY = 0
        case 125: targetY = origin.y + 40
        case 121: targetY = origin.y + contentView.bounds.height
        case 119: targetY = documentView?.bounds.height ?? origin.y
        default:
            super.keyDown(with: event)
            return
        }
        let rect = contentView.constrainBoundsRect(CGRect(origin: CGPoint(x: origin.x, y: targetY), size: contentView.bounds.size))
        contentView.scroll(to: rect.origin)
        reflectScrolledClipView(contentView)
        if [126, 116, 115].contains(event.keyCode) { onUpwardInput?() }
    }
}

@MainActor
final class TimelineCollectionView: NSCollectionView {
    override func keyDown(with event: NSEvent) {
        if [126, 116, 115, 125, 121, 119].contains(event.keyCode) {
            enclosingScrollView?.keyDown(with: event)
        } else {
            super.keyDown(with: event)
        }
    }
}
