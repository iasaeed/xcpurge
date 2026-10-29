import Foundation

enum ResourceLoader {
    static func config() -> Data? {
        guard let url = Bundle.main.url(forResource: "config", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }
}
