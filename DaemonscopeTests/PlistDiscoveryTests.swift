import Foundation
import Testing
@testable import Daemonscope

/// Builds a throwaway directory tree so discovery runs against known fixtures instead of the real system.
private final class Fixture {
    let root: URL

    init() throws {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemonscope-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        // The temp folder lives under /var, a symlink to /private/var, and FileManager reports resolved paths.
        // `resolvingSymlinksInPath()` strips "/private" back off, so use realpath(3) instead.
        guard let resolved = realpath(unresolved.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ relative: String) -> URL {
        root.appendingPathComponent(relative)
    }

    @discardableResult
    func writePlist(_ relative: String, _ dictionary: [String: Any]) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        return try write(relative, data)
    }

    @discardableResult
    func write(_ relative: String, _ data: Data) throws -> URL {
        let file = url(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }
}

struct DiskJobParsingTests {
    @Test func parsesCommonFields() throws {
        let plist: [String: Any] = [
            "Label": "com.example.agent",
            "Program": "/usr/local/bin/agent",
            "ProgramArguments": ["/usr/local/bin/agent", "--verbose"],
            "RunAtLoad": true,
            "Disabled": false,
            "StartInterval": 300,
            "KeepAlive": ["SuccessfulExit": false, "NetworkState": true],
            "EnvironmentVariables": ["TOKEN": "s3cret"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)

        let job = try DiskJob.parse(data: data, path: "/Library/LaunchAgents/com.example.agent.plist", location: .globalAgents)

        #expect(job.label == "com.example.agent")
        #expect(job.program == "/usr/local/bin/agent")
        #expect(job.programArguments == ["/usr/local/bin/agent", "--verbose"])
        #expect(job.runAtLoad == true)
        #expect(job.disabledInPlist == false)
        #expect(job.startInterval == 300)
        #expect(job.keepAlive == .conditional(["NetworkState", "SuccessfulExit"]))
        #expect(job.environmentVariables == ["TOKEN": "s3cret"])
        #expect(job.location == .globalAgents)
        #expect(job.isApple == false)
    }

    @Test func bundleProgramResolvesAgainstOwningApp() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.vendor.helper", "BundleProgram": "Contents/Resources/helper"],
            format: .xml, options: 0)
        let job = try DiskJob.parse(
            data: data, path: "/Applications/Tool.app/Contents/Library/LaunchAgents/h.plist",
            location: .appAgents, owningApp: "/Applications/Tool.app")
        #expect(job.bundleProgram == "Contents/Resources/helper")
        #expect(job.executablePath == "/Applications/Tool.app/Contents/Resources/helper")
    }

    @Test func executablePathPrefersProgramThenFirstArgument() throws {
        func job(_ plist: [String: Any]) throws -> DiskJob {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            return try DiskJob.parse(data: data, path: "/x.plist", location: .globalAgents)
        }
        #expect(try job(["Label": "a", "Program": "/bin/a", "ProgramArguments": ["/bin/b"]]).executablePath == "/bin/a")
        #expect(try job(["Label": "a", "ProgramArguments": ["/bin/b", "-x"]]).executablePath == "/bin/b")
        #expect(try job(["Label": "a"]).executablePath == nil)
        // Without an owning app a relative BundleProgram can't be resolved.
        #expect(try job(["Label": "a", "BundleProgram": "Contents/x"]).executablePath == nil)
    }

