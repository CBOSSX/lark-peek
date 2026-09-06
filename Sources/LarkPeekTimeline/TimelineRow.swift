import SwiftUI

@MainActor
public struct TimelineRow {
    public let id: String
    public let version: AnyHashable
    public let content: AnyView

    public init(id: String, version: AnyHashable, content: AnyView) {
        self.id = id
        self.version = version
        self.content = content
    }
}
