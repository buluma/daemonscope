import Foundation
import Testing
@testable import Daemonscope

/// Builds throwaway `.app` folders with just an Info.plist, enough for the scanner.
private final class AppFixture {
    let root: URL

    init() throws {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemonscope-ls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        // /var is a symlink to /private/var and the scanner reports resolved paths.
        guard let resolved = realpath(unresolved.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func app(_ relative: String, _ info: [String: Any]) throws -> URL {
        let app = root.appendingPathComponent(relative)
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }
}

/// Answers handler questions from a table instead of Launch Services.
private struct FakeHandlers: HandlerLookup {
    var schemeHandlers: [String: [String]] = [:]
    var schemeDefaults: [String: String] = [:]
    var typeHandlers: [String: [String]] = [:]
    var typeDefaults: [String: String] = [:]

    func handlers(forScheme scheme: String) -> [String] { schemeHandlers[scheme] ?? [] }
    func defaultHandler(forScheme scheme: String) -> String? { schemeDefaults[scheme] }
    func handlers(forContentType type: String) -> [String] { typeHandlers[type] ?? [] }
    func defaultHandler(forContentType type: String) -> String? { typeDefaults[type] }
}

struct AppBundleScannerTests {
    @Test func readsIdentityAndDeclarations() throws {
        let fixture = try AppFixture()
        try fixture.app("Apps/Mailer.app", [
            "CFBundleIdentifier": "com.example.mailer",
            "CFBundleName": "Mailer",
            "CFBundleShortVersionString": "2.1",
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["mailto", "X-Mailer"]]],
            "CFBundleDocumentTypes": [
                ["LSItemContentTypes": ["com.apple.mail.email"]],
                ["CFBundleTypeExtensions": ["eml", "*"]],
            ],
        ])

        let scan = AppBundleScanner(roots: [fixture.root.appendingPathComponent("Apps")]).scan()
        let app = try #require(scan.apps.first)
        #expect(app.bundleID == "com.example.mailer")
        #expect(app.name == "Mailer")
        #expect(app.version == "2.1")
        // Schemes are case-insensitive; keep them lowercased so declarations and lookups agree.
        #expect(app.urlSchemes == ["mailto", "x-mailer"])
        // "eml" resolves to the same type as the explicit one, so it's listed once; "*" is a wildcard, not a type.
        #expect(app.contentTypes == ["com.apple.mail.email"])
        #expect(scan.issues.isEmpty)
    }

    @Test func unknownExtensionsBecomeDynamicTypes() throws {
        let fixture = try AppFixture()
        try fixture.app("Apps/Odd.app", ["CFBundleDocumentTypes": [["CFBundleTypeExtensions": ["zzqx"]]]])
        let types = try #require(AppBundleScanner(roots: [fixture.root.appendingPathComponent("Apps")]).scan().apps.first).contentTypes
        // Launch Services maps unknown extensions to dynamic "dyn." types, so they stay queryable.
        #expect(types.count == 1)
        #expect(types.first?.hasPrefix("dyn.") == true)
    }

    @Test func displayNamePrefersDisplayNameThenNameThenFolder() throws {
        let fixture = try AppFixture()
        try fixture.app("Apps/One.app", ["CFBundleDisplayName": "Uno", "CFBundleName": "One"])
        try fixture.app("Apps/Two.app", ["CFBundleName": "Dos"])
        try fixture.app("Apps/Three.app", [:])
        let names = AppBundleScanner(roots: [fixture.root.appendingPathComponent("Apps")]).scan().apps.map(\.name)
        #expect(Set(names) == ["Uno", "Dos", "Three"])
    }

    @Test func invisibleDisplayNameFallsBackToBundleName() throws {
        let fixture = try AppFixture()
        // Some system apps ship a CFBundleDisplayName that is only a left-to-right mark.
        try fixture.app("Apps/Media.app", ["CFBundleDisplayName": "\u{200E}", "CFBundleName": "MediaRemoteUI"])
        try fixture.app("Apps/Blank.app", ["CFBundleDisplayName": "  ", "CFBundleName": "\u{200F} "])
        let names = Set(AppBundleScanner(roots: [fixture.root.appendingPathComponent("Apps")]).scan().apps.map(\.name))
        #expect(names == ["MediaRemoteUI", "Blank"])
    }

    @Test func readsShallowBundlesWithInfoPlistAtTheTop() throws {
        let fixture = try AppFixture()
        let app = fixture.root.appendingPathComponent("Apps/Shallow.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.shallow"], format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Info.plist"))
        let scan = AppBundleScanner(roots: [fixture.root.appendingPathComponent("Apps")]).scan()
        #expect(scan.apps.compactMap(\.bundleID) == ["com.example.shallow"])
    }

