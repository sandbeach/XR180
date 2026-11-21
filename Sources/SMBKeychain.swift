import Foundation
import Security

struct SMBLogin: Codable, Equatable {
    let username: String
    let password: String
}

enum SMBKeychain {
    private static let service = "local.xr180.player.smb-login"

    static func login(for share: URL) throws -> SMBLogin? {
        var query = item(for: share)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var data: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &data)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let encoded = data as? Data else { throw Failure(code: errSecDecode) }
        return try JSONDecoder().decode(SMBLogin.self, from: encoded)
    }

    static func save(_ login: SMBLogin, for share: URL) throws {
        let query = item(for: share)
        let secret = try JSONEncoder().encode(login)
        var attributes = query
        attributes[kSecAttrLabel as String] = "XR180 SMB · \(share.absoluteString)"
        attributes[kSecValueData as String] = secret
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try check(SecItemUpdate(query as CFDictionary, [kSecValueData as String: secret] as CFDictionary))
        } else {
            try check(status)
        }
    }

    @discardableResult
    static func remove(for share: URL) throws -> Bool {
        let status = SecItemDelete(item(for: share) as CFDictionary)
        if status == errSecItemNotFound { return false }
        try check(status)
        return true
    }

    private static func item(for share: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: share.absoluteString
        ]
    }

    private static func check(_ status: OSStatus) throws {
        if status != errSecSuccess { throw Failure(code: status) }
    }

    private struct Failure: LocalizedError {
        let code: OSStatus
        var errorDescription: String? { "钥匙串访问失败（\(code)）。请检查钥匙串是否已解锁，并在 macOS 提示时允许 XR180 访问。" }
    }
}
