import ServiceManagement
import SwiftUI

@main
struct VolMixApp: App {
    @StateObject private var controller = AudioController()

    var body: some Scene {
        MenuBarExtra("VolMix", systemImage: "chart.bar.fill") {
            MenuView()
                .environmentObject(controller)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuView: View {
    @EnvironmentObject private var controller: AudioController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VolMix").font(.headline)

            if controller.apps.isEmpty {
                Text("No apps are playing audio.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(controller.apps) { app in
                            AppRow(app: app)
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let error = controller.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            HStack {
                Button("Reset All") { controller.resetAll() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { controller.setMenuVisible(true) }
        .onDisappear { controller.setMenuVisible(false) }
    }
}

struct AppRow: View {
    @EnvironmentObject private var controller: AudioController
    let app: AudioApp

    var body: some View {
        let setting = controller.setting(for: app)
        HStack(spacing: 8) {
            Image(nsImage: app.identity.icon)
                .resizable()
                .frame(width: 22, height: 22)
                .opacity(app.isPlaying ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.callout)
                    .lineLimit(1)
                Slider(
                    value: Binding(
                        get: { Double(setting.volume) },
                        set: { controller.setVolume(Float($0), for: app) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                .disabled(setting.muted)
            }

            Text(setting.muted ? "Muted" : "\(Int((setting.volume * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)

            Button {
                controller.toggleMute(for: app)
            } label: {
                Image(systemName: setting.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(setting.muted ? "Unmute" : "Mute")
        }
    }
}