    @Test func keepAliveBooleanForm() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "a", "KeepAlive": true], format: .xml, options: 0)
        let job = try DiskJob.parse(data: data, path: "/x.plist", location: .userAgents)
        #expect(job.keepAlive == .always(true))
    }

    @Test func absentFieldsStayAbsent() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["Label": "a"], format: .xml, options: 0)
        let job = try DiskJob.parse(data: data, path: "/x.plist", location: .userAgents)
        #expect(job.program == nil)
        #expect(job.programArguments.isEmpty)
        #expect(job.runAtLoad == nil)
        #expect(job.disabledInPlist == nil)
        #expect(job.keepAlive == nil)
        #expect(job.environmentVariables.isEmpty)
    }

    @Test func rejectsMalformedData() {
        #expect(throws: DiskJob.ParseError.self) {
            try DiskJob.parse(data: Data("not a plist".utf8), path: "/x.plist", location: .userAgents)
        }
    }

    @Test func rejectsNonDictionaryRoot() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["a", "b"], format: .xml, options: 0)
        #expect(throws: DiskJob.ParseError.notADictionary) {
            try DiskJob.parse(data: data, path: "/x.plist", location: .userAgents)
        }
    }

    @Test(arguments: [
        ("/System/Library/LaunchDaemons/foo.plist", "org.example.foo", true),
        ("/Library/LaunchDaemons/foo.plist", "com.apple.foo", true),
        ("/Library/LaunchDaemons/foo.plist", "com.example.foo", false),
        ("/Library/LaunchDaemons/foo.plist", "com.applesauce.foo", false),
    ])
    func appleJobDetection(path: String, label: String, expected: Bool) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["Label": label], format: .xml, options: 0)
        let job = try DiskJob.parse(data: data, path: path, location: .globalDaemons)
        #expect(job.isApple == expected)
    }
}

struct PlistDiscoveryTests {
    @Test func scansJobDirectoriesAndIgnoresNonPlists() throws {
        let fixture = try Fixture()
        try fixture.writePlist("UserAgents/com.example.one.plist", ["Label": "com.example.one"])
        try fixture.writePlist("Daemons/com.example.two.plist", ["Label": "com.example.two"])
        try fixture.write("UserAgents/.DS_Store", Data([0, 1, 2]))
        try fixture.write("UserAgents/readme.txt", Data("hi".utf8))

        let discovery = PlistDiscovery(
            jobDirectories: [
                .init(url: fixture.url("UserAgents"), location: .userAgents),
                .init(url: fixture.url("Daemons"), location: .globalDaemons),
            ],
            appSearchRoots: [])
        let scan = discovery.scan()

        // Jobs are sorted by path, and "Daemons" sorts before "UserAgents".
        #expect(scan.jobs.map(\.label) == ["com.example.two", "com.example.one"])
        #expect(scan.jobs.first { $0.label == "com.example.one" }?.location == .userAgents)
        #expect(scan.jobs.first { $0.label == "com.example.two" }?.location == .globalDaemons)
        #expect(scan.issues.isEmpty)
    }

