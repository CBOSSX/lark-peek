import AppKit
import ApplicationServices

public enum HoverResolverError: LocalizedError, Equatable {
    case accessibilityPermissionMissing
    case larkNotRunning
    case pointerNotOverLark
    case conversationRowNotFound
    case conversationNameNotFound

    public var diagnosticCode: String {
        switch self {
        case .accessibilityPermissionMissing: "permission_missing"
        case .larkNotRunning: "lark_not_running"
        case .pointerNotOverLark: "pointer_not_over_lark"
        case .conversationRowNotFound: "conversation_row_not_found"
        case .conversationNameNotFound: "conversation_name_not_found"
        }
    }

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

    public static func isMainApplication(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifierRoots.contains(bundleIdentifier)
    }
}

enum ConversationRowGeometry {
    static let widthRange: ClosedRange<CGFloat> = 250...800
    static let heightRange: ClosedRange<CGFloat> = 44...90

    static func isCandidate(_ frame: CGRect, containing point: CGPoint) -> Bool {
        widthRange.contains(frame.width)
            && heightRange.contains(frame.height)
            && frame.insetBy(dx: -1, dy: -1).contains(point)
    }

    static func prefers(_ lhs: CGRect, over rhs: CGRect) -> Bool {
        if lhs.width != rhs.width { return lhs.width > rhs.width }
        return lhs.height > rhs.height
    }

    static func horizontalProbePoints(around point: CGPoint) -> [CGPoint] {
        let distances = stride(from: CGFloat(32), through: 352, by: 32)
        return distances.flatMap { distance in
            [
                CGPoint(x: point.x - distance, y: point.y),
                CGPoint(x: point.x + distance, y: point.y)
            ]
        }
        .filter { $0.x >= 0 }
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
        let before = isAccessibilityTrusted
        // Avoid importing the mutable C global into Swift 6 concurrency checking.
        // This is the documented string value of kAXTrustedCheckOptionPrompt.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let current = AXIsProcessTrustedWithOptions(options)
        LarkPeekDiagnostics.accessibility.notice(
            "event=permission_request before=\(before) current=\(current)"
        )
        return current
    }

