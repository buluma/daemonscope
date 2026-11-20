import Foundation
import Testing
@testable import Daemonscope

// Hand-written in the shape `launchctl` printed on macOS 27.3. Real output isn't committed: it holds environment
// variables and account details.

private let systemPrint = """
system = {
	type = system
	handle = 0
	service count = 3
	security context = {
		uid = 0
	}

	services = {
		     612      - 	com.cloudflare.cloudflared
		       0      0 	com.example.ondemand
		       0     78 	com.example.badconfig
	}

	unmanaged processes = {
		com.example.unmanaged = {
			pid = 5
		}
	}

	disabled services = {
		"com.example.turnedoff" => disabled
		"com.example.turnedon" => enabled
	}
}
"""

private let guiPrint = """
gui/501 = {
	type = login
	service count = 3
	services = {
		       0      0 	io.tailscale.ipn.macsys.login-item-helper
		     777   (pe) 	com.example.agent
		       0      - 	dev.attacker.agent
	}

	disabled services = {
		"com.example.agentoff" => disabled
	}
}
"""

/// What `dumpstate` printed for a user agent whose arguments and environment contain newlines: launchd doesn't
/// escape them, so the agent's owner can write lines that look like other services' blocks.
private let dumpWithInjection = """
system = {
	disabled services = {
		"com.example.fakedisabled" => disabled
	}
}

system/com.cloudflare.cloudflared = {
	path = /Library/LaunchDaemons/com.cloudflare.cloudflared.plist
	type = LaunchDaemon
	state = running
	program = /opt/homebrew/bin/cloudflared
	environment = {
		TUNNEL_TOKEN => do-not-parse-me
	}
	pid = 612
	last exit code = (never exited)
}

system/com.example.ondemand = {
	path = /Library/LaunchDaemons/com.example.ondemand.plist
	type = LaunchDaemon
	state = not running
	last exit code = 0
}

gui/501/io.tailscale.ipn.macsys.login-item-helper = {
	path = (submitted by smd.332)
	type = Submitted
	state = not running
	parent bundle identifier = io.tailscale.ipn.macsys
}

gui/501/dev.attacker.agent = {
	path = /Users/tester/Library/LaunchAgents/dev.attacker.agent.plist
	type = LaunchAgent
	state = not running
	arguments = {
		/usr/bin/true
		arg
}

system/com.fake.injected = {
	state = running
	pid = 1
}

system/com.example.ondemand = {
	path = /tmp/evil.plist
	state = running
	pid = 1
}

system = {
	disabled services = {
		"com.cloudflare.cloudflared" => disabled
	}
}

	}
	domain = gui/501 [100019]
}

gui/502/com.someone.else = {
	state = running
}
"""

struct DomainListingTests {
    @Test func parsesServicesAndDisabledEntries() throws {
        let listing = try #require(DomainListing.parse(systemPrint, domain: "system"))
        #expect(listing.services["com.cloudflare.cloudflared"] == .init(pid: 612, status: "-"))
        #expect(listing.services["com.example.ondemand"] == .init(pid: nil, status: "0"))
        #expect(listing.services["com.example.badconfig"] == .init(pid: nil, status: "78"))
        #expect(listing.services.count == 3)
        #expect(listing.disabled == ["com.example.turnedoff": true, "com.example.turnedon": false])
    }

    @Test func ignoresNestedBlocksOtherThanServices() throws {
        let listing = try #require(DomainListing.parse(systemPrint, domain: "system"))
        #expect(listing.services["com.example.unmanaged"] == nil)
    }

    @Test func statusColumnKeepsMarkersAsReported() throws {
        let listing = try #require(DomainListing.parse(guiPrint, domain: "gui/501"))
        #expect(listing.services["com.example.agent"] == .init(pid: 777, status: "(pe)"))
    }

    @Test func rejectsOutputForAnotherDomainOrGarbage() {
        #expect(DomainListing.parse(systemPrint, domain: "gui/501") == nil)
        #expect(DomainListing.parse("Bad request.\nCould not find domain", domain: "system") == nil)
        #expect(DomainListing.parse("", domain: "system") == nil)
    }
}

