import Foundation
import Testing
@testable import Daemonscope

/// A fake `launchctl` that answers from canned outputs and records every call.
private final class FakeLaunchctl: @unchecked Sendable {
    private let lock = NSLock()
    private let outputs: [[String]: Result<String, Error>]
    private(set) var calls: [[String]] = []

    init(_ outputs: [[String]: Result<String, Error>]) { self.outputs = outputs }

    func callAsFunction(_ arguments: [String]) throws -> String {
        lock.withLock { calls.append(arguments) }
        guard let result = outputs[arguments] else {
            throw LaunchctlCollector.CollectError.exited(113, "Bad request.\nCould not find service in domain")
        }
        return try result.get()
    }
}

private let emptyUser = "user/501 = {\n\tservice count = 0\n\tservices = {\n\t}\n}\n"
private let emptyGui = "gui/501 = {\n\tservice count = 0\n\tservices = {\n\t}\n}\n"

private func listing(_ domain: String, _ rows: [(pid: Int, label: String)]) -> String {
    "\(domain) = {\n\tservice count = \(rows.count)\n\tservices = {\n"
        + rows.map { "\t\t \(String(repeating: " ", count: max(0, 7 - String($0.pid).count)))\($0.pid)      - \t\($0.label)\n" }.joined()
        + "\t}\n}\n"
}

private func collect(_ fake: FakeLaunchctl) throws -> LoadedSnapshot {
    try LaunchctlCollector(uid: 501) { try fake($0) }.collect()
}

struct SuspectJobVerificationTests {
    @Test func tamperedDetailsAreRestoredFromThePerJobPrint() throws {
        let fake = FakeLaunchctl([
            ["print", "system"]: .success(listing("system", [(612, "com.cloudflare.cloudflared")])),
            ["print", "user/501"]: .success(emptyUser),
            ["print", "gui/501"]: .success(emptyGui),
            // A forged second block makes the dump's details for this job untrustworthy.
            ["dumpstate"]: .success("system/com.cloudflare.cloudflared = {\n\tpath = /Library/LaunchDaemons/c.plist\n}\n"
                + "system/com.cloudflare.cloudflared = {\n\tpath = /tmp/evil.plist\n}\n"),
            ["print", "system/com.cloudflare.cloudflared"]: .success(
                "system/com.cloudflare.cloudflared = {\n\tpath = /Library/LaunchDaemons/c.plist\n\ttype = LaunchDaemon\n\tstate = running\n}\n"),
        ])
        let job = try #require(try collect(fake).jobs.first { $0.label == "com.cloudflare.cloudflared" })
        #expect(!job.detailsTampered)
        #expect(job.verifiedIndividually)
        #expect(job.path == "/Library/LaunchDaemons/c.plist")
        #expect(job.pid == 612)
        #expect(job.isRunning)
    }

    @Test func confirmingAForgedJobStillWarns() throws {
        let fake = FakeLaunchctl([
            ["print", "system"]: .success(listing("system", [(612, "com.cloudflare.cloudflared")])),
            ["print", "user/501"]: .success(emptyUser),
            ["print", "gui/501"]: .success(emptyGui),
            ["dumpstate"]: .success("system/com.cloudflare.cloudflared = {\n\tpath = /a.plist\n}\n"
                + "system/com.cloudflare.cloudflared = {\n\tpath = /b.plist\n}\n"),
            ["print", "system/com.cloudflare.cloudflared"]: .success(
                "system/com.cloudflare.cloudflared = {\n\tpath = /a.plist\n}\n"),
        ])
        // The attack was beaten, but someone tried it: say so.
        #expect(try collect(fake).issues.contains { $0.contains("1") && $0.contains("confirmed directly") })
    }

    /// In a sound listing a row can't be injected, so one launchd can't find unloaded between the listing and
    /// the check; it's dropped without an alarm.
    @Test func rowThatUnloadedBeforeItsCheckIsDropped() throws {
        let fake = FakeLaunchctl([
            ["print", "system"]: .success(listing("system", [(612, "com.example.real"), (1, "com.fake.row")])),
            ["print", "user/501"]: .success(emptyUser),
            ["print", "gui/501"]: .success(emptyGui),
            ["dumpstate"]: .success("system/com.example.real = {\n\tpath = /Library/LaunchDaemons/r.plist\n}\n"),
        ])
        let snapshot = try collect(fake)
        #expect(snapshot.jobs.map(\.label) == ["com.example.real"])
        #expect(snapshot.issues.isEmpty)
        #expect(snapshot.queriedDomains?.contains("system") == true)
    }

    @Test func rowWithoutDumpBlockThatLaunchdFindsIsKept() throws {
        let fake = FakeLaunchctl([
            ["print", "system"]: .success(listing("system", [(0, "com.example.late")])),
            ["print", "user/501"]: .success(emptyUser),
            ["print", "gui/501"]: .success(emptyGui),
            // Loaded between the listing and the dump, so it has no block.
            ["dumpstate"]: .success(""),
            ["print", "system/com.example.late"]: .success(
                "system/com.example.late = {\n\tpath = /Library/LaunchDaemons/l.plist\n\tstate = not running\n}\n"),
        ])
        let job = try #require(try collect(fake).jobs.first)
        #expect(!job.rowSuspect)
        #expect(job.verifiedIndividually)
        #expect(job.path == "/Library/LaunchDaemons/l.plist")
    }

