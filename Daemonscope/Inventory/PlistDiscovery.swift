import Foundation

/// A problem met while scanning that didn't stop the scan. Kept so the UI can show partial results honestly.
struct ScanIssue: Sendable, Hashable, Identifiable {
    var id: String { path + message }
    let path: String
    let message: String
}

struct DiskScan: Sendable {
    let date: Date
    let jobs: [DiskJob]
    let issues: [ScanIssue]
}

/// Finds launchd job plists on disk. It reads files only; it never asks launchd anything.
struct PlistDiscovery: Sendable {
    struct JobDirectory: Sendable {
        let url: URL
        let location: JobLocation
    }

    let jobDirectories: [JobDirectory]
    /// Folders searched recursively for `.app` bundles that carry their own LaunchAgents or LaunchDaemons.
    let appSearchRoots: [URL]

    static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> PlistDiscovery {
        PlistDiscovery(
            jobDirectories: [
                .init(url: home.appendingPathComponent("Library/LaunchAgents"), location: .userAgents),
                .init(url: URL(fileURLWithPath: "/Library/LaunchAgents"), location: .globalAgents),
                .init(url: URL(fileURLWithPath: "/Library/LaunchDaemons"), location: .globalDaemons),
                .init(url: URL(fileURLWithPath: "/System/Library/LaunchAgents"), location: .systemAgents),
                .init(url: URL(fileURLWithPath: "/System/Library/LaunchDaemons"), location: .systemDaemons),
            ],
            appSearchRoots: [
                URL(fileURLWithPath: "/Applications"),
                home.appendingPathComponent("Applications"),
            ])
    }

    func scan(now: Date = Date()) -> DiskScan {
        var jobs: [DiskJob] = []
        var issues: [ScanIssue] = []

        for directory in jobDirectories {
            read(directory: directory.url, location: directory.location, owningApp: nil, into: &jobs, issues: &issues)
        }

        for app in appBundles(issues: &issues) {
            let library = app.appendingPathComponent("Contents/Library")
            read(directory: library.appendingPathComponent("LaunchAgents"), location: .appAgents,
                 owningApp: app.path, into: &jobs, issues: &issues)
            read(directory: library.appendingPathComponent("LaunchDaemons"), location: .appDaemons,
                 owningApp: app.path, into: &jobs, issues: &issues)
        }

        jobs.sort { $0.path < $1.path }
        return DiskScan(date: now, jobs: jobs, issues: issues)
    }

    private func read(
        directory: URL, location: JobLocation, owningApp: String?,
        into jobs: inout [DiskJob], issues: inout [ScanIssue]
    ) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        // A missing folder is normal (most apps ship no jobs, many users have no LaunchAgents folder).
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            issues.append(ScanIssue(path: directory.path, message: "Couldn't list folder: \(error.localizedDescription)"))
            return
        }

        for file in entries where file.pathExtension == "plist" {
            do {
                let data = try Data(contentsOf: file)
                let job = try DiskJob.parse(data: data, path: file.path, location: location, owningApp: owningApp)
                if job.label == nil {
                    issues.append(ScanIssue(path: file.path, message: "Missing or empty Label; launchd won't load this job."))
                }
                jobs.append(job)
            } catch DiskJob.ParseError.notADictionary {
                issues.append(ScanIssue(path: file.path, message: "Not a job definition: the plist root isn't a dictionary."))
            } catch DiskJob.ParseError.unreadable(let reason) {
                issues.append(ScanIssue(path: file.path, message: "Malformed plist: \(reason)"))
            } catch {
                issues.append(ScanIssue(path: file.path, message: "Couldn't read file: \(error.localizedDescription)"))
            }
        }
    }

    /// `.app` bundles under the search roots. Doesn't descend into a bundle once found, so helper apps nested
    /// inside another app aren't treated as separately installed apps.
    private func appBundles(issues: inout [ScanIssue]) -> [URL] {
        /// The enumerator's error handler is an escaping closure, so it can't append to `issues` directly.
        final class ErrorLog {
            var issues: [ScanIssue] = []
        }

        var apps: [URL] = []
        for root in appSearchRoots where FileManager.default.fileExists(atPath: root.path) {
            let log = ErrorLog()
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    log.issues.append(ScanIssue(
                        path: url.path, message: "Couldn't search folder for apps: \(error.localizedDescription)"))
                    // Keep going: one unreadable folder shouldn't hide every other app.
                    return true
                })
            else {
                issues.append(ScanIssue(path: root.path, message: "Couldn't search folder for apps."))
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "app" {
                apps.append(url)
            }
            issues.append(contentsOf: log.issues)
        }
        return apps
    }
}
