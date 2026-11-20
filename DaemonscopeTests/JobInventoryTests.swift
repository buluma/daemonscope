import Foundation
import Testing
@testable import Daemonscope

private func disk(
    _ label: String?, path: String, location: JobLocation = .globalDaemons, disabledInPlist: Bool? = nil,
    owningApp: String? = nil
) -> DiskJob {
    DiskJob(
        path: path, location: location, owningApp: owningApp, label: label, program: nil, bundleProgram: nil,
        programArguments: [], runAtLoad: nil, disabledInPlist: disabledInPlist, keepAlive: nil, startInterval: nil,
        environmentVariables: [:])
}

private func loaded(
    _ label: String, domain: String = "system", path: String?, state: String = "running", pid: Int? = 1
) -> LoadedJob {
    LoadedJob(
        domain: domain, label: label, path: path, submittedBy: path == nil ? "(submitted by smd.1)" : nil,
        type: "LaunchDaemon", state: state, pid: pid, program: nil, lastExit: nil, parentBundleID: nil)
}

struct JobInventoryTests {
    @Test func matchesByLaunchdReportedPath() throws {
        let entries = JobInventory.merge(
            disk: [disk("com.example.a", path: "/Library/LaunchDaemons/a.plist")],
            loaded: LoadedSnapshot(jobs: [loaded("com.example.a", path: "/Library/LaunchDaemons/a.plist")], disabled: [:]),
            uid: 501)
        let entry = try #require(entries.only)
        #expect(entry.disk?.path == "/Library/LaunchDaemons/a.plist")
        #expect(entry.loaded?.label == "com.example.a")
        #expect(entry.state == .running)
    }

    @Test func matchesSymlinkedPlistByItsTarget() throws {
        var job = disk("com.vendor.agent", path: "/Library/LaunchAgents/com.vendor.agent.plist", location: .globalAgents)
        job.symlinkTarget = "/Library/Application Support/Vendor/agent.plist"
        let entries = JobInventory.merge(
            disk: [job],
            loaded: LoadedSnapshot(jobs: [
                loaded("com.vendor.agent", domain: "gui/501", path: "/Library/Application Support/Vendor/agent.plist",
                       state: "not running", pid: nil),
            ], disabled: [:]),
            uid: 501)
        let entry = try #require(entries.only)
        #expect(entry.disk?.path == "/Library/LaunchAgents/com.vendor.agent.plist")
        #expect(entry.state == .loadedNotRunning)
    }

    @Test func runningboardAppInstancesAreFlagged() {
        let instance = LoadedJob(
            domain: "gui/501", label: "application.com.example.App.123.456", path: nil,
            submittedBy: "(submitted by runningboardd.408)", type: nil, state: "running", pid: 9, program: nil,
            lastExit: nil, parentBundleID: nil)
        let entries = JobInventory.merge(
            disk: [], loaded: LoadedSnapshot(jobs: [instance, loaded("com.example.real", path: nil)], disabled: [:]),
            uid: 501)
        #expect(entries.filter(\.isAppInstance).compactMap(\.label) == ["application.com.example.App.123.456"])
    }

    @Test func sameLabelInTwoDomainsStaysTwoEntries() {
        let entries = JobInventory.merge(
            disk: [disk("com.example.dup", path: "/Users/t/Library/LaunchAgents/dup.plist", location: .userAgents)],
            loaded: LoadedSnapshot(jobs: [
                loaded("com.example.dup", domain: "gui/501", path: "/Users/t/Library/LaunchAgents/dup.plist"),
                loaded("com.example.dup", domain: "system", path: "/Library/LaunchDaemons/dup.plist", state: "not running", pid: nil),
            ], disabled: [:]),
            uid: 501)
        #expect(entries.count == 2)
        let gui = entries.first { $0.loaded?.domain == "gui/501" }
        let system = entries.first { $0.loaded?.domain == "system" }
        #expect(gui?.disk != nil)
        // Different path from the only plist on disk: a matching label alone isn't evidence enough.
        #expect(system?.disk == nil)
        #expect(system?.state == .loadedNotRunning)
    }

