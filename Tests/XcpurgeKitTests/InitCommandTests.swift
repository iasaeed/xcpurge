import Foundation
import XCTest
@testable import XcpurgeKit

/// `xcpurge init --xcode-phase` prints a Run Script phase and writes nothing; plain `init` still writes the starters.
final class InitCommandTests: XCTestCase {
    private func shellCheck(_ script: String) throws -> Int32 {
        let file = try FixtureSupport.tempTree(["phase.sh": script]).appendingPathComponent("phase.sh")
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-n", file.path]
        sh.standardError = Pipe()
        try sh.run()
        sh.waitUntilExit()
        return sh.terminationStatus
    }

    func testXcodePhasePrintsScriptAndWritesNothing() throws {
        let root = try FixtureSupport.tempTree(["README.md": "x"])
        let run = try CLISupport.run(["init", root.path, "--xcode-phase"])
        XCTAssertEqual(run.status, 0, run.stderr)
        let script = run.stdout
        XCTAssertEqual(try shellCheck(script), 0, "sh -n accepts the script")
        for needle in ["command -v xcpurge", "${CI:-}", "CONFIGURATION", "/opt/homebrew/bin", "/usr/local/bin",
                       "ENABLE_USER_SCRIPT_SANDBOXING", "Input File Lists", "$(DERIVED_FILE_DIR)/xcpurge.stamp",
                       "--format xcode --min-confidence medium --quiet --max-warnings 50 || echo \"warning: xcpurge exited $? "
                           + "(run xcpurge --version to check the install)\"",
                       "WANT=\"${XCPURGE_CONFIGURATION:-Release}\"", "xcpurge \(XcpurgeVersion.current)"] {
            XCTAssertTrue(script.contains(needle), "missing \(needle) in\n\(script)")
        }
        XCTAssertTrue(script.hasPrefix("# xcpurge Run Script phase"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["README.md"], "nothing written")
        XCTAssertEqual(run.stderr, "")
    }

    func testXcodePhaseSubstitutions() throws {
        let any = try CLISupport.run(["init", "--xcode-phase", "--configuration", "any", "--max-warnings", "10"])
        XCTAssertEqual(any.status, 0, any.stderr)
        XCTAssertTrue(any.stdout.contains("WANT=\"${XCPURGE_CONFIGURATION:-any}\""), any.stdout)
        XCTAssertTrue(any.stdout.contains("--max-warnings 10 || echo \"warning: xcpurge exited $?"), any.stdout)
        XCTAssertEqual(try shellCheck(any.stdout), 0)
        XCTAssertEqual(any.stdout, InitCommandScript.render(configuration: "any", maxWarnings: 10))
        XCTAssertEqual(try CLISupport.run(["init", "--max-warnings", "10"]).status, 2, "--max-warnings needs --xcode-phase")
        // A configuration name may contain spaces (App Store); shell syntax may not.
        let spaced = try CLISupport.run(["init", "--xcode-phase", "--configuration", "App Store"])
        XCTAssertEqual(spaced.status, 0, spaced.stderr)
        XCTAssertTrue(spaced.stdout.contains("WANT=\"${XCPURGE_CONFIGURATION:-App Store}\""), spaced.stdout)
        XCTAssertEqual(try shellCheck(spaced.stdout), 0)
        for bad in ["Re\"lease", "$(id)", "`id`", "a\\b", "x}", " ", "a\nb"] {
            XCTAssertEqual(try CLISupport.run(["init", "--xcode-phase", "--configuration", bad]).status, 2, bad)
        }
    }

    /// A failing xcpurge (bad flags, a crash) does not fail the build either, but says so instead of `|| true`.
    func testScriptWarnsWhenXcpurgeFails() throws {
        let script = try CLISupport.run(["init", "--xcode-phase"]).stdout
        let bin = try FixtureSupport.tempTree(["xcpurge": "#!/bin/sh\nexit 7\n", "phase.sh": script])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("xcpurge").path)
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = [bin.appendingPathComponent("phase.sh").path]
        sh.environment = ["HOME": bin.path, "PATH": bin.path + ":/usr/bin:/bin", "CONFIGURATION": "Release",
                          "SRCROOT": bin.path, "DERIVED_FILE_DIR": bin.path]
        let out = Pipe()
        sh.standardOutput = out
        sh.standardError = Pipe()
        try sh.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        sh.waitUntilExit()
        XCTAssertEqual(sh.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("warning: xcpurge exited 7 (run xcpurge --version to check the install)"), text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bin.appendingPathComponent("xcpurge.stamp").path), "stamp still touched")
    }

    /// The script runs cleanly end to end in a shell: it exits 0 on CI, for other configurations, and when xcpurge is
    /// missing, so it can never fail a build.
    func testScriptExitsZeroWhenSkipping() throws {
        let script = try CLISupport.run(["init", "--xcode-phase"]).stdout
        let file = try FixtureSupport.tempTree(["phase.sh": script]).appendingPathComponent("phase.sh")
        func run(_ env: [String: String]) throws -> (Int32, String) {
            let sh = Process()
            sh.executableURL = URL(fileURLWithPath: "/bin/sh")
            sh.arguments = [file.path]
            sh.environment = env.merging(["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]) { a, _ in a }
            let out = Pipe()
            sh.standardOutput = out
            sh.standardError = Pipe()
            try sh.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            sh.waitUntilExit()
            return (sh.terminationStatus, text)
        }
        let ci = try run(["CI": "true", "CONFIGURATION": "Release"])
        XCTAssertEqual(ci.0, 0)
        XCTAssertTrue(ci.1.contains("note: xcpurge skipped on CI"))
        XCTAssertEqual(try run(["CONFIGURATION": "Debug"]).0, 0, "other configuration: silent exit 0")
        // Release with no xcpurge on PATH (HOME points at an empty folder; an installed /usr/local or Homebrew copy
        // would scan the empty SRCROOT instead): still exit 0.
        let empty = try FixtureSupport.tempTree([:])
        let missing = try run(["CONFIGURATION": "Release", "PATH": "/nonexistent", "HOME": empty.path,
                               "SRCROOT": empty.path, "DERIVED_FILE_DIR": empty.path])
        XCTAssertEqual(missing.0, 0, missing.1)
    }

    func testPlainInitStillWritesStarters() throws {
        let root = try FixtureSupport.tempTree([:])
        let run = try CLISupport.run(["init", root.path])
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), [Config.fileName, Ignore.fileName])
        let again = try CLISupport.run(["init", root.path])
        XCTAssertTrue(again.stdout.contains("exists: \(Config.fileName)"))
    }
}

