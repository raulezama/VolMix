import AppKit
import CoreAudio
import Foundation

struct AppSetting: Codable, Equatable {
    var volume: Float = 1
    var muted = false

    var gain: Float { muted ? 0 : volume }
    /// Apps at full volume and unmuted are left untouched: no tap, no added latency.
    var needsTap: Bool { muted || volume < 0.999 }
}

struct AudioApp: Identifiable {
    let identity: AppIdentity
    let processObjectIDs: Set<AudioObjectID>
    let isPlaying: Bool

    var id: String { identity.id }
    var name: String { identity.name }
}

@MainActor
final class AudioController: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var settings: [String: AppSetting] = [:]
    @Published private(set) var lastError: String?

    private var taps: [String: ProcessTap] = [:]
    private var seenPlaying: Set<String> = []
    private var identities: [pid_t: AppIdentity] = [:]
    private var timer: Timer?
    private let defaultsKey = "AppSettings"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([String: AppSetting].self, from: data) {
            settings = saved
        }
        listen(to: kAudioHardwarePropertyProcessObjectList)
        listen(to: kAudioHardwarePropertyDefaultOutputDevice, rebuildTaps: true)
        refresh()
    }

    /// "Playing" state only matters while the menu is visible, so poll only then.
    /// When the menu is closed the app does no periodic work; it just reacts to Core Audio events.
    func setMenuVisible(_ visible: Bool) {
        timer?.invalidate()
        timer = nil
        guard visible else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - User actions

    func setting(for app: AudioApp) -> AppSetting { settings[app.id] ?? AppSetting() }

    func setVolume(_ volume: Float, for app: AudioApp) {
        update(app) { $0.volume = volume }
    }

    func toggleMute(for app: AudioApp) {
        update(app) { $0.muted.toggle() }
    }

    func resetAll() {
        settings = [:]
        save()
        syncTaps()
    }

    private func update(_ app: AudioApp, _ change: (inout AppSetting) -> Void) {
        var setting = setting(for: app)
        change(&setting)
        settings[app.id] = setting == AppSetting() ? nil : setting
        save()
        syncTaps()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    // MARK: - Discovery

    func refresh() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let processes = AudioProcess.all().filter { $0.pid != ownPID }
        // Resolve each pid to its app once; drop entries for processes that are gone.
        identities = identities.filter { entry in processes.contains { $0.pid == entry.key } }
        var groups: [AppIdentity: (ids: Set<AudioObjectID>, playing: Bool)] = [:]
        for process in processes {
            let identity = identities[process.pid] ?? AppResolver.identity(for: process)
            identities[process.pid] = identity
            var group = groups[identity] ?? (ids: Set<AudioObjectID>(), playing: false)
            group.ids.insert(process.objectID)
            group.playing = group.playing || process.isRunningOutput
            groups[identity] = group
        }

        // Merge entries for the same app id (e.g. several helper pids resolved to one app).
        var merged: [String: AudioApp] = [:]
        for (identity, group) in groups {
            let existing = merged[identity.id]
            merged[identity.id] = AudioApp(
                identity: existing?.identity ?? identity,
                processObjectIDs: group.ids.union(existing?.processObjectIDs ?? []),
                isPlaying: group.playing || (existing?.isPlaying ?? false)
            )
        }

        for app in merged.values where app.isPlaying { seenPlaying.insert(app.id) }
        apps = merged.values
            .filter { $0.isPlaying || seenPlaying.contains($0.id) || settings[$0.id] != nil }
            .sorted { ($0.isPlaying ? 0 : 1, $0.name.localizedLowercase) < ($1.isPlaying ? 0 : 1, $1.name.localizedLowercase) }
        syncTaps()
    }

    // MARK: - Taps

    /// Creates, updates, rebuilds or removes taps so each app with a custom setting has exactly one.
    private func syncTaps(forceRebuild: Bool = false) {
        let outputUID: String
        do {
            outputUID = try AudioObjectID.defaultOutputDevice().deviceUID()
        } catch {
            lastError = error.localizedDescription
            return
        }

        let wanted = Dictionary(uniqueKeysWithValues: apps.compactMap { app -> (String, (AudioApp, AppSetting))? in
            guard let setting = settings[app.id], setting.needsTap else { return nil }
            return (app.id, (app, setting))
        })

        for id in taps.keys where wanted[id] == nil { taps[id] = nil }

        var errors: [String] = []
        for (id, (app, setting)) in wanted {
            if let tap = taps[id], !forceRebuild,
               tap.processObjectIDs == app.processObjectIDs, tap.outputDeviceUID == outputUID {
                tap.gain = setting.gain
                continue
            }
            taps[id] = nil // tear down the old tap before tapping the same processes again
            do {
                taps[id] = try ProcessTap(name: app.name, processObjectIDs: app.processObjectIDs,
                                          outputDeviceUID: outputUID, gain: setting.gain)
            } catch {
                errors.append("\(app.name): \(error.localizedDescription)")
            }
        }
        lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    private func listen(to selector: AudioObjectPropertySelector, rebuildTaps: Bool = false) {
        var address = AudioObjectID.address(selector)
        AudioObjectAddPropertyListenerBlock(AudioObjectID.system, &address, .main) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                if rebuildTaps { self.syncTaps(forceRebuild: true) } else { self.refresh() }
            }
        }
    }
}
