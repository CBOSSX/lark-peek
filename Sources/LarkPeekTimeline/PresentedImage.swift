import AppKit

public struct PresentedImage: Identifiable {
    public let id: String
    public let image: NSImage
    public let senderName: String
    public let sourceFrame: CGRect
}
