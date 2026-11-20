import SwiftUI

struct MainWindowView: View {
    enum Section: String, CaseIterable, Identifiable {
        case launchd = "Launchd"
        case launchServices = "Launch Services"
        var id: Self { self }
    }

    let store: InventoryStore

    @State private var section: Section? = .launchd
    @State private var filter = JobFilter()
    @State private var selection: InventoryEntry.ID?

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
                    .navigationSplitViewColumnWidth(min: 560, ideal: 720)
            case .launchServices:
                ContentUnavailableView(
                    "Not Built Yet", systemImage: "hammer",
                    description: Text("Launch Services inventory comes in a later slice."))
                    .navigationSplitViewColumnWidth(min: 560, ideal: 720)
            }
        } detail: {
            if section != .launchServices, let entry = store.entries.first(where: { $0.id == selection }) {
                JobDetailView(entry: entry, scanDate: store.scan?.date, loadedDate: store.loadedDate)
            } else {
                ContentUnavailableView("No Job Selected", systemImage: "sidebar.right")
            }
        }
        .navigationTitle("Daemonscope")
        .frame(minWidth: 1080, minHeight: 480)
    }
}

struct JobFilter {
    /// Which launchd domain a job is in, or that it isn't loaded anywhere.
    enum Domain: Hashable {
        case system, user, gui, notLoaded

        var displayName: String {
            switch self {
            case .system: "system"
            case .user: "user"
            case .gui: "gui (login session)"
            case .notLoaded: "Not loaded"
            }
        }

        static func of(_ entry: InventoryEntry) -> Domain {
            guard let domain = entry.loaded?.domain else { return .notLoaded }
            if domain == "system" { return .system }
            return domain.hasPrefix("gui/") ? .gui : .user
        }
    }

    var query = ""
    var showApple = false
    var showAppInstances = false
    var state: JobState?
    var domain: Domain?
    var location: JobLocation?

    var isNarrowed: Bool { state != nil || domain != nil || location != nil }

    func apply(to entries: [InventoryEntry]) -> [InventoryEntry] {
        entries.filter { entry in
            (showApple || !entry.isApple)
                && (showAppInstances || !entry.isAppInstance)
                && (state == nil || entry.state == state)
                && (domain == nil || Domain.of(entry) == domain)
                && (location == nil || entry.disk?.location == location)
                && (query.isEmpty || entry.matches(query))
        }
    }
}

private struct JobTableView: View {
    let store: InventoryStore
    @Binding var filter: JobFilter
    @Binding var selection: InventoryEntry.ID?

    @State private var sortOrder = [KeyPathComparator(\InventoryEntry.sortLabel)]

    private var entries: [InventoryEntry] { filter.apply(to: store.entries).sorted(using: sortOrder) }

