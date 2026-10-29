import SwiftUI
import DesignSystem

struct ContentView: View {
    let code = 404

    var body: some View {
        VStack {
            Image("hero")
            Image(.Brand.brandMark)
            // Generated symbol for DesignSystem's `logo`; visible because App depends on DesignSystem.
            Image(.logo)
            Image("dup_a")
            ForEach(1..<3) { i in
                Image("icon_\(i)")
            }
            Text("welcome_title")
            Text(String(localized: "manual_used"))
            Text(.onboardingStepTitle)
            Text(String(localized: "error_\(code)"))
            // DesignSystem also has `shared_key`; without `bundle:` this resolves against the main bundle.
            Text("shared_key")
            Text(NSLocalizedString("legacy_greeting", tableName: "Legacy", comment: ""))
            Text(String.localizedStringWithFormat(NSLocalizedString("legacy_items", tableName: "Legacy", comment: ""), 3))
            Text(verbatim: "Brand").font(.custom("Brand-Regular", size: 14))
            DSButton(title: DSStrings.title)
        }
        .onAppear { _ = ResourceLoader.config() }
    }
}
