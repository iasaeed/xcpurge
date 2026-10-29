import ArgumentParser

/// xcpurge process exit codes.
enum XcpurgeExit: Int32 {
    case ok = 0
    /// A `--fail-on` rule matched a finding.
    case failOnHit = 1
    /// Bad flags, config file or paths.
    case usage = 2
    case internalError = 3

    var exitCode: ArgumentParser.ExitCode { ArgumentParser.ExitCode(rawValue) }
}