    public func resolveCurrentConversation(triggerID: String? = nil) throws -> HoveredConversation {
        let trigger = triggerID ?? LarkPeekDiagnostics.triggerID ?? "none"
        LarkPeekDiagnostics.accessibility.info(
            "event=resolve_started trigger=\(trigger, privacy: .public) trusted=\(self.isAccessibilityTrusted)"
        )
        guard isAccessibilityTrusted else {
            throw loggedFailure(.accessibilityPermissionMissing, trigger: trigger, stage: "permission")
        }
        guard NSWorkspace.shared.runningApplications.contains(where: { app in
            LarkApplicationIdentity.matches(bundleIdentifier: app.bundleIdentifier)
        }) else {
            throw loggedFailure(.larkNotRunning, trigger: trigger, stage: "lark_process")
        }
        guard let point = CGEvent(source: nil)?.location else {
            throw loggedFailure(.pointerNotOverLark, trigger: trigger, stage: "pointer")
        }

        let systemWide = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let hit else {
            throw loggedFailure(.pointerNotOverLark, trigger: trigger, stage: "hit_test")
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid),
              LarkApplicationIdentity.matches(bundleIdentifier: app.bundleIdentifier) else {
            throw loggedFailure(.pointerNotOverLark, trigger: trigger, stage: "process_identity")
        }

        guard let lookup = conversationRow(
            startingAt: hit,
            point: point,
            systemWide: systemWide,
            trigger: trigger
        ) else {
            throw loggedFailure(.conversationRowNotFound, trigger: trigger, stage: "row_lookup")
        }
        let row = lookup.element
        let frame = lookup.frame
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
        ) else {
            LarkPeekDiagnostics.accessibility.error(
                "event=resolve_failed trigger=\(trigger, privacy: .public) stage=name_lookup code=conversation_name_not_found nodes=\(records.count) rowWidth=\(frame.width, format: .fixed(precision: 0)) rowHeight=\(frame.height, format: .fixed(precision: 0))"
            )
            throw HoverResolverError.conversationNameNotFound
        }
        LarkPeekDiagnostics.accessibility.info(
            "event=resolve_succeeded trigger=\(trigger, privacy: .public) strategy=\(lookup.strategy, privacy: .public) scanned=\(lookup.scanned) nodes=\(records.count) rowWidth=\(frame.width, format: .fixed(precision: 0)) rowHeight=\(frame.height, format: .fixed(precision: 0)) target=\(name, privacy: .private(mask: .hash))"
        )
        return HoveredConversation(name: name, rowFrame: frame, rowTexts: allTexts)
    }

    private func loggedFailure(
        _ error: HoverResolverError,
        trigger: String,
        stage: String
    ) -> HoverResolverError {
        LarkPeekDiagnostics.accessibility.error(
            "event=resolve_failed trigger=\(trigger, privacy: .public) stage=\(stage, privacy: .public) code=\(error.diagnosticCode, privacy: .public)"
        )
        return error
    }

    private struct RowLookup {
        let element: AXUIElement
        let frame: CGRect
        let strategy: String
        let scanned: Int
    }

    private struct DescendantSearch {
        let match: (element: AXUIElement, frame: CGRect)?
        let scanned: Int
        let roots: Int
    }

    private func conversationRow(
        startingAt element: AXUIElement,
        point: CGPoint,
        systemWide: AXUIElement,
        trigger: String
    ) -> RowLookup? {
        if let match = bestAncestorConversationRow(startingAt: element, point: point) {
            return RowLookup(element: match.element, frame: match.frame, strategy: "ancestor", scanned: 0)
        }
        let descendantSearch = bestDescendantConversationRow(startingAt: element, point: point)
        if let match = descendantSearch.match {
            return RowLookup(
                element: match.element,
                frame: match.frame,
                strategy: "descendant",
                scanned: descendantSearch.scanned
            )
        }

        var probeCount = 0
        for probe in ConversationRowGeometry.horizontalProbePoints(around: point) {
            probeCount += 1
            var probeHit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(
                systemWide,
                Float(probe.x),
                Float(probe.y),
                &probeHit
            ) == .success, let probeHit else { continue }
            var probePID: pid_t = 0
            guard AXUIElementGetPid(probeHit, &probePID) == .success,
                  let probeApp = NSRunningApplication(processIdentifier: probePID),
                  LarkApplicationIdentity.matches(bundleIdentifier: probeApp.bundleIdentifier),
                  let match = bestAncestorConversationRow(startingAt: probeHit, point: point) else {
                continue
            }
            return RowLookup(
                element: match.element,
                frame: match.frame,
                strategy: "horizontal_probe",
                scanned: descendantSearch.scanned + probeCount
            )
        }
        // Probing text or avatar positions can cause Electron to materialize a
        // previously cold accessibility subtree. Retry the container walk once.
        let retrySearch = bestDescendantConversationRow(startingAt: element, point: point)
        if let match = retrySearch.match {
            return RowLookup(
                element: match.element,
                frame: match.frame,
                strategy: "descendant_retry",
                scanned: descendantSearch.scanned + retrySearch.scanned + probeCount
            )
        }
        let applicationSearch = bestApplicationConversationRow(point: point)
        if let match = applicationSearch.match {
            return RowLookup(
                element: match.element,
                frame: match.frame,
                strategy: "application_root",
                scanned: descendantSearch.scanned
                    + retrySearch.scanned
                    + applicationSearch.scanned
                    + probeCount
            )
        }
        let hitFrame = frame(of: element)
        let hitRole = stringAttribute(element, kAXRoleAttribute as CFString) ?? "unknown"
        let hitWidth = Double(hitFrame?.width ?? -1)
        let hitHeight = Double(hitFrame?.height ?? -1)
        LarkPeekDiagnostics.accessibility.error(
            "event=row_lookup_exhausted trigger=\(trigger, privacy: .public) hitRole=\(hitRole, privacy: .public) hitWidth=\(hitWidth, format: .fixed(precision: 0)) hitHeight=\(hitHeight, format: .fixed(precision: 0)) roots=\(descendantSearch.roots + retrySearch.roots) scanned=\(descendantSearch.scanned + retrySearch.scanned) appScanned=\(applicationSearch.scanned) probes=\(probeCount)"
        )
        return nil
    }

    private func bestAncestorConversationRow(
        startingAt element: AXUIElement,
        point: CGPoint
    ) -> (element: AXUIElement, frame: CGRect)? {
        var candidates: [(element: AXUIElement, frame: CGRect)] = []
        var current: AXUIElement? = element
        for _ in 0..<14 {
            guard let item = current else { break }
            if let value = frame(of: item),
               ConversationRowGeometry.isCandidate(value, containing: point),
               !textRecords(in: item, maximumDepth: 6).isEmpty {
                candidates.append((item, value))
            }
            current = elementAttribute(item, kAXParentAttribute as CFString)
        }
        return candidates.max {
            ConversationRowGeometry.prefers($1.frame, over: $0.frame)
        }
    }

    private func bestDescendantConversationRow(
        startingAt element: AXUIElement,
        point: CGPoint
    ) -> DescendantSearch {
        var root: AXUIElement? = element
        var totalScanned = 0
        var roots = 0
        for _ in 0..<8 {
            guard let item = root else { break }
            roots += 1
            if let rootFrame = frame(of: item),
               (!rootFrame.insetBy(dx: -1, dy: -1).contains(point) || rootFrame.width > 900) {
                root = elementAttribute(item, kAXParentAttribute as CFString)
                continue
            }
            let result = bestDescendantConversationRow(
                in: item,
                point: point,
                limit: 192
            )
            totalScanned += result.scanned
            if let match = result.match {
                return DescendantSearch(match: match, scanned: totalScanned, roots: roots)
            }
            root = elementAttribute(item, kAXParentAttribute as CFString)
        }
        return DescendantSearch(match: nil, scanned: totalScanned, roots: roots)
    }

    private func bestApplicationConversationRow(point: CGPoint) -> DescendantSearch {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { app in
            LarkApplicationIdentity.isMainApplication(bundleIdentifier: app.bundleIdentifier)
        }) else {
            return DescendantSearch(match: nil, scanned: 0, roots: 0)
        }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        let warmed = warmAccessibilityTree(root, maximumDepth: 24, limit: 4_096)
        let search = bestDescendantConversationRow(
            in: root,
            point: point,
            limit: 4_096,
            maximumDepth: 24
        )
        return DescendantSearch(
            match: search.match,
            scanned: warmed + search.scanned,
            roots: 1
        )
    }

    private func warmAccessibilityTree(
        _ root: AXUIElement,
        maximumDepth: Int,
        limit: Int
    ) -> Int {
        var stack: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var scanned = 0
        while let current = stack.popLast(), scanned < limit {
            scanned += 1
            // Electron lazily materializes web accessibility layout. Reading
            // children alone leaves conversation rows frameless after launch;
            // touching role and geometry forces the renderer to publish them.
            _ = stringAttribute(current.element, kAXRoleAttribute as CFString)
            _ = frame(of: current.element)
            guard current.depth < maximumDepth else { continue }
            for child in children(of: current.element).reversed() {
                stack.append((child, current.depth + 1))
            }
        }
        return scanned
    }

    private func bestDescendantConversationRow(
        in root: AXUIElement,
        point: CGPoint,
        limit: Int,
        maximumDepth: Int = 5
    ) -> (match: (element: AXUIElement, frame: CGRect)?, scanned: Int) {
        var candidates: [(element: AXUIElement, frame: CGRect)] = []
        var stack: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var scanned = 0

        while let current = stack.popLast(), scanned < limit {
            guard current.depth < maximumDepth else { continue }
            for child in children(of: current.element) {
                guard scanned < limit else { break }
                scanned += 1
                let childFrame = frame(of: child)
                if let childFrame,
                   !childFrame.insetBy(dx: -1, dy: -1).contains(point) {
                    continue
                }
                if let childFrame,
                   ConversationRowGeometry.isCandidate(childFrame, containing: point),
                   !textRecords(in: child, maximumDepth: 6).isEmpty {
                    candidates.append((child, childFrame))
                }
                stack.append((child, current.depth + 1))
            }
        }

        let match = candidates.max {
            ConversationRowGeometry.prefers($1.frame, over: $0.frame)
        }
        return (match, scanned)
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
