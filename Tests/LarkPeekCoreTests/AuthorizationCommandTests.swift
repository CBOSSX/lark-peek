import Foundation
import Testing
@testable import LarkPeekCore

@Test func authorizationRequestsOnlyTheMissingApprovedScopes() throws {
    #expect(try AuthorizationCommand.begin(scopes: ["search:message", "im:chat:read"]).arguments() == [
        "auth", "login", "--scope", "im:chat:read search:message", "--no-wait", "--json"
    ])
    #expect(try AuthorizationCommand.complete(deviceCode: "safe-code.value_1").arguments() == [
        "auth", "login", "--device-code", "safe-code.value_1"
    ])
}

@Test func authorizationCannotExpandScopesOrInjectArguments() {
    #expect(throws: AuthorizationPolicyError.invalidScope) {
        try AuthorizationCommand.begin(scopes: ["im:message"]).arguments()
    }
    #expect(throws: AuthorizationPolicyError.invalidScope) {
        try AuthorizationCommand.begin(scopes: []).arguments()
    }
    #expect(throws: AuthorizationPolicyError.invalidDeviceCode) {
        try AuthorizationCommand.complete(deviceCode: "safe\n--yes").arguments()
    }
}

@Test func authStatusRequiresEveryLarkPeekScope() throws {
    let complete = #"{"verified":true,"identities":{"user":{"available":true,"verified":true,"scope":"im:chat:read im:message:readonly search:message offline_access"}}}"#
    let incomplete = #"{"verified":true,"identities":{"user":{"available":true,"verified":true,"scope":"im:chat:read im:message:readonly"}}}"#
    let invalidUser = #"{"verified":true,"identity":"bot","identities":{"user":{"available":true,"verified":false,"scope":"im:chat:read im:message:readonly search:message"}}}"#

    #expect(try LarkCLIParser.authStatus(from: Data(complete.utf8)).state == .ready)
    let status = try LarkCLIParser.authStatus(from: Data(incomplete.utf8))
    #expect(status.state == .needsLogin)
    #expect(status.missingRequiredScopes == ["search:message"])
    #expect(try LarkCLIParser.authStatus(from: Data(invalidUser.utf8)).state == .needsLogin)
}

@Test func parsesOnlyTrustedAuthorizationRequests() throws {
    let json = #"{"verification_url":"https://accounts.feishu.cn/oauth/v1/device/verify?flow_id=safe","device_code":"safe-code.value","expires_in":600}"#
    let request = try LarkCLIParser.authorizationRequest(from: Data(json.utf8))
    #expect(request.verificationURL.host == "accounts.feishu.cn")
    #expect(request.deviceCode == "safe-code.value")
    #expect(request.expiresIn == 600)

    let untrusted = #"{"verification_url":"https://example.com/steal","device_code":"safe-code.value","expires_in":600}"#
    #expect(throws: LarkCLIError.malformedResponse) {
        try LarkCLIParser.authorizationRequest(from: Data(untrusted.utf8))
    }
}
