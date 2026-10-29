// LANE: B
/// Removes unused keys from `.xcstrings` / `.strings` / `.stringsdict` (plan §4.6 step 6), backing every
/// file up into the `TrashStore` first. Handover stub: Lane B implements `apply`.
public struct PruneStrings: Sendable {
    public let store: TrashStore

    public init(store: TrashStore) {
        self.store = store
    }

    public func apply(_ findings: [Finding], context: ScanContext) throws -> ActionReport { ActionReport() }
}
