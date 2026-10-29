// swiftlint:disable all
// Generated using SwiftGen - https://github.com/SwiftGen/SwiftGen

import UIKit

internal enum Asset {
  internal static let swiftgenBanner = ImageAsset(name: "swiftgen_banner")
  internal static let swiftgenUnused = ImageAsset(name: "swiftgen_unused")
}

internal struct ImageAsset {
  internal fileprivate(set) var name: String
  internal var image: UIImage { UIImage(named: name)! }
}
