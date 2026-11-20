import Foundation
import Observation

/// Holds the latest on-disk job scan and runs refreshes.
///
/// A failed or partial refresh never wipes the last good results: issues are shown next to whatever was found.
@MainActor
@Observable
final class DiskInventoryStore {
    static let defaultRefreshInterval: Duration = .seconds(5 * 60)

    private(set) var scan: DiskScan?
    private(set) var isRefreshing = false

    private let discovery: PlistDiscovery
    private var timerTask: Task<Void, Never>?

    init(discovery: PlistDiscovery = .standard(), refreshInterval: Duration? = defaultRefreshInterval) {
        self.discovery = discovery
        if let refreshInterval {
            startTimer(every: refreshInterval)
        }
    }

    /// Runs a scan off the main thread. A call made while a scan is already running is ignored rather than
    /// queued, so refreshes never overlap.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let discovery = discovery
        scan = await Task.detached(priority: .utility) { discovery.scan() }.value
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
