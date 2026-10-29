// swiftlint:disable all
// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen

import Foundation

// MARK: - Strings

internal enum L10n {
  /// Used through SwiftGen
  internal static let swiftgenUsed = L10n.tr("Gen", "swiftgen_used", fallback: "SwiftGen")
  /// Never used
  internal static let genUnused = L10n.tr("Gen", "gen_unused", fallback: "Unused")
}

extension L10n {
  private static func tr(_ table: String, _ key: String, _ args: CVarArg..., fallback value: String) -> String {
    let format = Bundle.module.localizedString(forKey: key, value: value, table: table)
    return String(format: format, locale: Locale.current, arguments: args)
  }
}
