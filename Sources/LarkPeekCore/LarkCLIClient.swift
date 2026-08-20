import Foundation

public struct CLIResult: Sendable {
    public let data: Data
    public let stderr: Data
    public let exitCode: Int32
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
        let arguments = try command.arguments()
        let process = Process()
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
                        if process.terminationStatus == 0 {
                            continuation.resume(returning: result)
                        } else {
                            continuation.resume(throwing: Self.error(from: error, fallbackCode: process.terminationStatus))
                        }
                    }
                }
                do {
                    try process.run()
                    stdout.fileHandleForWriting.closeFile()
                    stderr.fileHandleForWriting.closeFile()
                } catch {
                    stdout.fileHandleForWriting.closeFile()
                    stderr.fileHandleForWriting.closeFile()
                    continuation.resume(throwing: LarkCLIError.executionFailed("无法启动 lark-cli：\(error.localizedDescription)"))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
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
        if error["type"] as? String == "authorization" {
            return LarkCLIError.authorization(message: message, missingScopes: scopes)
        }
        return LarkCLIError.executionFailed(message)
    }
}
