import AppKit
import Combine

public struct PeekShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: UInt

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevantModifiers).rawValue
    }

    public static let keys: [(code: UInt16, label: String)] = [
        (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"),
        (5, "G"), (4, "H"), (34, "I"), (38, "J"), (40, "K"), (37, "L"),
        (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"), (15, "R"),
        (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"),
        (16, "Y"), (6, "Z"), (49, "空格"), (50, "`"),
        (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"),
        (22, "6"), (26, "7"), (28, "8"), (25, "9"), (29, "0"),
        (27, "-"), (24, "="), (33, "["), (30, "]"), (42, "\\"),
        (41, ";"), (39, "'"), (43, ","), (47, "."), (44, "/"),
        (123, "←"), (124, "→"), (125, "↓"), (126, "↑"),
        (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"),
        (96, "F5"), (97, "F6"), (98, "F7"), (100, "F8"),
        (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12")
    ]
    public static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .command, .shift]

    public static func modifierLabel(_ flags: NSEvent.ModifierFlags) -> String {
        let symbols: [(NSEvent.ModifierFlags, String)] = [
            (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")
        ]
        return symbols.filter { flags.contains($0.0) }.map(\.1).joined()
    }

    public static let preview = PeekShortcut(keyCode: 35, modifiers: [.control, .option])
    public static let search = PeekShortcut(keyCode: 3, modifiers: [.control, .option])

    public var isValid: Bool {
        Self.keys.contains { $0.code == keyCode }
            && modifiers & ~Self.relevantModifiers.rawValue == 0
            && !NSEvent.ModifierFlags(rawValue: modifiers).intersection([.control, .option, .command]).isEmpty
    }

    public var label: String {
        Self.modifierLabel(.init(rawValue: modifiers))
            + (Self.keys.first { $0.code == keyCode }?.label ?? "")
    }

    public func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift]
        return self.keyCode == keyCode && self.modifiers == modifiers.intersection(relevant).rawValue
    }
}

@MainActor
public final class PeekSettings: ObservableObject {
    public static let indexLimits = [100, 300, 500, 1_000, 2_000]
    public static let holdDelayRange = 0...5_000
    private let defaults: UserDefaults
    @Published public var indexLimit: Int { didSet { defaults.set(indexLimit, forKey: "settings.indexLimit") } }
    @Published public var optionHoverEnabled: Bool { didSet { defaults.set(optionHoverEnabled, forKey: "settings.optionHoverEnabled") } }
    @Published public var holdDelay: Int { didSet { defaults.set(holdDelay, forKey: "settings.holdDelay") } }
    @Published public private(set) var previewShortcut: PeekShortcut
    @Published public private(set) var searchShortcut: PeekShortcut

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let limit = defaults.integer(forKey: "settings.indexLimit")
        indexLimit = Self.indexLimits.contains(limit) ? limit : 500
        let delay = defaults.integer(forKey: "settings.holdDelay")
        holdDelay = defaults.object(forKey: "settings.holdDelay") != nil && Self.holdDelayRange.contains(delay) ? delay : 120
        optionHoverEnabled = defaults.object(forKey: "settings.optionHoverEnabled") as? Bool ?? true
        func shortcut(_ key: String, fallback: PeekShortcut) -> PeekShortcut {
            guard let data = defaults.data(forKey: key),
                  let value = try? JSONDecoder().decode(PeekShortcut.self, from: data), value.isValid else { return fallback }
            return value
        }
        let preview = shortcut("settings.previewShortcut", fallback: .preview)
        let search = shortcut("settings.searchShortcut", fallback: .search)
        previewShortcut = preview == search ? .preview : preview
        searchShortcut = preview == search ? .search : search
    }

    public func setShortcut(_ shortcut: PeekShortcut, forSearch: Bool) -> Bool {
        guard shortcut.isValid, shortcut != (forSearch ? previewShortcut : searchShortcut) else { return false }
        if forSearch { searchShortcut = shortcut } else { previewShortcut = shortcut }
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: forSearch ? "settings.searchShortcut" : "settings.previewShortcut")
        return true
    }

    public func restoreDefaults() {
        indexLimit = 500
        optionHoverEnabled = true
        holdDelay = 120
        previewShortcut = .preview
        searchShortcut = .search
        defaults.removeObject(forKey: "settings.previewShortcut")
        defaults.removeObject(forKey: "settings.searchShortcut")
    }
}