    var body: some View {
        Table(entries, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Label", value: \.sortLabel) { Text($0.label ?? "— no label —") }
                .width(min: 160, ideal: 280)
            TableColumn("State", value: \.state.sortRank) { StateBadge(state: $0.state) }
                .width(min: 120, ideal: 150, max: 170)
            TableColumn("Domain", value: \.domainText) { Text($0.domainText) }
                .width(min: 60, ideal: 80, max: 110)
            TableColumn("Source", value: \.sourceText) { Text($0.sourceText).foregroundStyle(.secondary) }
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

            Menu {
                Picker("State", selection: $filter.state) {
                    Text("Any State").tag(JobState?.none)
                    ForEach(JobState.allCases, id: \.self) { Text($0.displayName).tag(JobState?.some($0)) }
                }
                Picker("Domain", selection: $filter.domain) {
                    Text("Any Domain").tag(JobFilter.Domain?.none)
                    ForEach([JobFilter.Domain.system, .user, .gui, .notLoaded], id: \.self) {
                        Text($0.displayName).tag(JobFilter.Domain?.some($0))
                    }
                }
                Picker("Plist Location", selection: $filter.location) {
                    Text("Any Location").tag(JobLocation?.none)
                    ForEach(JobLocation.allCases, id: \.self) { Text($0.displayName).tag(JobLocation?.some($0)) }
                }
                Divider()
                Toggle("Show Running App Instances", isOn: $filter.showAppInstances)
                if filter.isNarrowed {
                    Divider()
                    Button("Clear Filters") {
                        filter.state = nil
                        filter.domain = nil
                        filter.location = nil
                    }
                }
            } label: {
                Label("Filter", systemImage: filter.isNarrowed
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
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
            Text("\(entries.count) of \(store.entries.count) jobs")
            if let scan = store.scan {
                Text("· disk \(scan.date, style: .time)")
                if !scan.issues.isEmpty {
                    IssuesButton(issues: scan.issues)
                }
            }
            if let loadedDate = store.loadedDate {
                Text("· launchd \(loadedDate, style: .time)")
            }
            if let error = store.loadedError {
                Label(store.loadedDate == nil ? "launchd unavailable" : "launchd refresh failed",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
            }
            if !store.loadedIssues.isEmpty {
                Label("\(store.loadedIssues.count) launchd warnings", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(store.loadedIssues.joined(separator: "\n"))
            }
            if store.isRefreshing { ProgressView().controlSize(.small) }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct StateBadge: View {
    let state: JobState

    var body: some View {
        Label(state.displayName, systemImage: state.symbol)
            .foregroundStyle(state.tint)
    }
}

extension JobState {
    var symbol: String {
        switch self {
        case .running: "circle.fill"
        case .loadedNotRunning: "circle"
        case .disabled: "slash.circle"
        case .foundOnDisk: "doc"
        case .unknown: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .running: .green
        case .loadedNotRunning: .primary
        case .disabled: .orange
        case .foundOnDisk, .unknown: .secondary
        }
    }

    var sortRank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

extension InventoryEntry {
    var sortLabel: String { label ?? "" }

    var domainText: String { loaded?.domain ?? "—" }

    /// Where the job comes from: the plist path, or launchd's submitter note when there's no file.
    var sourceText: String { disk?.path ?? loaded?.path ?? loaded?.submittedBy ?? "—" }

    /// Search by label, program, or path. Environment variables are deliberately not searched.
    func matches(_ query: String) -> Bool {
        [label, disk?.executablePath, disk?.path, loaded?.path, loaded?.program, loaded?.parentBundleID]
            .contains { $0?.localizedCaseInsensitiveContains(query) ?? false }
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
    let entry: InventoryEntry
    let scanDate: Date?
    let loadedDate: Date?

    @State private var revealEnvironment = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Label", value: entry.label ?? "— none —")
                LabeledContent("State") { StateBadge(state: entry.state) }
                Text(entry.state.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let loaded = entry.loaded {
                launchdSection(loaded)
            } else if let override = entry.disabledOverride {
                Section("launchd") {
                    LabeledContent("Override", value: override ? "Disabled" : "Enabled")
                }
            }
            if let job = entry.disk {
                plistSection(job)
            } else {
                Section("Plist") {
                    Text("No plist on disk is linked to this job. It may have been submitted by an app or system service, or its file may live somewhere Daemonscope doesn't scan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if let loadedDate {
                    LabeledContent("launchd Queried") { Text(loadedDate, style: .time) }
                }
                if let scanDate {
                    LabeledContent("Disk Scanned") { Text(scanDate, style: .time) }
                }
            }
        }
        .formStyle(.grouped)
        // A different job shouldn't inherit the revealed state of the previous one.
        .onChange(of: entry.id) { revealEnvironment = false }
    }

    private func launchdSection(_ loaded: LoadedJob) -> some View {
        Section("launchd") {
            if loaded.detailsTampered {
                Label("launchd's dump held conflicting entries for this job, so another job may be trying to impersonate it. Only the PID and loaded state, which come from the domain listing, are shown.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            LabeledContent("Domain", value: loaded.domain)
            if let state = loaded.state { LabeledContent("Reported State", value: state) }
            if let pid = loaded.pid { LabeledContent("PID", value: String(pid)) }
            if let lastExit = loaded.lastExit { LabeledContent("Last Exit", value: lastExit) }
            if let type = loaded.type { LabeledContent("Type", value: type) }
            if let path = loaded.path {
                LabeledContent("Loaded From") { Text(path).textSelection(.enabled) }
            } else if let submitter = loaded.submittedBy {
                LabeledContent("Loaded From", value: submitter)
            }
            if let bundle = loaded.parentBundleID {
                LabeledContent("Registered By") { Text(bundle).textSelection(.enabled) }
            }
            if let program = loaded.program {
                LabeledContent("Program") { Text(program).textSelection(.enabled) }
            }
            if let override = entry.disabledOverride {
                LabeledContent("Override", value: override ? "Disabled" : "Enabled")
            }
        }
    }

    private func plistSection(_ job: DiskJob) -> some View {
        Section("Plist") {
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
                environmentRow(job)
            }
        }
    }

    /// Values can be secrets, so they stay hidden until asked for.
    @ViewBuilder private func environmentRow(_ job: DiskJob) -> some View {
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

private extension JobState {
    var explanation: String {
        switch self {
        case .running: "launchd reports a running process."
        case .loadedNotRunning: "Loaded but idle. Many jobs start on demand, so this isn't necessarily a fault."
        case .disabled: "Not loaded, and disabled by launchd's override database or the plist's Disabled key."
        case .foundOnDisk: "The plist exists, but launchd doesn't report the job as loaded in the domain Daemonscope checked."
        case .unknown: "launchd couldn't be queried, so whether this job is loaded isn't known."
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
