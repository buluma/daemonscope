import Foundation
import Observation

/// Holds the latest app scan and association inventory.
///
/// Refreshed on demand (when the Launch Services section is first shown, and from its Refresh button) rather
/// than on the launchd timer: app registrations change rarely, and a scan reads every installed app's Info.plist.
@MainActor
@Observable
final class LaunchServicesStore {
    private(set) var scan: AppBundleScan?
    private(set) var inventory = AssociationInventory(associations: [])
    private(set) var isRefreshing = false

    private let scanner: AppBundleScanner
    private let lookup: HandlerLookup

    init(scanner: AppBundleScanner = .standard(), lookup: HandlerLookup = WorkspaceHandlerLookup()) {
        self.scanner = scanner
        self.lookup = lookup
    }

    /// Scans off the main thread. A call made while one is running is ignored, so refreshes never overlap.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let scanner = scanner
        let lookup = lookup
        let (newScan, newInventory) = await Task.detached(priority: .utility) {
            let scan = scanner.scan()
            return (scan, AssociationInventory.build(apps: scan.apps, lookup: lookup))
        }.value
        scan = newScan
        inventory = newInventory
    }

    /// Display name for a handler path: the scanned app's name, or the bundle's folder name.
    func appName(for path: String) -> String {
        scan?.apps.first { $0.resolvedPath == path }?.name
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
}
