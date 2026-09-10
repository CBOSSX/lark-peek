import Foundation

/// The geometry animation is independent of message loading and SwiftUI measurement.
struct TimelineHeightTransition {
    let id = UUID()
    let from: [CGFloat]
    let to: [CGFloat]
    let anchorIndex: Int?
    let anchorScreenY: CGFloat
    let originY: CGFloat

    func heights(at progress: Double) -> [CGFloat] {
        let t = min(1, max(0, progress))
        let eased = 1 - pow(1 - t, 3)
        return zip(from, to).map { $0 + ($1 - $0) * eased }
    }
}
