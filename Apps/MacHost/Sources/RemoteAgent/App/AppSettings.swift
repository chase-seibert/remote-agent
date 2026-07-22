import Foundation
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark

  var id: Self { self }

  var label: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

@MainActor
final class AppSettings: ObservableObject {
  private enum Key {
    static let projectsRoot = "projectsRoot"
    static let codexPath = "codexPath"
    static let codexModel = "codexModel"
    static let apiEnabled = "apiEnabled"
    static let apiPort = "apiPort"
    static let apiToken = "apiToken"
    static let fontScale = "fontScale"
    static let appearance = "appearance"
    static let autoRelaunchAfterCrash = "autoRelaunchAfterCrash"
    static let selectedMakeTargetsBySession = "selectedMakeTargetsBySession"
  }

  private let defaults: UserDefaults

  @Published var projectsRoot: String {
    didSet { defaults.set(projectsRoot, forKey: Key.projectsRoot) }
  }
  @Published var codexPath: String { didSet { defaults.set(codexPath, forKey: Key.codexPath) } }
  @Published var codexModel: String {
    didSet { defaults.set(codexModel, forKey: Key.codexModel) }
  }
  @Published var apiEnabled: Bool { didSet { defaults.set(apiEnabled, forKey: Key.apiEnabled) } }
  @Published var apiPort: Int { didSet { defaults.set(apiPort, forKey: Key.apiPort) } }
  @Published var apiToken: String { didSet { defaults.set(apiToken, forKey: Key.apiToken) } }
  @Published var fontScale: Double { didSet { defaults.set(fontScale, forKey: Key.fontScale) } }
  @Published var appearance: AppAppearance {
    didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
  }
  @Published var autoRelaunchAfterCrash: Bool {
    didSet { defaults.set(autoRelaunchAfterCrash, forKey: Key.autoRelaunchAfterCrash) }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    projectsRoot =
      defaults.string(forKey: Key.projectsRoot)
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("projects").path
    codexPath =
      defaults.string(forKey: Key.codexPath)
      ?? "/Applications/ChatGPT.app/Contents/Resources/codex"
    codexModel = defaults.string(forKey: Key.codexModel) ?? ""
    apiEnabled = defaults.object(forKey: Key.apiEnabled) as? Bool ?? true
    let storedPort = defaults.integer(forKey: Key.apiPort)
    apiPort = storedPort == 0 ? 8765 : storedPort
    apiToken = defaults.string(forKey: Key.apiToken) ?? Self.makeToken()
    fontScale = defaults.object(forKey: Key.fontScale) as? Double ?? 1
    appearance =
      defaults.string(forKey: Key.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .system
    autoRelaunchAfterCrash =
      defaults.object(forKey: Key.autoRelaunchAfterCrash) as? Bool ?? true
    defaults.set(apiToken, forKey: Key.apiToken)
    defaults.set(autoRelaunchAfterCrash, forKey: Key.autoRelaunchAfterCrash)
  }

  func increaseFontScale() { fontScale = min(fontScale + 0.1, 1.8) }
  func decreaseFontScale() { fontScale = max(fontScale - 0.1, 0.7) }
  func resetFontScale() { fontScale = 1 }
  func regenerateToken() { apiToken = Self.makeToken() }

  func selectedMakeTarget(sessionID: UUID) -> String? {
    (defaults.dictionary(forKey: Key.selectedMakeTargetsBySession) as? [String: String])?[
      sessionID.uuidString
    ]
  }

  func clearSelectedMakeTarget(sessionID: UUID) {
    var selections =
      defaults.dictionary(forKey: Key.selectedMakeTargetsBySession) as? [String: String] ?? [:]
    selections.removeValue(forKey: sessionID.uuidString)
    defaults.set(selections, forKey: Key.selectedMakeTargetsBySession)
  }

  private static func makeToken() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
      + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }
}
