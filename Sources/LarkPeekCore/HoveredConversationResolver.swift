import AppKit
import ApplicationServices

public enum HoverResolverError: LocalizedError, Equatable {
    case accessibilityPermissionMissing
    case larkNotRunning
    case pointerNotOverLark
    case conversationRowNotFound
    case conversationNameNotFound

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            "需要允许 Lark Peek 使用辅助功能，才能读取鼠标下方的飞书会话名。"
        case .larkNotRunning:
            "没有检测到正在运行的飞书。"
        case .pointerNotOverLark:
            "请先把鼠标停在飞书左侧的会话行上。"
        case .conversationRowNotFound:
            "已检测到飞书，但鼠标没有停在一个会话行上。"
        case .conversationNameNotFound:
            "找到了会话行，但无法识别会话名称。"
        }
    }
}

public enum ConversationNameHeuristics {
    private static let ignored = Set([
        "公开", "外部", "机器人", "免打扰", "未读", "标记", "群组", "单聊", "话题", "已完成"
    ])

    public static func chooseName(fromOrderedTexts texts: [String]) -> String? {
        texts.lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: isPlausibleName)
    }

    private static func isPlausibleName(_ value: String) -> Bool {
        guard value.count >= 2, !ignored.contains(value) else { return false }
        if value == ":" || value == "@" { return false }
        if value.range(of: #"^\d+([/:]\d+)?$"#, options: .regularExpression) != nil { return false }
        if value.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil { return false }
        return true
    }
}

public enum LarkApplicationIdentity {
    private static let bundleIdentifierRoots = ["com.electron.lark", "com.larksuite.suite"]

    public static func matches(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifierRoots.contains { root in
            bundleIdentifier == root || bundleIdentifier.hasPrefix(root + ".")
        }
    }
}

@MainActor
public final class HoveredConversationResolver {
    public init() {}

    public var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    public func requestAccessibilityPermission() -> Bool {
        // Avoid importing the mutable C global into Swift 6 concurrency checking.
        // This is the documented string value of kAXTrustedCheckOptionPrompt.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func resolveCurrentConversation() throws -> HoveredConversation {
        guard isAccessibilityTrusted else { throw HoverResolverError.accessibilityPermissionMissing }
        guard NSWorkspace.shared.runningApplications.contains(where: { app in
            LarkApplicationIdentity.matches(bundleIdentifier: app.bundleIdentifier)
        }) else { throw HoverResolverError.larkNotRunning }
        guard let point = CGEvent(source: nil)?.location else { throw HoverResolverError.pointerNotOverLark }

        let systemWide = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { throw HoverResolverError.pointerNotOverLark }

        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid),
              LarkApplicationIdentity.matches(bundleIdentifier: app.bundleIdentifier) else {
            throw HoverResolverError.pointerNotOverLark
        }

        guard let row = bestConversationRow(startingAt: hit), let frame = frame(of: row) else {
            throw HoverResolverError.conversationRowNotFound
        }
        let records = textRecords(in: row)
        let topLineLimit = frame.minY + frame.height * 0.58
        let topTexts = records
            .filter { record in
                guard let textFrame = record.frame else { return true }
                return textFrame.midY <= topLineLimit
            }
            .map(\.text)
        let allTexts = records.map(\.text)
        guard let name = ConversationNameHeuristics.chooseName(
            fromOrderedTexts: topTexts.isEmpty ? allTexts : topTexts
        ) else { throw HoverResolverError.conversationNameNotFound }
        return HoveredConversation(name: name, rowFrame: frame, rowTexts: allTexts)
    }

    private func bestConversationRow(startingAt element: AXUIElement) -> AXUIElement? {
        var candidates: [(element: AXUIElement, frame: CGRect)] = []
        var current: AXUIElement? = element
        for _ in 0..<14 {
            guard let item = current else { break }
            if let value = frame(of: item),
               (250...800).contains(value.width),
               (44...90).contains(value.height),
               !textRecords(in: item, maximumDepth: 6).isEmpty {
                candidates.append((item, value))
            }
            current = elementAttribute(item, kAXParentAttribute as CFString)
        }
        return candidates.max { lhs, rhs in
            if lhs.frame.width != rhs.frame.width { return lhs.frame.width < rhs.frame.width }
            return lhs.frame.height < rhs.frame.height
        }?.element
    }

    private struct TextRecord {
        let text: String
        let frame: CGRect?
    }

    private func textRecords(in root: AXUIElement, maximumDepth: Int = 9) -> [TextRecord] {
        var records: [TextRecord] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (element, depth) = stack.popLast(), records.count < 64 {
            if stringAttribute(element, kAXRoleAttribute as CFString) == kAXStaticTextRole as String,
               let text = stringAttribute(element, kAXValueAttribute as CFString),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                records.append(TextRecord(text: text, frame: frame(of: element)))
            }
            guard depth < maximumDepth else { continue }
            for child in children(of: element).reversed() {
                stack.append((child, depth + 1))
            }
        }
        return records
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        attribute(element, name) as? String
    }

    private func elementAttribute(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute as CFString),
              let sizeValue = attribute(element, kAXSizeAttribute as CFString),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
