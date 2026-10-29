import Foundation
import Security

/// The bridge token, stored on this device only.
enum Keychain {
    private static let service = "org.example.iperipheral"
    private static let account = "bridge-token"

    static var token: String? {
        get {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecReturnData as String: true,
            ]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else {
                return nil
            }
            return String(data: d, encoding: .utf8)
        }
        set {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(q as CFDictionary)
            guard let newValue else { return }
            var add = q
            add[kSecValueData as String] = Data(newValue.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
