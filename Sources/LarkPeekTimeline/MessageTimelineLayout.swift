import AppKit

/// Geometry is prepared before publication. Hosting views never estimate item heights.
@MainActor
final class MessageTimelineLayout: NSCollectionViewLayout {
    private(set) var frames: [CGRect] = []
    private var size = CGSize.zero
    var updateOrigin: CGPoint?

    func prepare(heights: [CGFloat], width: CGFloat, viewportHeight: CGFloat) {
        let contentHeight = heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * 10 + 8
        var y = max(0, viewportHeight - contentHeight)
        frames = heights.map { height in
            defer { y += height + 10 }
            return CGRect(x: 14, y: y, width: max(1, width - 28), height: height)
        }
        size = CGSize(width: width, height: max(viewportHeight, contentHeight))
    }

    override var collectionViewContentSize: NSSize { size }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard frames.indices.contains(indexPath.item) else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = frames[indexPath.item]
        return attributes
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        // Binary search avoids scanning an entire loaded history on every scroll event.
        var low = 0
        var high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].maxY < rect.minY { low = middle + 1 } else { high = middle }
        }
        var result: [NSCollectionViewLayoutAttributes] = []
        while low < frames.count, frames[low].minY <= rect.maxY {
            if let attributes = layoutAttributesForItem(at: IndexPath(item: low, section: 0)) {
                result.append(attributes)
            }
            low += 1
        }
        return result
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: NSPoint) -> NSPoint {
        updateOrigin ?? proposedContentOffset
    }
}
