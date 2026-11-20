import SwiftUI

struct MainWindowView: View {
    enum Section: String, CaseIterable, Identifiable {
        case launchd = "Launchd"
        case launchServices = "Launch Services"
        var id: Self { self }
    }

    let store: DiskInventoryStore

    @State private var section: Section? = .launchd
    @State private var filter = JobFilter()
    @State private var selection: DiskJob.ID?

    var body: some View {
        // Three real columns rather than a table and detail sharing one HSplitView, so the table and the detail
        // pane each get their own resizable column, with the divider and its separator lined up top to bottom.
        NavigationSplitView {
            List(Section.allCases, selection: $section) { section in
                Label(section.rawValue, systemImage: section == .launchd ? "gearshape.2" : "app.badge")
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } content: {
            switch section {
            case .launchd, nil:
                JobTableView(store: store, filter: $filter, selection: $selection)
                    .navigationSplitViewColumnWidth(min: 460, ideal: 640)
            case .launchServices:
                ContentUnavailableView(
                    "Not Built Yet", systemImage: "hammer",
                    description: Text("Launch Services inventory comes in a later slice."))
                    .navigationSplitViewColumnWidth(min: 460, ideal: 640)
            }
        } detail: {
            if section != .launchServices, let job = store.scan?.jobs.first(where: { $0.id == selection }) {
                JobDetailView(job: job, scanDate: store.scan?.date)
            } else {
                ContentUnavailableView("No Job Selected", systemImage: "sidebar.right")
            }
        }
        .navigationTitle("Daemonscope")
        .frame(minWidth: 980, minHeight: 480)
    }
}

struct JobFilter {
    var query = ""
    var showApple = false
    var location: JobLocation?

    func apply(to jobs: [DiskJob]) -> [DiskJob] {
        jobs.filter { job in
            (showApple || !job.isApple)
                && (location == nil || job.location == location)
                && (query.isEmpty || job.matches(query))
        }
    }
}

private struct JobTableView: View {
    let store: DiskInventoryStore
    @Binding var filter: JobFilter
    @Binding var selection: DiskJob.ID?

    private var jobs: [DiskJob] { filter.apply(to: store.scan?.jobs ?? []) }

    var body: some View {
        Table(jobs, selection: $selection) {
            TableColumn("Label") { Text($0.label ?? "— no label —") }
            TableColumn("Location") { Text($0.location.displayName) }
                .width(ideal: 140)
            TableColumn("Path") { Text($0.path).foregroundStyle(.secondary) }
        }
        // Filters live in a bar inside this column, not the window toolbar: on macOS the toolbar only splits at
        // the sidebar, so toolbar items here would drift to the far trailing edge, over the detail pane.
        .safeAreaInset(edge: .top, spacing: 0) { filterBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Label, program, or path", text: $filter.query)
                    .textFieldStyle(.plain)
                if !filter.query.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") { filter.query = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(in: .capsule)

            Picker("Location", selection: $filter.location) {
                Text("All Locations").tag(JobLocation?.none)
                ForEach(JobLocation.allCases, id: \.self) { Text($0.displayName).tag(JobLocation?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()

            Toggle("Show Apple Jobs", isOn: $filter.showApple)
                .toggleStyle(.button)
                .fixedSize()

            Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                .labelStyle(.iconOnly)
                .disabled(store.isRefreshing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let scan = store.scan {
                Text("\(jobs.count) of \(scan.jobs.count) plists · scanned \(scan.date, style: .time)")
                if !scan.issues.isEmpty {
                    IssuesButton(issues: scan.issues)
                }
            }
            if store.isRefreshing { ProgressView().controlSize(.small) }
            Spacer()
            Text("On-disk evidence only")
                .help("Loaded and running state isn't collected yet.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct IssuesButton: View {
    let issues: [ScanIssue]
    @State private var isPresented = false

    var body: some View {
        Button("\(issues.count) issues") { isPresented = true }
            .buttonStyle(.link)
            .popover(isPresented: $isPresented) {
                List(issues) { issue in
                    VStack(alignment: .leading) {
                        Text(issue.path).font(.caption.monospaced())
                        Text(issue.message)
                    }
                }
                .frame(width: 520, height: 300)
            }
    }
}

private struct JobDetailView: View {
    let job: DiskJob
    let scanDate: Date?

    @State private var revealEnvironment = false

    var body: some View {
        Form {
            LabeledContent("Label", value: job.label ?? "— none —")
            LabeledContent("State", value: "Found on disk")
            LabeledContent("Location", value: job.location.displayName)
            LabeledContent("Path") { Text(job.path).textSelection(.enabled) }
            if let app = job.owningApp {
                LabeledContent("Owning App") { Text(app).textSelection(.enabled) }
            }
            if let executable = job.executablePath {
                LabeledContent("Executable") { Text(executable).textSelection(.enabled) }
            }
            if let bundleProgram = job.bundleProgram {
                LabeledContent("BundleProgram") { Text(bundleProgram).textSelection(.enabled) }
            }
            if !job.programArguments.isEmpty {
                LabeledContent("Arguments") {
                    Text(job.programArguments.joined(separator: " ")).textSelection(.enabled)
                }
            }
            if let runAtLoad = job.runAtLoad {
                LabeledContent("RunAtLoad", value: runAtLoad ? "Yes" : "No")
            }
            if let keepAlive = job.keepAlive {
                LabeledContent("KeepAlive", value: keepAlive.summary)
            }
            if let interval = job.startInterval {
                LabeledContent("StartInterval", value: "\(interval) s")
            }
            if let disabled = job.disabledInPlist {
                LabeledContent("Disabled (plist key)", value: disabled ? "Yes" : "No")
            }
            if !job.environmentVariables.isEmpty {
                environmentSection
            }
            if let scanDate {
                LabeledContent("Last Scan") { Text(scanDate, style: .time) }
            }
            Text("Shows the plist only. launchd may override `Disabled`, and the loaded or running state isn't collected yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        // A different job shouldn't inherit the revealed state of the previous one.
        .onChange(of: job.id) { revealEnvironment = false }
    }

    /// Values can be secrets, so they stay hidden until asked for.
    @ViewBuilder private var environmentSection: some View {
        LabeledContent("Environment") {
            if revealEnvironment {
                VStack(alignment: .trailing) {
                    ForEach(job.environmentVariables.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        Text("\(key)=\(value)").font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            } else {
                Button("Show \(job.environmentVariables.count) variables") { revealEnvironment = true }
            }
        }
    }
}

private extension DiskJob.KeepAlive {
    var summary: String {
        switch self {
        case .always(let flag): flag ? "Yes" : "No"
        case .conditional(let keys): "When: " + keys.joined(separator: ", ")
        }
    }
}
