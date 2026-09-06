import AppKit
import LarkPeekCore
import LarkPeekTimeline
import QuartzCore
import SwiftUI

private final class PeekPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that only accepts mouse events inside the card. Clicks landing
/// on the transparent in-flight margin fall through to the windows below.
private final class CardHostingView: NSHostingView<PeekPanelView> {
    /// Interactive rect in view coordinates (the card's frame within the window).
    var interactiveRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveRect.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

/// Drives the fly-in / fly-out presentation animation of the peek panel.
@MainActor
private final class PanelPresentation: ObservableObject {
    @Published var isPresented = false
    /// Offset of the card within the window while the window is enlarged to give
    /// the fly-in animation room to render past the card's resting frame.
    @Published var cardOffset: CGSize = .zero
    /// Unit point (in card coordinates) the card scales from — the cursor position.
    var appearAnchor: UnitPoint = .center
}

@MainActor
final class PeekPanelController {
    static let cardSize = CGSize(width: 480, height: 540)
    /// Transparent margin around the card so the SwiftUI shadow has room to draw.
    static let cardPadding: CGFloat = 18
    /// Extra transparent margin used while the fly-in/out animation is in flight.
    private static let flightPadding: CGFloat = 30

    private let model: PeekModel
    private let panel: PeekPanel
    private let presentation = PanelPresentation()
    private lazy var imagePreviewController = ImagePreviewPanelController()
    private var closeTask: Task<Void, Never>?

