import BibleLookupCore
import Foundation
import Security

/// API keys live in the keychain; the API.Bible translation IDs and the anonymous
/// fair-use device ID live in the app's preferences.
enum SettingsStore {
    private static let service = "Bible Lookup"
    private static let defaults = UserDefaults.standard

    enum Key: String, CaseIterable {
        case esv = "esv_api_key"
        case nlt = "nlt_api_key"
        case apiBible = "api_bible_key"
    }

    static func loadConfig() -> Config {
        Config(esvKey: read(.esv), nltKey: read(.nlt), apiBibleKey: read(.apiBible),
               apiBible: apiBibleIds, fumsDeviceId: fumsDeviceId())
    }

    // MARK: keychain

    static func read(_ key: Key) -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func write(_ key: Key, _ value: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            let status = SecItemDelete(q as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Bible Lookup: \(key.rawValue)"
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    // MARK: preferences

    static var apiBibleIds: [String: FoundBible] {
        get {
            guard let data = defaults.data(forKey: "apiBible"),
                  let found = try? JSONDecoder().decode([String: FoundBible].self, from: data) else { return [:] }
            return found
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: "apiBible")
        }
    }

    /// A random ID for API.Bible's fair-use reports (no personal information).
    static func fumsDeviceId() -> String {
        if let id = defaults.string(forKey: "fumsDeviceId"), !id.isEmpty { return id }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(id, forKey: "fumsDeviceId")
        return id
    }
}
