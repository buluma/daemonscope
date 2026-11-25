import AppKit
import SwiftUI
import Testing
@testable import Daemonscope

@MainActor
struct MenuBarViewTests {
    /// The menu bar window can size its content to the minimum height. A ScrollView's minimum height is zero,
    /// which collapsed the job list to nothing in the menu bar while the summary still showed a job count.
    @Test func jobListKeepsItsHeightUnderMinimumProposal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemonscope-menubar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func height(jobCount: Int, partial: Bool = false) async throws -> CGFloat {
            let folder = root.appendingPathComponent("jobs-\(jobCount)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<jobCount {
                let data = try PropertyListSerialization.data(
                    fromPropertyList: ["Label": "com.example.job\(index)"], format: .xml, options: 0)
                try data.write(to: folder.appendingPathComponent("job\(index).plist"))
            }
            let store = InventoryStore(
                discovery: PlistDiscovery(jobDirectories: [.init(url: folder, location: .userAgents)], appSearchRoots: []),
                collector: LaunchctlCollector { LoadedSnapshot(jobs: [], disabled: [:],
                    queriedDomains: partial ? ["system"] : nil, issues: partial ? ["Couldn't list gui/501: unavailable"] : []) },
                refreshInterval: nil)
            await store.refresh()
            return NSHostingController(rootView: MenuBarView(store: store))
                .sizeThatFits(in: CGSize(width: 320, height: 0)).height
        }

        let empty = try await height(jobCount: 0)
        let populated = try await height(jobCount: 5)

        let partial = try await height(jobCount: 5, partial: true)
        #expect(partial > populated)

        // Five rows of a label plus a caption need well over 100 points.
        #expect(populated - empty > 100)
    }
}
