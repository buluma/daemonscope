import SwiftUI
import UniformTypeIdentifiers

/// What's selected in the Launch Services section.
enum LaunchServicesSelection: Hashable {
    case app(AppRecord.ID)
    case association(Association.ID)
}

struct LaunchServicesView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case apps = "Apps"
        case schemes = "URL Schemes"
        case types = "File Types"
        var id: Self { self }
    }

    let store: LaunchServicesStore
    @Binding var selection: LaunchServicesSelection?

    @State private var mode = Mode.apps
    @State private var query = ""

    var body: some View {
        Group {
            switch mode {
            case .apps: appsTable
            case .schemes: associationsTable(kind: .urlScheme)
            case .types: associationsTable(kind: .contentType)
            }
        }
        // Same reasoning as the launchd table: the window toolbar only splits at the sidebar.
        .safeAreaInset(edge: .top, spacing: 0) { filterBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        .task {
            if store.scan == nil { await store.refresh() }
        }
        .onChange(of: mode) { selection = nil }
    }

    // MARK: Tables

    private var apps: [AppRecord] {
        let all = store.scan?.apps ?? []
        guard !query.isEmpty else { return all }
        return all.filter { app in
            [app.name, app.bundleID, app.path].contains { $0?.localizedCaseInsensitiveContains(query) ?? false }
        }
    }

    private var appsTable: some View {
        Table(apps, selection: appSelection) {
            TableColumn("Name", value: \.name)
                .width(min: 140, ideal: 200)
            TableColumn("Bundle ID") { Text($0.bundleID ?? "—").foregroundStyle(.secondary) }
                .width(min: 120, ideal: 220)
            TableColumn("Schemes") { Text("\($0.urlSchemes.count)").monospacedDigit() }
                .width(min: 70, ideal: 80, max: 100)
            TableColumn("Types") { Text("\($0.contentTypes.count)").monospacedDigit() }
                .width(min: 50, ideal: 60, max: 90)
        }
    }

    private func associations(kind: Association.Kind) -> [Association] {
        let all = store.inventory.associations.filter { $0.kind == kind }
        guard !query.isEmpty else { return all }
        return all.filter { association in
            association.identifier.localizedCaseInsensitiveContains(query)
                || association.displayName.localizedCaseInsensitiveContains(query)
                || association.defaultHandler.map { store.appName(for: $0).localizedCaseInsensitiveContains(query) } == true
        }
    }

    private func associationsTable(kind: Association.Kind) -> some View {
        Table(associations(kind: kind), selection: associationSelection) {
            TableColumn(kind == .urlScheme ? "Scheme" : "Type") { association in
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind == .urlScheme ? "\(association.identifier):" : association.displayName)
                    if kind == .contentType {
                        Text(association.identifier).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 160, ideal: 260)
            TableColumn("Default") { association in
                if let handler = association.defaultHandler {
                    Text(store.appName(for: handler))
                } else {
                    Text("None").foregroundStyle(.secondary)
                }
            }
            .width(min: 100, ideal: 160)
            TableColumn("Handlers") { Text("\($0.handlers.count)").monospacedDigit() }
                .width(min: 60, ideal: 70, max: 90)
        }
    }

    private var appSelection: Binding<AppRecord.ID?> {
        Binding(
            get: { if case .app(let id) = selection { id } else { nil } },
            set: { selection = $0.map(LaunchServicesSelection.app) })
    }

    private var associationSelection: Binding<Association.ID?> {
        Binding(
            get: { if case .association(let id) = selection { id } else { nil } },
            set: { selection = $0.map(LaunchServicesSelection.association) })
    }

    // MARK: Bars

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(mode == .apps ? "Name, bundle ID, or path" : "Scheme, type, or app", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(in: .capsule)

            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
                Text("\(scan.apps.count) apps · \(store.inventory.associations.filter { $0.kind == .urlScheme }.count) schemes · \(store.inventory.associations.filter { $0.kind == .contentType }.count) types · scanned \(scan.date, style: .time)")
                if !scan.issues.isEmpty {
                    Text("· \(scan.issues.count) unreadable").foregroundStyle(.orange)
                        .help(scan.issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n"))
                }
            }
            if store.isRefreshing { ProgressView().controlSize(.small) }
            Spacer()
            Label("Partial", systemImage: "info.circle")
                .help(coverageNote)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var coverageNote: String {
        let roots = store.scan?.roots.map(\.path).joined(separator: ", ") ?? ""
        return "Not the full Launch Services database. Schemes and types are those declared by apps in: \(roots). "
            + "Defaults and handlers come from Launch Services, so they include apps outside those folders, but a "
            + "scheme or type claimed only by such apps isn't listed."
    }
}

// MARK: - Detail

struct LaunchServicesDetailView: View {
    let store: LaunchServicesStore
    let selection: LaunchServicesSelection?

    var body: some View {
        switch selection {
        case .app(let id):
            if let app = store.scan?.apps.first(where: { $0.id == id }) {
                AppDetailView(store: store, app: app)
            } else {
                ContentUnavailableView("No Selection", systemImage: "sidebar.right")
            }
        case .association(let id):
            if let association = store.inventory.associations.first(where: { $0.id == id }) {
                AssociationDetailView(store: store, association: association)
            } else {
                ContentUnavailableView("No Selection", systemImage: "sidebar.right")
            }
        case nil:
            ContentUnavailableView("No Selection", systemImage: "sidebar.right")
        }
    }
}

private struct AppDetailView: View {
    let store: LaunchServicesStore
    let app: AppRecord

    var body: some View {
        let declarations = store.inventory.declarations(of: app)
        Form {
            Section {
                LabeledContent("Name", value: app.name)
                LabeledContent("Bundle ID") { Text(app.bundleID ?? "—").textSelection(.enabled) }
                if let version = app.version { LabeledContent("Version", value: version) }
                LabeledContent("Path") { Text(app.path).textSelection(.enabled) }
                if app.resolvedPath != app.path {
                    LabeledContent("Resolves To") { Text(app.resolvedPath).textSelection(.enabled) }
                }
            }
            declarationSection("URL Schemes", declarations.filter { $0.association.kind == .urlScheme })
            declarationSection("File Types", declarations.filter { $0.association.kind == .contentType })
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func declarationSection(_ title: String, _ declarations: [AppDeclaration]) -> some View {
        if !declarations.isEmpty {
            Section(title) {
                ForEach(declarations, id: \.association.id) { declaration in
                    LabeledContent {
                        if declaration.isDefault {
                            Label("Default", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if declaration.isRegistered {
                            Text("Handler").foregroundStyle(.secondary)
                        } else {
                            Text("Declared, not registered")
                                .foregroundStyle(.orange)
                                .help("This app declares it, but Launch Services doesn't list the app as a handler.")
                        }
                    } label: {
                        Text(declaration.association.kind == .urlScheme
                             ? "\(declaration.association.identifier):" : declaration.association.displayName)
                    }
                }
            }
        }
    }
}

private struct AssociationDetailView: View {
    let store: LaunchServicesStore
    let association: Association

    var body: some View {
        Form {
            Section {
                LabeledContent(association.kind == .urlScheme ? "Scheme" : "Type") {
                    Text(association.kind == .urlScheme ? "\(association.identifier):" : association.displayName)
                }
                if association.kind == .contentType {
                    LabeledContent("Identifier") { Text(association.identifier).textSelection(.enabled) }
                }
                LabeledContent("Default") {
                    Text(association.defaultHandler.map(store.appName(for:)) ?? "None")
                }
            }
            Section("Handlers (from Launch Services)") {
                if association.handlers.isEmpty {
                    Text("Launch Services lists no handlers.").foregroundStyle(.secondary)
                }
                ForEach(association.handlers, id: \.self) { path in
                    LabeledContent {
                        HStack(spacing: 6) {
                            if path == association.defaultHandler { Text("Default").foregroundStyle(.green) }
                            if association.handlersOutsideScan.contains(path) {
                                Text("Outside scanned folders").foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(store.appName(for: path))
                            Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            if !association.declaredButNotRegistered.isEmpty {
                Section("Declared but Not Registered") {
                    ForEach(association.declaredButNotRegistered, id: \.self) { path in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(store.appName(for: path))
                            Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Text("These scanned apps declare it, but Launch Services doesn't list them: often a duplicate copy of an app, or an app that ranks itself out of handling it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension Association {
    /// A readable name: the scheme, or the type's description (".ext" for dynamic types).
    var displayName: String {
        guard kind == .contentType else { return identifier }
        guard let type = UTType(identifier) else { return identifier }
        if type.isDynamic, let ext = type.preferredFilenameExtension { return ".\(ext)" }
        return type.localizedDescription ?? identifier
    }
}