    init(model: PeekModel) {
        self.model = model
        panel = PeekPanel(
            contentRect: CGRect(
                x: 0, y: 0,
                width: Self.cardSize.width + Self.cardPadding * 2,
                height: Self.cardSize.height + Self.cardPadding * 2
            ),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The shadow is drawn by SwiftUI inside the content view so it scales
        // together with the fly-in animation.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow

        installContentView()
    }

    private func installContentView() {
        let hostingView = CardHostingView(rootView: PeekPanelView(
            model: model,
            presentation: presentation,
            onClose: { [weak self] in self?.close() },
            onSelect: { [weak model] chat, conversation in
                Task { @MainActor in await model?.select(chat, for: conversation) }
            },
            onRetry: { [weak model] in
                Task { @MainActor in await model?.retryCurrent() }
            },
            onOpenImage: { [weak self] item in self?.showPresentedImage(item) }
        ))
        // The window is resized manually (it stays enlarged to give the fly-in/out
        // animation room to render), so the hosting view must not clamp it to the
        // SwiftUI ideal size.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
    }

    var isVisible: Bool { panel.isVisible }
    /// Screen frame of the visible card (used for click-outside hit testing).
    var frame: CGRect { lastCardFrame }

    private var lastCardFrame: CGRect = .zero
    private var lastTriggerID: String?

    func show(anchor axFrame: CGRect, triggerID: String) {
        dismissPresentedImage()
        closeTask?.cancel()
        closeTask = nil
        lastTriggerID = triggerID
        let cardFrame = CGRect(origin: origin(for: axFrame, panelSize: Self.cardSize), size: Self.cardSize)
        lastCardFrame = cardFrame
        let anchor = cursorPoint(NSEvent.mouseLocation, relativeTo: cardFrame)
        presentation.appearAnchor = anchor
        // The window always covers the card's whole flight path from the cursor,
        // so the animation is never clipped at the window edge. The extra area is
        // transparent and click-through.
        let flight = flightFrame(cardFrame: cardFrame, anchor: anchor)
        panel.setFrame(flight, display: false)
        presentation.cardOffset = cardOffset(of: cardFrame, within: flight)
        updateInteractiveRect()
        LarkPeekDiagnostics.panel.info(
            "event=show_requested trigger=\(triggerID, privacy: .public) alreadyVisible=\(self.panel.isVisible) cardWidth=\(cardFrame.width, format: .fixed(precision: 0)) cardHeight=\(cardFrame.height, format: .fixed(precision: 0)) flightWidth=\(flight.width, format: .fixed(precision: 0)) flightHeight=\(flight.height, format: .fixed(precision: 0))"
        )
        if panel.isVisible {
            presentation.isPresented = true
            LarkPeekDiagnostics.panel.notice(
                "event=show_completed trigger=\(triggerID, privacy: .public) visible=\(self.panel.isVisible) reused=true"
            )
            return
        }
        panel.orderFrontRegardless()
        LarkPeekDiagnostics.panel.notice(
            "event=window_ordered_front trigger=\(triggerID, privacy: .public) visible=\(self.panel.isVisible)"
        )
        // Let the hidden state render for one pass so the fly-in animation plays.
        DispatchQueue.main.async { [presentation] in
            presentation.isPresented = true
            LarkPeekDiagnostics.panel.notice(
                "event=show_completed trigger=\(triggerID, privacy: .public) visible=\(self.panel.isVisible) reused=false"
            )
        }
    }

    func showPreviewFixture(anchor: CGRect) {
        model.showPreviewFixture()
        installContentView()
        show(anchor: anchor, triggerID: "fixture")
    }

    func showError(_ title: String, detail: String, anchor: CGRect, triggerID: String) {
        LarkPeekDiagnostics.panel.error(
            "event=show_error trigger=\(triggerID, privacy: .public) title=\(title, privacy: .private)"
        )
        model.presentError("\(title)：\(detail)")
        show(anchor: anchor, triggerID: triggerID)
    }

    func close(triggerID: String? = nil, reason: String = "panel_control") {
        dismissPresentedImage()
        model.invalidatePreviewRequests()
        let trigger = triggerID ?? lastTriggerID ?? "none"
        guard panel.isVisible, closeTask == nil else {
            LarkPeekDiagnostics.panel.debug(
                "event=close_ignored trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public) visible=\(self.panel.isVisible) closePending=\(self.closeTask != nil)"
            )
            return
        }
        LarkPeekDiagnostics.panel.info(
            "event=close_requested trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public)"
        )
        // The window already covers the flight path, so the fly-out can start
        // immediately — no re-framing, no jump.
        presentation.isPresented = false
        closeTask = Task { @MainActor [weak self] in
            // Wait for the fly-out animation before removing the window.
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self else { return }
            self.panel.orderOut(nil)
            self.presentation.cardOffset = .zero
            self.model.dismiss()
            self.closeTask = nil
            self.lastTriggerID = nil
            LarkPeekDiagnostics.panel.notice(
                "event=close_completed trigger=\(trigger, privacy: .public) visible=\(self.panel.isVisible)"
            )
        }
    }

    @discardableResult
    func dismissPresentedImage() -> Bool {
        imagePreviewController.dismiss()
    }

    func contains(_ point: CGPoint) -> Bool {
        lastCardFrame.contains(point) || imagePreviewController.contains(point)
    }

    private func showPresentedImage(_ item: PresentedImage) {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(lastCardFrame) }) ?? NSScreen.main
        imagePreviewController.show(item, on: screen)
    }

    /// Restricts mouse interaction to the card; the transparent margin around it
    /// lets clicks fall through to the apps below.
    private func updateInteractiveRect() {
        guard let view = panel.contentView as? CardHostingView else { return }
        let windowFrame = panel.frame
        view.interactiveRect = CGRect(
            x: lastCardFrame.minX - windowFrame.minX,
            y: lastCardFrame.minY - windowFrame.minY,
            width: lastCardFrame.width,
            height: lastCardFrame.height
        )
    }