    @Test func unmatchedEntriesArePreservedOnBothSides() {
        let entries = JobInventory.merge(
            disk: [disk("com.example.idle", path: "/Library/LaunchDaemons/idle.plist")],
            loaded: LoadedSnapshot(jobs: [loaded("com.example.nofile", path: nil)], disabled: [:]),
            uid: 501)
        #expect(entries.count == 2)
        #expect(entries.first { $0.disk?.label == "com.example.idle" }?.state == .foundOnDisk)
        #expect(entries.first { $0.loaded?.label == "com.example.nofile" }?.disk == nil)
    }

    @Test func submittedJobMatchesUniqueAppBundledPlistByLabel() {
        let app = "/Applications/Tool.app"
        let entries = JobInventory.merge(
            disk: [disk("com.vendor.helper", path: "\(app)/Contents/Library/LaunchAgents/h.plist", location: .appAgents, owningApp: app)],
            loaded: LoadedSnapshot(jobs: [loaded("com.vendor.helper", domain: "gui/501", path: nil, state: "not running", pid: nil)], disabled: [:]),
            uid: 501)
        #expect(entries.count == 1)
        #expect(entries.first?.disk?.owningApp == app)
        #expect(entries.first?.state == .loadedNotRunning)
    }

    @Test func submittedJobDoesNotMatchAmbiguousOrNonAppPlists() {
        let entries = JobInventory.merge(
            disk: [
                disk("com.vendor.helper", path: "/A.app/Contents/Library/LaunchAgents/h.plist", location: .appAgents, owningApp: "/A.app"),
                disk("com.vendor.helper", path: "/B.app/Contents/Library/LaunchAgents/h.plist", location: .appAgents, owningApp: "/B.app"),
                disk("com.vendor.other", path: "/Library/LaunchAgents/o.plist", location: .globalAgents),
            ],
            loaded: LoadedSnapshot(jobs: [
                loaded("com.vendor.helper", domain: "gui/501", path: nil),
                loaded("com.vendor.other", domain: "gui/501", path: nil),
            ], disabled: [:]),
            uid: 501)
        #expect(entries.count == 5)
        #expect(entries.filter { $0.loaded != nil }.allSatisfy { $0.disk == nil })
    }

    @Test func disabledOverrideInExpectedDomain() {
        let entries = JobInventory.merge(
            disk: [
                disk("com.example.daemonoff", path: "/Library/LaunchDaemons/d.plist", location: .globalDaemons),
                disk("com.example.agentoff", path: "/Library/LaunchAgents/a.plist", location: .globalAgents),
                // Disabled in gui/501, but a daemon is expected in system, so the override doesn't apply.
                disk("com.example.wrongdomain", path: "/Library/LaunchDaemons/w.plist", location: .globalDaemons),
            ],
            loaded: LoadedSnapshot(jobs: [], disabled: [
                "system": ["com.example.daemonoff": true],
                "gui/501": ["com.example.agentoff": true, "com.example.wrongdomain": true],
            ]),
            uid: 501)
        #expect(entries.first { $0.disk?.label == "com.example.daemonoff" }?.state == .disabled)
        #expect(entries.first { $0.disk?.label == "com.example.agentoff" }?.state == .disabled)
        #expect(entries.first { $0.disk?.label == "com.example.wrongdomain" }?.state == .foundOnDisk)
    }

    @Test func enabledOverrideBeatsPlistDisabledKey() {
        let entries = JobInventory.merge(
            disk: [
                disk("com.example.plistoff", path: "/Library/LaunchDaemons/p.plist", disabledInPlist: true),
                disk("com.example.overridden", path: "/Library/LaunchDaemons/o.plist", disabledInPlist: true),
            ],
            loaded: LoadedSnapshot(jobs: [], disabled: ["system": ["com.example.overridden": false]]),
            uid: 501)
        #expect(entries.first { $0.disk?.label == "com.example.plistoff" }?.state == .disabled)
        #expect(entries.first { $0.disk?.label == "com.example.overridden" }?.state == .foundOnDisk)
    }

    @Test func failedCollectionMakesDiskJobsUnknown() {
        let entries = JobInventory.merge(
            disk: [disk("com.example.a", path: "/Library/LaunchDaemons/a.plist")], loaded: nil, uid: 501)
        #expect(entries.only?.state == .unknown)
    }

