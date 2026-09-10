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
    private var initialPosition: TimelineReadingPosition?
    private var keepBottomUntilInteraction = false
    private var heightTransition: TimelineHeightTransition?
    private var heightAnimationTask: Task<Void, Never>?
    var reduceMotionOverride: Bool?
    var isAnimatingExpansion: Bool { heightTransition != nil }
    private let measurementView = NSHostingView(rootView: AnyView(EmptyView()))
    public var onLoadNewer: (() -> Void)?
    public var onLoadOlder: (() -> Void)?
    public var onPositionChange: ((TimelineReadingPosition) -> Void)?

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
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView.onUserInput = { [weak self] in
            self?.keepBottomUntilInteraction = false
            self?.finishExpansionForUserInput()
        }
        scrollView.onUpwardInput = { [weak self] in
            guard let self, !self.applying, self.sessionID != nil,
                  self.scrollView.contentView.bounds.minY <= 24 else { return }
            self.onLoadOlder?()
        }
        scrollView.onDownwardInput = { [weak self] in
            guard let self, !self.applying, self.sessionID != nil,
                  self.scrollView.remainingBelow <= 24 else { return }
            self.onLoadNewer?()
        }
    }

    public func update(sessionID: UUID, rows: [TimelineRow], interactionAnchor: String? = nil, interactionRevision: Int = 0,
                       initialPosition: TimelineReadingPosition? = nil) {
        requestedSessionID = sessionID
        requestedRows = rows
        self.interactionAnchor = interactionAnchor
        self.interactionRevision = interactionRevision
        self.initialPosition = initialPosition
        loadViewIfNeeded()
        applyPendingRows()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        applyPendingRows()
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        cancelHeightAnimation()
    }

    private func applyPendingRows() {
        guard !applying, let requestedSessionID else { return }
        let width = scrollView.contentView.bounds.width
        let viewportHeight = scrollView.contentView.bounds.height
        guard width > 28, viewportHeight > 0, view.window != nil else { return }
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
        if explicitAnchor != nil { keepBottomUntilInteraction = false }
        let anchorIndex = explicitAnchor ?? timelineLayout.frames.indices.first {
            timelineLayout.frames[$0].maxY > oldOrigin.y && newIDSet.contains(oldIDs[$0])
                && !oldIDs[$0].hasPrefix("timeline-")
        }
        let anchor = anchorIndex.map { (id: oldIDs[$0], screenY: timelineLayout.frames[$0].minY - oldOrigin.y) }
        let isPrepend = oldIDs.first(where: { !$0.hasPrefix("timeline-") })
            != newIDs.first(where: { !$0.hasPrefix("timeline-") }) && !newSession
        let oldHeights = timelineLayout.frames.map(\.height)
        let expansionChanged = zip(rows, newRows).contains { $0.expansionVersion != $1.expansionVersion }
        let reduceMotion = reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animateHeight = !reduceMotion && !newSession && !resized && oldIDs == newIDs
            && (explicitAnchor != nil || expansionChanged || heightTransition != nil)
            && zip(oldHeights, newHeights).contains { abs($0 - $1) > 0.5 }
        cancelHeightAnimation()
        if animateHeight {
            heightTransition = TimelineHeightTransition(from: oldHeights, to: newHeights,
                anchorIndex: anchorIndex, anchorScreenY: anchor?.screenY ?? 0, originY: oldOrigin.y)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        timelineLayout.prepare(heights: animateHeight ? oldHeights : newHeights, width: width, viewportHeight: viewportHeight)
        var targetY = oldOrigin.y
        if newSession {
            keepBottomUntilInteraction = initialPosition?.isAtBottom ?? true
            if let initialPosition, !initialPosition.isAtBottom, let index = newIDs.firstIndex(of: initialPosition.messageID) {
                targetY = timelineLayout.frames[index].minY - initialPosition.screenY
            } else {
                targetY = timelineLayout.collectionViewContentSize.height - viewportHeight
            }
        } else if resized && keepBottomUntilInteraction {
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
            if !difference.isEmpty {
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
            }
            if animateHeight {
                for indexPath in reloaded {
                    (collectionView.item(at: indexPath) as? TimelineItem)?.setContent(
                        newRows[indexPath.item].content, id: newRows[indexPath.item].id,
                        height: newHeights[indexPath.item], animate: true)
                }
            } else {
                collectionView.reloadItems(at: reloaded)
            }
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
        saveReadingPosition()
        if let heightTransition { startHeightAnimation(id: heightTransition.id) }
    }

    private func startHeightAnimation(id: UUID) {
        heightAnimationTask = Task { @MainActor [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard let self, self.heightTransition?.id == id else { return }
                let progress = (ProcessInfo.processInfo.systemUptime - start) / 0.24
                self.advanceExpansionAnimation(to: progress)
                if progress >= 1 { return }
            }
        }
    }

    /// Each frame commits interpolated row heights and the reading anchor together.
    func advanceExpansionAnimation(to progress: Double) {
        guard let transition = heightTransition, !applying else { return }
        applying = true
        defer { applying = false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        timelineLayout.prepare(heights: transition.heights(at: progress), width: measuredWidth, viewportHeight: measuredViewportHeight)
        var targetY = transition.originY
        if let index = transition.anchorIndex, timelineLayout.frames.indices.contains(index) {
            targetY = timelineLayout.frames[index].minY - transition.anchorScreenY
        }
        targetY = max(0, min(targetY, timelineLayout.collectionViewContentSize.height - measuredViewportHeight))
        timelineLayout.updateOrigin = CGPoint(x: 0, y: targetY)
        timelineLayout.invalidateLayout()
        collectionView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let t = min(1, max(0, progress))
        for item in collectionView.visibleItems() {
            (item as? TimelineItem)?.setContentTransitionProgress(1 - pow(1 - t, 3))
        }
        timelineLayout.updateOrigin = nil
        NSAnimationContext.endGrouping()
        CATransaction.commit()
        saveReadingPosition()
        if progress >= 1 { cancelHeightAnimation() }
    }

    private func cancelHeightAnimation() {
        heightAnimationTask?.cancel()
        heightAnimationTask = nil
        heightTransition = nil
        for item in collectionView.visibleItems() {
            (item as? TimelineItem)?.setContentTransitionProgress(1)
        }
    }

    private func finishExpansionForUserInput() {
        guard let transition = heightTransition else { return }
        let origin = scrollView.contentView.bounds.minY
        let index = timelineLayout.frames.indices.first { timelineLayout.frames[$0].maxY > origin }
        heightTransition = TimelineHeightTransition(from: transition.from, to: transition.to,
            anchorIndex: index, anchorScreenY: index.map { timelineLayout.frames[$0].minY - origin } ?? 0, originY: origin)
        advanceExpansionAnimation(to: 1)
    }

    @objc private func boundsChanged() {
        guard !applying else { return }
        saveReadingPosition()
    }

    private func saveReadingPosition() {
        let origin = scrollView.contentView.bounds.minY
        guard let index = timelineLayout.frames.indices.first(where: {
            $0 < rows.count && timelineLayout.frames[$0].maxY > origin && !rows[$0].id.hasPrefix("timeline-")
        }) else { return }
        let remaining = timelineLayout.collectionViewContentSize.height - scrollView.contentView.bounds.maxY
        onPositionChange?(TimelineReadingPosition(messageID: rows[index].id,
            screenY: timelineLayout.frames[index].minY - origin, isAtBottom: remaining <= 1))
    }

    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    public func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: TimelineItem.identifier, for: indexPath) as! TimelineItem
        let row = rows[indexPath.item]
        item.setContent(row.content, id: row.id, height: heights[row.id]?.height ?? 1)
        return item
    }
}

