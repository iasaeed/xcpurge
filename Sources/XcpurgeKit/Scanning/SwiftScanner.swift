import Foundation

/// Extracts references from Swift source: literals with call context, member symbols, identifiers,
/// dynamic name patterns and `xcpurge:ignore` markers.
public enum SwiftScanner {
    public static func scan(_ data: Data, file: Int32, localizationMacros: [String] = []) -> ScanOutput {
        let tokenized = SwiftTokenizer.tokenize(data, dialect: .swift)
        if GeneratedAccessorScanner.isGenerated(head: data.prefix(2048)) {
            var out = ScanOutput()
            out.isGenerated = true
            out.accessors = GeneratedAccessorScanner.accessors(in: tokenized.tokens)
            return out
        }
        return TokenReferenceExtractor.extract(tokenized, file: file, dialect: .swift, localizationMacros: localizationMacros)
    }

    public static func scan(_ text: String, file: Int32 = 0, localizationMacros: [String] = []) -> ScanOutput {
        scan(Data(text.utf8), file: file, localizationMacros: localizationMacros)
    }
}
