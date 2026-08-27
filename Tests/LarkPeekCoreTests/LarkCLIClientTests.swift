import Foundation
import Testing
@testable import LarkPeekCore

@Test func clientDrainsLargeOutputWhileProcessIsRunning() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LarkCLIClientTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cli = directory.appendingPathComponent("lark-cli")
    let script = """
    #!/bin/sh
    head -c 262144 /dev/zero | tr '\\000' x
    """
    try Data(script.utf8).write(to: cli)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

    let resolver = LarkCLIResolver(
        homeDirectory: directory,
        inheritedPath: "/usr/bin:/bin",
        additionalSearchDirectories: [directory],
        includeStandardLocations: false
    )
    let client = try LarkCLIClient(executableURL: cli, workingDirectory: directory, resolver: resolver)

    let result = try await client.run(.authStatus)

    #expect(result.exitCode == 0)
    #expect(result.data.count == 262_144)
    #expect(result.stderr.isEmpty)
}

@Test func clientMapsBlockedKeychainToActionableError() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LarkCLIClientKeychainTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cli = directory.appendingPathComponent("lark-cli")
    let script = """
    #!/bin/sh
    printf '%s' '{"error":{"type":"api","message":"keychain Get failed: keychain access blocked"}}' >&2
    exit 1
    """
    try Data(script.utf8).write(to: cli)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

    let resolver = LarkCLIResolver(
        homeDirectory: directory,
        inheritedPath: "/usr/bin:/bin",
        additionalSearchDirectories: [directory],
        includeStandardLocations: false
    )
    let client = try LarkCLIClient(executableURL: cli, workingDirectory: directory, resolver: resolver)

    await #expect(throws: LarkCLIError.keychainAccessBlocked) {
        try await client.run(.authStatus)
    }
}

@Test func cliErrorMetadataKeepsOnlySafeHandoffFields() {
    let data = Data(#"{"error":{"type":"rate_limit","code":429,"log_id":"20260827ABC-123","message":"private message body"}}"#.utf8)
    #expect(LarkCLIClient.errorMetadata(from: data) == CLIErrorMetadata(
        type: "rate_limit",
        code: "429",
        requestID: "20260827ABC-123"
    ))

    let unsafe = Data(#"{"error":{"type":"api/error","code":"bad code","request_id":"person@example.com"}}"#.utf8)
    #expect(LarkCLIClient.errorMetadata(from: unsafe) == CLIErrorMetadata(
        type: nil,
        code: nil,
        requestID: nil
    ))
}

@Test func triggerIDsAreShortOpaqueCorrelationValues() {
    let first = LarkPeekDiagnostics.makeTriggerID()
    let second = LarkPeekDiagnostics.makeTriggerID()
    #expect(first.count == 8)
    #expect(first != second)
    #expect(first.allSatisfy { $0.isHexDigit })
}

@Test func cancellingACommandSurfacesCancellationInsteadOfExecutionFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "LarkCLIClientCancellationTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cli = directory.appendingPathComponent("lark-cli")
    let script = """
    #!/bin/sh
    exec /bin/sleep 10
    """
    try Data(script.utf8).write(to: cli)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

    let resolver = LarkCLIResolver(
        homeDirectory: directory,
        inheritedPath: "/usr/bin:/bin",
        additionalSearchDirectories: [directory],
        includeStandardLocations: false
    )
    let client = try LarkCLIClient(executableURL: cli, workingDirectory: directory, resolver: resolver)
    let startedAt = Date()
    let task = Task { try await client.run(.authStatus) }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    #expect(Date().timeIntervalSince(startedAt) < 3)
}
