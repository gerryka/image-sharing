import Foundation
import Security

public enum StorageError: Error, Equatable, Sendable, UserFacingError {
    case keyMissing
    case keychain(OSStatus)

    public var message: String {
        switch self {
        case .keyMissing: "Schlüssel nicht gefunden – bitte Chat neu einrichten."
        case .keychain(let s): "Schlüsselbund-Fehler (\(s))."
        }
    }
}

/// Root-Key und Invite-Code im Schlüsselbund (Ersatz für DPAPI unter Windows).
public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String = "at.mediatesystems.imgshare") { self.service = service }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func set(_ data: Data, account: String) throws {
        let status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = base(account)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            q[kSecAttrSynchronizable as String] = false
            let s = SecItemAdd(q as CFDictionary, nil)
            guard s == errSecSuccess else { throw StorageError.keychain(s) }
        } else if status != errSecSuccess {
            throw StorageError.keychain(status)
        }
    }

    public func get(account: String) throws -> Data? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess else { throw StorageError.keychain(s) }
        return out as? Data
    }

    public func delete(account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    public func rootKey(chatId: String) throws -> Data {
        guard let k = try get(account: "\(chatId).key"), k.count == ChatKeys.rootKeyLength else {
            throw StorageError.keyMissing
        }
        return k
    }

    public func setRootKey(_ key: Data, chatId: String) throws {
        try set(key, account: "\(chatId).key")
    }

    public func invite(chatId: String) -> String? {
        guard let d = try? get(account: "\(chatId).invite"), let s = String(data: d, encoding: .utf8),
              !s.isEmpty else { return nil }
        return s
    }

    public func setInvite(_ invite: String?, chatId: String) throws {
        let t = invite?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty { delete(account: "\(chatId).invite") } else { try set(Data(t.utf8), account: "\(chatId).invite") }
    }

    public func removeAll(chatId: String) {
        delete(account: "\(chatId).key")
        delete(account: "\(chatId).invite")
    }
}
