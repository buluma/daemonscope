import AppKit
import UniformTypeIdentifiers

/// Answers which apps Launch Services lists for a URL scheme or content type. Paths are resolved app paths.
protocol HandlerLookup: Sendable {
    func handlers(forScheme scheme: String) -> [String]
    func defaultHandler(forScheme scheme: String) -> String?
    func handlers(forContentType type: String) -> [String]
    func defaultHandler(forContentType type: String) -> String?
}

/// The supported public API: NSWorkspace. It answers for one scheme or type at a time and can't list the whole
/// Launch Services database, which is why the scheme and type list comes from scanned apps' declarations.
struct WorkspaceHandlerLookup: HandlerLookup {
    func handlers(forScheme scheme: String) -> [String] {
        guard let url = Self.url(for: scheme) else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: url).map(Self.resolved)
    }

    func defaultHandler(forScheme scheme: String) -> String? {
        Self.url(for: scheme).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }.map(Self.resolved)
    }

    func handlers(forContentType type: String) -> [String] {
        guard let utType = UTType(type) else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: utType).map(Self.resolved)
    }

    func defaultHandler(forContentType type: String) -> String? {
        UTType(type).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }.map(Self.resolved)
    }

    private static func url(for scheme: String) -> URL? {
        URL(string: scheme + ":")
    }

    private static func resolved(_ url: URL) -> String {
        AppBundleScanner.realPath(url.path) ?? url.path
    }
}

/// One URL scheme or content type that at least one scanned app declares.
struct Association: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable, Hashable {
        case urlScheme
        case contentType
    }

    var id: String { "\(kind.rawValue):\(identifier)" }

    let kind: Kind
    /// A lowercased scheme (`mailto`) or uniform type identifier (`public.plain-text`).
    let identifier: String
    /// Resolved paths of scanned apps that declare it.
    let declaredBy: [String]
    /// What Launch Services opens it with, if anything.
    let defaultHandler: String?
    /// Every app Launch Services lists for it, scanned or not.
    let handlers: [String]
    /// Scanned apps that declare it but aren't listed as handlers: duplicate copies, apps that rank themselves
    /// out (LSHandlerRank None), or apps Launch Services hasn't registered.
    let declaredButNotRegistered: [String]
    /// Handlers outside the scanned folders, such as apps nested in other apps or in Downloads.
    let handlersOutsideScan: [String]
}

/// A declaration from one app's point of view.
struct AppDeclaration: Sendable, Hashable {
    let association: Association
    let isRegistered: Bool
    let isDefault: Bool
}

/// Schemes and types declared by scanned apps, with handlers as Launch Services reports them.
///
/// Not the whole Launch Services database: a scheme or type claimed only by apps outside the scanned folders
/// isn't listed, though such apps do appear as handlers of listed ones.
struct AssociationInventory: Sendable {
    let associations: [Association]
    private let byID: [String: Association]

    init(associations: [Association]) {
        self.associations = associations
        byID = Dictionary(associations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func build(apps: [AppRecord], lookup: HandlerLookup) -> AssociationInventory {
        let scanned = Set(apps.map(\.resolvedPath))
        var schemes: [String: [String]] = [:]
        var types: [String: [String]] = [:]
        for app in apps {
            for scheme in app.urlSchemes { schemes[scheme, default: []].append(app.resolvedPath) }
            for type in app.contentTypes { types[type, default: []].append(app.resolvedPath) }
        }

        func make(_ kind: Association.Kind, _ identifier: String, declaredBy: [String]) -> Association {
            let handlers = kind == .urlScheme
                ? lookup.handlers(forScheme: identifier) : lookup.handlers(forContentType: identifier)
            let defaultHandler = kind == .urlScheme
                ? lookup.defaultHandler(forScheme: identifier) : lookup.defaultHandler(forContentType: identifier)
            let handlerSet = Set(handlers)
            let declared = Array(Set(declaredBy)).sorted()
            return Association(
                kind: kind, identifier: identifier, declaredBy: declared, defaultHandler: defaultHandler,
                handlers: handlers,
                declaredButNotRegistered: declared.filter { !handlerSet.contains($0) },
                handlersOutsideScan: handlers.filter { !scanned.contains($0) })
        }

        let associations = schemes.keys.sorted().map { make(.urlScheme, $0, declaredBy: schemes[$0]!) }
            + types.keys.sorted().map { make(.contentType, $0, declaredBy: types[$0]!) }
        return AssociationInventory(associations: associations)
    }

    func association(_ kind: Association.Kind, _ identifier: String) -> Association? {
        byID["\(kind.rawValue):\(identifier)"]
    }

    /// The app's declarations, schemes then types, each sorted, with whether Launch Services lists the app for it.
    func declarations(of app: AppRecord) -> [AppDeclaration] {
        let schemes = app.urlSchemes.sorted().compactMap { association(.urlScheme, $0) }
        let types = app.contentTypes.sorted().compactMap { association(.contentType, $0) }
        return (schemes + types).map { association in
            AppDeclaration(
                association: association,
                isRegistered: association.handlers.contains(app.resolvedPath),
                isDefault: association.defaultHandler == app.resolvedPath)
        }
    }
}