    @Test func recordsSymlinkTargets() throws {
        let fixture = try Fixture()
        let target = try fixture.writePlist("Vendor/Real.app/Contents/Resources/com.vendor.agent.plist", ["Label": "com.vendor.agent"])
        try FileManager.default.createDirectory(at: fixture.url("Agents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.url("Agents/com.vendor.agent.plist"), withDestinationURL: target)
        try fixture.writePlist("Agents/plain.plist", ["Label": "plain"])

        let scan = PlistDiscovery(
            jobDirectories: [.init(url: fixture.url("Agents"), location: .globalAgents)], appSearchRoots: []
        ).scan()

        let linked = try #require(scan.jobs.first { $0.label == "com.vendor.agent" })
        #expect(linked.path == fixture.url("Agents/com.vendor.agent.plist").path)
        #expect(linked.symlinkTarget == target.path)
        #expect(scan.jobs.first { $0.label == "plain" }?.symlinkTarget == nil)
    }

    @Test func missingDirectoryIsNotAnIssue() throws {
        let fixture = try Fixture()
        let discovery = PlistDiscovery(
            jobDirectories: [.init(url: fixture.url("DoesNotExist"), location: .userAgents)],
            appSearchRoots: [fixture.url("NoApps")])
        let scan = discovery.scan()
        #expect(scan.jobs.isEmpty)
        #expect(scan.issues.isEmpty)
    }

    @Test func malformedPlistBecomesIssueWithoutDroppingOthers() throws {
        let fixture = try Fixture()
        try fixture.writePlist("Agents/good.plist", ["Label": "good"])
        let bad = try fixture.write("Agents/bad.plist", Data("<plist><dict><key>".utf8))

        let scan = PlistDiscovery(
            jobDirectories: [.init(url: fixture.url("Agents"), location: .globalAgents)],
            appSearchRoots: []
        ).scan()

        #expect(scan.jobs.map(\.label) == ["good"])
        #expect(scan.issues.map(\.path) == [bad.path])
    }

    @Test func missingLabelKeepsJobAndRecordsIssue() throws {
        let fixture = try Fixture()
        let file = try fixture.writePlist("Agents/nolabel.plist", ["Program": "/bin/true"])

        let scan = PlistDiscovery(
            jobDirectories: [.init(url: fixture.url("Agents"), location: .globalAgents)],
            appSearchRoots: []
        ).scan()

        #expect(scan.jobs.count == 1)
        #expect(scan.jobs.first?.label == nil)
        #expect(scan.jobs.first?.program == "/bin/true")
        #expect(scan.issues.map(\.path) == [file.path])
    }

    @Test func unreadableDirectoryBecomesIssue() throws {
        let fixture = try Fixture()
        try fixture.writePlist("Locked/x.plist", ["Label": "x"])
        let locked = fixture.url("Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let scan = PlistDiscovery(
            jobDirectories: [.init(url: locked, location: .globalDaemons)],
            appSearchRoots: []
        ).scan()

        #expect(scan.jobs.isEmpty)
        #expect(scan.issues.map(\.path) == [locked.path])
    }

    @Test func findsAppBundledJobsIncludingNestedFolders() throws {
        let fixture = try Fixture()
        try fixture.writePlist(
            "Applications/Tool.app/Contents/Library/LaunchAgents/com.vendor.tool.helper.plist",
            ["Label": "com.vendor.tool.helper"])
        try fixture.writePlist(
            "Applications/Vendor/Suite.app/Contents/Library/LaunchDaemons/com.vendor.suite.daemon.plist",
            ["Label": "com.vendor.suite.daemon"])
        // Jobs inside a nested bundle are not app-registered jobs of the outer app; don't descend into bundles.
        try fixture.writePlist(
            "Applications/Tool.app/Contents/Resources/Inner.app/Contents/Library/LaunchAgents/inner.plist",
            ["Label": "inner"])

        let scan = PlistDiscovery(jobDirectories: [], appSearchRoots: [fixture.url("Applications")]).scan()

        let helper = try #require(scan.jobs.first { $0.label == "com.vendor.tool.helper" })
        #expect(helper.location == .appAgents)
        #expect(helper.owningApp == fixture.url("Applications/Tool.app").path)

        let daemon = try #require(scan.jobs.first { $0.label == "com.vendor.suite.daemon" })
        #expect(daemon.location == .appDaemons)
        #expect(daemon.owningApp == fixture.url("Applications/Vendor/Suite.app").path)

        #expect(!scan.jobs.contains { $0.label == "inner" })
        #expect(scan.issues.isEmpty)
    }

    @Test func standardLocationsCoverUserSystemAndApps() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let discovery = PlistDiscovery.standard(home: home)
        let dirs = Dictionary(uniqueKeysWithValues: discovery.jobDirectories.map { ($0.url.path, $0.location) })
        #expect(dirs == [
            "/Users/tester/Library/LaunchAgents": .userAgents,
            "/Library/LaunchAgents": .globalAgents,
            "/Library/LaunchDaemons": .globalDaemons,
            "/System/Library/LaunchAgents": .systemAgents,
            "/System/Library/LaunchDaemons": .systemDaemons,
        ])
        #expect(discovery.appSearchRoots.map(\.path) == ["/Applications", "/Users/tester/Applications"])
    }

    @Test func scanTimestampComesFromCaller() throws {
        let when = Date(timeIntervalSince1970: 1_000_000)
        let scan = PlistDiscovery(jobDirectories: [], appSearchRoots: []).scan(now: when)
        #expect(scan.date == when)
    }
}