    /// Window frame large enough to contain the card's whole flight path from the
    /// cursor to its resting position, plus room for the shadow.
    private func flightFrame(cardFrame: CGRect, anchor: UnitPoint) -> CGRect {
        let scale: CGFloat = 0.2
        let cursor = CGPoint(
            x: cardFrame.minX + anchor.x * cardFrame.width,
            y: cardFrame.minY + (1 - anchor.y) * cardFrame.height
        )
        let smallOrigin = CGPoint(
            x: scale * cardFrame.minX + (1 - scale) * cursor.x,
            y: scale * cardFrame.minY + (1 - scale) * cursor.y
        )
        let smallRect = CGRect(
            origin: smallOrigin,
            size: CGSize(width: cardFrame.width * scale, height: cardFrame.height * scale)
        )
        return cardFrame.union(smallRect).insetBy(dx: -Self.flightPadding, dy: -Self.flightPadding)
    }

    /// Offset of the card's center from the window's center, in SwiftUI coordinates.
    private func cardOffset(of cardFrame: CGRect, within windowFrame: CGRect) -> CGSize {
        CGSize(
            width: cardFrame.midX - windowFrame.midX,
            height: windowFrame.midY - cardFrame.midY
        )
    }

    /// Cursor position as a unit point in card coordinates. The cursor is usually
    /// outside the card (on the conversation row), so the range is only loosely
    /// clamped — the card should genuinely fly out from the cursor.
    private func cursorPoint(_ cursor: CGPoint, relativeTo cardFrame: CGRect) -> UnitPoint {
        let u = (cursor.x - cardFrame.minX) / cardFrame.width
        let v = 1 - (cursor.y - cardFrame.minY) / cardFrame.height
        return UnitPoint(
            x: min(max(u, -3), 4),
            y: min(max(v, -3), 4)
        )
    }

    private func origin(for axFrame: CGRect, panelSize: CGSize) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let anchor = CGRect(
            x: axFrame.minX,
            y: primaryHeight - axFrame.maxY,
            width: axFrame.width,
            height: axFrame.height
        )
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let preferredRight = anchor.maxX + 10
        let preferredLeft = anchor.minX - panelSize.width - 10
        let x = preferredRight + panelSize.width <= visible.maxX ? preferredRight : max(visible.minX, preferredLeft)
        let desiredY = anchor.maxY - panelSize.height
        let y = min(max(desiredY, visible.minY + 8), visible.maxY - panelSize.height - 8)
        return CGPoint(x: x, y: y)
    }
}

private struct PeekPanelView: View {
    @ObservedObject var model: PeekModel
    @ObservedObject var presentation: PanelPresentation
    let onClose: () -> Void
    let onSelect: (LarkChat, HoveredConversation) -> Void
    let onRetry: () -> Void
    let onOpenImage: (PresentedImage) -> Void

