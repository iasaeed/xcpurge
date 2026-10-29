/// Kind of an asset-catalog entry, from its folder extension (`hero.imageset` -> `.image`).
public enum AssetType: String, Sendable, Codable, CaseIterable {
    case image, color, symbol, data, texture, cubeTexture, mipmap, spriteAtlas, imageStack, arResourceGroup
    case appIcon, launchImage, brandAssets, iconset, complication, iconComposer
    case stickerPack, sticker, gameCenter

    /// Folder extension -> type; folders with other extensions (or none) are plain groups.
    public static let byExtension: [String: AssetType] = [
        "imageset": .image, "colorset": .color, "symbolset": .symbol, "dataset": .data,
        "textureset": .texture, "cubetextureset": .cubeTexture, "mipmapset": .mipmap,
        "spriteatlas": .spriteAtlas, "imagestack": .imageStack, "arresourcegroup": .arResourceGroup,
        "appiconset": .appIcon, "launchimage": .launchImage, "brandassets": .brandAssets, "iconset": .iconset,
        "complicationset": .complication, "stickerpack": .stickerPack, "stickersequence": .sticker,
        "sticker": .sticker, "gcdashboardimage": .gameCenter, "gcleaderboard": .gameCenter,
        "gcleaderboardset": .gameCenter, "gcachievement": .gameCenter,
    ]

    /// App icons, launch images and complications: used through build settings / Info.plist, not by name in code.
    public var isAppIconLike: Bool {
        switch self {
        case .appIcon, .launchImage, .brandAssets, .iconset, .complication, .iconComposer: true
        default: false
        }
    }

    /// Kinds xcpurge never reports (consumed by system extensions or Game Center configuration).
    public var isAlwaysKept: Bool {
        switch self {
        case .stickerPack, .sticker, .gameCenter: true
        default: false
        }
    }
}
