import Foundation

struct ConfigurationStore {
  private let defaults: UserDefaults
  private let keychain: KeychainStore

  init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
    self.defaults = defaults
    self.keychain = keychain
  }

  func load() throws -> APIConfiguration? {
    guard let host = defaults.string(forKey: Keys.host), !host.isEmpty,
      let token = try keychain.readToken(), !token.isEmpty
    else { return nil }
    let storedPort = defaults.integer(forKey: Keys.port)
    return APIConfiguration(host: host, port: storedPort == 0 ? 8765 : storedPort, token: token)
  }

  func save(_ configuration: APIConfiguration) throws {
    try keychain.saveToken(configuration.token)
    defaults.set(configuration.host, forKey: Keys.host)
    defaults.set(configuration.port, forKey: Keys.port)
  }

  func clear() throws {
    try keychain.deleteToken()
    defaults.removeObject(forKey: Keys.host)
    defaults.removeObject(forKey: Keys.port)
  }

  private enum Keys {
    static let host = "connection.host"
    static let port = "connection.port"
  }
}
