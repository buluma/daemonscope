import Foundation

/// A job launchd reports as loaded in a domain.
///
/// Built from `launchctl` diagnostic text, which isn't a stable API: every field except `domain` and `label`
/// may be missing, and values are kept as reported rather than interpreted.
struct LoadedJob: Sendable, Hashable {
    let domain: String
    let label: String
    /// The plist launchd loaded the job from; `nil` when launchd reports no file.
    let path: String?
    /// The raw `path` value when it names a submitter instead of a file, e.g. `(submitted by smd.332)`.
    let submittedBy: String?
    let type: String?
    let state: String?
    let pid: Int?
    let program: String?
    /// e.g. `0`, `78: EX_CONFIG`, `-15`, or `(never exited)`.
    let lastExit: String?
    /// The app that registered the job, for jobs submitted through Service Management.
    let parentBundleID: String?
    /// The dump held more than one block for this job, so someone wrote fake ones. The details from the dump
    /// were dropped; what's left comes from the domain listing.
    var detailsTampered = false
    /// The domain listing this row came from looks forged (a newline in some job's label can add or hide
    /// rows), or its label is listed twice. Its PID isn't trusted and its state is unknown.
    var rowSuspect = false
    /// launchd confirmed this job with a per-job `launchctl print`, which another job can't forge.
    var verifiedIndividually = false

    /// From the domain listing's PID column, not the dump, so another job can't fake it. A job rebuilt from a
    /// forged domain has no trustworthy PID column, so its own per-job `state` (printed before any nested
    /// block) decides.
    var isRunning: Bool { pid != nil || (verifiedIndividually && state == "running") }
}

/// One domain as `launchctl print <domain>` lists it.
///
/// This listing is the authority for which jobs are loaded, their PIDs and the disabled overrides. Unlike
/// `dumpstate`, it doesn't include any job's arguments or environment, so one job can't forge lines that look
/// like another job's entry.
struct DomainListing: Sendable, Equatable {
    struct Service: Sendable, Equatable {
        /// `nil` when the PID column is 0 (not running).
        let pid: Int?
        /// The status column as printed: a last exit status, `-`, or a marker such as `(pe)`.
        let status: String
    }

    var services: [String: Service]
    var disabled: [String: Bool]
    /// Labels listed more than once. launchd lists each label once per domain, so a repeat means someone forged
    /// a row; the first row is kept and the job is flagged.
    var suspectLabels: Set<String> = []
    /// `false` when the listing's structure doesn't match what launchd prints: the row count differs from the
    /// header's `service count`, a section repeats, a row doesn't parse, or row-like lines appear outside any
    /// block. Any of these means a label with newlines rewrote the listing, so none of its rows, PIDs or
    /// disabled entries can be trusted.
    var isStructurallySound = true
    /// `service count` from the listing's header, printed before any label.
    var declaredServiceCount: Int?

    /// `nil` unless `text` is `launchctl print` output for `domain`.
    static func parse(_ text: String, domain: String) -> DomainListing? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "\(domain) = {" else { return nil }

        var services: [String: Service] = [:]
        var disabled: [String: Bool] = [:]
        var suspect: Set<String> = []
        var rowCount = 0
        var declaredCount: Int?
        var inHeader = true
        var isSound = true
        var seenServices = false
        var seenDisabled = false
        var closed = false
        var seenBlocks: Set<String> = []
        enum Section { case none, services, disabled, other(depth: Int) }
        var section = Section.none