    @Test func forgedListingIsRebuiltFromVerifiedCandidates() throws {
        // The attacker's label injected com.fake.row, then closed `services` and opened a dummy block, which
        // hides the real com.example.hidden row from the listing. Its dump block header is still genuine.
        let forgedGui = "gui/501 = {\n\tservice count = 2\n\tservices = {\n"
            + "\t\t       0      - \tdev.attacker.x\n\t\t   12345      - \tcom.fake.row\n\t}\n\tfoo = {\n"
            + "\t\t     777      - \tcom.example.hidden\n\t}\n}\n"
        let fake = FakeLaunchctl([
            ["print", "system"]: .success(listing("system", [])),
            ["print", "user/501"]: .success(emptyUser),
            ["print", "gui/501"]: .success(forgedGui),
            ["dumpstate"]: .success("gui/501/dev.attacker.x = {\n\tstate = not running\n}\n"
                + "gui/501/com.example.hidden = {\n\tpath = /Library/LaunchAgents/h.plist\n\tstate = running\n}\n"),
            ["print", "gui/501/dev.attacker.x"]: .success("gui/501/dev.attacker.x = {\n\tstate = not running\n}\n"),
            ["print", "gui/501/com.example.hidden"]: .success(
                "gui/501/com.example.hidden = {\n\tpath = /Library/LaunchAgents/h.plist\n\tstate = running\n}\n"),
        ])
        let snapshot = try collect(fake)
        let gui = snapshot.jobs.filter { $0.domain == "gui/501" }
        #expect(Set(gui.filter(\.verifiedIndividually).map(\.label)) == ["dev.attacker.x", "com.example.hidden"])
        #expect(gui.filter(\.verifiedIndividually).allSatisfy { !$0.rowSuspect })
        // launchd denies com.fake.row, but in a forged listing that row is evidence (it may be the visible half
        // of the attacker's own newline label), so it stays, as suspect, instead of vanishing.
        let fakeRow = try #require(gui.first { $0.label == "com.fake.row" })
        #expect(fakeRow.rowSuspect && !fakeRow.isRunning)
        #expect(gui.first { $0.label == "com.example.hidden" }?.isRunning == true)
        #expect(gui.first { $0.label == "dev.attacker.x" }?.isRunning == false)
        // Its disabled list is still untrusted, so it can't vouch that plists aren't loaded.
        #expect(snapshot.queriedDomains?.contains("gui/501") == false)
        #expect(snapshot.issues.contains { $0.contains("gui/501") })
    }

    @Test func perJobPrintForAnotherLabelIsRejected() throws {
        let fake = FakeLaunchctl([
            ["print", "system"]: .success(listing("system", [(0, "com.example.a")])),
            ["print", "user/501"]: .success(emptyUser),
            ["print", "gui/501"]: .success(emptyGui),
            ["dumpstate"]: .success(""),
            ["print", "system/com.example.a"]: .success("system/com.example.other = {\n\tstate = running\n}\n"),
        ])
        let job = try #require(try collect(fake).jobs.first)
        #expect(job.rowSuspect)
        #expect(!job.verifiedIndividually)
    }

    @Test func perJobPrintWithItsOwnDuplicateBlockIsRejected() throws {
        let fake = FakeLaunchctl([
            ["print", "system"]: .success(listing("system", [(0, "com.example.a")])),
            ["print", "user/501"]: .success(emptyUser),
            ["print", "gui/501"]: .success(emptyGui),
            ["dumpstate"]: .success(""),
            ["print", "system/com.example.a"]: .success(
                "system/com.example.a = {\n\tstate = not running\n}\nsystem/com.example.a = {\n\tstate = running\n}\n"),
        ])
        #expect(try #require(try collect(fake).jobs.first).rowSuspect)
    }

    @Test func hiddenCandidateWhoseCheckFailsStaysVisibleAsSuspect() throws {
        let forgedGui = "gui/501 = {\n\tservice count = 2\n\tservices = {\n"
            + "\t\t       0      - \tdev.attacker.x\n\t\t   12345      - \tcom.fake.row\n\t}\n\tfoo = {\n"
            + "\t\t     777      - \tcom.example.hidden\n\t}\n}\n"
        let fake = FakeLaunchctl([
            ["print", "system"]: .success(listing("system", [])),
            ["print", "user/501"]: .success(emptyUser),
            ["print", "gui/501"]: .success(forgedGui),
            ["dumpstate"]: .success("gui/501/com.example.hidden = {\n\tstate = running\n}\n"),
            // The direct check times out instead of answering.
            ["print", "gui/501/com.example.hidden"]: .failure(LaunchctlCollector.CollectError.timedOut),
        ])
        let job = try #require(try collect(fake).jobs.first { $0.label == "com.example.hidden" })
        #expect(job.rowSuspect)
        #expect(!job.isRunning)
    }

    @Test func listedTwiceGetsNoPidEvenAfterConfirmation() throws {
        var listing = DomainListing(services: ["com.example.a": .init(pid: 4242, status: "-")], disabled: [:])
        listing.suspectLabels = ["com.example.a"]
        let snapshot = LoadedSnapshot.build(listings: ["system": listing], details: nil)
        let outcome = SuspectJobVerifier.verify(
            snapshot: snapshot, listings: ["system": listing], details: nil,
            launchctl: { _ in "system/com.example.a = {\n\tstate = running\n}\n" })
        let job = try #require(outcome.jobs.first)
        #expect(job.verifiedIndividually)
        #expect(job.pid == nil)
        // Running comes from launchd's direct answer instead.
        #expect(job.isRunning)
    }

    @Test func healthyJobsAreNotQueriedOneByOne() throws {
        let fake = FakeLaunchctl([
            ["print", "system"]: .success(listing("system", [(612, "com.example.a")])),
            ["print", "user/501"]: .success(emptyUser),
            ["print", "gui/501"]: .success(emptyGui),
            ["dumpstate"]: .success("system/com.example.a = {\n\tpath = /Library/LaunchDaemons/a.plist\n}\n"),
        ])
        _ = try collect(fake)
        #expect(fake.calls.count == 4)
    }
}
