import Foundation
import Testing
@testable import LarkPeekCore

@MainActor
struct RuntimeAuthorizationTests {
    @Test(arguments: ["authorization", "missing", "api", "keychain"])
    func runtimeFailuresOnlyInvalidateAuthorizationForAuthErrors(kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RuntimeAuth-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "RuntimeAuth-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let errorType = kind == "missing" ? "authorization" : kind
        let scopes = kind == "missing" ? ["search:message"] : []
        let scopesJSON = String(decoding: try JSONSerialization.data(withJSONObject: scopes), as: UTF8.self)
        let message = kind == "keychain" ? "keychain access blocked" : "request failed"
        let cli = directory.appendingPathComponent("lark-cli")
        let script = """
        #!/bin/sh
        if [ "$1 $2" = "auth status" ]; then
          printf '%s' '{"verified":true,"identities":{"user":{"available":true,"verified":true,"scope":"im:chat:read im:message:readonly search:message"}}}'
        elif [ "$1 $2" = "auth login" ]; then
          if [ "$3" = "--device-code" ]; then
            touch recovered
            printf '{}'
          else
            printf '%s' "$*" > authorization-arguments
            printf '%s' '{"verification_url":"https://accounts.feishu.cn/oauth/v1/device/verify?flow_id=safe","device_code":"safe-code","expires_in":600}'
          fi
        elif [ "$2" = "+chat-list" ]; then
          printf '%s' '{"data":{"chats":[],"has_more":false}}'
        else
          printf '%s' '{"error":{"type":"\(errorType)","message":"\(message)","missing_scopes":\(scopesJSON)}}' >&2
          exit 1
        fi
        """
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        defaults.set(cli.path, forKey: "selectedLarkCLIPath")
        let model = PeekModel(defaults: defaults, workingDirectory: directory)
        await model.start()
        #expect(model.authStatus.state == .ready)
        do {
            _ = try await model.searchMessages(.searchMessages(query: "test", chatIDs: [], pageToken: nil, pageSize: 20))
            Issue.record("Fixture should fail")
        } catch {}
        if errorType == "authorization" {
            #expect(model.authStatus.state == .needsLogin)
            #expect(model.authStatus.missingRequiredScopes == (kind == "missing" ? ["search:message"] : Set(AuthStatus.requiredScopes)))
            var opened = false
            await model.authorize { _ in opened = true; return true }
            #expect(opened)
            #expect(model.authStatus.state == .ready)
            #expect(!model.isAuthorizing)
            let arguments = try String(contentsOf: directory.appendingPathComponent("authorization-arguments"), encoding: .utf8)
            #expect(arguments.contains(kind == "missing" ? "--scope search:message" : "--scope im:chat:read im:message:readonly search:message"))
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("recovered").path))
        } else {
            #expect(model.authStatus.state == .ready)
        }
    }
}
