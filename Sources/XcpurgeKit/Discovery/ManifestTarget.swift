/// Manifest-level description of a package target, shared by the `dump-package` and token-based readers.
struct ManifestTarget {
    enum Dependency {
        case byName(String)
        case target(String)
        case product(name: String, package: String?)
    }

    var name: String
    var type: String
    var path: String?
    var exclude: [String] = []
    var resources: [PackageResource] = []
    var dependencies: [Dependency] = []
}