/// Mirror of `InitCommand.xcodePhaseScript` (the CLI target is not importable); the CLI test compares the two.
enum InitCommandScript {
    static func render(configuration: String, maxWarnings: Int) -> String {
        """
        # xcpurge Run Script phase (xcpurge \(XcpurgeVersion.current)). Add after "Compile Sources".
        # Either set ENABLE_USER_SCRIPT_SANDBOXING = NO for this target, or add $(SRCROOT) to Input File Lists.
        # Output Files: $(DERIVED_FILE_DIR)/xcpurge.stamp  (lets Xcode skip the phase when nothing changed)
        if [ "$(uname -m)" = arm64 ]; then export PATH="/opt/homebrew/bin:$PATH"; fi
        export PATH="$PATH:/usr/local/bin:$HOME/.local/bin"
        if [ -n "${CI:-}" ]; then echo "note: xcpurge skipped on CI"; exit 0; fi
        WANT="${XCPURGE_CONFIGURATION:-\(configuration)}"
        if [ "$WANT" != any ] && [ "${CONFIGURATION:-}" != "$WANT" ]; then exit 0; fi
        command -v xcpurge >/dev/null 2>&1 || { echo "warning: xcpurge not installed"; exit 0; }
        xcpurge scan "${SRCROOT}" --format xcode --min-confidence medium --quiet --max-warnings \(maxWarnings) || echo "warning: xcpurge exited $? (run xcpurge --version to check the install)"
        touch "${DERIVED_FILE_DIR}/xcpurge.stamp"

        """
    }
}
