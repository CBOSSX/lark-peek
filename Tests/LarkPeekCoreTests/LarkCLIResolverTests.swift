import Foundation
import Testing
@testable import LarkPeekCore

@Test func resolvesEnvNodeNextToCLIWithoutInheritedPath() throws {
    let directory = try makeTemporaryDirectory()
    let cli = directory.appendingPathComponent("lark-cli")
    let node = directory.appendingPathComponent("node")
    try makeExecutable(cli, contents: "#!/usr/bin/env node\n")
    try makeExecutable(node, contents: "node-placeholder")

    let resolver = LarkCLIResolver(
        homeDirectory: directory,
        inheritedPath: "",
        additionalSearchDirectories: [directory],
        includeStandardLocations: false
    )
    let installation = try resolver.resolve()

    #expect(installation.cliURL == cli)
    #expect(installation.launchExecutableURL == node)
    #expect(installation.prefixArguments == [cli.path])
    #expect(installation.environmentPath.split(separator: ":").contains(Substring(directory.path)))
}

@Test func resolvesCustomCLIAndNodeFromDifferentManagedRuntimeDirectories() throws {
    let root = try makeTemporaryDirectory()
    let cliDirectory = root.appendingPathComponent("custom-cli", isDirectory: true)
    let runtimeDirectory = root.appendingPathComponent("runtime", isDirectory: true)
    try FileManager.default.createDirectory(at: cliDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
    let cli = cliDirectory.appendingPathComponent("lark-cli")
    let node = runtimeDirectory.appendingPathComponent("node")
    try makeExecutable(cli, contents: "#!/usr/bin/env node\n")
    try makeExecutable(node, contents: "node-placeholder")

    let resolver = LarkCLIResolver(
        homeDirectory: root,
        inheritedPath: "",
        additionalSearchDirectories: [runtimeDirectory],
        includeStandardLocations: false
    )
    let installation = try resolver.resolve(preferredCLIURL: cli)

    #expect(installation.launchExecutableURL == node)
    #expect(installation.prefixArguments == [cli.path])
}

@Test func automaticDiscoveryCanPairCLIAndRuntimeAcrossManagedDirectories() throws {
    let root = try makeTemporaryDirectory()
    let broken = root.appendingPathComponent("broken", isDirectory: true)
    let working = root.appendingPathComponent("working", isDirectory: true)
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
    try makeExecutable(broken.appendingPathComponent("lark-cli"), contents: "#!/usr/bin/env node\n")
    try makeExecutable(working.appendingPathComponent("lark-cli"), contents: "#!/usr/bin/env node\n")
    try makeExecutable(working.appendingPathComponent("node"), contents: "node-placeholder")

    let resolver = LarkCLIResolver(homeDirectory: root, inheritedPath: "", additionalSearchDirectories: [broken, working], includeStandardLocations: false)
    let installation = try resolver.resolve()
    #expect(installation.cliURL == broken.appendingPathComponent("lark-cli"))
    #expect(installation.launchExecutableURL == working.appendingPathComponent("node"))
}

@Test func directShellShimPreservesStructuredArgumentsWithoutShellCommandString() throws {
    let directory = try makeTemporaryDirectory()
    let cli = directory.appendingPathComponent("lark-cli")
    try makeExecutable(cli, contents: "#!/bin/sh\n")
    let resolver = LarkCLIResolver(homeDirectory: directory, inheritedPath: "", additionalSearchDirectories: [directory], includeStandardLocations: false)
    let installation = try resolver.resolve()
    #expect(installation.launchExecutableURL == cli)
    #expect(installation.prefixArguments.isEmpty)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("LarkCLIResolverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeExecutable(_ url: URL, contents: String) throws {
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}
