import AppKit
import CoreAudio
import UniformTypeIdentifiers

/// One Core Audio process object (any process that has opened an audio client).
struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningOutput: Bool

    static func all() -> [AudioProcess] {
        let ids = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList,
                                                       empty: AudioObjectID(kAudioObjectUnknown))) ?? []
        return ids.compactMap { id in
            guard let pid = try? id.read(kAudioProcessPropertyPID, default: pid_t(-1)), pid > 0 else { return nil }
            let running: UInt32 = (try? id.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0
            let bundleID = (try? id.readString(kAudioProcessPropertyBundleID)) ?? ""
            return AudioProcess(objectID: id, pid: pid, bundleID: bundleID, isRunningOutput: running != 0)
        }
    }
}

/// The user-facing app that owns one or more audio processes (e.g. Safari owns its WebKit GPU process).
struct AppIdentity: Hashable {
    let id: String
    let name: String
    let pid: pid_t

    var icon: NSImage {
        NSRunningApplication(processIdentifier: pid)?.icon
            ?? NSWorkspace.shared.icon(for: .application)
    }
}

enum AppResolver {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    /// Private libsystem call that maps helper/XPC processes to the app responsible for them.
    /// Looked up dynamically so the app still runs if it ever disappears.
    private static let responsiblePID: ResponsibleFn? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    static func identity(for process: AudioProcess) -> AppIdentity {
        // Prefer the responsible app (Safari for WebKit, Chrome for its helpers, ...).
        if let responsible = responsiblePID?(process.pid), responsible > 0, responsible != process.pid,
           let app = NSRunningApplication(processIdentifier: responsible), let identity = identity(for: app) {
            return identity
        }
        if let app = NSRunningApplication(processIdentifier: process.pid) {
            // Helper bundles usually extend the parent's bundle ID ("com.google.Chrome.helper").
            if app.activationPolicy != .regular, let bundleID = app.bundleIdentifier,
               let parent = NSWorkspace.shared.runningApplications.first(where: {
                   $0.activationPolicy == .regular && ($0.bundleIdentifier.map { bundleID.hasPrefix($0 + ".") } ?? false)
               }), let identity = identity(for: parent) {
                return identity
            }
            if let identity = identity(for: app) { return identity }
        }
        let id = process.bundleID.isEmpty ? "pid.\(process.pid)" : process.bundleID
        let name = process.bundleID.split(separator: ".").last.map(String.init) ?? "Process \(process.pid)"
        return AppIdentity(id: id, name: name, pid: process.pid)
    }

    private static func identity(for app: NSRunningApplication) -> AppIdentity? {
        guard let id = app.bundleIdentifier ?? app.executableURL?.path else { return nil }
        let name = app.localizedName ?? app.executableURL?.lastPathComponent ?? id
        return AppIdentity(id: id, name: name, pid: app.processIdentifier)
    }
}
