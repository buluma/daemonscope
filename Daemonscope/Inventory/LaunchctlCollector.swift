import Foundation

/// Asks launchd which jobs are loaded.
///
/// `launchctl print <domain>` for system, user and gui is the source of truth for which jobs are loaded, their
/// PIDs and disabled overrides. One `launchctl dumpstate` adds per-job details (plist path, type, last exit,
/// registering app). The dump is used instead of ~1,000 per-job prints (~0.4 s vs ~10 s), but it can hold
/// forged blocks, so see `LaunchctlDump` for how they're contained. It also holds every job's environment, so
/// it's parsed in memory and never written anywhere.
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

    /// Collects `uid`'s domains, running launchctl with the given arguments through `launchctl`.
    init(uid: uid_t, launchctl: @escaping @Sendable ([String], Duration) throws -> String) {
        body = {
            let deadline = ContinuousClock.now + .seconds(30)
            func remaining() -> Duration { ContinuousClock.now.duration(to: deadline) }
            func collectOutput(_ arguments: [String]) throws -> String {
                let timeout = remaining()
                guard timeout > .zero else { throw CollectError.timedOut }
                return try launchctl(arguments, timeout)
            }
            var listings: [String: DomainListing] = [:]
            var issues: [String] = []
            var firstError: Error?
            for domain in ["system", "user/\(uid)", "gui/\(uid)"] {
                do {
                    guard let listing = DomainListing.parse(try collectOutput(["print", domain]), domain: domain) else {
                        throw CollectError.unrecognizedOutput
                    }
                    listings[domain] = listing
                } catch {
                    firstError = firstError ?? error
                    issues.append("Couldn't list \(domain): \(error.localizedDescription)")
                }
            }
            // Nothing listed means launchd couldn't be asked at all; don't report that as "nothing is loaded".
            guard !listings.isEmpty else { throw firstError ?? CollectError.unrecognizedOutput }

            var details: [ServiceKey: [[String: String]]]?
            do {
                details = LaunchctlDump.serviceBlocks(try collectOutput(["dumpstate"]), domains: Set(listings.keys))
            } catch {
                issues.append("Job details unavailable: \(error.localizedDescription)")
            }
            let snapshot = LoadedSnapshot.build(listings: listings, details: details)
            let outcome = SuspectJobVerifier.verify(
                snapshot: snapshot, listings: listings, details: details, timeRemaining: remaining, launchctl: launchctl)
            for domain in outcome.rebuiltDomains {
                issues.append("\(domain)'s listing looks forged, so only individually confirmed jobs have known state and its disabled list was ignored.")
            }
            if outcome.skipped > 0 {
                issues.append("Refresh time limit reached. Unchecked jobs: \(outcome.skipped). Their state is unknown.")
            }
            if outcome.confirmed > 0 {
                issues.append("\(outcome.confirmed) jobs had conflicting launchd output and were confirmed directly; another job may be forging entries.")
            }
            let tampered = outcome.jobs.filter(\.detailsTampered).count
            if tampered > 0 {
                issues.append("launchd's dump held conflicting entries for \(tampered) jobs; their details were ignored.")
            }
            let suspect = outcome.jobs.filter(\.rowSuspect).count - outcome.skipped
            if suspect > 0 {
                issues.append("\(suspect) listed jobs couldn't be confirmed and may be forged; their state is unknown.")
            }
            return LoadedSnapshot(
                jobs: outcome.jobs, disabled: snapshot.disabled, queriedDomains: snapshot.queriedDomains, issues: issues)
        }
    }

    static let live = LaunchctlCollector(uid: getuid()) { arguments, timeout in
        try run(executable: "/bin/launchctl", arguments: arguments, timeout: timeout)
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
        // Waiting through a termination handler, not `waitUntilExit()`: that polls the run loop and costs ~70 ms
        // per call, which adds up when a forged domain is checked job by job. Set before launch so a fast exit
        // can't be missed.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

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
                // This read-only diagnostic has no state to save. Enforce the deadline even if it ignores SIGTERM.
                kill(process.processIdentifier, SIGKILL)
            }
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let timerQueue = DispatchQueue(label: "Daemonscope.launchctl-timeout")
        timerQueue.asyncAfter(deadline: .now() + seconds, execute: timer)

        // Drain stdout before waiting: dumpstate prints megabytes, far more than a pipe buffer holds.
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        timer.cancel()
        timerQueue.sync {} // Finish any timeout callback before reading its flag.
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
    /// happens after that writer finished (`errorReader.wait()`, the timer queue barrier).
    private final class SharedBox: @unchecked Sendable {
        var data = Data()
        var flag = false
    }
}
