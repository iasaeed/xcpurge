import Kit
import SwiftUI
import UIKit

/// Uses Kit's catalog image from the app: Kit's assets are visible to App only through the cross-project link.
@main
struct CrossApp: App {
    var body: some Scene {
        WindowGroup {
            Image(uiImage: UIImage(named: "kit_hero", in: Bundle(for: KitMarker.self), compatibleWith: nil)!)
        }
    }
}