struct DomainListingTamperTests {
    @Test func duplicateLabelRowsAreFlaggedNotOverwritten() throws {
        let text = "system = {\n\tservices = {\n\t\t     612      - \tcom.example.a\n\t\t       0      0 \tcom.example.a\n\t}\n}\n"
        let listing = try #require(DomainListing.parse(text, domain: "system"))
        #expect(listing.services["com.example.a"]?.pid == 612)
        #expect(listing.suspectLabels == ["com.example.a"])
    }

    @Test func labelsWithControlCharactersAreDropped() throws {
        let text = "system = {\n\tservices = {\n\t\t       0      0 \tcom.example.\u{1B}bad\n\t\t       0      0 \tcom.example.ok\n\t}\n}\n"
        let listing = try #require(DomainListing.parse(text, domain: "system"))
        #expect(Array(listing.services.keys) == ["com.example.ok"])
    }

    @Test func suspectListingLabelsMarkJobsTampered() throws {
        var listing = DomainListing(services: ["com.example.a": .init(pid: 5, status: "-")], disabled: [:])
        listing.suspectLabels = ["com.example.a"]
        let job = try #require(LoadedSnapshot.build(
            listings: ["system": listing],
            details: [ServiceKey(domain: "system", label: "com.example.a"): [["path": "/Library/LaunchDaemons/a.plist"]]]
        ).jobs.first)
        #expect(job.detailsTampered)
        #expect(job.path == nil)
    }
}

/// What `launchctl print gui/501` showed for an agent whose Label contained a newline: launchd prints it
/// unescaped, so the rest of the label became a second, fake row.
private let guiPrintWithInjectedRow = """
gui/501 = {
	service count = 2
	services = {
		       0      - 	dev.attacker.labeltest
		   12345      - 	com.fake.row
		     777   (pe) 	com.example.agent
	}

	disabled services = {
	}
}
"""

/// The matching dump: the attacker's block header is split across lines, so neither half gets a block.
private let dumpForInjectedRow = """
gui/501/dev.attacker.labeltest
		   12345      - 	com.fake.row = {
	state = not running
}

gui/501/com.example.agent = {
	path = /Library/LaunchAgents/com.example.agent.plist
	state = running
}
"""

struct ListingInjectionTests {
    @Test func injectedRowBreaksTheServiceCount() throws {
        // Two services, three rows: one row came from a newline in a label.
        let listing = try #require(DomainListing.parse(guiPrintWithInjectedRow, domain: "gui/501"))
        #expect(!listing.isStructurallySound)
    }

    @Test func forgedDumpBlocksCantVouchForAnInjectedRow() throws {
        // The attacker also forges a dump header for its fake row; the count check doesn't consult the dump.
        let listing = try #require(DomainListing.parse(guiPrintWithInjectedRow, domain: "gui/501"))
        let forgedDump = dumpForInjectedRow + "\ngui/501/com.fake.row = {\n\tstate = running\n}\n"
        let snapshot = LoadedSnapshot.build(
            listings: ["gui/501": listing], details: LaunchctlDump.serviceBlocks(forgedDump, domains: ["gui/501"]))
        let fake = try #require(snapshot.jobs.first { $0.label == "com.fake.row" })
        #expect(fake.rowSuspect)
        #expect(!fake.isRunning)
    }

    @Test func unsoundListingKeepsEveryRowVisibleButSuspect() throws {
        let listing = try #require(DomainListing.parse(guiPrintWithInjectedRow, domain: "gui/501"))
        let snapshot = LoadedSnapshot.build(listings: ["gui/501": listing], details: nil)
        #expect(Set(snapshot.jobs.map(\.label)) == ["dev.attacker.labeltest", "com.fake.row", "com.example.agent"])
        #expect(snapshot.jobs.allSatisfy { $0.rowSuspect && $0.pid == nil })
        // Its disabled list and its "not loaded" evidence can't be trusted either.
        #expect(snapshot.disabled["gui/501"] == nil)
        #expect(snapshot.queriedDomains == [])
    }

