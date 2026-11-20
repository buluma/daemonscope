import Foundation
import Testing
@testable import Daemonscope

@MainActor
struct DiskInventoryStoreTests {
    @Test func refreshPublishesScan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemonscope-store-\(UUID().uuidString)", isDirectory: true)
        let agents = root.appendingPathComponent("Agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try PropertyListSerialization.data(fromPropertyList: ["Label": "com.example.a"], format: .xml, options: 0)
        try data.write(to: agents.appendingPathComponent("a.plist"))

        let store = DiskInventoryStore(
            discovery: PlistDiscovery(jobDirectories: [.init(url: agents, location: .userAgents)], appSearchRoots: []),
            refreshInterval: nil)
        #expect(store.scan == nil)

        await store.refresh()

        #expect(store.scan?.jobs.map(\.label) == ["com.example.a"])
        #expect(store.isRefreshing == false)
    }
}
