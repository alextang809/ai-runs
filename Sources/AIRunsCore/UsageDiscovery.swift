import Foundation

public struct UsageSourceRoot: Sendable {
    public let provider: UsageProvider
    public let url: URL
    let desktopSessionStore: Bool

    public init(provider: UsageProvider, url: URL) {
        self.provider = provider
        self.url = url
        self.desktopSessionStore = false
    }

    private init(desktopStore: URL) {
        self.provider = .claudeCode
        self.url = desktopStore
        self.desktopSessionStore = true
    }

    public static func defaults(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> [Self] {
        let codex = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        var roots = [Self(provider: .codex, url: codex.appendingPathComponent("sessions")),
                     Self(provider: .codex, url: codex.appendingPathComponent("archived_sessions"))]
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            roots.append(Self(provider: .claudeCode, url: URL(fileURLWithPath: custom).appendingPathComponent("projects")))
        } else {
            roots += [Self(provider: .claudeCode, url: home.appendingPathComponent(".claude/projects")),
                      Self(provider: .claudeCode, url: home.appendingPathComponent(".config/claude/projects"))]
        }
        let desktop = home.appendingPathComponent("Library/Application Support/Claude")
        roots += [Self(desktopStore: desktop.appendingPathComponent("local-agent-mode-sessions")),
                  Self(desktopStore: desktop.appendingPathComponent("claude-code-sessions"))]
        return roots
    }

    var cacheIdentity: String {
        "\(provider.rawValue):\(desktopSessionStore):\(url.resolvingSymlinksInPath().standardizedFileURL.path)"
    }

    func contains(path: String, provider: UsageProvider) -> Bool {
        guard provider == self.provider, path.hasSuffix(".jsonl") else { return false }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        guard candidate.path == path, candidate.resolvingSymlinksInPath().path == path else { return false }
        let root = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path == root || path.hasPrefix(root + "/") else { return false }
        guard desktopSessionStore else { return true }
        let relative = String(path.dropFirst(root.count)).split(separator: "/")
        if relative.last == "audit.jsonl", relative.count <= 4 { return true }
        guard let index = relative.firstIndex(of: ".claude"), index <= 3,
              relative.indices.contains(index + 1), relative[index + 1] == "projects" else { return false }
        return true
    }
}

struct UsageDiscoveryResult {
    var files: [String: UsageProvider] = [:]
    var issues: [UsageProvider: Set<UsageIssue>] = [:]
    var complete = true
}

/// Discovers only explicitly selected history trees. Links inside a history tree
/// are skipped; a link supplied as the root itself is resolved once.
enum UsageDiscovery {
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    private static let skippedDesktopDirectories: Set<String> = [
        "workspace", "workspaces", "outputs", "output", "node_modules", "dependencies", ".git", "cache", "caches",
    ]

    static func discover(_ roots: [UsageSourceRoot], entryLimit: Int) -> UsageDiscoveryResult {
        var result = UsageDiscoveryResult()
        var remaining = max(1, entryLimit)
        for root in roots {
            let url = root.url.resolvingSymlinksInPath().standardizedFileURL
            do { _ = try FileManager.default.attributesOfItem(atPath: url.path) }
            catch {
                let code = (error as NSError).code
                if code != CocoaError.fileNoSuchFile.rawValue && code != CocoaError.fileReadNoSuchFile.rawValue {
                    result.issues[root.provider, default: []].insert(.ioFailure)
                    result.complete = false
                }
                continue
            }
            if root.desktopSessionStore {
                desktop(url, provider: root.provider, remaining: &remaining, result: &result)
            } else {
                transcripts(url, provider: root.provider, remaining: &remaining, result: &result)
            }
        }
        return result
    }