    @Test func soundListingRowsAreTrustedWithoutADump() throws {
        let text = "system = {\n\tservice count = 1\n\tservices = {\n\t\t     612      - \tcom.example.a\n\t}\n}\n"
        let listing = try #require(DomainListing.parse(text, domain: "system"))
        #expect(listing.isStructurallySound)
        let job = try #require(LoadedSnapshot.build(listings: ["system": listing], details: nil).jobs.first)
        #expect(!job.rowSuspect)
        #expect(job.pid == 612)
    }

    @Test func injectedSectionCloseThatHidesRowsIsCaught() throws {
        // A label ending in "\n\t}" closes the services section early; the real rows after it would be skipped.
        let text = "gui/501 = {\n\tservice count = 3\n\tservices = {\n\t\t       0      - \tdev.attacker.hider\n\t}\n"
            + "\t\t     777      - \tcom.example.hidden\n\t\t       0      0 \tcom.example.alsohidden\n\t}\n}\n"
        let listing = try #require(DomainListing.parse(text, domain: "gui/501"))
        #expect(!listing.isStructurallySound)
    }

    @Test func rowsInsideOtherNestedBlocksAreFine() throws {
        let text = "system = {\n\tservice count = 1\n\tsubdomains = {\n\t\tpid/1\n\t}\n"
            + "\tservices = {\n\t\t     612      - \tcom.example.a\n\t}\n"
            + "\tendpoints = {\n\t\t\"com.example.a\" = {\n\t\t\tport = 0x1\n\t\t}\n\t}\n}\n"
        #expect(try #require(DomainListing.parse(text, domain: "system")).isStructurallySound)
    }

    @Test func missingServiceCountIsUnsound() throws {
        let text = "system = {\n\tservices = {\n\t\t     612      - \tcom.example.a\n\t}\n}\n"
        #expect(try #require(DomainListing.parse(text, domain: "system")).isStructurallySound == false)
    }

    @Test func serviceCountIsReadFromTheHeaderOnly() throws {
        // A forged "service count" line later in the listing doesn't replace the real one.
        let text = "system = {\n\tservice count = 1\n\tservices = {\n\t\t     612      - \tcom.example.a\n\t}\n\tservice count = 5\n}\n"
        let listing = try #require(DomainListing.parse(text, domain: "system"))
        #expect(listing.declaredServiceCount == 1)
        #expect(listing.isStructurallySound)
    }

    @Test func repeatedSectionsBreakTheListing() throws {
        let text = "gui/501 = {\n\tservice count = 1\n\tservices = {\n\t\t       0      - \tdev.attacker.x\n\t}\n"
            + "\tdisabled services = {\n\t\t\"com.example.victim\" => disabled\n\t}\n\tdisabled services = {\n\t}\n}\n"
        #expect(try #require(DomainListing.parse(text, domain: "gui/501")).isStructurallySound == false)
    }

    @Test func malformedRowsBreakTheListing() throws {
        let text = "gui/501 = {\n\tservice count = 1\n\tservices = {\n\t\tnot a row at all\n\t}\n}\n"
        #expect(try #require(DomainListing.parse(text, domain: "gui/501")).isStructurallySound == false)
    }

    @Test func fixtureListingsAreSound() throws {
        #expect(try #require(DomainListing.parse(systemPrint, domain: "system")).isStructurallySound)
        #expect(try #require(DomainListing.parse(guiPrint, domain: "gui/501")).isStructurallySound)
    }
}

struct DumpFieldOrderTests {
    @Test func fieldsAfterTheFirstNestedBlockAreIgnored() throws {
        // A job's arguments and environment are printed in nested blocks, unescaped. Anything that looks like a
        // top-level field after them may have been written by the job itself.
        let dump = """
        gui/501/dev.attacker.agent = {
        	path = /Users/tester/Library/LaunchAgents/dev.attacker.agent.plist
        	type = LaunchAgent
        	arguments = {
        		/usr/bin/true
        	}
        	parent bundle identifier = com.apple.Finder
        	last exit code = 0
        	program = /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
        }
        """
        let fields = try #require(LaunchctlDump.serviceBlocks(dump, domains: ["gui/501"])[ServiceKey(domain: "gui/501", label: "dev.attacker.agent")]?.first)
        #expect(fields == ["path": "/Users/tester/Library/LaunchAgents/dev.attacker.agent.plist", "type": "LaunchAgent"])
    }
}

