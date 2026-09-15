import Foundation
import Testing
@testable import LarkPeekCore

@MainActor
struct SettingsAuthorizationTests {
    @Test func detectsMissingScopeAndRequestsOnlyThatScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsAuth-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "SettingsAuth-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let cli = directory.appendingPathComponent("lark-cli")
        let script = """
        #!/bin/sh
        if [ "$1 $2" = "auth status" ]; then
          scope='im:chat:read im:message:readonly'
          if [ -f recovered ]; then scope="$scope search:message"; fi
          printf '{"verified":true,"identities":{"user":{"available":true,"verified":true,"scope":"%s"}}}' "$scope"
        elif [ "$1 $2" = "auth login" ]; then
          if [ "$3" = "--device-code" ]; then
            touch recovered
            printf '{}'
          else
            printf '%s' "$*" > arguments
            printf '%s' '{"verification_url":"https://accounts.feishu.cn/oauth/v1/device/verify?flow_id=safe","device_code":"safe-code","expires_in":600}'
          fi
        elif [ "$2" = "+chat-list" ]; then
          printf '%s' '{"data":{"chats":[],"has_more":false}}'
        else
          exit 1
        fi
        """
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        defaults.set(cli.path, forKey: "selectedLarkCLIPath")
        let model = PeekModel(defaults: defaults, workingDirectory: directory)
        await model.start()
        await model.checkAuthorization()
        #expect(model.authStatus.state == .needsLogin)
        #expect(model.authStatus.missingRequiredScopes == ["search:message"])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("arguments").path))
        var opened = false
        await model.authorize { _ in opened = true; return true }
        #expect(opened)
        #expect(model.authStatus.state == .ready)
        #expect(model.authStatus.missingRequiredScopes.isEmpty)
        let arguments = try String(contentsOf: directory.appendingPathComponent("arguments"), encoding: .utf8)
        #expect(arguments == "auth login --scope search:message --no-wait --json")
        await model.checkAuthorization()
        #expect(model.authStatus.state == .ready)
    }
}