    @Test func appFolderWithoutAnyInfoPlistIsSkippedQuietly() throws {
        let fixture = try AppFixture()
        // Like /System/Library/CoreServices/liquiddetectiond.app: an executable and resources, nothing to declare.
        let app = fixture.root.appendingPathComponent("Apps/Bare.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data([0]).write(to: app.appendingPathComponent("bare"))
        let scan = AppBundleScanner(roots: [fixture.root.appendingPathComponent("Apps")]).scan()
        #expect(scan.apps.isEmpty)
        #expect(scan.issues.isEmpty)
    }

    @Test func doesNotDescendIntoAppBundles() throws {
        let fixture = try AppFixture()
        try fixture.app("Apps/Outer.app", ["CFBundleIdentifier": "com.example.outer"])
        try fixture.app("Apps/Outer.app/Contents/Applications/Inner.app", ["CFBundleIdentifier": "com.example.inner"])
        try fixture.app("Apps/Vendor/Nested.app", ["CFBundleIdentifier": "com.example.nested"])
        let ids = Set(AppBundleScanner(roots: [fixture.root.appendingPathComponent("Apps")]).scan().apps.compactMap(\.bundleID))
        #expect(ids == ["com.example.outer", "com.example.nested"])
    }

    @Test func unreadableInfoPlistIsAnIssueNotACrash() throws {
        let fixture = try AppFixture()
        let broken = fixture.root.appendingPathComponent("Apps/Broken.app/Contents")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: broken.appendingPathComponent("Info.plist"))
        try fixture.app("Apps/Fine.app", ["CFBundleIdentifier": "com.example.fine"])

        let scan = AppBundleScanner(roots: [fixture.root.appendingPathComponent("Apps")]).scan()
        #expect(scan.apps.compactMap(\.bundleID) == ["com.example.fine"])
        #expect(scan.issues.count == 1)
        #expect(scan.issues.first?.path.hasSuffix("Broken.app") == true)
    }

