import Foundation

/// Extracts references from storyboards and xibs with `XMLParser`: images, named colors, custom classes and
/// modules, storyboard references, fonts, segue destinations, object IDs and user-visible text.
public enum IBScanner {
    /// Attribute names whose value is a resource or symbol name.
    static let nameAttributes: Set<String> = [
        "image", "highlightedImage", "selectedImage", "backgroundImage", "customClass", "customModule",
        "storyboardName", "referencedIdentifier", "destination", "id", "symbolName",
    ]
    /// Attribute names whose value is user-visible text (localizable).
    static let textAttributes: Set<String> = ["text", "title", "placeholder", "headerTitle", "footerTitle"]

    public static func scan(_ data: Data, file: Int32) -> ScanOutput {
        let delegate = Delegate(file: file)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.parse()
        var out = ScanOutput()
        out.references = delegate.references
        return out
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let file: Int32
        var references: [Reference] = []
        private var stringKey: String?
        private var stringLine: Int32 = 0
        private var stringText = ""

        init(file: Int32) { self.file = file }

        private func add(_ attribute: String, _ value: String, element: String, line: Int32) {
            guard !value.isEmpty else { return }
            references.append(Reference(kind: .ibAttribute(attribute), value: value, file: file, line: line,
                                        context: CallContext(callee: element, label: attribute)))
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let line = Int32(parser.lineNumber)
            for (key, value) in attributes.sorted(by: { $0.key < $1.key }) {
                if IBScanner.nameAttributes.contains(key) || IBScanner.textAttributes.contains(key) {
                    add(key == "destination" && element == "segue" ? "segue" : key, value, element: element, line: line)
                }
            }
            switch element {
            case "image", "namedColor", "systemColor":
                if let name = attributes["name"] { add(element == "image" ? "image" : "namedColor", name, element: element, line: line) }
            case "color":
                if let name = attributes["name"] { add("namedColor", name, element: element, line: line) }
            case "font", "fontDescription":
                if let name = attributes["name"] { add("fontName", name, element: element, line: line) }
                if let family = attributes["family"] { add("fontFamily", family, element: element, line: line) }
            case "userDefinedRuntimeAttribute":
                if let value = attributes["value"] {
                    references.append(Reference(kind: .ibAttribute("userDefined"), value: value, file: file, line: line,
                                                context: CallContext(callee: element, label: attributes["keyPath"])))
                }
            case "string":
                stringKey = attributes["key"]
                stringLine = line
                stringText = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if stringKey != nil { stringText += string }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            guard element == "string", let key = stringKey else { return }
            if IBScanner.textAttributes.contains(key) { add(key, stringText, element: "string", line: stringLine) }
            stringKey = nil
        }
    }
}
