import CoreText
import Foundation

/// Names a bundled font file can be referenced by: PostScript, family and full names via CoreText,
/// plus the file name and stem. Unreadable or placeholder files yield only the file-derived names.
public enum FontInspector {
    public struct Names: Sendable, Hashable {
        public var postScript: [String] = []
        public var family: [String] = []
        public var full: [String] = []

        /// Every name, without duplicates, in a stable order.
        public var all: [String] {
            var seen = Set<String>()
            return (postScript + full + family).filter { !$0.isEmpty && seen.insert($0).inserted }
        }
    }

    /// Font names embedded in the file (one entry per face for collections).
    public static func names(of url: URL) -> Names {
        var out = Names()
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
            return out
        }
        for d in descriptors {
            if let s = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String { out.postScript.append(s) }
            if let s = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String { out.family.append(s) }
            if let s = CTFontDescriptorCopyAttribute(d, kCTFontDisplayNameAttribute) as? String { out.full.append(s) }
        }
        return out
    }

    /// File name, stem and embedded names: everything a reference may spell.
    public static func lookupNames(of url: URL) -> [String] {
        var seen = Set<String>()
        let file = url.lastPathComponent
        return ([file, RelPath.stem(file)] + names(of: url).all).filter { seen.insert($0).inserted }
    }
}
