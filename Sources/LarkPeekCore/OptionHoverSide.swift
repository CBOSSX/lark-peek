import AppKit

public enum OptionHoverSide: String, CaseIterable, Sendable {
    case either, left, right

    public var label: String {
        switch self {
        case .either: "任意一侧"
        case .left: "仅左侧"
        case .right: "仅右侧"
        }
    }

    public func isHeld(in flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.contains(.option) else { return false }
        // Device-specific bits from IOKit's IOLLEvent.h survive in the raw flags.
        switch self {
        case .either: return true
        case .left: return flags.rawValue & 0x20 != 0 // NX_DEVICELALTKEYMASK
        case .right: return flags.rawValue & 0x40 != 0 // NX_DEVICERALTKEYMASK
        }
    }

    public func isKeyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case 58: return self != .right && OptionHoverSide.left.isHeld(in: flags)
        case 61: return self != .left && OptionHoverSide.right.isHeld(in: flags)
        default: return false
        }
    }
}
