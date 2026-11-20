import Foundation
import Testing
@testable import Daemonscope

private struct CollectorFailure: Error, LocalizedError {
    var errorDescription: String? { "launchctl exploded" }
}

/// Hands out queued results, one per collection, so a test can script success and failure in sequence.
private final class ScriptedCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<LoadedSnapshot, Error>]

    init(_ results: [Result<LoadedSnapshot, Error>]) { self.results = results }

    var collector: LaunchctlCollector {
        LaunchctlCollector { [self] in
            try lock.withLock { results.removeFirst() }.get()
        }
    }
}

@MainActor
struct InventoryStoreTests {
    private func agentsFolder(labels: [String]) throws -> URL {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemonscope-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        // /var is a symlink to /private/var and discovery reports resolved paths, so the fake launchd paths
        // built from this folder must be resolved too. `resolvingSymlinksInPath()` strips "/private" back off.
        guard let resolved = realpath(unresolved.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        let folder = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        for label in labels {
            let data = try PropertyListSerialization.data(fromPropertyList: ["Label": label], format: .xml, options: 0)
            try data.write(to: folder.appendingPathComponent("\(label).plist"))
        }
        return folder
    }

    private func store(folder: URL, collector: LaunchctlCollector) -> InventoryStore {
        InventoryStore(
            discovery: PlistDiscovery(jobDirectories: [.init(url: folder, location: .userAgents)], appSearchRoots: []),
            collector: collector, refreshInterval: nil)
    }

    @Test func refreshPublishesMergedEntries() async throws {
        let folder = try agentsFolder(labels: ["com.example.a"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("com.example.a.plist").path
        let snapshot = LoadedSnapshot(
            jobs: [LoadedJob(domain: "gui/501", label: "com.example.a", path: path, submittedBy: nil, type: nil,
                             state: "running", pid: 7, program: nil, lastExit: nil, parentBundleID: nil)],
            disabled: [:])

        let store = store(folder: folder, collector: ScriptedCollector([.success(snapshot)]).collector)
        #expect(store.scan == nil)

        await store.refresh()

        #expect(store.scan?.jobs.map(\.label) == ["com.example.a"])
        #expect(store.entries.map(\.state) == [.running])
        #expect(store.loadedDate != nil)
        #expect(store.loadedError == nil)
        #expect(store.isRefreshing == false)
    }

    @Test func firstCollectionFailureLeavesStatesUnknown() async throws {
        let folder = try agentsFolder(labels: ["com.example.a"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = store(folder: folder, collector: ScriptedCollector([.failure(CollectorFailure())]).collector)
        await store.refresh()

        #expect(store.entries.map(\.state) == [.unknown])
        #expect(store.loadedError == "launchctl exploded")
        #expect(store.loadedDate == nil)
    }

    @Test func laterFailureKeepsLastGoodLaunchdResults() async throws {
        let folder = try agentsFolder(labels: ["com.example.a"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("com.example.a.plist").path
        let snapshot = LoadedSnapshot(
            jobs: [LoadedJob(domain: "gui/501", label: "com.example.a", path: path, submittedBy: nil, type: nil,
                             state: "running", pid: 7, program: nil, lastExit: nil, parentBundleID: nil)],
            disabled: [:])

        let store = store(
            folder: folder,
            collector: ScriptedCollector([.success(snapshot), .failure(CollectorFailure())]).collector)
        await store.refresh()
        let goodDate = try #require(store.loadedDate)

        await store.refresh()

        #expect(store.entries.map(\.state) == [.running])
        #expect(store.loadedDate == goodDate)
        #expect(store.loadedError == "launchctl exploded")
    }
}

struct LaunchctlCollectorTests {
    private static let systemListing = "system = {\n\tservice count = 1\n\tservices = {\n\t\t     612      - \tcom.example.a\n\t}\n}\n"
    private static let guiListing = "gui/501 = {\n\tservice count = 0\n\tservices = {\n\t}\n}\n"

    @Test func collectsListingsAndDetails() throws {
        let collector = LaunchctlCollector(uid: 501) { arguments in
            switch arguments {
            case ["print", "system"]: return Self.systemListing
            case ["print", "gui/501"]: return Self.guiListing
            case ["print", "user/501"]: throw LaunchctlCollector.CollectError.exited(113, "Could not find domain")
            case ["dumpstate"]: return "system/com.example.a = {\n\tpath = /Library/LaunchDaemons/a.plist\n}\n"
            default: throw LaunchctlCollector.CollectError.unrecognizedOutput
            }
        }
        let snapshot = try collector.collect()
        #expect(snapshot.jobs.map(\.label) == ["com.example.a"])
        #expect(snapshot.jobs.first?.path == "/Library/LaunchDaemons/a.plist")
        #expect(snapshot.queriedDomains == ["system", "gui/501"])
        #expect(snapshot.issues.count == 1)
        #expect(snapshot.issues.first?.contains("user/501") == true)
    }

    @Test func structurallyBrokenListingKeepsJobsButNotTheDomain() throws {
        let collector = LaunchctlCollector(uid: 501) { arguments in
            switch arguments {
            case ["print", "system"]: return Self.systemListing
            case ["print", "gui/501"]:
                return "gui/501 = {\n\tservice count = 0\n\tservices = {\n\t\t       0      - \tcom.example.extra\n\t}\n}\n"
            case ["print", "user/501"]: return Self.guiListing.replacingOccurrences(of: "gui/501", with: "user/501")
            default: return "system/com.example.a = {\n\tpath = /Library/LaunchDaemons/a.plist\n}\n"
            }
        }
        let snapshot = try collector.collect()
        #expect(snapshot.queriedDomains == ["system", "user/501"])
        #expect(snapshot.issues.contains { $0.contains("gui/501") })
        #expect(snapshot.jobs.first { $0.label == "com.example.extra" }?.rowSuspect == true)
    }

    @Test func dumpstateFailureKeepsListingsAndReportsIt() throws {
        let collector = LaunchctlCollector(uid: 501) { arguments in
            if arguments == ["dumpstate"] { throw LaunchctlCollector.CollectError.timedOut }
            return arguments == ["print", "system"] ? Self.systemListing : Self.guiListing.replacingOccurrences(
                of: "gui/501", with: arguments[1])
        }
        let snapshot = try collector.collect()
        #expect(snapshot.jobs.first?.isRunning == true)
        #expect(snapshot.jobs.first?.path == nil)
        #expect(snapshot.issues.count == 1)
    }

    @Test func noDomainListedIsAnError() {
        let collector = LaunchctlCollector(uid: 501) { _ in "Usage: launchctl <subcommand>\n" }
        #expect(throws: LaunchctlCollector.CollectError.self) { try collector.collect() }
    }

    @Test func runReportsNonZeroExit() {
        #expect(throws: LaunchctlCollector.CollectError.self) {
            try LaunchctlCollector.run(executable: "/usr/bin/false", arguments: [], timeout: .seconds(5))
        }
    }

    @Test func runTimesOut() {
        #expect(throws: LaunchctlCollector.CollectError.timedOut) {
            try LaunchctlCollector.run(executable: "/bin/sleep", arguments: ["5"], timeout: .milliseconds(200))
        }
    }

    @Test func runReturnsLargeOutputWithoutDeadlocking() throws {
        // Bigger than a pipe buffer, like a real dumpstate.
        let output = try LaunchctlCollector.run(
            executable: "/bin/sh", arguments: ["-c", "yes daemonscope | head -c 2000000"], timeout: .seconds(10))
        #expect(output.utf8.count == 2_000_000)
    }
}
