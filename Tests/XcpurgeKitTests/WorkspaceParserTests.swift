import XCTest
@testable import XcpurgeKit

final class WorkspaceParserTests: XCTestCase {
    func testFixtureWorkspaceWithNestedGroup() throws {
        let root = FixtureSupport.fixtureURL("ModularWorkspace")
        let paths = try WorkspaceParser.parse(workspace: root.appendingPathComponent("Modular.xcworkspace"))
            .map { RelPath.relative($0, to: root.path) }
        XCTAssertEqual(paths, ["App/App.xcodeproj", "Packages/Core", "Packages/DesignSystem"])
    }

    func testLocationKinds() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version = "1.0">
           <FileRef location = "container:Apps/A.xcodeproj"></FileRef>
           <Group location = "container:Libs" name = "Libs">
              <Group location = "group:Nested" name = "Nested">
                 <FileRef location = "group:B.xcodeproj"></FileRef>
              </Group>
              <FileRef location = "group:C"></FileRef>
           </Group>
           <Group name = "Virtual">
              <FileRef location = "group:D.xcodeproj"></FileRef>
           </Group>
           <FileRef location = "absolute:/opt/E.xcodeproj"></FileRef>
           <FileRef location = "self:"></FileRef>
        </Workspace>
        """
        let paths = WorkspaceParser.parse(data: Data(xml.utf8), workspaceDir: "/repo", workspacePath: "/repo/W.xcworkspace")
        XCTAssertEqual(paths, ["/repo/Apps/A.xcodeproj", "/repo/Libs/Nested/B.xcodeproj", "/repo/Libs/C",
                               "/repo/D.xcodeproj", "/opt/E.xcodeproj", "/repo"])
    }

    func testLocatorExpandsRootWorkspaceOnly() throws {
        let root = FixtureSupport.fixtureURL("ModularWorkspace")
        let walk = FileWalker().walk(root: root)
        let located = try ProjectLocator.locate(root: root, walk: walk, config: Config())
        XCTAssertEqual(located.workspaces, ["Modular.xcworkspace"])
        XCTAssertEqual(located.xcodeprojs, ["App/App.xcodeproj"])
        XCTAssertEqual(located.packages, ["Packages/Core", "Packages/DesignSystem"])
    }

    func testExplicitFlagsWin() throws {
        let root = FixtureSupport.fixtureURL("ModularWorkspace")
        var config = Config()
        config.package = root.appendingPathComponent("Packages/Core/Package.swift").path
        let located = try ProjectLocator.locate(root: root, walk: FileWalker().walk(root: root), config: config)
        XCTAssertEqual(located, LocatedProjects(packages: ["Packages/Core"]))
        config.package = "Nope"
        XCTAssertThrowsError(try ProjectLocator.locate(root: root, walk: FileWalker().walk(root: root), config: config))
    }
}
