import Foundation

/// Reads `contents.xcworkspacedata` and returns the absolute paths of its file references
/// (`group:`, `container:`, `self:`, `absolute:` locations, nested `<Group>`s).
public enum WorkspaceParser {
    public static func parse(workspace: URL) throws -> [String] {
        let data = try Data(contentsOf: workspace.appendingPathComponent("contents.xcworkspacedata"))
        return parse(data: data, workspaceDir: workspace.deletingLastPathComponent().standardizedFileURL.path,
                     workspacePath: workspace.standardizedFileURL.path)
    }

    public static func parse(data: Data, workspaceDir: String, workspacePath: String) -> [String] {
        let delegate = Delegate(base: workspaceDir, workspacePath: workspacePath)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.paths
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let workspaceDir: String
        let workspacePath: String
        var stack: [String]
        var paths: [String] = []

        init(base: String, workspacePath: String) {
            self.workspaceDir = base
            self.workspacePath = workspacePath
            self.stack = [base]
        }

        func resolve(_ location: String) -> String? {
            guard let colon = location.firstIndex(of: ":") else { return nil }
            let kind = location[..<colon], path = String(location[location.index(after: colon)...])
            switch kind {
            case "group": return RelPath.join(stack.last ?? workspaceDir, path)
            case "container": return RelPath.join(workspaceDir, path)
            case "self": return RelPath.join(RelPath.parent(workspacePath), path)
            case "absolute": return RelPath.normalize(path)
            default: return nil
            }
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let resolved = attributes["location"].flatMap(resolve)
            if element == "Group" { stack.append(resolved ?? stack.last ?? workspaceDir) }
            if element == "FileRef", let resolved { paths.append(resolved) }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            if element == "Group", stack.count > 1 { stack.removeLast() }
        }
    }
}
