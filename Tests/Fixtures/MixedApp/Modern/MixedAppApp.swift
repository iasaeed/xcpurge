import SwiftUI

/// Synchronized-folder source that uses the classic group's code and both catalogs.
@main
struct MixedAppApp: App {
    let banner = LegacyBanner()
    let content = ContentLoader.urls()

    var body: some Scene {
        WindowGroup {
            Image("modern_used")
            Text(banner.title())
        }
    }
}
