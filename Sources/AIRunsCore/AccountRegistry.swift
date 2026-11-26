import Darwin
import Foundation

/// Stores display metadata separately from CLI-owned credential profiles.
/// Directory traversal and atomic writes use no-follow, descriptor-relative paths.
public struct AccountRegistry: Sendable {
    public let root: URL
    private let metadataName = "accounts.json"
    private let maximumMetadataBytes = 1_048_576

    public init(root: URL) { self.root = root }

    public func load() throws -> [ManagedAccount] {
        guard let directory = try rootDescriptor(create: false) else { return [] }
        defer { close(directory) }
        guard let data = try readData(named: metadataName, in: directory) else { return [] }
        do {
            let accounts = try JSONDecoder().decode([ManagedAccount].self, from: data)
            try validate(accounts)
            return accounts
        } catch {
            throw AccountRegistryError.invalidMetadata
        }
    }

    public func save(_ accounts: [ManagedAccount]) throws {
        try validate(accounts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(accounts)
        guard let directory = try rootDescriptor(create: true) else { throw AccountRegistryError.writeFailed }
        defer { close(directory) }
        try writeData(data, named: metadataName, in: directory)
    }

    public func recordPlanUsage(for account: ManagedAccount, windows: [AccountRateWindow], at date: Date) throws {
        guard let identity = PlanUsageHistory.identity(of: account) else { return }
        let observations = PlanUsageHistory.observations(identity: identity, windows: windows, at: date)
        guard !observations.isEmpty else { return }
        guard let directory = try rootDescriptor(create: true) else { throw AccountRegistryError.writeFailed }
        defer { close(directory) }

        let name = planUsageFile(for: account)
        let history = try readPlanUsage(named: name, in: directory)
        let updated = history.recording(observations, at: date)
        guard updated != history else { return }
        try writeData(JSONEncoder().encode(updated), named: name, in: directory)
    }

    func loadPlanUsage(for account: ManagedAccount) throws -> PlanUsageHistory {
        guard let identity = PlanUsageHistory.identity(of: account),
              let directory = try rootDescriptor(create: false) else { return .init(cycles: []) }
        defer { close(directory) }
        let history = try readPlanUsage(named: planUsageFile(for: account), in: directory)
        return .init(cycles: history.cycles.filter { $0.identity == identity })
    }

    private func planUsageFile(for account: ManagedAccount) -> String {
        "plan-usage-\(account.id.uuidString.lowercased()).json"
    }

    private func readPlanUsage(named name: String, in directory: Int32) throws -> PlanUsageHistory {
        guard let data = try readData(named: name, in: directory) else { return .init(cycles: []) }
        do { return try JSONDecoder().decode(PlanUsageHistory.self, from: data) }
        catch { throw AccountRegistryError.invalidMetadata }
    }

    private func readData(named name: String, in directory: Int32) throws -> Data? {
        guard let descriptor = try fileDescriptor(named: name, in: directory) else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            let data = try handle.read(upToCount: maximumMetadataBytes + 1) ?? Data()
            guard data.count <= maximumMetadataBytes else { throw AccountRegistryError.invalidMetadata }
            return data
        } catch {
            throw AccountRegistryError.invalidMetadata
        }
    }

    private func writeData(_ data: Data, named name: String, in directory: Int32) throws {
        guard data.count <= maximumMetadataBytes else { throw AccountRegistryError.writeFailed }
        if let existing = try fileDescriptor(named: name, in: directory) { close(existing) }
        let temporary = ".accounts-\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw AccountRegistryError.writeFailed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            unlinkat(directory, temporary, 0)
        }
        do {
            guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw AccountRegistryError.writeFailed }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard renameat(directory, temporary, directory, name) == 0,
                  fsync(directory) == 0 else { throw AccountRegistryError.writeFailed }
        } catch {
            throw AccountRegistryError.writeFailed
        }
    }

    public func profileURL(for account: ManagedAccount) throws -> URL {
        guard let directory = try rootDescriptor(create: true) else { throw AccountRegistryError.writeFailed }
        defer { close(directory) }
        let provider = try privateDirectory(account.provider.rawValue, in: directory)
        defer { close(provider) }
        let name = account.id.uuidString.lowercased()
        let profile = try privateDirectory(name, in: provider)
        defer { close(profile) }
        return try physicalRoot().appendingPathComponent(account.provider.rawValue, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private func validate(_ accounts: [ManagedAccount]) throws {
        guard accounts.count <= 128, Set(accounts.map(\.id)).count == accounts.count,
              accounts.allSatisfy({ account in
                  validText(account.label, limit: 128) && !account.label.isEmpty
                    && (account.email.map({ validText($0, limit: 320) }) ?? true)
                    && (account.plan.map({ validText($0, limit: 128) }) ?? true)
                    && account.createdAt.timeIntervalSince1970.isFinite
                    && (account.lastVerifiedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true)
              }) else { throw AccountRegistryError.invalidMetadata }
    }

    private func validText(_ text: String, limit: Int) -> Bool {
        text.count <= limit && text.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private func rootDescriptor(create: Bool) throws -> Int32? {
        let components = try physicalRoot().path.split(separator: "/").map(String.init)
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw AccountRegistryError.readFailed }
        do {
            for component in components {
                if create, mkdirat(directory, component, mode_t(0o700)) != 0, errno != EEXIST {
                    throw AccountRegistryError.writeFailed
                }
                let child = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0, errno == ENOENT, !create { close(directory); return nil }
                guard child >= 0 else { throw AccountRegistryError.unsafePath }
                close(directory)
                directory = child
            }
            try validatePrivateDirectory(directory, repairPermissions: create)
            return directory
        } catch {
            close(directory)
            throw error
        }
    }

    private func physicalRoot() throws -> URL {
        var components = root.path.split(separator: "/").map(String.init)
        guard root.isFileURL, root.path.hasPrefix("/"), !components.isEmpty,
              !components.contains("."), !components.contains("..") else { throw AccountRegistryError.unsafePath }
        // Darwin's two system aliases are normalized explicitly; application-owned
        // links are still rejected by descriptor-relative O_NOFOLLOW traversal.
        if components.first == "var" || components.first == "tmp" {
            components.insert("private", at: 0)
        }
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"), isDirectory: true)
    }

    private func privateDirectory(_ name: String, in parent: Int32) throws -> Int32 {
        if mkdirat(parent, name, mode_t(0o700)) != 0, errno != EEXIST { throw AccountRegistryError.writeFailed }
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw AccountRegistryError.unsafePath }
        do {
            try validatePrivateDirectory(directory, repairPermissions: true)
            return directory
        } catch {
            close(directory)
            throw error
        }
    }

    private func validatePrivateDirectory(_ descriptor: Int32, repairPermissions: Bool) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_uid == getuid(),
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw AccountRegistryError.unsafePath }
        if repairPermissions {
            guard fchmod(descriptor, mode_t(0o700)) == 0 else { throw AccountRegistryError.writeFailed }
        } else if status.st_mode & mode_t(0o077) != 0 {
            throw AccountRegistryError.unsafePath
        }
    }

    private func fileDescriptor(named name: String, in directory: Int32) throws -> Int32? {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw AccountRegistryError.unsafePath }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_uid == getuid(), status.st_nlink == 1,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), status.st_mode & mode_t(0o077) == 0,
              status.st_size >= 0, status.st_size <= Int64(maximumMetadataBytes) else {
            close(descriptor)
            throw AccountRegistryError.unsafePath
        }
        return descriptor
    }
}
