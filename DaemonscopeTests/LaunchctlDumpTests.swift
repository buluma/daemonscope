import Foundation
import Testing
@testable import Daemonscope

// Hand-written in the shape `launchctl` printed on macOS 27.3. Real output isn't committed: it holds environment
// variables and account details.

private let systemPrint = """
system = {
	type = system
	handle = 0
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
        #expect(job.lastExit == "(never exited)")
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
