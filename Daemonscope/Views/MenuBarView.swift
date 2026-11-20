import AppKit
import SwiftUI

struct MenuBarView: View {
    let store: DiskInventoryStore

    private static let rowLimit = 8

    @Environment(\.openWindow) private var openWindow
    @State private var query = ""

    private var thirdPartyJobs: [DiskJob] {
        store.scan?.jobs.filter { !$0.isApple } ?? []
    }

    private var matches: [DiskJob] {
        let jobs = thirdPartyJobs
        guard !query.isEmpty else { return jobs }
        return jobs.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary

            TextField("Filter jobs", text: $query)
                .textFieldStyle(.roundedBorder)

            // A plain stack, not a ScrollView: the menu bar window may size content to its minimum height, and a
            // ScrollView's minimum is zero, which hid the list entirely. The row cap keeps the window short instead.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(matches.prefix(Self.rowLimit)) { job in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(job.label ?? job.fileName).lineLimit(1)
                        Text(job.location.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if matches.count > Self.rowLimit {
                    Text("\(matches.count - Self.rowLimit) more in the main window")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack {
                Button("Open Daemonscope") { showMainWindow(openWindow) }
                Spacer()
                Button("Refresh") { Task { await store.refresh() } }
                    .disabled(store.isRefreshing)
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    @ViewBuilder private var summary: some View {
        if let scan = store.scan {
            VStack(alignment: .leading, spacing: 2) {
                // Disk evidence only: these counts say nothing about what launchd has loaded or is running.
                Text("\(thirdPartyJobs.count) third-party job plists found on disk")
                    .font(.headline)
                Text("Loaded and running state isn't collected yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text("Scanned \(scan.date, style: .time)")
                    if !scan.issues.isEmpty {
                        Text("· \(scan.issues.count) issues").foregroundStyle(.orange)
                    }
                    if store.isRefreshing {
                        ProgressView().controlSize(.mini)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text("Scanning…")
            }
        }
    }
}

extension DiskJob {
    var fileName: String { (path as NSString).lastPathComponent }

    /// Search by label, program, or path. Environment variables are deliberately not searched.
    func matches(_ query: String) -> Bool {
        [label, executablePath, path].contains { $0?.localizedCaseInsensitiveContains(query) ?? false }
    }
}