    private let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            content
                .id(stateKey)
                .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
        }
        .animation(.easeOut(duration: 0.16), value: stateKey)
        .frame(width: PeekPanelController.cardSize.width, height: PeekPanelController.cardSize.height)
        .background { glassBackground }
        .clipShape(cardShape)
        .overlay {
            cardShape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.38),
                        Color.white.opacity(0.10),
                        Color.white.opacity(0.03)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
        .shadow(color: .black.opacity(0.30), radius: 12, y: 5)
        // Presentation modifiers apply to the card itself (before the transparent
        // padding is added) so the scale anchor maps exactly to card coordinates.
        .scaleEffect(presentation.isPresented ? 1 : 0.2, anchor: presentation.appearAnchor)
        .opacity(presentation.isPresented ? 1 : 0)
        .blur(radius: presentation.isPresented ? 0 : 14)
        .animation(
            presentation.isPresented
                ? .spring(response: 0.34, dampingFraction: 0.78)
                : .easeIn(duration: 0.18),
            value: presentation.isPresented
        )
        .padding(PeekPanelController.cardPadding)
        // Positions the card inside the enlarged in-flight window. Kept outside
        // the animation modifier so window re-framing never animates.
        .offset(presentation.cardOffset)
        // The card stays centered in the window whatever size the window is.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Frosted-glass gradient: material base, a diagonal light wash, and a soft
    /// accent glow bleeding in from the top edge.
    private var glassBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [
                    Color.white.opacity(0.14),
                    Color.white.opacity(0.03),
                    Color.black.opacity(0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.accentColor.opacity(0.10), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 320
            )
        }
    }

    private var hairline: some View {
        LinearGradient(
            colors: [Color.white.opacity(0.20), Color.white.opacity(0.05)],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
    }

    private var stateKey: String {
        switch model.state {
        case .waiting: "waiting"
        case .loading: "loading"
        case .candidates: "candidates"
        case .messages: "messages"
        case .error: "error"
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "eye.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.blue.gradient)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 12)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.07), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭（Esc）")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .waiting:
            instructionView
        case let .loading(conversation):
            loadingView(conversation)
        case let .candidates(conversation, chats):
            candidateView(conversation, chats: chats)
        case let .messages(conversation, _, messages, _):
            MessageTimelineView(
                model: model,
                messages: messages,
                expandThreadsByDefault: conversation.threadHint != nil,
                onOpenImage: onOpenImage
            )
        case let .error(_, message):
            errorView(message)
        }
    }

    private var instructionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "cursorarrow.motionlines")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse.byLayer, options: .repeating)
            Text("把鼠标停在飞书会话行上")
                .font(.headline)
            Text("长按 ⌥，或按 ⌃⌥P 读取最近消息")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadingView(_ conversation: HoveredConversation) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("正在读取“\(conversation.name)”")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func candidateView(_ conversation: HoveredConversation, chats: [LarkChat]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("发现多个同名会话")
                .font(.headline)
            Text("请选择一次。Lark Peek 只保存匿名映射，不保存消息正文。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(chats) { chat in
                        Button { onSelect(chat, conversation) } label: {
                            HStack(spacing: 11) {
                                Image(systemName: chat.kind == .p2p ? "person.fill" : "person.2.fill")
                                    .frame(width: 28, height: 28)
                                    .background(Color.blue.opacity(0.12), in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(chat.name).font(.system(size: 13, weight: .medium))
                                    Text([chat.kind.label, chat.external ? "外部" : nil].compactMap { $0 }.joined(separator: " · "))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(10)
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .modifier(HoverBackground(cornerRadius: 10))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 13) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("预览失败").font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("重试", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var title: String {
        switch model.state {
        case .waiting: "Lark Peek"
        case let .loading(conversation): conversation.name
        case let .candidates(conversation, _): conversation.name
        case let .messages(_, chat, _, _): chat.name
        case .error: "Lark Peek"
        }
    }

}

private struct ImageLightboxView: View {
    let item: PresentedImage
    @ObservedObject var presentation: ImagePreviewPresentation
    let onDismiss: () -> Void

    private var geometryAnimation: Animation {
        presentation.isExpanded
            ? .spring(response: 0.3, dampingFraction: 0.86, blendDuration: 0.04)
            : .timingCurve(0.4, 0, 0.8, 0.2, duration: 0.2)
    }

    var body: some View {
        ZStack {
            Button(action: onDismiss) {
                Color.black.opacity(presentation.isExpanded ? 0.82 : 0)
                    .contentShape(Rectangle())
                    .animation(
                        presentation.isExpanded ? .easeOut(duration: 0.18) : .easeIn(duration: 0.14),
                        value: presentation.isExpanded
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭图片预览背景")
            .accessibilityIdentifier("peek-image-backdrop")

            Image(nsImage: item.image)
                .resizable()
                .scaledToFit()
                .contentShape(Rectangle())
                .onTapGesture { }
                .padding(presentation.isExpanded ? 28 : 0)
                .animation(geometryAnimation, value: presentation.isExpanded)
                .accessibilityLabel("来自\(item.senderName)的图片")
                .accessibilityIdentifier("peek-image-lightbox")

            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(6)
                .background(Color.black.opacity(0.58), in: Circle())
                .padding(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .opacity(presentation.isExpanded ? 0 : 1)
                .animation(.easeOut(duration: 0.1), value: presentation.isExpanded)
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                .opacity(presentation.isExpanded ? 0 : 1)
                .allowsHitTesting(false)

            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 30, height: 30)
                            .background(.ultraThinMaterial, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭图片预览")
                    .accessibilityIdentifier("peek-image-close")
                }
                Spacer()
            }
            .padding(14)
            .opacity(presentation.isExpanded ? 1 : 0)
            .animation(
                presentation.isExpanded
                    ? .spring(response: 0.26, dampingFraction: 0.82).delay(0.06)
                    : .easeOut(duration: 0.08),
                value: presentation.isExpanded
            )
        }
        .clipShape(RoundedRectangle(
            cornerRadius: presentation.isExpanded ? 16 : 9,
            style: .continuous
        ))
        .animation(geometryAnimation, value: presentation.isExpanded)
    }
}

@MainActor
private final class ImagePreviewPresentation: ObservableObject {
    @Published var isExpanded = false
}

@MainActor
private final class ImagePreviewPanelController {
    private static let maximumSize = CGSize(width: 1_200, height: 900)
    private static let screenFraction: CGFloat = 0.86
    private static let expansionDuration: TimeInterval = 0.28
    private static let collapseDuration: TimeInterval = 0.2
    private static let expansionTiming = CAMediaTimingFunction(
        controlPoints: 0.16, 0.9, 0.22, 1
    )
    private static let collapseTiming = CAMediaTimingFunction(
        controlPoints: 0.4, 0, 0.8, 0.2
    )

    private let panel: PeekPanel
    private let presentation = ImagePreviewPresentation()
    private var sourceFrame = CGRect.zero
    private var animationGeneration = 0
    private var isDismissing = false

    init() {
        panel = PeekPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.title = "图片预览"
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
    }

    func show(_ item: PresentedImage, on screen: NSScreen?) {
        animationGeneration += 1
        isDismissing = false
        presentation.isExpanded = false
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let size = CGSize(
            width: min(Self.maximumSize.width, visible.width * Self.screenFraction),
            height: min(Self.maximumSize.height, visible.height * Self.screenFraction)
        )
        let destinationFrame = CGRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        sourceFrame = normalizedSourceFrame(item.sourceFrame, fallbackIn: destinationFrame)
        let hostingView = NSHostingView(rootView: ImageLightboxView(
            item: item,
            presentation: presentation,
            onDismiss: { [weak self] in self?.dismiss() }
        ))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.setFrame(sourceFrame, display: true)
        hostingView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.isDismissing else { return }
            self.presentation.isExpanded = true
            self.animatePanel(
                to: destinationFrame,
                duration: Self.expansionDuration,
                timingFunction: Self.expansionTiming
            )
        }
    }

    @discardableResult
    func dismiss() -> Bool {
        guard panel.isVisible, !isDismissing else { return false }
        isDismissing = true
        animationGeneration += 1
        let generation = animationGeneration
        presentation.isExpanded = false
        animatePanel(
            to: sourceFrame,
            duration: Self.collapseDuration,
            timingFunction: Self.collapseTiming
        ) { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            self.panel.orderOut(nil)
            self.panel.contentView = nil
            self.isDismissing = false
        }
        return true
    }

    func contains(_ point: CGPoint) -> Bool {
        panel.isVisible && panel.frame.contains(point)
    }

    private func normalizedSourceFrame(_ frame: CGRect, fallbackIn destination: CGRect) -> CGRect {
        guard frame.width > 2, frame.height > 2 else {
            let fallbackSize = CGSize(width: 96, height: 72)
            return CGRect(
                x: destination.midX - fallbackSize.width / 2,
                y: destination.midY - fallbackSize.height / 2,
                width: fallbackSize.width,
                height: fallbackSize.height
            )
        }
        return frame
    }

    private func animatePanel(
        to frame: CGRect,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunction,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = timingFunction
            panel.animator().setFrame(frame, display: true)
        } completionHandler: {
            Task { @MainActor in completion?() }
        }
    }
}

private struct HoverBackground: ViewModifier {
    let cornerRadius: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                Color.primary.opacity(isHovered ? 0.10 : 0.05),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}
