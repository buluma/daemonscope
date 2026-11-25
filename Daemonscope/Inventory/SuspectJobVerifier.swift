import Foundation

/// Re-checks jobs whose bulk evidence looks forged by asking launchd about each one: `launchctl print
/// <domain>/<label>`.
///
/// A per-job print holds only that job's own block, so one job can't forge entries for another there. That
/// makes it the tie-breaker when the dump holds conflicting blocks for a job, when a listed row has no dump
/// block, or when a domain's whole listing is unsound. It costs one launchctl call per job (~9 ms), so it runs
/// only for flagged jobs, or for every job in a forged domain.
enum SuspectJobVerifier {
    enum Lookup {
        /// The job exists; fields printed before its first nested block.
        case found([String: String])
        /// launchd says no such job is loaded in that domain.
        case notFound
        /// The answer couldn't be trusted or read.
        case failed
    }

    struct Outcome {
        var jobs: [LoadedJob]
        /// Rows in a sound listing that launchd denies having, removed.
        var removed = 0
        /// Candidates left unchecked when the refresh budget expired.
        var skipped = 0
        /// Jobs in a sound listing whose bulk output conflicted and that launchd then confirmed directly.
        var confirmed = 0
        /// Domains whose forged listing was rebuilt job by job.
        var rebuiltDomains: [String] = []
    }

    static func lookup(domain: String, label: String, launchctl: ([String]) throws -> String) -> Lookup {
        // A label with control characters can't be passed back safely and is forged anyway.
        guard !label.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return .failed }
        let output: String
        do {
            output = try launchctl(["print", "\(domain)/\(label)"])
        } catch LaunchctlCollector.CollectError.exited(_, let message) where message.contains("Could not find service") {
            return .notFound
        } catch {
            return .failed
        }
        // The answer must be this job's block and nothing that claims to be a second one.
        let header = "\(domain)/\(label) = {"
        guard output.split(separator: "\n", maxSplits: 1).first.map(String.init) == header,
              let blocks = LaunchctlDump.serviceBlocks(output, domains: [domain])[ServiceKey(domain: domain, label: label)],
              blocks.count == 1
        else { return .failed }
        return .found(blocks[0])
    }

    static func verify(
        snapshot: LoadedSnapshot,
        listings: [String: DomainListing],
        details: [ServiceKey: [[String: String]]]?,
        timeRemaining: () -> Duration,
        launchctl: ([String], Duration) throws -> String
    ) -> Outcome {
        var outcome = Outcome(jobs: [])
        let soundDomains = Set(listings.filter { $0.value.isStructurallySound }.keys)

        func check(domain: String, label: String) -> Lookup? {
            let timeout = timeRemaining()
            guard timeout > .zero else {
                outcome.skipped += 1
                return nil
            }
            return lookup(domain: domain, label: label) { try launchctl($0, timeout) }
        }

        for job in snapshot.jobs where soundDomains.contains(job.domain) {
            guard job.detailsTampered || job.rowSuspect else {
                outcome.jobs.append(job)
                continue
            }
            switch check(domain: job.domain, label: job.label) {
            case nil:
                var unchecked = job
                unchecked.rowSuspect = true
                outcome.jobs.append(unchecked)
            case .found(let fields):
                // The listing is sound, so its PID and status stand, unless this label was listed twice, in which
                // case the PID column can't be trusted and running comes from launchd's direct `state`.
                let service = listings[job.domain]?.services[job.label]
                let listedTwice = listings[job.domain]?.suspectLabels.contains(job.label) ?? false
                outcome.jobs.append(LoadedJob(
                    domain: job.domain, label: job.label, fields: fields, pid: listedTwice ? nil : service?.pid,
                    lastExit: service.flatMap { $0.status == "-" ? nil : $0.status }, verifiedIndividually: true))
                outcome.confirmed += 1
            case .notFound:
                // A sound listing can't carry injected rows, so this is a job that unloaded in the meantime.
                outcome.removed += 1
            case .failed:
                outcome.jobs.append(job)
            }
        }

        for domain in listings.keys.sorted() where !soundDomains.contains(domain) {
            // Labels come from the forged listing and from dump headers. A label can't remove another job's
            // dump header, so jobs hidden from the listing are still among the candidates.
            var candidates = Set(listings[domain]?.services.keys ?? [:].keys)
            for key in details?.keys ?? [:].keys where key.domain == domain { candidates.insert(key.label) }
            for label in candidates.sorted() {
                switch check(domain: domain, label: label) {
                case .found(let fields):
                    // No trustworthy PID column here; `state` is printed before any nested block.
                    outcome.jobs.append(LoadedJob(
                        domain: domain, label: label, fields: fields, pid: nil, lastExit: nil,
                        verifiedIndividually: true))
                case .notFound:
                    // In a forged listing a row launchd denies is evidence, possibly the visible half of the
                    // attacker's own newline label, so it stays visible as suspect. A dump-only candidate
                    // launchd denies was forged in the dump and is dropped.
                    if let job = snapshot.jobs.first(where: { $0.domain == domain && $0.label == label }) {
                        outcome.jobs.append(job)
                    }
                case .failed, nil:
                    // No answer either way. Keep it visible as suspect, whether it came from the listing or only
                    // from a dump header (a job the forgery may have hidden).
                    outcome.jobs.append(snapshot.jobs.first { $0.domain == domain && $0.label == label }
                        ?? LoadedJob(
                            domain: domain, label: label, path: nil, submittedBy: nil, type: nil, state: nil, pid: nil,
                            program: nil, lastExit: nil, parentBundleID: nil, rowSuspect: true))
                }
            }
            outcome.rebuiltDomains.append(domain)
        }
        return outcome
    }
}

extension LoadedJob {
    /// A job built from launchd's own answer about it (a per-job print).
    init(domain: String, label: String, fields: [String: String], pid: Int?, lastExit: String?, verifiedIndividually: Bool) {
        let rawPath = fields["path"]
        let isFile = rawPath?.hasPrefix("/") ?? false
        self.init(
            domain: domain, label: label,
            path: isFile ? rawPath : nil,
            submittedBy: isFile ? nil : rawPath,
            type: fields["type"],
            state: fields["state"],
            pid: pid,
            program: fields["program"],
            lastExit: lastExit,
            parentBundleID: fields["parent bundle identifier"],
            verifiedIndividually: verifiedIndividually)
    }
}
