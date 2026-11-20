import Foundation

/// Asks launchd which jobs are loaded, through one `launchctl dumpstate` call.
///
/// `dumpstate` was picked over `launchctl print` per job: both print the same undocumented block format, but
/// one dumpstate takes ~0.2 s where ~1,000 per-job prints take ~10 s. Its output also holds every job's
/// environment, so it's parsed in memory and never written anywhere.
struct LaunchctlCollector: Sendable {
    enum CollectError: Error, Equatable, LocalizedError {
        case launchFailed(String)
        case exited(Int32, String)
        case timedOut
        case unrecognizedOutput

        var errorDescription: String? {
            switch self {
            case .launchFailed(let reason): "Couldn't run launchctl: \(reason)"
            case .exited(let code, let message):
                "launchctl exited with status \(code)" + (message.isEmpty ? "." : ": \(message)")
            case .timedOut: "launchctl didn't finish in time."
            case .unrecognizedOutput: "launchctl's output wasn't in a recognized format."
            }
        }
    }

    private let body: @Sendable () throws -> LoadedSnapshot

    init(collect: @escaping @Sendable () throws -> LoadedSnapshot) {
        body = collect
    }

    /// Parses whatever `output` returns as dumpstate text for `uid`'s domains.
    init(uid: uid_t, output: @escaping @Sendable () throws -> String) {
        body = {
            let snapshot = LaunchctlDump.parse(try output(), uid: uid)
            // No domain header at all means the format changed or the command misbehaved; don't report that as
            // "nothing is loaded".
            guard !snapshot.disabled.isEmpty || !snapshot.jobs.isEmpty else { throw CollectError.unrecognizedOutput }
            return snapshot
        }
    }

    static let live = LaunchctlCollector(uid: getuid()) {
        try run(executable: "/bin/launchctl", arguments: ["dumpstate"], timeout: .seconds(30))
    }

    func collect() throws -> LoadedSnapshot {
        try body()
    }

    /// Runs a command and returns its stdout. Blocks the calling thread, so call it off the main actor.
    static func run(executable: String, arguments: [String], timeout: Duration) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CollectError.launchFailed(error.localizedDescription)
        }

        // Read stderr concurrently so a chatty command can't fill that pipe and stall while stdout is drained.
        let errorData = SharedBox()
        let errorReader = DispatchGroup()
        DispatchQueue.global().async(group: errorReader) {
            errorData.data = stderr.fileHandleForReading.readDataToEndOfFile()
        }

        let didTimeOut = SharedBox()
        let timer = DispatchWorkItem { [process] in
            if process.isRunning {
                didTimeOut.flag = true
                process.terminate()
            }
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)

        // Drain stdout before waiting: dumpstate prints megabytes, far more than a pipe buffer holds.
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        errorReader.wait()

        if didTimeOut.flag {
            throw CollectError.timedOut
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CollectError.exited(process.terminationStatus, String(message.prefix(200)))
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// A mutable box shared with the reader and timer callbacks. Each field has a single writer, and every read
    /// happens after that writer finished (`errorReader.wait()`, `waitUntilExit()`).
    private final class SharedBox: @unchecked Sendable {
        var data = Data()
        var flag = false
    }
}
