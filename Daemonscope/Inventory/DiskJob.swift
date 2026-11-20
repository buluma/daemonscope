import Foundation

/// Where a job plist was found. The location says which launchd domain is *expected* to load the job; it is
/// evidence from disk only and says nothing about whether launchd actually loaded it.
enum JobLocation: String, CaseIterable, Sendable, Hashable {
    case userAgents
    case globalAgents
    case globalDaemons
    case systemAgents
    case systemDaemons
    case appAgents
    case appDaemons

    var displayName: String {
        switch self {
        case .userAgents: "User Agents"
        case .globalAgents: "Global Agents"
        case .globalDaemons: "Global Daemons"
        case .systemAgents: "System Agents"
        case .systemDaemons: "System Daemons"
        case .appAgents: "App-Bundled Agents"
        case .appDaemons: "App-Bundled Daemons"
        }
    }
}

/// A launchd job property list as read from disk.
///
/// `environmentVariables` can hold secrets. It is kept so the UI can show it on request, and it must never be
/// logged; `description` deliberately leaves it out.
struct DiskJob: Identifiable, Sendable, Hashable, CustomStringConvertible {
    enum KeepAlive: Sendable, Hashable {
        case always(Bool)
        /// The plist uses the dictionary form; holds its condition keys, sorted.
        case conditional([String])
    }

    enum ParseError: Error, Equatable {
        case unreadable(String)
        case notADictionary
    }

    var id: String { path }

    let path: String
    /// Where `path` points when it's a symlink. launchd reports the resolved file, so matching needs both.
    var symlinkTarget: String?
    let location: JobLocation
    /// The `.app` bundle that contains the plist, for app-bundled jobs.
    let owningApp: String?
    /// `nil` when the plist has no usable `Label`; launchd won't load such a job, but the file still exists.
    let label: String?
    let program: String?
    /// Executable path relative to `owningApp`; used by app-bundled jobs registered through Service Management.
    let bundleProgram: String?
    let programArguments: [String]
    let runAtLoad: Bool?
    /// The plist's own `Disabled` key. launchd's override database (`launchctl print-disabled`) takes precedence.
    let disabledInPlist: Bool?
    let keepAlive: KeepAlive?
    let startInterval: Int?
    let environmentVariables: [String: String]

    /// The executable launchd would run, by launchd's precedence: `Program`, then `BundleProgram` resolved
    /// against the owning app, then the first `ProgramArguments` entry.
    var executablePath: String? {
        if let program { return program }
        if let bundleProgram {
            guard let owningApp else { return nil }
            return URL(fileURLWithPath: owningApp).appendingPathComponent(bundleProgram).path
        }
        return programArguments.first
    }

    /// Apple's own jobs, hidden by default in the UI. Decided by location only: System Integrity Protection
    /// guards these folders, while anyone with admin rights can give a job a `com.apple.*` label to hide it.
    var isApple: Bool {
        Self.isSIPProtected(path)
    }

    /// Only canonical absolute paths count: `/System/Library/../../tmp/x` starts with the right prefix but
    /// points elsewhere.
    static func isSIPProtected(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.hasPrefix("/"), !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return false
        }
        return path.hasPrefix("/System/Library/") || path.hasPrefix("/Library/Apple/")
    }

    var description: String {
        "DiskJob(label: \(label ?? "<none>"), path: \(path), location: \(location.rawValue))"
    }

    static func parse(data: Data, path: String, location: JobLocation, owningApp: String? = nil) throws -> DiskJob {
        let root: Any
        do {
            root = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw ParseError.unreadable(error.localizedDescription)
        }
        guard let plist = root as? [String: Any] else { throw ParseError.notADictionary }

        let keepAlive: KeepAlive? =
            if let flag = plist["KeepAlive"] as? Bool {
                .always(flag)
            } else if let conditions = plist["KeepAlive"] as? [String: Any] {
                .conditional(conditions.keys.sorted())
            } else {
                nil
            }

        let label = (plist["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        return DiskJob(
            path: path,
            symlinkTarget: nil,
            location: location,
            owningApp: owningApp,
            label: label,
            program: plist["Program"] as? String,
            bundleProgram: plist["BundleProgram"] as? String,
            programArguments: plist["ProgramArguments"] as? [String] ?? [],
            runAtLoad: plist["RunAtLoad"] as? Bool,
            disabledInPlist: plist["Disabled"] as? Bool,
            keepAlive: keepAlive,
            startInterval: plist["StartInterval"] as? Int,
            environmentVariables: plist["EnvironmentVariables"] as? [String: String] ?? [:])
    }
}
