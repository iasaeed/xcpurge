// LANE: A
/// Deletes findings safely: moves files / asset sets into the `TrashStore` and removes their project
/// references via `PBXProjEditor`. Handover stub: Lane A implements `apply`.
public struct Trash: Sendable {
    public let store: TrashStore

    public init(store: TrashStore) {
        self.store = store
    }

    /// Moves every deletable finding's path into the trash and updates project files.
    public func apply(_ findings: [Finding], context: ScanContext) throws -> ActionReport { ActionReport() }
}
