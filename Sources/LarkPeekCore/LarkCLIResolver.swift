import Foundation

public struct LarkCLIInstallation: Equatable, Sendable {
    public let cliURL: URL
    public let launchExecutableURL: URL
    public let prefixArguments: [String]
    public let environmentPath: String

    public init(cliURL: URL, launchExecutableURL: URL, prefixArguments: [String], environmentPath: String) {
        self.cliURL = cliURL
        self.launchExecutableURL = launchExecutableURL
        self.prefixArguments = prefixArguments
        self.environmentPath = environmentPath
    }
}

public enum LarkCLIResolverError: LocalizedError, Equatable {
    case executableNotFound
    case invalidCLIPath(String)
    case interpreterNotFound(name: String, cliPath: String)
    case unsupportedInterpreter(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "未找到 lark-cli。请在设置中选择 lark-cli 可执行文件。"
        case let .invalidCLIPath(path):
            "所选路径不是可执行的 lark-cli：\(path)"
        case let .interpreterNotFound(name, _):
            "找到了 lark-cli，但没有找到它需要的 \(name)。请安装 Node.js，或选择与 Node.js 位于同一运行时目录的 lark-cli。"
        case let .unsupportedInterpreter(name):
            "lark-cli 使用了暂不支持的解释器：\(name)"
        }
    }
}

public struct LarkCLIResolver: Sendable {
    private let homeDirectory: URL
    private let inheritedPath: String
    private let additionalSearchDirectories: [URL]
    private let includeStandardLocations: Bool

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        inheritedPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        additionalSearchDirectories: [URL] = [],
        includeStandardLocations: Bool = true
    ) {
        self.homeDirectory = homeDirectory
        self.inheritedPath = inheritedPath
        self.additionalSearchDirectories = additionalSearchDirectories
        self.includeStandardLocations = includeStandardLocations
    }

    public func resolve(preferredCLIURL: URL? = nil) throws -> LarkCLIInstallation {
        if let preferredCLIURL {
            guard isExecutable(preferredCLIURL), preferredCLIURL.lastPathComponent == "lark-cli" else {
                throw LarkCLIResolverError.invalidCLIPath(preferredCLIURL.path)
            }
            return try installation(for: preferredCLIURL, searchDirectories: searchDirectories())
        }

        let directories = searchDirectories()
        var firstResolutionError: Error?
        for directory in directories {
            let candidate = directory.appendingPathComponent("lark-cli")
            guard isExecutable(candidate) else { continue }
            do { return try installation(for: candidate, searchDirectories: directories) }
            catch { if firstResolutionError == nil { firstResolutionError = error } }
        }
        if let firstResolutionError { throw firstResolutionError }
        throw LarkCLIResolverError.executableNotFound
    }

    public func searchDirectories() -> [URL] {
        var directories = additionalSearchDirectories
        if includeStandardLocations {
            directories.append(contentsOf: [
                URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
                URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
                URL(fileURLWithPath: "/usr/bin", isDirectory: true),
                URL(fileURLWithPath: "/bin", isDirectory: true),
                homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
                homeDirectory.appendingPathComponent("bin", isDirectory: true),
                homeDirectory.appendingPathComponent(".volta/bin", isDirectory: true),
                homeDirectory.appendingPathComponent(".npm-global/bin", isDirectory: true),
                homeDirectory.appendingPathComponent(".bun/bin", isDirectory: true),
                homeDirectory.appendingPathComponent("Library/pnpm", isDirectory: true)
            ])
            directories.append(contentsOf: versionedDirectories(root: homeDirectory.appendingPathComponent(".nvm/versions/node"), suffix: "bin"))
            directories.append(contentsOf: versionedDirectories(root: homeDirectory.appendingPathComponent(".fnm/node-versions"), suffix: "installation/bin"))
            directories.append(contentsOf: versionedDirectories(root: homeDirectory.appendingPathComponent("Library/Application Support/fnm/node-versions"), suffix: "installation/bin"))
            directories.append(contentsOf: versionedDirectories(root: homeDirectory.appendingPathComponent(".local/share/mise/installs/node"), suffix: "bin"))
            directories.append(contentsOf: versionedDirectories(root: homeDirectory.appendingPathComponent(".asdf/installs/nodejs"), suffix: "bin"))
            directories.append(contentsOf: [
                homeDirectory.appendingPathComponent(".local/share/mise/shims", isDirectory: true),
                homeDirectory.appendingPathComponent(".asdf/shims", isDirectory: true)
            ])
        }
        directories.append(contentsOf: inheritedPath.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) })
        return uniqueDirectories(directories)
    }

    private func installation(for cliURL: URL, searchDirectories: [URL]) throws -> LarkCLIInstallation {
        let cliDirectory = cliURL.deletingLastPathComponent()
        var runtimeDirectories = [cliDirectory] + searchDirectories
        let interpreter = shebangInterpreter(at: cliURL)
        let launchURL: URL
        let prefixArguments: [String]

        if let interpreter {
            let interpreterName = interpreter.lastPathComponent
            if interpreterName == "node" || interpreterName == "nodejs" {
                if interpreter.path.hasPrefix("/"), isExecutable(interpreter) {
                    launchURL = interpreter
                } else if let resolved = resolveExecutable(named: interpreterName, directories: runtimeDirectories) {
                    launchURL = resolved
                } else {
                    throw LarkCLIResolverError.interpreterNotFound(name: interpreterName, cliPath: cliURL.path)
                }
                runtimeDirectories.insert(launchURL.deletingLastPathComponent(), at: 0)
                prefixArguments = [cliURL.path]
            } else {
                // Package-manager shims may use bash/sh. Launching the selected file
                // directly still preserves argv boundaries and does not use sh -c.
                launchURL = cliURL
                prefixArguments = []
            }
        } else {
            launchURL = cliURL
            prefixArguments = []
        }

        let systemDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let path = uniqueDirectories(runtimeDirectories + systemDirectories).map(\.path).joined(separator: ":")
        return LarkCLIInstallation(cliURL: cliURL, launchExecutableURL: launchURL, prefixArguments: prefixArguments, environmentPath: path)
    }

    private func shebangInterpreter(at url: URL) -> URL? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512), let text = String(data: data, encoding: .utf8), text.hasPrefix("#!") else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var tokens = line.dropFirst(2).split(whereSeparator: \.isWhitespace).map(String.init)
        guard let command = tokens.first else { return nil }
        tokens.removeFirst()
        if command == "/usr/bin/env" {
            if tokens.first == "-S" { tokens.removeFirst() }
            guard let name = tokens.first, !name.hasPrefix("-") else { return nil }
            return URL(fileURLWithPath: name)
        }
        return URL(fileURLWithPath: command)
    }

    private func resolveExecutable(named name: String, directories: [URL]) -> URL? {
        for directory in uniqueDirectories(directories) {
            let candidate = directory.appendingPathComponent(name)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    private func versionedDirectories(root: URL, suffix: String) -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return children.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .map { $0.appendingPathComponent(suffix, isDirectory: true) }
    }

    private func uniqueDirectories(_ directories: [URL]) -> [URL] {
        var seen = Set<String>()
        return directories.filter {
            let path = $0.standardizedFileURL.path
            return !path.isEmpty && seen.insert(path).inserted
        }
    }

    private func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }
}