        for line in lines.dropFirst() {
            if closed {
                // Nothing follows the domain's closing brace except a trailing newline.
                if !line.isEmpty { isSound = false }
                continue
            }
            switch section {
            case .none:
                if line.isEmpty { continue }
                if line == "}" {
                    closed = true
                } else if line == "\tservices = {" {
                    inHeader = false
                    if seenServices { isSound = false }
                    seenServices = true
                    section = .services
                } else if line == "\tdisabled services = {" {
                    inHeader = false
                    if seenDisabled { isSound = false }
                    seenDisabled = true
                    section = .disabled
                } else if line.hasPrefix("\t"), !line.hasPrefix("\t\t"), line.hasSuffix(" = {") {
                    inHeader = false
                    // launchd prints each top-level block once; a repeat means a label reopened one.
                    if !seenBlocks.insert(line).inserted { isSound = false }
                    section = .other(depth: 1)
                } else if line.hasPrefix("\t"), !line.hasPrefix("\t\t"), !line.hasPrefix("\t}"),
                          let range = line.range(of: " = ") {
                    // A plain "key = value" field. The count is taken from the header only: a label printed
                    // later can't supply one.
                    if inHeader, declaredCount == nil, line[line.index(after: line.startIndex)..<range.lowerBound] == "service count" {
                        declaredCount = Int(line[range.upperBound...])
                    }
                } else {
                    // A row-like line, a stray brace, or anything else outside a block: the structure was rewritten.
                    isSound = false
                }
            case .other(let depth):
                // Other blocks are skipped, but they must not swallow rows: a label can close `services` and open
                // a dummy block so the real rows after it land here, while fake rows keep the count right.
                if parseServiceRow(line) != nil || parseDisabledEntry(line) != nil {
                    isSound = false
                }
                if line.hasPrefix("\t"), !line.hasPrefix("\t\t") {
                    // Inside a nested block only its own closing brace sits one tab deep.
                    if depth == 1, line == "\t}" {
                        section = .none
                    } else {
                        isSound = false
                    }
                    continue
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "}" {
                    section = depth == 1 ? .none : .other(depth: depth - 1)
                } else if line.hasSuffix("{") {
                    section = .other(depth: depth + 1)
                }
            case .services, .disabled:
                if line == "\t}" {
                    section = .none
                    continue
                }
                if case .services = section, let (label, service) = parseServiceRow(line) {
                    rowCount += 1
                    if services[label] == nil {
                        services[label] = service
                    } else {
                        suspect.insert(label)
                    }
                } else if case .disabled = section, let (label, isDisabled) = parseDisabledEntry(line) {
                    disabled[label] = isDisabled
                } else {
                    isSound = false
                }
            }
        }
        // launchd prints the service count before any label; a newline in a label can add or hide rows but can't
        // change that number, so a mismatch means the rows were tampered with.
        if declaredCount == nil || declaredCount != rowCount || !closed { isSound = false }
        return DomainListing(
            services: services, disabled: disabled, suspectLabels: suspect, isStructurallySound: isSound,
            declaredServiceCount: declaredCount)
    }

    /// `\t\t     612      - \tcom.example.job`: PID, status, then a tab before the label.
    private static func parseServiceRow(_ line: String) -> (String, Service)? {
        guard line.hasPrefix("\t\t"), !line.hasPrefix("\t\t\t") else { return nil }
        let columns = line.split(separator: "\t", omittingEmptySubsequences: true)
        guard columns.count == 2 else { return nil }
        let numbers = columns[0].split(separator: " ", omittingEmptySubsequences: true)
        guard numbers.count == 2, let pid = Int(numbers[0]) else { return nil }
        let label = columns[1].trimmingCharacters(in: .whitespaces)
        // Control characters have no business in a label and are the raw material for faking rows.
        guard !label.isEmpty, !label.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        return (label, Service(pid: pid == 0 ? nil : pid, status: String(numbers[1])))
    }

    /// `\t\t"com.example.job" => disabled`
    private static func parseDisabledEntry(_ line: String) -> (String, Bool)? {
        guard line.hasPrefix("\t\t"), !line.hasPrefix("\t\t\t") else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\""), let close = trimmed.dropFirst().firstIndex(of: "\"") else { return nil }
        let label = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        switch trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces) {
        case "=> disabled": return (label, true)
        case "=> enabled": return (label, false)
        default: return nil
        }
    }
}

struct LoadedSnapshot: Sendable {
    let jobs: [LoadedJob]
    /// Domain → label → `true` when launchd's override database says disabled, `false` when it says enabled.
    let disabled: [String: [String: Bool]]
    /// Domains that answered. `nil` means every domain did (used by tests that don't care).
    let queriedDomains: Set<String>?
    /// Partial failures, such as a domain that couldn't be listed or a missing dump.
    let issues: [String]

    init(jobs: [LoadedJob], disabled: [String: [String: Bool]], queriedDomains: Set<String>? = nil, issues: [String] = []) {
        self.jobs = jobs
        self.disabled = disabled
        self.queriedDomains = queriedDomains
        self.issues = issues
    }

