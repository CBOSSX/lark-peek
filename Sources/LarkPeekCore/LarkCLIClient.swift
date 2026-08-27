import Foundation

public struct CLIResult: Sendable {
    public let data: Data
    public let stderr: Data
    public let exitCode: Int32
}

struct CLIErrorMetadata: Equatable {
    let type: String?
    let code: String?
    let requestID: String?
}

private final class RequestCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    @discardableResult
    func markCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        cancelled = true
        return true
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public actor LarkCLIClient {
    public nonisolated let cliURL: URL
    private let installation: LarkCLIInstallation
    private let workingDirectory: URL

    public init(executableURL: URL? = nil, workingDirectory: URL? = nil, resolver: LarkCLIResolver = LarkCLIResolver()) throws {
        let installation = try resolver.resolve(preferredCLIURL: executableURL)
        self.installation = installation
        self.cliURL = installation.cliURL
        self.workingDirectory = workingDirectory ?? FileManager.default.temporaryDirectory
    }

    public static func findExecutable() -> URL? {
        try? LarkCLIResolver().resolve().cliURL
    }

    public func run(_ command: ReadOnlyCommand) async throws -> CLIResult {
        try await run(commandName: command.diagnosticName) {
            try command.arguments()
        }
    }

    public func run(_ command: AuthorizationCommand) async throws -> CLIResult {
        try await run(commandName: command.diagnosticName) {
            try command.arguments()
        }
    }

    private func run(
        commandName: String,
        arguments makeArguments: () throws -> [String]
    ) async throws -> CLIResult {
        let trigger = LarkPeekDiagnostics.triggerID ?? "none"
        let requestID = LarkPeekDiagnostics.makeTriggerID()
        let arguments: [String]
        do {
            arguments = try makeArguments()
        } catch {
            LarkPeekDiagnostics.cli.error(
                "event=command_rejected trigger=\(trigger, privacy: .public) request=\(requestID, privacy: .public) command=\(commandName, privacy: .public) code=\(LarkPeekDiagnostics.errorKind(error), privacy: .public)"
            )
            throw error
        }

        let startedAt = Date()
        LarkPeekDiagnostics.cli.info(
            "event=request_started trigger=\(trigger, privacy: .public) request=\(requestID, privacy: .public) command=\(commandName, privacy: .public)"
        )
        let process = Process()
        let cancellationState = RequestCancellationState()
        let stdout = Pipe()
        let stderr = Pipe()
        let outputTask = Task.detached {
            try stdout.fileHandleForReading.readToEnd() ?? Data()
        }
        let errorTask = Task.detached {
            try stderr.fileHandleForReading.readToEnd() ?? Data()
        }
        process.executableURL = installation.launchExecutableURL
        process.arguments = installation.prefixArguments + arguments
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = stdout
        process.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = installation.environmentPath
        environment["LARKSUITE_CLI_NO_UPDATE_NOTIFIER"] = "1"
        environment["LARKSUITE_CLI_NO_SKILLS_NOTIFIER"] = "1"
        process.environment = environment

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    Task {
                        let output = (try? await outputTask.value) ?? Data()
                        let error = (try? await errorTask.value) ?? Data()
                        let result = CLIResult(data: output, stderr: error, exitCode: process.terminationStatus)
                        let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
                        if cancellationState.isCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else if process.terminationStatus == 0 {
                            LarkPeekDiagnostics.cli.info(
                                "event=request_succeeded trigger=\(trigger, privacy: .public) request=\(requestID, privacy: .public) command=\(commandName, privacy: .public) exit=\(process.terminationStatus) elapsedMs=\(elapsedMilliseconds) stdoutBytes=\(output.count) stderrBytes=\(error.count)"
                            )
                            continuation.resume(returning: result)
                        } else {
                            let mappedError = Self.error(from: error, fallbackCode: process.terminationStatus)
                            let metadata = Self.errorMetadata(from: error)
                            LarkPeekDiagnostics.cli.error(
                                "event=request_failed trigger=\(trigger, privacy: .public) request=\(requestID, privacy: .public) command=\(commandName, privacy: .public) exit=\(process.terminationStatus) elapsedMs=\(elapsedMilliseconds) code=\(LarkPeekDiagnostics.errorKind(mappedError), privacy: .public) upstreamType=\(metadata.type ?? "none", privacy: .public) upstreamCode=\(metadata.code ?? "none", privacy: .public) upstreamRequest=\(metadata.requestID ?? "none", privacy: .public) stderrBytes=\(error.count)"
                            )
                            continuation.resume(throwing: mappedError)
                        }
                    }
                }
                do {
                    guard !cancellationState.isCancelled else {
                        stdout.fileHandleForWriting.closeFile()
                        stderr.fileHandleForWriting.closeFile()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    try process.run()
                    stdout.fileHandleForWriting.closeFile()
                    stderr.fileHandleForWriting.closeFile()
                    if cancellationState.isCancelled, process.isRunning {
                        process.terminate()
                    }
                } catch {
                    stdout.fileHandleForWriting.closeFile()
                    stderr.fileHandleForWriting.closeFile()
                    guard !cancellationState.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let mappedError = LarkCLIError.executionFailed("无法启动 lark-cli：\(error.localizedDescription)")
                    let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
                    LarkPeekDiagnostics.cli.error(
                        "event=launch_failed trigger=\(trigger, privacy: .public) request=\(requestID, privacy: .public) command=\(commandName, privacy: .public) elapsedMs=\(elapsedMilliseconds) code=\(LarkPeekDiagnostics.errorKind(mappedError), privacy: .public) error=\(error.localizedDescription, privacy: .private)"
                    )
                    continuation.resume(throwing: mappedError)
                }
            }
        } onCancel: {
            guard cancellationState.markCancelled() else { return }
            LarkPeekDiagnostics.cli.info(
                "event=request_cancelled trigger=\(trigger, privacy: .public) request=\(requestID, privacy: .public) command=\(commandName, privacy: .public)"
            )
            if process.isRunning { process.terminate() }
        }
    }

    static func errorMetadata(from data: Data) -> CLIErrorMetadata {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CLIErrorMetadata(type: nil, code: nil, requestID: nil)
        }
        let error = root["error"] as? [String: Any] ?? [:]
        return CLIErrorMetadata(
            type: firstDiagnosticValue(in: error, keys: ["type", "error_type"]),
            code: firstDiagnosticValue(in: error, keys: ["code", "error_code"])
                ?? firstDiagnosticValue(in: root, keys: ["code", "error_code"]),
            requestID: firstDiagnosticValue(
                in: error,
                keys: ["log_id", "logid", "logId", "request_id", "requestId"]
            ) ?? firstDiagnosticValue(
                in: root,
                keys: ["log_id", "logid", "logId", "request_id", "requestId"]
            )
        )
    }

    private static func firstDiagnosticValue(
        in object: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            let text: String
            if let value = value as? String { text = value }
            else if let value = value as? NSNumber { text = value.stringValue }
            else { continue }
            guard !text.isEmpty, text.count <= 128 else { continue }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
            guard text.unicodeScalars.allSatisfy(allowed.contains) else { continue }
            return text
        }
        return nil
    }

    private static func error(from data: Data, fallbackCode: Int32) -> Error {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any]
        else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return LarkCLIError.executionFailed(message?.isEmpty == false ? message! : "lark-cli 执行失败（退出码 \(fallbackCode)）。")
        }
        let message = error["message"] as? String ?? "飞书只读请求失败。"
        let scopes = error["missing_scopes"] as? [String] ?? []
        let normalizedMessage = message.lowercased()
        if normalizedMessage.contains("keychain access blocked")
            || normalizedMessage.contains("keychain not initialized") {
            return LarkCLIError.keychainAccessBlocked
        }
        if error["type"] as? String == "authorization" {
            return LarkCLIError.authorization(message: message, missingScopes: scopes)
        }
        return LarkCLIError.executionFailed(message)
    }
}