    @Test func appleDetectionUsesOnlySIPProtectedPaths() {
        let entries = JobInventory.merge(
            disk: [],
            loaded: LoadedSnapshot(jobs: [
                // A com.apple.* label alone proves nothing: any admin can pick it.
                loaded("com.apple.thing", path: nil),
                loaded("com.apple.fake", path: "/Library/LaunchDaemons/com.apple.fake.plist"),
                loaded("org.example.sys", path: "/System/Library/LaunchDaemons/x.plist"),
                loaded("com.apple.extra", path: "/Library/Apple/System/Library/LaunchDaemons/y.plist"),
                loaded("com.example.mine", path: nil),
            ], disabled: [:]),
            uid: 501)
        #expect(entries.filter(\.isApple).compactMap(\.label).sorted() == ["com.apple.extra", "org.example.sys"])
    }

    @Test func nonCanonicalPathsAreNotApple() {
        let entries = JobInventory.merge(
            disk: [],
            loaded: LoadedSnapshot(jobs: [
                loaded("com.example.sneaky", path: "/System/Library/../../Library/LaunchDaemons/sneaky.plist"),
                loaded("com.example.dot", path: "/System/Library/./LaunchDaemons/../../../tmp/x.plist"),
                loaded("com.example.slashes", path: "/System/Library//LaunchDaemons/x.plist"),
            ], disabled: [:]),
            uid: 501)
        #expect(entries.filter(\.isApple).isEmpty)
    }

    @Test func appInstanceNeedsBothRunningboardSubmitterAndApplicationLabel() {
        let impostor = LoadedJob(
            domain: "gui/501", label: "dev.attacker.agent", path: nil,
            submittedBy: "(submitted by runningboardd.408)", type: nil, state: nil, pid: 9, program: nil,
            lastExit: nil, parentBundleID: nil)
        let entries = JobInventory.merge(disk: [], loaded: LoadedSnapshot(jobs: [impostor], disabled: [:]), uid: 501)
        #expect(entries.first?.isAppInstance == false)
    }

    @Test func diskJobsOutsideQueriedDomainsAreUnknown() {
        let entries = JobInventory.merge(
            disk: [
                disk("com.example.daemon", path: "/Library/LaunchDaemons/d.plist", location: .globalDaemons),
                disk("com.example.agent", path: "/Library/LaunchAgents/a.plist", location: .globalAgents),
            ],
            // Only the gui domain answered; system couldn't be listed.
            loaded: LoadedSnapshot(jobs: [], disabled: ["gui/501": [:]], queriedDomains: ["gui/501"]),
            uid: 501)
        #expect(entries.first { $0.disk?.label == "com.example.daemon" }?.state == .unknown)
        #expect(entries.first { $0.disk?.label == "com.example.agent" }?.state == .foundOnDisk)
    }

    @Test func idsAreUnique() {
        let entries = JobInventory.merge(
            disk: [disk("com.example.a", path: "/Library/LaunchDaemons/a.plist")],
            loaded: LoadedSnapshot(jobs: [
                loaded("com.example.a", domain: "gui/501", path: "/Library/LaunchDaemons/a.plist"),
                loaded("com.example.a", domain: "user/501", path: "/Library/LaunchDaemons/a.plist"),
            ], disabled: [:]),
            uid: 501)
        #expect(Set(entries.map(\.id)).count == entries.count)
    }
}

struct JobInventoryCountTests {
    @Test func countsEachStateSeparately() {
        let entries = JobInventory.merge(
            disk: [
                disk("com.example.idle", path: "/Library/LaunchDaemons/idle.plist"),
                disk("com.example.off", path: "/Library/LaunchDaemons/off.plist", disabledInPlist: true),
            ],
            loaded: LoadedSnapshot(jobs: [
                loaded("com.example.run", path: nil),
                loaded("com.example.wait", path: nil, state: "not running", pid: nil),
                loaded("com.example.wait2", path: nil, state: "spawn scheduled", pid: nil),
            ], disabled: [:]),
            uid: 501)
        #expect(JobInventory.counts(entries) == [.running: 1, .loadedNotRunning: 2, .disabled: 1, .foundOnDisk: 1])
    }

    @Test func unknownIsNeverCountedAsADefiniteState() {
        let entries = JobInventory.merge(
            disk: [disk("com.example.a", path: "/Library/LaunchDaemons/a.plist")], loaded: nil, uid: 501)
        #expect(JobInventory.counts(entries) == [.unknown: 1])
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