struct LaunchctlDumpTests {
    private func snapshot(dump: String? = dumpWithInjection) -> LoadedSnapshot {
        LoadedSnapshot.build(
            listings: [
                "system": DomainListing.parse(systemPrint, domain: "system")!,
                "gui/501": DomainListing.parse(guiPrint, domain: "gui/501")!,
            ],
            details: dump.map { LaunchctlDump.serviceBlocks($0, domains: ["system", "user/501", "gui/501"]) })
    }

    @Test func loadedJobsComeOnlyFromDomainListings() {
        let labels = Set(snapshot().jobs.map { "\($0.domain)/\($0.label)" })
        #expect(labels == [
            "system/com.cloudflare.cloudflared", "system/com.example.ondemand", "system/com.example.badconfig",
            "gui/501/io.tailscale.ipn.macsys.login-item-helper", "gui/501/com.example.agent", "gui/501/dev.attacker.agent",
        ])
    }

    @Test func injectedBlockForUnlistedLabelIsIgnored() {
        #expect(!snapshot().jobs.contains { $0.label == "com.fake.injected" })
    }

    @Test func injectedDuplicateBlockMarksDetailsTamperedAndDropsThem() throws {
        let job = try #require(snapshot().jobs.first { $0.label == "com.example.ondemand" })
        #expect(job.detailsTampered)
        #expect(job.path == nil)
        #expect(job.pid == nil)
        #expect(!job.isRunning)
    }

    @Test func disabledOverridesComeOnlyFromDomainListings() {
        let disabled = snapshot().disabled
        #expect(disabled["system"] == ["com.example.turnedoff": true, "com.example.turnedon": false])
        #expect(disabled["gui/501"] == ["com.example.agentoff": true])
    }

    @Test func runningStateAndPidComeFromTheListing() throws {
        let job = try #require(snapshot().jobs.first { $0.label == "com.cloudflare.cloudflared" })
        #expect(job.isRunning)
        #expect(job.pid == 612)
        #expect(!job.detailsTampered)
        #expect(job.path == "/Library/LaunchDaemons/com.cloudflare.cloudflared.plist")
        #expect(job.type == "LaunchDaemon")
        #expect(job.program == "/opt/homebrew/bin/cloudflared")
        // `last exit code` is printed after nested blocks, where a job can forge lines, so it isn't read.
        #expect(job.lastExit == nil)
        #expect(!String(describing: job).contains("do-not-parse-me"))
    }

    @Test func listingStatusIsTheFallbackLastExit() throws {
        let job = try #require(snapshot().jobs.first { $0.label == "com.example.badconfig" })
        #expect(job.lastExit == "78")
        #expect(job.path == nil)
        #expect(!job.detailsTampered)
    }

    @Test func submittedJobsKeepSubmitterAndBundle() throws {
        let job = try #require(snapshot().jobs.first { $0.label.hasPrefix("io.tailscale") })
        #expect(job.path == nil)
        #expect(job.submittedBy == "(submitted by smd.332)")
        #expect(job.parentBundleID == "io.tailscale.ipn.macsys")
    }

    @Test func withoutDumpstateJobsStillHaveState() throws {
        let snapshot = snapshot(dump: nil)
        #expect(snapshot.jobs.count == 6)
        let job = try #require(snapshot.jobs.first { $0.label == "com.cloudflare.cloudflared" })
        #expect(job.isRunning)
        #expect(job.path == nil)
    }

    @Test func queriedDomainsAreTheListedOnes() {
        #expect(snapshot().queriedDomains == ["system", "gui/501"])
    }
}
