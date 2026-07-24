import Foundation
import Security

struct APIKeyStore {
	enum Key: String {
		case elevenLabs = "elevenlabs"
	}

	private let service = Bundle.main.bundleIdentifier ?? "com.stefan.myvoicememo"

	func value(for key: Key) -> String {
		let query: [CFString: Any] = [
			kSecClass: kSecClassGenericPassword,
			kSecAttrService: service,
			kSecAttrAccount: key.rawValue,
			kSecReturnData: true,
			kSecMatchLimit: kSecMatchLimitOne
		]
		var result: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
			let data = result as? Data,
			let value = String(data: data, encoding: .utf8)
		else { return "" }
		return value
	}

	func set(_ value: String, for key: Key) {
		let query: [CFString: Any] = [
			kSecClass: kSecClassGenericPassword,
			kSecAttrService: service,
			kSecAttrAccount: key.rawValue
		]
		SecItemDelete(query as CFDictionary)

		let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !value.isEmpty else { return }
		var item = query
		item[kSecValueData] = Data(value.utf8)
		item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
		assert(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
	}
}
