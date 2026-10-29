import Foundation

enum ContentLoader {
    /// Every JSON file of the blue `Content` folder reference.
    static func urls() -> [URL] {
        Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "Content") ?? []
    }
}
