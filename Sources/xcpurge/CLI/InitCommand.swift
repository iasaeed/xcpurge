import ArgumentParser
import Foundation
import XcpurgeKit

/// `xcpurge init`: writes starter `xcpurge.json` and `.xcpurgeignore`; `--xcode-phase` instead prints a Run Script
/// build phase to paste into Xcode (nothing is written, no project file is touched).
struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init", abstract: "Write starter xcpurge.json and .xcpurgeignore files, or print an Xcode Run Script phase.")

    @Argument(help: "Project root.", completion: .directory) var path: String = "."
    @Flag(help: "Overwrite existing files.") var force = false
    @Flag(help: "Print a Run Script build phase that shows findings as Xcode warnings; writes nothing.") var xcodePhase = false
    @Option(help: ArgumentHelp("--xcode-phase: run only for this build configuration, or `any`.", valueName: "Release|any"))
    var configuration: String = "Release"
    @Option(help: "--xcode-phase: cap the warnings the phase emits; a summary line follows.") var maxWarnings: Int = 50

    func validate() throws {
        if !xcodePhase, configuration != "Release" || maxWarnings != 50 {
            throw ValidationError("--configuration and --max-warnings apply to --xcode-phase")
        }
        // The name lands inside a double-quoted shell default: spaces ("App Store") are fine, shell syntax is not.
        if configuration.trimmingCharacters(in: .whitespaces).isEmpty
            || configuration.contains(where: { $0.isNewline || "\"$`\\}".contains($0) }) {
            throw ValidationError("--configuration: expected a build configuration name or `any`")
        }
        if maxWarnings < 0 { throw ValidationError("--max-warnings must be 0 or more") }
    }

    func run() async throws {
        if xcodePhase {
            print(Self.xcodePhaseScript(configuration: configuration, maxWarnings: maxWarnings), terminator: "")
            return
        }
        let root = CommonOptions.absolute(path)
        for (name, text) in [(Config.fileName, Config.template), (Ignore.fileName, Ignore.template)] {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path), !force {
                print("exists: \(name) (use --force to overwrite)")
                continue
            }
            try Data(text.utf8).write(to: url, options: .atomic)
            print("wrote: \(name)")
        }
    }

    /// The Run Script body: finds xcpurge on Homebrew/local paths, skips CI and other configurations, never fails
    /// the build, and touches a stamp so Xcode can skip the phase when inputs are unchanged.
    static func xcodePhaseScript(configuration: String = "Release", maxWarnings: Int = 50) -> String {
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
