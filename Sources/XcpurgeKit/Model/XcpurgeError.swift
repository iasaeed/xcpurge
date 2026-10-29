/// Errors that abort a scan (as opposed to `Diagnostics`, which never do).
public enum XcpurgeError: Error, CustomStringConvertible, Sendable {
    case invalidProject(String, String)
    case invalidConfig(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .invalidProject(let path, let why): "invalid project \(path): \(why)"
        case .invalidConfig(let why): "invalid configuration: \(why)"
        case .notFound(let path): "not found: \(path)"
        }
    }
}
