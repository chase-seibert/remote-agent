import Foundation
import Security

struct KeychainStore: Sendable {
  private let service = "com.cseibert.RemoteAgentIOS"
  private let account = "remote-agent-bearer-token"

  func readToken() throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data,
      let token = String(data: data, encoding: .utf8)
    else {
      throw KeychainError.operationFailed(status)
    }
    return token
  }

  func saveToken(_ token: String) throws {
    let encoded = Data(token.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: encoded,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainError.operationFailed(updateStatus)
    }

    var newItem = query
    for (key, value) in attributes {
      newItem[key] = value
    }
    let addStatus = SecItemAdd(newItem as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainError.operationFailed(addStatus)
    }
  }

  func deleteToken() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.operationFailed(status)
    }
  }
}

enum KeychainError: LocalizedError {
  case operationFailed(OSStatus)

  var errorDescription: String? {
    "Could not access the saved connection credential."
  }
}
