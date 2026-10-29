/// Coarse file classification by extension, used for scanning and detector selection.
public enum FileKind: String, Codable, Sendable {
    case swift, objc, header, c, cpp, metal
    case storyboard, xib
    case assetCatalog, stringCatalog, strings, stringsdict
    case plist, entitlements, xcconfig, json, html, css, js
    case image, font, audio, video
    case dataModel, bundle, iconComposer, sceneAssets, docc, playground, framework
    case intentDefinition, packageManifest, other

    public init(path: String) {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if name == "Package.swift" { self = .packageManifest; return }
        let ext = name.split(separator: ".").count > 1 ? String(name.split(separator: ".").last!).lowercased() : ""
        switch ext {
        case "swift": self = .swift
        case "m", "mm": self = .objc
        case "h", "hpp": self = .header
        case "c": self = .c
        case "cc", "cpp", "cxx": self = .cpp
        case "metal": self = .metal
        case "storyboard": self = .storyboard
        case "xib": self = .xib
        case "xcassets": self = .assetCatalog
        case "xcstrings": self = .stringCatalog
        case "strings": self = .strings
        case "stringsdict": self = .stringsdict
        case "plist": self = .plist
        case "entitlements": self = .entitlements
        case "xcconfig": self = .xcconfig
        case "json", "geojson": self = .json
        case "html", "htm": self = .html
        case "css": self = .css
        case "js": self = .js
        case "png", "jpg", "jpeg", "gif", "pdf", "svg", "heic", "webp", "tif", "tiff", "bmp", "ico", "icns": self = .image
        case "ttf", "otf", "ttc", "woff", "woff2": self = .font
        case "mp3", "wav", "aiff", "aif", "caf", "m4a", "aac": self = .audio
        case "mp4", "mov", "m4v": self = .video
        case "xcdatamodeld", "xcdatamodel", "xcmappingmodel": self = .dataModel
        case "bundle": self = .bundle
        case "icon": self = .iconComposer
        case "scnassets", "rcproject", "reality": self = .sceneAssets
        case "docc": self = .docc
        case "playground": self = .playground
        case "framework", "xcframework": self = .framework
        case "intentdefinition": self = .intentDefinition
        default: self = .other
        }
    }

    /// Kinds whose contents are scanned for references.
    public var isReferenceSource: Bool {
        switch self {
        case .swift, .objc, .header, .c, .cpp, .metal, .storyboard, .xib, .plist, .entitlements,
             .xcconfig, .json, .html, .css, .js, .intentDefinition: true
        default: false
        }
    }

    /// Kinds that are folders treated as one unit (never descended into by the walker).
    public static let bundleExtensions: Set<String> = [
        "xcassets", "xcdatamodeld", "bundle", "framework", "icon", "scnassets", "rcproject",
        "docc", "playground", "xcframework",
    ]
}
