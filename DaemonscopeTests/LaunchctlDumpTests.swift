import Foundation
import Testing
@testable import Daemonscope

/// Hand-written in the shape `launchctl dumpstate` produced on macOS 27.3. Real dumps aren't committed: they hold
/// environment variables and account details.
private let sampleDump = """
system = {
	type = system
	handle = 0
	services = {
		     612      - 	com.cloudflare.cloudflared
		       0      0 	com.example.ondemand
	}

	disabled services = {
		"com.example.turnedoff" => disabled
		"com.example.turnedon" => enabled
	}
}

system/com.cloudflare.cloudflared = {
	active count = 1
	path = /Library/LaunchDaemons/com.cloudflare.cloudflared.plist
	type = LaunchDaemon
	state = running
	program = /opt/homebrew/bin/cloudflared
	environment = {
		TUNNEL_TOKEN => do-not-parse-me
	}
	domain = system
	pid = 612
	last exit code = (never exited)
}

system/com.example.ondemand = {
	path = /Library/LaunchDaemons/com.example.ondemand.plist
	type = LaunchDaemon
	state = not running
	last exit code = 78: EX_CONFIG
}

user/501 = {
	type = user
	disabled services = {
	}
}

user/501/com.example.useronly = {
	path = /Users/tester/Library/LaunchAgents/com.example.useronly.plist
	type = LaunchAgent
	state = spawn scheduled
	last exit code = -15
}

user/502/com.someone.else = {
	path = /Users/other/Library/LaunchAgents/com.someone.else.plist
	type = LaunchAgent
	state = running
	pid = 99
}

gui/501 = {
	type = login
	disabled services = {
		"com.example.agentoff" => disabled
	}
}

gui/501/io.tailscale.ipn.macsys.login-item-helper = {
	active count = 0
	path = (submitted by smd.332)
	type = Submitted
	managed_by = com.apple.xpc.ServiceManagement
	state = not running
	parent bundle identifier = io.tailscale.ipn.macsys
	last exit code = 0
}

gui/502 = {
	disabled services = {
		"com.someone.else" => disabled
	}
}

"""

struct LaunchctlDumpTests {
    @Test func keepsOnlyTheCurrentUsersDomainsAndSystem() {
        let snapshot = LaunchctlDump.parse(sampleDump, uid: 501)
        #expect(Set(snapshot.jobs.map(\.domain)) == ["system", "user/501", "gui/501"])
        #expect(!snapshot.jobs.contains { $0.label == "com.someone.else" })
        #expect(snapshot.disabled["gui/502"] == nil)
    }

    @Test func parsesRunningServiceFields() throws {
        let job = try #require(LaunchctlDump.parse(sampleDump, uid: 501).jobs.first { $0.label == "com.cloudflare.cloudflared" })
        #expect(job.domain == "system")
        #expect(job.path == "/Library/LaunchDaemons/com.cloudflare.cloudflared.plist")
        #expect(job.submittedBy == nil)
        #expect(job.type == "LaunchDaemon")
        #expect(job.state == "running")
        #expect(job.isRunning)
        #expect(job.pid == 612)
        #expect(job.program == "/opt/homebrew/bin/cloudflared")
        #expect(job.lastExit == "(never exited)")
    }

    @Test func ignoresNestedBlocksSoEnvironmentIsNeverRead() throws {
        let job = try #require(LaunchctlDump.parse(sampleDump, uid: 501).jobs.first { $0.label == "com.cloudflare.cloudflared" })
        #expect(!String(describing: job).contains("do-not-parse-me"))
        #expect(job.domain == "system")
    }

    @Test func parsesNotRunningAndOtherStates() throws {
        let jobs = LaunchctlDump.parse(sampleDump, uid: 501).jobs
        let ondemand = try #require(jobs.first { $0.label == "com.example.ondemand" })
        #expect(!ondemand.isRunning)
        #expect(ondemand.pid == nil)
        #expect(ondemand.lastExit == "78: EX_CONFIG")

        let scheduled = try #require(jobs.first { $0.label == "com.example.useronly" })
        #expect(scheduled.state == "spawn scheduled")
        #expect(!scheduled.isRunning)
        #expect(scheduled.lastExit == "-15")
    }

    @Test func submittedJobsHaveNoFilePath() throws {
        let job = try #require(LaunchctlDump.parse(sampleDump, uid: 501).jobs.first { $0.label.hasPrefix("io.tailscale") })
        #expect(job.path == nil)
        #expect(job.submittedBy == "(submitted by smd.332)")
        #expect(job.parentBundleID == "io.tailscale.ipn.macsys")
    }

    @Test func parsesDisabledOverridesPerDomain() {
        let snapshot = LaunchctlDump.parse(sampleDump, uid: 501)
        #expect(snapshot.disabled["system"] == ["com.example.turnedoff": true, "com.example.turnedon": false])
        #expect(snapshot.disabled["user/501"] == [:])
        #expect(snapshot.disabled["gui/501"] == ["com.example.agentoff": true])
    }

    @Test func emptyOrGarbageInputYieldsNothing() {
        #expect(LaunchctlDump.parse("", uid: 501).jobs.isEmpty)
        let garbage = LaunchctlDump.parse("Bad request.\nnot = {\n", uid: 501)
        #expect(garbage.jobs.isEmpty)
        #expect(garbage.disabled.isEmpty)
    }
}
