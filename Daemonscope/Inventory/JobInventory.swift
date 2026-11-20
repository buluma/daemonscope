import Foundation

/// What the evidence supports about a job. `unknown` is used whenever launchd couldn't be asked, so a job is
/// never reported as "not loaded" without having checked.
enum JobState: String, CaseIterable, Sendable {
    case running
    case loadedNotRunning
    case disabled
    case foundOnDisk
    case unknown

    var displayName: String {
        switch self {
        case .running: "Running"
        case .loadedNotRunning: "Loaded, not running"
        case .disabled: "Disabled"
        case .foundOnDisk: "Found on disk"
        case .unknown: "Unknown"
        }
    }
}

/// One row of the inventory: a plist on disk, a job launchd has loaded, or both when the evidence links them.
struct InventoryEntry: Identifiable, Sendable, Hashable {
    let disk: DiskJob?
    let loaded: LoadedJob?
    /// launchd's override for this label in the relevant domain, if it has one.
    let disabledOverride: Bool?
    let state: JobState

    var id: String {
        if let loaded { "\(loaded.domain)/\(loaded.label)" } else { disk?.path ?? "" }
    }

    var label: String? { loaded?.label ?? disk?.label }

    /// Per-launch app jobs runningboardd creates for every running app (`application.<bundle id>.<ids>`). They
    /// track open apps, not daemons or agents anyone installed.
    var isAppInstance: Bool {
        loaded?.submittedBy?.hasPrefix("(submitted by runningboardd") ?? false
    }

    var isApple: Bool {
        if disk?.isApple == true { return true }
        guard let loaded else { return false }
        return loaded.label.hasPrefix("com.apple.") || (loaded.path?.hasPrefix("/System/Library/") ?? false)
    }
}

enum JobInventory {
    /// Joins disk and launchd evidence. `loaded == nil` means launchd couldn't be queried.
    ///
    /// A loaded job is linked to a plist only when launchd reports that plist's path or its symlink target, or,
    /// for jobs submitted through Service Management (no path), when exactly one app-bundled plist has the
    /// same label.
    static func merge(disk: [DiskJob], loaded: LoadedSnapshot?, uid: uid_t) -> [InventoryEntry] {
        guard let loaded else {
            return disk.map { InventoryEntry(disk: $0, loaded: nil, disabledOverride: nil, state: .unknown) }
        }

        let pathKeys = disk.map { ($0.path, $0) } + disk.compactMap { job in job.symlinkTarget.map { ($0, job) } }
        let byPath = Dictionary(pathKeys, uniquingKeysWith: { first, _ in first })
        let appBundledByLabel = Dictionary(grouping: disk.filter { $0.owningApp != nil && $0.label != nil }, by: { $0.label! })
        var matchedPaths: Set<String> = []
        var entries: [InventoryEntry] = []

        for job in loaded.jobs {
            var match: DiskJob?
            if let path = job.path {
                match = byPath[path]
            } else if let candidates = appBundledByLabel[job.label], candidates.count == 1 {
                match = candidates[0]
            }
            if let match { matchedPaths.insert(match.path) }
            entries.append(InventoryEntry(
                disk: match, loaded: job,
                disabledOverride: loaded.disabled[job.domain]?[job.label],
                state: job.isRunning ? .running : .loadedNotRunning))
        }

        for job in disk where !matchedPaths.contains(job.path) {
            let override = job.label.flatMap { label in
                expectedDomains(for: job.location, uid: uid).lazy.compactMap { loaded.disabled[$0]?[label] }.first
            }
            // launchd's override database wins over the plist's own Disabled key.
            let isDisabled = override ?? job.disabledInPlist ?? false
            entries.append(InventoryEntry(
                disk: job, loaded: nil, disabledOverride: override, state: isDisabled ? .disabled : .foundOnDisk))
        }

        return entries
    }

    /// Where launchd would load a plist from this location, most specific first.
    static func expectedDomains(for location: JobLocation, uid: uid_t) -> [String] {
        switch location {
        case .globalDaemons, .systemDaemons, .appDaemons: ["system"]
        case .userAgents, .globalAgents, .systemAgents, .appAgents: ["gui/\(uid)", "user/\(uid)"]
        }
    }
}

extension JobInventory {
    /// How many entries are in each state. Unknown entries are counted under `.unknown` only, never folded
    /// into a definite state.
    static func counts(_ entries: [InventoryEntry]) -> [JobState: Int] {
        entries.reduce(into: [:]) { $0[$1.state, default: 0] += 1 }
    }
}
