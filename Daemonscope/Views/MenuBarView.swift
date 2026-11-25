import AppKit
import SwiftUI

struct MenuBarView: View {
    let store: InventoryStore

    private static let rowLimit = 8

    @Environment(\.openWindow) private var openWindow
    @State private var query = ""

    private var thirdPartyEntries: [InventoryEntry] {
        store.entries.filter { !$0.isApple && !$0.isAppInstance }
    }

    /// Running jobs first, then the rest by state and label, so the short list shows the most active jobs.
    private var matches: [InventoryEntry] {
        let entries = query.isEmpty ? thirdPartyEntries : thirdPartyEntries.filter { $0.matches(query) }
        return entries.sorted { ($0.state.sortRank, $0.sortLabel) < ($1.state.sortRank, $1.sortLabel) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary

            TextField("Filter jobs", text: $query)
                .textFieldStyle(.roundedBorder)

            // A plain stack, not a ScrollView: the menu bar window may size content to its minimum height, and a
            // ScrollView's minimum is zero, which hid the list entirely. The row cap keeps the window short instead.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(matches.prefix(Self.rowLimit)) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: entry.state.symbol)
                            .foregroundStyle(entry.state.tint)
                            .imageScale(.small)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.label ?? entry.disk?.fileName ?? "—").lineLimit(1)
                            Text(entry.state.displayName + " · " + (entry.loaded?.domain ?? entry.disk?.location.displayName ?? ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
            let counts = JobInventory.counts(thirdPartyEntries)
            VStack(alignment: .leading, spacing: 4) {
                Text("Third-party jobs").font(.headline)
                if store.loadedDate == nil {
                    // Without a launchd query nothing can be called running or not loaded.
                    Text("\(counts[.unknown, default: 0]) jobs, state unknown")
                    Text("launchd couldn't be queried.").font(.caption).foregroundStyle(.orange)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                        GridRow {
                            CountLabel(state: .running, count: counts[.running, default: 0])
                            CountLabel(state: .loadedNotRunning, count: counts[.loadedNotRunning, default: 0])
                        }
                        GridRow {
                            CountLabel(state: .disabled, count: counts[.disabled, default: 0])
                            CountLabel(state: .foundOnDisk, count: counts[.foundOnDisk, default: 0])
                        }
                    }
                    .font(.callout)
                    if let unknown = counts[.unknown], unknown > 0 {
                        CountLabel(state: .unknown, count: unknown)
                    }
                    if let warning = store.loadedIssues.first {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help(store.loadedIssues.joined(separator: "\n"))
                    }
                }
                HStack(spacing: 4) {
                    if let loadedDate = store.loadedDate {
                        Text("launchd \(loadedDate, style: .time)")
                    } else {
                        Text("Scanned \(scan.date, style: .time)")
                    }
                    if store.loadedDate != nil, store.loadedError != nil {
                        Text("· refresh failed").foregroundStyle(.orange).help(store.loadedError ?? "")
                    }
                    if !scan.issues.isEmpty {
                        Text("· \(scan.issues.count) plist issues").foregroundStyle(.orange)
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

private struct CountLabel: View {
    let state: JobState
    let count: Int

    var body: some View {
        Label {
            Text("\(count) \(state.displayName.lowercased())")
        } icon: {
            Image(systemName: state.symbol).foregroundStyle(state.tint)
        }
    }
}

extension DiskJob {
    var fileName: String { (path as NSString).lastPathComponent }
}
