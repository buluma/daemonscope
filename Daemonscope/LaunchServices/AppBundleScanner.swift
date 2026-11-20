import Foundation
import UniformTypeIdentifiers

/// An app bundle and the URL schemes and content types its Info.plist declares.
///
/// Declarations are what the app claims; whether Launch Services actually lists it as a handler is a separate
/// question, answered by `AssociationInventory`.
struct AppRecord: Identifiable, Sendable, Hashable {
    var id: String { path }

    /// Where the bundle was found, as found (it may be a symlink, like /Applications/Safari.app).
    let path: String
    /// `path` with symlinks resolved. Launch Services reports handlers by their real location.
    let resolvedPath: String
    let bundleID: String?
    let name: String
    let version: String?
    /// Lowercased: schemes are case-insensitive.
    let urlSchemes: [String]
    /// Uniform type identifiers, including ones resolved from declared filename extensions.
    let contentTypes: [String]
}

struct AppBundleScan: Sendable {
    let date: Date
    let roots: [URL]
    let apps: [AppRecord]
    let issues: [ScanIssue]
}

/// Finds `.app` bundles in a few folders and reads their declarations straight from Info.plist.
///
/// Info.plist is read with PropertyListSerialization rather than `Bundle`, which caches bundles for the life of
/// the process and would miss changes between refreshes.
struct AppBundleScanner: Sendable {
    let roots: [URL]

    static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AppBundleScanner {
        AppBundleScanner(roots: [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Library/CoreServices"),
        ])
    }

    func scan(now: Date = Date()) -> AppBundleScan {
        var apps: [AppRecord] = []
        var issues: [ScanIssue] = []
        var seen: Set<String> = []

        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil,
                // Apps nested inside other apps (helpers, Xcode's bundled tools) aren't separately installed.
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else {
                issues.append(ScanIssue(path: root.path, message: "Couldn't search folder for apps."))
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "app" {
                let resolved = Self.realPath(url.path) ?? url.path
                // The same app can be reachable twice, e.g. through a symlink.
                guard seen.insert(resolved).inserted else { continue }
                do {
                    if let app = try Self.read(app: url, resolvedPath: resolved) { apps.append(app) }
                } catch {
                    issues.append(ScanIssue(path: url.path, message: "Couldn't read Info.plist: \(error.localizedDescription)"))
                }
            }
        }
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return AppBundleScan(date: now, roots: roots, apps: apps, issues: issues)
    }

    /// `nil` when the bundle has no Info.plist at all, so it can't declare anything (some system bundles are
    /// just an executable and resources). A present but unreadable Info.plist throws.
    static func read(app url: URL, resolvedPath: String) throws -> AppRecord? {
        // Regular bundles keep it in Contents/; iOS-style "shallow" bundles keep it at the top.
        let candidates = [url.appendingPathComponent("Contents/Info.plist"), url.appendingPathComponent("Info.plist")]
        guard let plistURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return nil
        }
        let data = try Data(contentsOf: plistURL)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }

        var schemes: [String] = []
        for urlType in info["CFBundleURLTypes"] as? [[String: Any]] ?? [] {
            for scheme in urlType["CFBundleURLSchemes"] as? [String] ?? [] where !scheme.isEmpty {
                let lowered = scheme.lowercased()
                if !schemes.contains(lowered) { schemes.append(lowered) }
            }
        }

        var types: [String] = []
        func add(_ identifier: String) {
            let lowered = identifier.lowercased()
            if !types.contains(lowered) { types.append(lowered) }
        }
        for documentType in info["CFBundleDocumentTypes"] as? [[String: Any]] ?? [] {
            for identifier in documentType["LSItemContentTypes"] as? [String] ?? [] where !identifier.isEmpty {
                add(identifier)
            }
            for ext in documentType["CFBundleTypeExtensions"] as? [String] ?? [] where !ext.isEmpty && ext != "*" {
                // Unknown extensions become dynamic "dyn." types, which Launch Services can still map.
                if let type = UTType(filenameExtension: ext) { add(type.identifier) }
            }
        }

        let folderName = url.deletingPathExtension().lastPathComponent
        let name = [info["CFBundleDisplayName"], info["CFBundleName"]]
            .compactMap { ($0 as? String).map(visibleText) }
            .first { !$0.isEmpty } ?? folderName

        return AppRecord(
            path: url.path,
            resolvedPath: resolvedPath,
            bundleID: info["CFBundleIdentifier"] as? String,
            name: name,
            version: info["CFBundleShortVersionString"] as? String,
            urlSchemes: schemes.sorted(),
            contentTypes: types.sorted())
    }

    /// The string without surrounding whitespace and invisible formatting characters. Some system apps ship a
    /// display name that is only a left-to-right mark (U+200E).
    static func visibleText(_ string: String) -> String {
        let invisible = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{2060}\u{FEFF}"))
        return string.trimmingCharacters(in: invisible)
    }

    /// realpath(3), because `resolvingSymlinksInPath()` rewrites "/private/var/…" back to "/var/…".
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
