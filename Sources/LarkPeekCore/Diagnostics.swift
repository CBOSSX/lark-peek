import Foundation
import OSLog

/// Shared, privacy-conscious diagnostics for the complete preview pipeline.
///
/// Log messages use stable `event=... key=value` fields so a support bundle can
/// correlate one preview attempt without recording chat names or message bodies.
public enum LarkPeekDiagnostics {
    public static let subsystem = "io.github.cbossx.larkpeek"

    public static let lifecycle = Logger(subsystem: subsystem, category: "Lifecycle")
    public static let input = Logger(subsystem: subsystem, category: "Input")
    public static let accessibility = Logger(subsystem: subsystem, category: "Accessibility")
    public static let panel = Logger(subsystem: subsystem, category: "Panel")
    public static let cli = Logger(subsystem: subsystem, category: "CLI")
    public static let hoverRouting = Logger(subsystem: subsystem, category: "HoverRouting")
    public static let chatMatching = Logger(subsystem: subsystem, category: "ChatMatching")
    public static let threadMatching = Logger(subsystem: subsystem, category: "ThreadMatching")
    public static let pagination = Logger(subsystem: subsystem, category: "Pagination")
    public static let messageTimeline = Logger(subsystem: subsystem, category: "MessageTimeline")

    /// Propagates a preview attempt across model and CLI tasks without changing
    /// every internal API. Detached pipe readers intentionally do not use it.
    @TaskLocal public static var triggerID: String?

    public static func makeTriggerID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    public static func errorKind(_ error: Error) -> String {
        switch error {
        case let value as HoverResolverError:
            return value.diagnosticCode
        case let value as LarkCLIResolverError:
            switch value {
            case .executableNotFound: return "cli_not_found"
            case .invalidCLIPath: return "invalid_cli_path"
            case .interpreterNotFound: return "interpreter_not_found"
            case .unsupportedInterpreter: return "unsupported_interpreter"
            }
        case let value as LarkCLIError:
            switch value {
            case .executableNotFound: return "cli_not_found"
            case .keychainAccessBlocked: return "keychain_access_blocked"
            case .executionFailed: return "cli_execution_failed"
            case .malformedResponse: return "malformed_response"
            case .authorization: return "authorization"
            }
        case is CancellationError:
            return "cancelled"
        default:
            return String(describing: type(of: error))
        }
    }
}

public extension AuthStatus.State {
    var diagnosticCode: String {
        switch self {
        case .checking: "checking"
        case .ready: "ready"
        case .needsLogin: "needs_login"
        case .error: "error"
        }
    }
}
