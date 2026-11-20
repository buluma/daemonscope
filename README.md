# Daemonscope

A read-only macOS menu bar app for inspecting launchd jobs and Launch Services registrations.

It shows which launchd jobs exist on disk, which ones launchd has loaded, whether they're running or disabled, and which apps handle which URL schemes and file types. It never loads, unloads, disables or edits anything.

## Requirements

- macOS 26 or later
- Xcode 26 or later (developed with Xcode 27)

## Build and install

Daemonscope is distributed as source only and signed locally ("Sign to Run Locally"), so it runs only on the Mac that built it.

```sh
xcodebuild -scheme Daemonscope -configuration Release -derivedDataPath build build
ditto build/Build/Products/Release/Daemonscope.app /Applications/Daemonscope.app
open /Applications/Daemonscope.app
```

To update, quit Daemonscope from its menu, rebuild, and copy it over again. It doesn't start at login on its own.

Run the tests with:

```sh
xcodebuild test -scheme Daemonscope -destination 'platform=macOS'
```

## Using it

Daemonscope lives in the menu bar (gear icon) and has no Dock icon. The menu shows counts of third-party jobs by state, a short filterable list, and **Open Daemonscope**, **Refresh** and **Quit**. Closing the main window leaves the app running in the menu bar.

The main window has two sections. Press ⌘F to jump to the search field in either one.

### Launchd

Every job plist found on disk, merged with what launchd reports as loaded:

| State | Meaning |
| --- | --- |
| Running | launchd reports a running process. |
| Loaded, not running | Loaded but idle. Many jobs start on demand, so this isn't necessarily a fault. |
| Disabled | Not loaded, and disabled by launchd's override database or the plist's `Disabled` key. |
| Found on disk | The plist exists, but launchd doesn't report the job loaded in any domain it could load in. |
| Unknown | launchd couldn't be queried, or its answer for this job couldn't be trusted. |

- Plists are read from `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`, `/System/Library/LaunchAgents`, `/System/Library/LaunchDaemons`, and the `Contents/Library/LaunchAgents` and `LaunchDaemons` folders of apps in `/Applications` and `~/Applications`.
- Loaded state comes from the `system`, `user/<uid>` and `gui/<uid>` domains. Refreshes run every 5 minutes and on demand.
- Apple's jobs are hidden by default. A job counts as Apple's only when its plist is under `/System/Library` or `/Library/Apple`, which System Integrity Protection guards; a `com.apple.*` label alone doesn't count, since anyone with admin rights can choose it.
- Per-app instances created for running apps are hidden by default too; the Filter menu shows them.
- Environment variables in plists can hold secrets. They stay hidden until you ask, and are never logged.

### Launch Services

Apps and the URL schemes and file types they handle, in three views: **Apps**, **URL Schemes** and **File Types**.

This is not the full Launch Services database. Schemes and types are those declared by apps in `/Applications`, `/System/Applications`, `~/Applications` and `/System/Library/CoreServices`. Default and other handlers come from Launch Services itself (NSWorkspace), so they include apps outside those folders, but a scheme or type claimed only by such apps isn't listed. Apps that declare a scheme or type without being registered for it are marked.

## How it gets its data, and its limits

- **Plists** are parsed with `PropertyListSerialization`.
- **Loaded state** comes from `launchctl print <domain>`, with details added from one `launchctl dumpstate`. Neither is a stable API, and both can change between macOS versions.
- **Tamper detection:** launchd prints job labels, arguments and environment values without escaping. A job can therefore try to forge entries in that output. Daemonscope checks the output's structure against counts launchd prints before any job-supplied text. When something looks forged, it asks launchd about the affected jobs one at a time and shows a warning. Treat its results as best-effort with tamper detection, not as proof.
- **Sandbox:** Daemonscope doesn't use the App Sandbox. The sandbox would block reading job folders and running `launchctl`, and App Store distribution is out of scope.
- **False alarms at startup:** a domain that launchd is still setting up, for example right after login, can briefly print a job count that doesn't match its rows. Daemonscope then flags the domain and checks its jobs one by one; the warning clears on the next refresh.
- **Testing status:**
  - Tested on macOS 27 with an administrator account.
  - **Unprivileged access**, approximated by running the data collection as the `nobody` user: the `system` domain was fully readable without admin rights. That covers every job, PID, the disabled list, the dump, and per-job prints. The user's own domain was readable too.
  - **Not tested in a real standard-account session.** `nobody` has no login session, so the `gui` domain and the menu bar UI weren't exercised.
  - macOS 26 hasn't been tested.