    @Test func missingRootIsNotAnIssue() {
        let scan = AppBundleScanner(roots: [URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")]).scan()
        #expect(scan.apps.isEmpty)
        #expect(scan.issues.isEmpty)
    }

    @Test func standardRootsCoverSystemUserAndCoreServices() {
        let roots = AppBundleScanner.standard(home: URL(fileURLWithPath: "/Users/tester")).roots.map(\.path)
        #expect(roots == ["/Applications", "/System/Applications", "/Users/tester/Applications", "/System/Library/CoreServices"])
    }
}

struct AssociationInventoryTests {
    private func app(_ path: String, schemes: [String] = [], types: [String] = []) -> AppRecord {
        AppRecord(path: path, resolvedPath: path, bundleID: nil, name: (path as NSString).lastPathComponent,
                  version: nil, urlSchemes: schemes, contentTypes: types)
    }

    @Test func groupsDeclarationsAndAsksLaunchServicesForHandlers() throws {
        let apps = [
            app("/Applications/A.app", schemes: ["mailto"]),
            app("/Applications/B.app", schemes: ["mailto"], types: ["public.plain-text"]),
        ]
        let lookup = FakeHandlers(
            schemeHandlers: ["mailto": ["/Applications/A.app", "/Elsewhere/C.app"]],
            schemeDefaults: ["mailto": "/Applications/A.app"],
            typeHandlers: ["public.plain-text": ["/Applications/B.app"]],
            typeDefaults: ["public.plain-text": "/Applications/B.app"])

        let inventory = AssociationInventory.build(apps: apps, lookup: lookup)

        let mailto = try #require(inventory.associations.first { $0.kind == .urlScheme && $0.identifier == "mailto" })
        #expect(mailto.declaredBy == ["/Applications/A.app", "/Applications/B.app"])
        #expect(mailto.defaultHandler == "/Applications/A.app")
        #expect(mailto.handlers == ["/Applications/A.app", "/Elsewhere/C.app"])
        // B declares mailto, but Launch Services doesn't list it as a handler.
        #expect(mailto.declaredButNotRegistered == ["/Applications/B.app"])
        // C handles mailto but wasn't in a scanned folder.
        #expect(mailto.handlersOutsideScan == ["/Elsewhere/C.app"])

        let text = try #require(inventory.associations.first { $0.kind == .contentType })
        #expect(text.identifier == "public.plain-text")
        #expect(text.declaredButNotRegistered.isEmpty)
    }

    @Test func handlerPathsAreComparedAfterResolvingSymlinks() throws {
        // Like Safari: found at /Applications/Safari.app, registered at its resolved Cryptex path.
        let safari = AppRecord(
            path: "/Applications/Safari.app", resolvedPath: "/System/Cryptexes/App/System/Applications/Safari.app",
            bundleID: "com.apple.Safari", name: "Safari", version: nil, urlSchemes: ["http"], contentTypes: [])
        let lookup = FakeHandlers(schemeHandlers: ["http": ["/System/Cryptexes/App/System/Applications/Safari.app"]])
        let http = try #require(AssociationInventory.build(apps: [safari], lookup: lookup).associations.first)
        #expect(http.declaredButNotRegistered.isEmpty)
        #expect(http.handlersOutsideScan.isEmpty)
    }

    @Test func appsGetPerDeclarationRegistrationAndDefaultFlags() throws {
        let apps = [app("/Applications/A.app", schemes: ["mailto", "a-only"])]
        let lookup = FakeHandlers(
            schemeHandlers: ["mailto": ["/Applications/A.app"]],
            schemeDefaults: ["mailto": "/Applications/A.app"])
        let inventory = AssociationInventory.build(apps: apps, lookup: lookup)
        let declarations = inventory.declarations(of: apps[0])
        #expect(declarations.map(\.association.identifier) == ["a-only", "mailto"])
        #expect(declarations.first { $0.association.identifier == "mailto" }?.isRegistered == true)
        #expect(declarations.first { $0.association.identifier == "mailto" }?.isDefault == true)
        #expect(declarations.first { $0.association.identifier == "a-only" }?.isRegistered == false)
    }

    @Test func associationsAreSortedSchemesThenTypesByIdentifier() {
        let apps = [app("/A.app", schemes: ["zed", "abc"], types: ["public.png", "com.adobe.pdf"])]
        let ids = AssociationInventory.build(apps: apps, lookup: FakeHandlers()).associations.map(\.identifier)
        #expect(ids == ["abc", "zed", "com.adobe.pdf", "public.png"])
    }
}

@MainActor
struct LaunchServicesStoreTests {
    @Test func refreshScansAndBuildsInventory() async throws {
        let fixture = try AppFixture()
        let app = try fixture.app("Apps/Mailer.app", [
            "CFBundleName": "Mailer", "CFBundleURLTypes": [["CFBundleURLSchemes": ["mailto"]]],
        ])
        let store = LaunchServicesStore(
            scanner: AppBundleScanner(roots: [fixture.root.appendingPathComponent("Apps")]),
            lookup: FakeHandlers(schemeHandlers: ["mailto": [app.path]], schemeDefaults: ["mailto": app.path]))
        #expect(store.scan == nil)

        await store.refresh()

        #expect(store.scan?.apps.map(\.name) == ["Mailer"])
        #expect(store.inventory.associations.map(\.identifier) == ["mailto"])
        #expect(store.inventory.associations.first?.defaultHandler == app.path)
        #expect(store.appName(for: app.path) == "Mailer")
        #expect(store.appName(for: "/Elsewhere/Other Thing.app") == "Other Thing")
        #expect(!store.isRefreshing)
    }
}

struct AppFilterTests {
    private func app(_ name: String, schemes: [String] = [], types: [String] = [], bundleID: String? = nil) -> AppRecord {
        AppRecord(path: "/Applications/\(name).app", resolvedPath: "/Applications/\(name).app", bundleID: bundleID,
                  name: name, version: nil, urlSchemes: schemes, contentTypes: types)
    }

    @Test func onlyWithAssociationsDropsAppsThatDeclareNothing() {
        let apps = [app("Mailer", schemes: ["mailto"]), app("Viewer", types: ["public.png"]), app("Clock")]
        #expect(AppFilter(onlyWithAssociations: true).apply(to: apps).map(\.name) == ["Mailer", "Viewer"])
        #expect(AppFilter(onlyWithAssociations: false).apply(to: apps).map(\.name) == ["Mailer", "Viewer", "Clock"])
    }

    @Test func queryMatchesNameBundleIDOrPath() {
        let apps = [app("Mailer", bundleID: "com.example.mail"), app("Clock", bundleID: "com.example.time")]
        #expect(AppFilter(query: "mail").apply(to: apps).map(\.name) == ["Mailer"])
        #expect(AppFilter(query: "TIME").apply(to: apps).map(\.name) == ["Clock"])
        #expect(AppFilter(query: "/Applications/Clock").apply(to: apps).map(\.name) == ["Clock"])
    }
}
