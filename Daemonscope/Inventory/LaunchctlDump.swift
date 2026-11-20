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

    var isRunning: Bool { state == "running" }
}

struct LoadedSnapshot: Sendable {
    let jobs: [LoadedJob]
    /// Domain → label → `true` when launchd's override database says disabled, `false` when it says enabled.
    let disabled: [String: [String: Bool]]
}

/// Parses `launchctl dumpstate` output.
///
/// Only the service blocks' top-level fields and each domain's `disabled services` list are read. Nested blocks,
/// which include environment variables, are skipped without being stored.
enum LaunchctlDump {
    static func domains(uid: uid_t) -> Set<String> {
        ["system", "user/\(uid)", "gui/\(uid)"]
    }

    static func parse(_ text: String, uid: uid_t) -> LoadedSnapshot {
        let wanted = domains(uid: uid)
        var jobs: [LoadedJob] = []
        var disabled: [String: [String: Bool]] = [:]

        enum Block {
            case none
            case domain(String)
            case service(domain: String, label: String, fields: [String: String])
            case skipped
        }
        var block = Block.none
        var inDisabledList = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            // Top-level block start: "<name> = {" at column 0.
            if !line.hasPrefix("\t"), line.hasSuffix(" = {") {
                let name = String(line.dropLast(4))
                inDisabledList = false
                if wanted.contains(name) {
                    block = .domain(name)
                    disabled[name, default: [:]] = disabled[name] ?? [:]
                } else if let (domain, label) = splitServiceName(name, wanted: wanted) {
                    block = .service(domain: domain, label: label, fields: [:])
                } else {
                    block = .skipped
                }
                continue
            }

            if line == "}" {
                if case .service(let domain, let label, let fields) = block {
                    jobs.append(makeJob(domain: domain, label: label, fields: fields))
                }
                block = .none
                inDisabledList = false
                continue
            }

            switch block {
            case .domain(let name):
                if line == "\tdisabled services = {" {
                    inDisabledList = true
                } else if inDisabledList, line == "\t}" {
                    inDisabledList = false
                } else if inDisabledList, let (label, isDisabled) = parseDisabledEntry(line) {
                    disabled[name, default: [:]][label] = isDisabled
                }
            case .service(let domain, let label, var fields):
                // Only one tab deep: deeper lines belong to nested blocks (environment, endpoints, …).
                guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
                let body = line.dropFirst()
                guard let range = body.range(of: " = "), !body.hasSuffix("{") else { continue }
                let key = String(body[..<range.lowerBound])
                if fields[key] == nil {
                    fields[key] = String(body[range.upperBound...])
                    block = .service(domain: domain, label: label, fields: fields)
                }
            case .none, .skipped:
                continue
            }
        }

        return LoadedSnapshot(jobs: jobs, disabled: disabled)
    }

    /// "gui/501/com.example.job" → ("gui/501", "com.example.job"), only for wanted domains. Labels may contain "/".
    private static func splitServiceName(_ name: String, wanted: Set<String>) -> (String, String)? {
        for domain in wanted where name.hasPrefix(domain + "/") {
            let label = String(name.dropFirst(domain.count + 1))
            return label.isEmpty ? nil : (domain, label)
        }
        return nil
    }

    /// `\t\t"com.example.job" => disabled`
    private static func parseDisabledEntry(_ line: String) -> (String, Bool)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\""), let close = trimmed.dropFirst().firstIndex(of: "\"") else { return nil }
        let label = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
        switch rest {
        case "=> disabled": return (label, true)
        case "=> enabled": return (label, false)
        default: return nil
        }
    }

    private static func makeJob(domain: String, label: String, fields: [String: String]) -> LoadedJob {
        let rawPath = fields["path"]
        let isFile = rawPath?.hasPrefix("/") ?? false
        return LoadedJob(
            domain: domain,
            label: label,
            path: isFile ? rawPath : nil,
            submittedBy: isFile ? nil : rawPath,
            type: fields["type"],
            state: fields["state"],
            pid: fields["pid"].flatMap { Int($0) },
            program: fields["program"],
            lastExit: fields["last exit code"],
            parentBundleID: fields["parent bundle identifier"])
    }
}
