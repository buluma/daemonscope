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

    /// From the domain listing's PID column, not the dump, so another job can't fake it.
    var isRunning: Bool { pid != nil }
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

    /// `nil` unless `text` is `launchctl print` output for `domain`.
    static func parse(_ text: String, domain: String) -> DomainListing? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "\(domain) = {" else { return nil }

        var services: [String: Service] = [:]
        var disabled: [String: Bool] = [:]
        enum Section { case none, services, disabled }
        var section = Section.none

        for line in lines.dropFirst() {
            switch section {
            case .none:
                if line == "\tservices = {" { section = .services }
                else if line == "\tdisabled services = {" { section = .disabled }
            case .services, .disabled:
                if line == "\t}" {
                    section = .none
                    continue
                }
                guard line.hasPrefix("\t\t"), !line.hasPrefix("\t\t\t") else { continue }
                if section == .services, let (label, service) = parseServiceRow(line) {
                    services[label] = service
                } else if section == .disabled, let (label, isDisabled) = parseDisabledEntry(line) {
                    disabled[label] = isDisabled
                }
            }
        }
        return DomainListing(services: services, disabled: disabled)
    }

    /// `\t\t     612      - \tcom.example.job`: PID, status, then a tab before the label.
    private static func parseServiceRow(_ line: String) -> (String, Service)? {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: true)
        guard columns.count == 2 else { return nil }
        let numbers = columns[0].split(separator: " ", omittingEmptySubsequences: true)
        guard numbers.count == 2, let pid = Int(numbers[0]) else { return nil }
        let label = columns[1].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return (label, Service(pid: pid == 0 ? nil : pid, status: String(numbers[1])))
    }

    /// `\t\t"com.example.job" => disabled`
    private static func parseDisabledEntry(_ line: String) -> (String, Bool)? {
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
        for (domain, listing) in listings.sorted(by: { $0.key < $1.key }) {
            for (label, service) in listing.services.sorted(by: { $0.key < $1.key }) {
                let blocks = details?[ServiceKey(domain: domain, label: label)] ?? []
                let fields = blocks.count == 1 ? blocks[0] : [:]
                let rawPath = fields["path"]
                let isFile = rawPath?.hasPrefix("/") ?? false
                jobs.append(LoadedJob(
                    domain: domain,
                    label: label,
                    path: isFile ? rawPath : nil,
                    submittedBy: isFile ? nil : rawPath,
                    type: fields["type"],
                    state: fields["state"],
                    pid: service.pid,
                    program: fields["program"],
                    lastExit: fields["last exit code"] ?? (service.status == "-" ? nil : service.status),
                    parentBundleID: fields["parent bundle identifier"],
                    detailsTampered: blocks.count > 1))
            }
        }
        return LoadedSnapshot(
            jobs: jobs, disabled: listings.mapValues(\.disabled), queriedDomains: Set(listings.keys), issues: issues)
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
/// names. Nested blocks (environment, endpoints, …) are skipped without being stored.
enum LaunchctlDump {
    static func serviceBlocks(_ text: String, domains: Set<String>) -> [ServiceKey: [[String: String]]] {
        var blocks: [ServiceKey: [[String: String]]] = [:]
        var current: (key: ServiceKey, fields: [String: String])?

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
                }
                continue
            }
            if line == "}" {
                finish()
                continue
            }
            // Only one tab deep: deeper lines belong to nested blocks.
            guard current != nil, line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let body = line.dropFirst()
            guard let range = body.range(of: " = "), !body.hasSuffix("{") else { continue }
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
