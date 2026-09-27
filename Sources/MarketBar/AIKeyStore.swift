import Foundation
import Security

protocol AIKeyStore {
    func read(_ account: String) throws -> String?
    func save(_ value: String, account: String) throws
}

struct KeychainAIKeyStore: AIKeyStore {
    var service = "com.marketbar.ai-sign"

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read(_ account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw AISignError.message("无法读取钥匙串中的 AI Key（\(status)）")
        }
        return value
    }

    /// 空值只删除本功能对应的 Key，不接触其它钥匙串条目。
    func save(_ value: String, account: String) throws {
        let query = query(account)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AISignError.message("无法移除 AI Key（\(status)）")
            }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var entry = query
            entry[kSecValueData as String] = data
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(entry as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AISignError.message("无法保存 AI Key（\(status)）") }
    }
}
