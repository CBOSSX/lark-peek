import SwiftUI
import LarkPeekCore

@MainActor
public struct NativeMessageTimeline: NSViewControllerRepresentable {
    let sessionID: UUID
    let rows: [TimelineRow]
    let interactionAnchor: String?
    let interactionRevision: Int
    let onLoadOlder: () -> Void
    let initialPosition: TimelineReadingPosition?
    let onPositionChange: ((TimelineReadingPosition) -> Void)?

    public init(sessionID: UUID, rows: [TimelineRow], interactionAnchor: String? = nil, interactionRevision: Int = 0,
                initialPosition: TimelineReadingPosition? = nil, onPositionChange: ((TimelineReadingPosition) -> Void)? = nil,
                onLoadOlder: @escaping () -> Void) {
        self.sessionID = sessionID
        self.rows = rows
        self.interactionAnchor = interactionAnchor
        self.interactionRevision = interactionRevision
        self.onLoadOlder = onLoadOlder
        self.initialPosition = initialPosition
        self.onPositionChange = onPositionChange
    }

    public func makeNSViewController(context: Context) -> MessageTimelineController {
        MessageTimelineController()
    }

    public func updateNSViewController(_ controller: MessageTimelineController, context: Context) {
        controller.onLoadOlder = onLoadOlder
        controller.onPositionChange = onPositionChange
        controller.update(sessionID: sessionID, rows: rows, interactionAnchor: interactionAnchor, interactionRevision: interactionRevision, initialPosition: initialPosition)
    }
}