    /// Jobs and disabled lists come from `listings`. `details` (parsed `dumpstate` blocks, or `nil` without a
    /// dump) only add fields to jobs a listing already names, and only when the dump holds exactly one block
    /// for that job.
    static func build(
        listings: [String: DomainListing], details: [ServiceKey: [[String: String]]]?, issues: [String] = []
    ) -> LoadedSnapshot {
        var jobs: [LoadedJob] = []
        // Rows of an unsound listing stay visible, but nothing about them is trusted, and the domain can't
        // vouch that a plist isn't loaded.
        let soundListings = listings.filter { $0.value.isStructurallySound }
        for (domain, listing) in listings.sorted(by: { $0.key < $1.key }) {
            for (label, service) in listing.services.sorted(by: { $0.key < $1.key }) {
                let blocks = details?[ServiceKey(domain: domain, label: label)] ?? []
                let tampered = blocks.count > 1 || listing.suspectLabels.contains(label)
                // Every genuine row has exactly one dump block (checked on macOS 27.3). The dump can be forged, so
                // a block doesn't prove a row genuine, but a missing one is still a reason for doubt.
                let rowSuspect = !listing.isStructurallySound || listing.suspectLabels.contains(label)
                    || (details != nil && blocks.isEmpty)
                let fields = !tampered && blocks.count == 1 ? blocks[0] : [:]
                let rawPath = fields["path"]
                let isFile = rawPath?.hasPrefix("/") ?? false
                jobs.append(LoadedJob(
                    domain: domain,
                    label: label,
                    path: isFile ? rawPath : nil,
                    submittedBy: isFile ? nil : rawPath,
                    type: fields["type"],
                    state: fields["state"],
                    pid: rowSuspect ? nil : service.pid,
                    program: fields["program"],
                    // From the listing: the dump prints `last exit code` after nested blocks, where a job can forge it.
                    lastExit: service.status == "-" ? nil : service.status,
                    parentBundleID: fields["parent bundle identifier"],
                    detailsTampered: tampered,
                    rowSuspect: rowSuspect))
            }
        }
        return LoadedSnapshot(
            jobs: jobs, disabled: soundListings.mapValues(\.disabled), queriedDomains: Set(soundListings.keys),
            issues: issues)
    }
}

struct ServiceKey: Hashable, Sendable {
    let domain: String
    let label: String
}

/// Reads service blocks out of `launchctl dumpstate` output.
///
/// The dump isn't trustworthy on its own: launchd doesn't escape newlines in a job's arguments or environment,
/// so a job's owner can print lines that look like any other job's block. Every block is therefore collected
/// per job, and `LoadedSnapshot.build` uses one only when it's the single block for a job a domain listing
/// names. Within a block, only fields printed before the first nested block (arguments, environment, …) are
/// read: anything after it may have been written by the job itself. launchd prints path, type, state,
/// program and parent bundle identifier before any nested block (checked on macOS 27.3).
enum LaunchctlDump {
    static func serviceBlocks(_ text: String, domains: Set<String>) -> [ServiceKey: [[String: String]]] {
        var blocks: [ServiceKey: [[String: String]]] = [:]
        var current: (key: ServiceKey, fields: [String: String])?
        var pastFirstNestedBlock = false

        func finish() {
            if let current { blocks[current.key, default: []].append(current.fields) }
            current = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            if !line.hasPrefix("\t"), line.hasSuffix(" = {") {
                finish()
                if let key = serviceKey(String(line.dropLast(4)), domains: domains) {
                    current = (key, [:])
                    pastFirstNestedBlock = false
                }
                continue
            }
            if line == "}" {
                finish()
                continue
            }
            // Only one tab deep: deeper lines belong to nested blocks.
            guard current != nil, !pastFirstNestedBlock, line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let body = line.dropFirst()
            if body.hasSuffix("{") {
                pastFirstNestedBlock = true
                continue
            }
            guard let range = body.range(of: " = ") else { continue }
            let key = String(body[..<range.lowerBound])
            if current?.fields[key] == nil {
                current?.fields[key] = String(body[range.upperBound...])
            }
        }
        finish()
        return blocks
    }

    /// "gui/501/com.example.job" → (gui/501, com.example.job), only for wanted domains. Labels may contain "/".
    private static func serviceKey(_ name: String, domains: Set<String>) -> ServiceKey? {
        for domain in domains where name.hasPrefix(domain + "/") {
            let label = String(name.dropFirst(domain.count + 1))
            return label.isEmpty ? nil : ServiceKey(domain: domain, label: label)
        }
        return nil
    }
}
