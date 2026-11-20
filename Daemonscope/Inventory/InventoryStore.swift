import Foundation
import Observation

/// Holds the latest inventory and runs refreshes.
///
/// A failed or partial refresh never wipes the last good results: if launchd can't be queried, the previous
/// launchd snapshot is kept (with its own timestamp) and the error is shown next to it.
@MainActor
@Observable
final class InventoryStore {
    static let defaultRefreshInterval: Duration = .seconds(5 * 60)

    private(set) var scan: DiskScan?
    private(set) var entries: [InventoryEntry] = []
    /// When launchd was last queried successfully.
    private(set) var loadedDate: Date?
    /// Why the most recent launchd query failed; `nil` after a success.
    private(set) var loadedError: String?
    private(set) var isRefreshing = false

    /// Partial problems in the launchd snapshot in use: a domain that couldn't be listed, missing details, or
    /// conflicting (forged) dump entries.
    var loadedIssues: [String] { loaded?.issues ?? [] }

    private var loaded: LoadedSnapshot?
    private let discovery: PlistDiscovery
    private let collector: LaunchctlCollector
    private let uid: uid_t
    private var timerTask: Task<Void, Never>?

    init(
        discovery: PlistDiscovery = .standard(),
        collector: LaunchctlCollector = .live,
        uid: uid_t = getuid(),
        refreshInterval: Duration? = defaultRefreshInterval
    ) {
        self.discovery = discovery
        self.collector = collector
        self.uid = uid
        if let refreshInterval {
            startTimer(every: refreshInterval)
        }
    }

    /// Runs a refresh off the main thread. A call made while one is already running is ignored rather than
    /// queued, so refreshes never overlap.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let discovery = discovery
        let collector = collector
        async let diskScan = Task.detached(priority: .utility) { discovery.scan() }.value
        async let collection = Task.detached(priority: .utility) {
            Result { try collector.collect() }
        }.value

        let (newScan, result) = await (diskScan, collection)
        switch result {
        case .success(let snapshot):
            loaded = snapshot
            loadedDate = Date()
            loadedError = nil
        case .failure(let error):
            loadedError = error.localizedDescription
        }
        scan = newScan
        entries = JobInventory.merge(disk: newScan.jobs, loaded: loaded, uid: uid)
    }

    private func startTimer(every interval: Duration) {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }
}
