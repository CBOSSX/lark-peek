import Foundation

public enum AuthorizationPolicyError: LocalizedError, Equatable {
    case invalidScope
    case invalidDeviceCode

    public var errorDescription: String? {
        switch self {
        case .invalidScope: "授权范围不合法，命令未执行。"
        case .invalidDeviceCode: "授权设备码不合法，命令未执行。"
        }
    }
}

/// The only credential-changing commands Lark Peek can execute.
///
/// This is deliberately separate from `ReadOnlyCommand`: authorization changes
/// the local user credential, while all business-data commands remain read-only.
public enum AuthorizationCommand: Equatable, Sendable {
    case begin(scopes: Set<String>)
    case complete(deviceCode: String)

    public func arguments() throws -> [String] {
        switch self {
        case let .begin(scopes):
            let allowed = Set(AuthStatus.requiredScopes)
            guard !scopes.isEmpty, scopes.isSubset(of: allowed) else {
                throw AuthorizationPolicyError.invalidScope
            }
            let orderedScopes = AuthStatus.requiredScopes.filter(scopes.contains)
            return [
                "auth", "login",
                "--scope", orderedScopes.joined(separator: " "),
                "--no-wait", "--json"
            ]

        case let .complete(deviceCode):
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            guard !deviceCode.isEmpty, deviceCode.count <= 1_024,
                  deviceCode.unicodeScalars.allSatisfy(allowed.contains) else {
                throw AuthorizationPolicyError.invalidDeviceCode
            }
            return ["auth", "login", "--device-code", deviceCode]
        }
    }
}

public struct AuthorizationRequest: Equatable, Sendable {
    public let verificationURL: URL
    public let deviceCode: String
    public let expiresIn: TimeInterval

    public init(verificationURL: URL, deviceCode: String, expiresIn: TimeInterval) {
        self.verificationURL = verificationURL
        self.deviceCode = deviceCode
        self.expiresIn = expiresIn
    }
}