@MainActor
final class TimelineItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("MessageTimelineItem")
    private var host: TimelineContentHost?
    private var outgoingHost: TimelineContentHost?

    override func loadView() {
        view = TimelineItemContainer()
        view.clipsToBounds = true
    }

    func setContent(_ content: AnyView, id: String, height: CGFloat, animate: Bool = false) {
        setContentTransitionProgress(1)
        // Keep content at its measured height while the enclosing item reveals/clips it.
        let root = AnyView(content.id(id).frame(maxWidth: .infinity, alignment: .topLeading).frame(height: height, alignment: .topLeading))
        if animate, let host {
            outgoingHost = host
            host.isOutgoing = true
            host.setAccessibilityHidden(true)
            self.host = nil
        }
        if let host {
            host.rootView = root
            host.setFrameSize(CGSize(width: view.bounds.width, height: height))
        } else {
            let host = TimelineContentHost(rootView: root)
            host.sizingOptions = []
            host.autoresizingMask = [.width]
            host.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: height)
            host.alphaValue = outgoingHost == nil ? 1 : 0
            view.addSubview(host)
            self.host = host
        }
    }

    func setContentTransitionProgress(_ progress: Double) {
        guard let outgoingHost else { return }
        host?.alphaValue = progress
        outgoingHost.alphaValue = 1 - progress
        if progress >= 1 {
            outgoingHost.removeFromSuperview()
            self.outgoingHost = nil
        }
    }
}

@MainActor
private final class TimelineItemContainer: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class TimelineContentHost: NSHostingView<AnyView> {
    var isOutgoing = false
    override func hitTest(_ point: NSPoint) -> NSView? { isOutgoing ? nil : super.hitTest(point) }
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

    var onDownwardInput: (() -> Void)?
    var onUpwardInput: (() -> Void)?
    var onUserInput: (() -> Void)?
    private var requestedInGesture = false
    private var requestedNewerInGesture = false
    var remainingBelow: CGFloat { (documentView?.bounds.height ?? 0) - contentView.bounds.maxY }

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        onUserInput?()
        if event.phase.contains(.began) || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            requestedInGesture = false
            requestedNewerInGesture = false
        }
        super.scrollWheel(with: event)
        if contentView.bounds.minY > 80 { requestedInGesture = false }
        if remainingBelow > 80 { requestedNewerInGesture = false }
        if event.scrollingDeltaY < 0, remainingBelow <= 24, !requestedNewerInGesture {
            requestedNewerInGesture = true
            onDownwardInput?()
        }
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
        onUserInput?()
        let rect = contentView.constrainBoundsRect(CGRect(origin: CGPoint(x: origin.x, y: targetY), size: contentView.bounds.size))
        contentView.scroll(to: rect.origin)
        reflectScrolledClipView(contentView)
        if [126, 116, 115].contains(event.keyCode) { onUpwardInput?() }
        if [125, 121, 119].contains(event.keyCode) { onDownwardInput?() }
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
