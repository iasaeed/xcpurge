import SpriteKit
import SwiftUI
import UIKit

@main
struct EdgeApp: App {
    var body: some Scene {
        WindowGroup { EdgeView() }
    }
}

struct EdgeView: View {
    let mode = "dark"
    let n = 7

    var body: some View {
        VStack {
            Color(.brand)                  // BrandColor.colorset: generated symbol drops "Color"
            Image(.no)                     // noImage.imageset: generated symbol drops "Image"
            Image(.abcLogo)                // ABCLogo.imageset
            Image(._2fa)                   // 2fa.imageset
            Image(.`default`)              // default.imageset (keyword)
            Image(.Icons.Settings.gear)    // provides-namespace chain
            Image(.xcodeChoseThis)         // indexed-only.imageset: only GeneratedAssetSymbols-Index.plist knows
            Image("plain_used")            // folder without namespace
            Image("custom.symbol")         // symbol set
            Image("badge_1")               // badge_2 is a numbered sibling
            Image(uiImage: UIImage(resource: .japanStreet))
            Image(uiImage: UIImage(named: "casehero")!)          // CaseHero.imageset, case differs
            Image(uiImage: #imageLiteral(resourceName: "literal_image"))
            Image(uiImage: Asset.swiftgenBanner.image)           // generated accessor (Generated/Assets.swift)
            Image(uiImage: UIImage(named: "tile_\(n)")!)         // dynamic: tile_7 is low
            Image(uiImage: UIImage(named: "loose_used")!)        // loose_used@2x.png / @3x.png
            Image(uiImage: UIImage(named: "pad_only")!)          // pad_only~ipad.png
            Image(uiImage: UIImage(named: "dupe_one")!)
            Image(uiImage: UIImage(named: "dupe_two.png")!)
            Text(verbatim: "Edge").font(.custom("Edge-Display", size: 12))
        }
        .onAppear {
            _ = NSDataAsset(name: "config_data")
            _ = SKTexture(imageNamed: "hero_run")                // inside Characters.spriteatlas
            let themeName = "theme_" + mode                      // unknown lookup kind: theme_dark is medium
            _ = UIImage(named: themeName)
            _ = NSBundleResourceRequest(tags: ["level1"])        // odr_level.imageset is low
            _ = Bundle.main.url(forResource: "web_logo", withExtension: "svg")
        }
    }
}
