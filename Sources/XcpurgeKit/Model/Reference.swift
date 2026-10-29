/// One reference site: a token value found in a scanned file.
public struct Reference: Sendable, Hashable {
    public var kind: RefKind
    public var value: String
    /// Index into `ReferenceIndex.sources` (inventory index, or a synthetic build-settings source).
    public var file: Int32
    public var line: Int32
    public var context: CallContext?

    public init(kind: RefKind, value: String, file: Int32, line: Int32, context: CallContext? = nil) {
        self.kind = kind
        self.value = value
        self.file = file
        self.line = line
        self.context = context
    }
}
