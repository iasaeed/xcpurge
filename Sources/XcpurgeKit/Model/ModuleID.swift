/// Identity of a module: the container (xcodeproj or package dir, root-relative) plus the target name.
public struct ModuleID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let container: String
    public let name: String

    public init(container: String, name: String) {
        self.container = container
        self.name = name
    }

    /// Files no project or package claims; visible to and from every module.
    public static let unknown = ModuleID(container: "", name: "unknown")

    public var description: String { container.isEmpty ? name : "\(container):\(name)" }

    public static func < (lhs: ModuleID, rhs: ModuleID) -> Bool {
        (lhs.container, lhs.name) < (rhs.container, rhs.name)
    }
}
