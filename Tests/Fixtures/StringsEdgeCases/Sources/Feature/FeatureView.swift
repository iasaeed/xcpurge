import SwiftUI

struct FeatureView: View {
    let count: Int
    let code: String
    let name: String
    let title: String

    var body: some View {
        VStack {
            Text("module_key", bundle: .module)
            Text(String(localized: "hash_bundle_key", bundle: #bundle))
            Text(String(localized: .symbolUsed))
            Text(.itemsCount(count))
            Text(.FeatureStrings.featureTitle)
            Text("table_key", tableName: "Legacy", bundle: .module)
            Text(LocalizedStringKey("status_\(code)"), bundle: .module)
            Text("Hello \(name)", bundle: .module)
            Text("stale_found", bundle: .module)
            Text(NSLocalizedString("plural_used", tableName: "Plurals", bundle: .module, comment: ""))
            Text(L10n.swiftgenUsed)
            Text(R.string.gen.rswiftUsed)
            Text(Date(), style: .date)
            Text(title)
        }
        .navigationTitle(Text("nav_title", bundle: .module))
    }
}

enum Loose {
    /// A key held in a constant: found, but not inside a localization call.
    static let key = "loose_key"
    /// No `bundle:` inside a package: resolves against the app's main bundle.
    static func noBundle() -> String { NSLocalizedString("no_bundle_key", comment: "") }
    /// The receiver is the bundle.
    static func byReceiver() -> String { Bundle.module.localizedString(forKey: "receiver_key", value: nil, table: nil) }
    /// Generated symbol used outside a localization call.
    static let device: LocalizedStringResource = .deviceKey
}
