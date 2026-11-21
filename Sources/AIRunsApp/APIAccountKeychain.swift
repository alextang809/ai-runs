import AIRunsCore
import Foundation
import Security

protocol APIAccountKeyStoring: Sendable {
    func load(for account: ManagedAccount) throws -> APIAccountCredentials?
    func save(_ credentials: APIAccountCredentials, for account: ManagedAccount) throws
    func remove(for account: ManagedAccount) throws
}

struct APIAccountKeychain: APIAccountKeyStoring {
    func load(for account: ManagedAccount) throws -> APIAccountCredentials? {
        let query = item(for: account).merging([kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]) { current, _ in current }
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data,
              let credentials = try? JSONDecoder().decode(APIAccountCredentials.self, from: data) else { throw APIAccountError.keychain }
        return credentials
    }

    func save(_ credentials: APIAccountCredentials, for account: ManagedAccount) throws {
        let query = item(for: account)
        let attributes: [CFString: Any] = [kSecValueData: try JSONEncoder().encode(credentials)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let newItem = query.merging(attributes) { current, _ in current }
            guard SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess else { throw APIAccountError.keychain }
        } else if status != errSecSuccess {
            throw APIAccountError.keychain
        }
    }

    func remove(for account: ManagedAccount) throws {
        let status = SecItemDelete(item(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw APIAccountError.keychain }
    }

    private func item(for account: ManagedAccount) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "io.github.alextang809.airuns.api-key",
         kSecAttrAccount: "\(account.provider.rawValue):\(account.id.uuidString.lowercased())"]
    }
}