    private static func transcripts(_ root: URL, provider: UsageProvider, remaining: inout Int,
                                    result: inout UsageDiscoveryResult) {
        var pending = [(root, 0)]
        while let (url, depth) = pending.popLast() {
            guard consumeBudget(&remaining, provider: provider, result: &result) else { return }
            guard let values = resources(url, provider: provider, result: &result) else { continue }
            if values.isSymbolicLink == true {
                result.issues[provider, default: []].insert(.unsupportedHistory)
            } else if values.isRegularFile == true, url.pathExtension == "jsonl" {
                guard result.files.count < 5_000 else {
                    result.issues[provider, default: []].insert(.unsupportedHistory)
                    result.complete = false
                    return
                }
                result.files[url.standardizedFileURL.path] = provider
            } else if values.isRegularFile == true, url.lastPathComponent.hasSuffix(".jsonl.zst") {
                result.issues[provider, default: []].insert(.unsupportedHistory)
            } else if values.isDirectory == true {
                guard depth < 12 else {
                    result.issues[provider, default: []].insert(.unsupportedHistory)
                    result.complete = false
                    continue
                }
                for child in children(url, provider: provider, remaining: &remaining, result: &result) {
                    pending.append((child, depth + 1))
                }
            }
        }
    }

    /// The desktop's account/session wrappers occupy at most three directories.
    /// Once a session is reached, inspect only audit.jsonl and .claude/projects,
    /// never the session's workspace, generated output or dependencies.
    private static func desktop(_ root: URL, provider: UsageProvider, remaining: inout Int,
                                result: inout UsageDiscoveryResult) {
        var pending = [(root, 0)]
        while let (url, depth) = pending.popLast() {
            guard consumeBudget(&remaining, provider: provider, result: &result) else { return }
            let audit = url.appendingPathComponent("audit.jsonl")
            if exists(audit, provider: provider, result: &result) {
                transcripts(audit, provider: provider, remaining: &remaining, result: &result)
            }
            let projects = url.appendingPathComponent(".claude/projects")
            if exists(projects, provider: provider, result: &result) {
                let configuration = url.appendingPathComponent(".claude")
                let configurationValues = resources(configuration, provider: provider, result: &result)
                let projectValues = resources(projects, provider: provider, result: &result)
                if configurationValues?.isSymbolicLink == true || projectValues?.isSymbolicLink == true {
                    result.issues[provider, default: []].insert(.unsupportedHistory)
                } else if configurationValues != nil && projectValues != nil {
                    transcripts(projects, provider: provider, remaining: &remaining, result: &result)
                }
            }
            guard depth < 3 else { continue }
            for child in children(url, provider: provider, remaining: &remaining, result: &result) {
                guard !skippedDesktopDirectories.contains(child.lastPathComponent.lowercased()),
                      child.lastPathComponent != ".claude",
                      let values = resources(child, provider: provider, result: &result),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                pending.append((child, depth + 1))
            }
        }
    }

    private static func exists(_ url: URL, provider: UsageProvider,
                               result: inout UsageDiscoveryResult) -> Bool {
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return true }
        catch {
            let code = (error as NSError).code
            if code != CocoaError.fileNoSuchFile.rawValue && code != CocoaError.fileReadNoSuchFile.rawValue {
                result.issues[provider, default: []].insert(.ioFailure)
                result.complete = false
            }
            return false
        }
    }

    private static func consumeBudget(_ remaining: inout Int, provider: UsageProvider,
                                      result: inout UsageDiscoveryResult) -> Bool {
        guard remaining > 0 else {
            result.issues[provider, default: []].insert(.unsupportedHistory)
            result.complete = false
            return false
        }
        remaining -= 1
        return true
    }

    private static func resources(_ url: URL, provider: UsageProvider,
                                  result: inout UsageDiscoveryResult) -> URLResourceValues? {
        do { return try url.resourceValues(forKeys: keys) }
        catch {
            result.issues[provider, default: []].insert(.ioFailure)
            result.complete = false
            return nil
        }
    }

    private static func children(_ url: URL, provider: UsageProvider, remaining: inout Int,
                                result: inout UsageDiscoveryResult) -> [URL] {
        var failed = false
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                    options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in failed = true; return false }) else {
            result.issues[provider, default: []].insert(.ioFailure)
            result.complete = false
            return []
        }
        var children: [URL] = []
        for case let child as URL in enumerator {
            guard consumeBudget(&remaining, provider: provider, result: &result) else { break }
            children.append(child)
        }
        if failed {
            result.issues[provider, default: []].insert(.ioFailure)
            result.complete = false
        }
        return children
    }
}
