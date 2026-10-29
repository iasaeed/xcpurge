/// A (source index, line) pair, used for `xcpurge:ignore` markers.
public struct FileLine: Hashable, Sendable {
    public let file: Int32
    public let line: Int32
    public init(file: Int32, line: Int32) {
        self.file = file
        self.line = line
    }
}
