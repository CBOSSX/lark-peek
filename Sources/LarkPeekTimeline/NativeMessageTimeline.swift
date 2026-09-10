import SwiftUI
import LarkPeekCore

@MainActor
public struct NativeMessageTimeline: NSViewControllerRepresentable {
    let sessionID: UUID
    let rows: [TimelineRow]
    let interactionAnchor: String?
    let interactionRevision: Int
    let onLoadNewer: (() -> Void)?
    let onLoadOlder: () -> Void
    let initialPosition: TimelineReadingPosition?
    let isPresenting: Bool
    let onPositionChange: ((TimelineReadingPosition) -> Void)?

    public init(sessionID: UUID, rows: [TimelineRow], interactionAnchor: String? = nil, interactionRevision: Int = 0,
                initialPosition: TimelineReadingPosition? = nil, isPresenting: Bool = false, onPositionChange: ((TimelineReadingPosition) -> Void)? = nil,
                onLoadNewer: (() -> Void)? = nil, onLoadOlder: @escaping () -> Void) {
        self.sessionID = sessionID
        self.rows = rows
        self.interactionAnchor = interactionAnchor
        self.interactionRevision = interactionRevision
        self.onLoadOlder = onLoadOlder
        self.onLoadNewer = onLoadNewer
        self.initialPosition = initialPosition
        self.isPresenting = isPresenting
        self.onPositionChange = onPositionChange
    }

    public func makeNSViewController(context: Context) -> MessageTimelineController {
        MessageTimelineController()
    }

    public func updateNSViewController(_ controller: MessageTimelineController, context: Context) {
        controller.onLoadOlder = onLoadOlder
        controller.onLoadNewer = onLoadNewer
        controller.onPositionChange = onPositionChange
        controller.update(sessionID: sessionID, rows: rows, interactionAnchor: interactionAnchor, interactionRevision: interactionRevision, initialPosition: initialPosition, isPresenting: isPresenting)
    }
}
