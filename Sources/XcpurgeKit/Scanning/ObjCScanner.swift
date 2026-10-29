import Foundation

/// Extracts references from Objective-C / C / C++ / Metal source: `@"…"` literals with message-send context,
/// identifiers, `#import "X.h"` names and format-string patterns.
public enum ObjCScanner {
    public static func scan(_ data: Data, file: Int32, localizationMacros: [String] = []) -> ScanOutput {
        let tokenized = SwiftTokenizer.tokenize(data, dialect: .objc)
        return TokenReferenceExtractor.extract(tokenized, file: file, dialect: .objc, localizationMacros: localizationMacros)
    }

    public static func scan(_ text: String, file: Int32 = 0, localizationMacros: [String] = []) -> ScanOutput {
        scan(Data(text.utf8), file: file, localizationMacros: localizationMacros)
    }
}
