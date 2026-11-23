import ServiceManagement
import SwiftUI

/// The panel that opens from the menu bar icon.
struct MixerView: View {
    let mixer: Mixer
    let app: AppDelegate
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 12)

            if mixer.permission == .denied {
                PermissionBanner()
                    .padding(12)
                Divider().padding(.horizontal, 12)
            }

            if mixer.apps.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "speaker.slash")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("No app is playing sound.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                VStack(spacing: 2) {
                    ForEach(mixer.apps) { item in
                        AppRow(item: item, mixer: mixer)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
            }

            if let problem = mixer.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Divider().padding(.horizontal, 12)
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Simmer").font(.headline)
            if !mixer.outputName.isEmpty {
                Text(mixer.outputName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if mixer.hasChanges {
                Button("Reset All") { mixer.resetAll() }
                    .buttonStyle(.link)
                    .help("Put every app back to full volume")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Open at Login", isOn: $opensAtLogin)
                .toggleStyle(.checkbox)
                .onChange(of: opensAtLogin) { _, on in app.setOpensAtLogin(on) }
            HStack(spacing: 14) {
                if app.canCheckForUpdates {
                    Button("Check for Updates…") { app.checkForUpdates() }
                }
                Button("Debug Log") { app.showDebugLog() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// One app: icon, name, mute button and volume slider.
private struct AppRow: View {
    let item: MixerApp
    let mixer: Mixer
    @State private var volume: Double = 1
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 28, height: 28)
                .opacity(item.isPlaying ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(item.name)
                        .lineLimit(1)
                        .foregroundStyle(item.isPlaying ? .primary : .secondary)
                    Spacer()
                    Text(item.isMuted ? "Muted" : "\(Int((volume * 100).rounded()))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $volume, in: 0...1)
                .controlSize(.small)
                .disabled(item.isMuted)
                .onChange(of: volume) { _, value in mixer.setVolume(Float(value), for: item.id) }
            }

            Button {
                mixer.toggleMute(item.id)
            } label: {
                Image(systemName: item.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 22)
                    .foregroundStyle(item.isMuted ? Color.red : .secondary)
            }
            .buttonStyle(.borderless)
            .help(item.isMuted ? "Unmute \(item.name)" : "Mute \(item.name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(isHovered ? Color.primary.opacity(0.06) : .clear))
        .onHover { isHovered = $0 }
        .onAppear { volume = Double(item.volume) }
        .onChange(of: item.volume) { _, value in
            if abs(Double(value) - volume) > 0.001 { volume = Double(value) }
        }
    }
}

/// Shown when the person said no to the permission prompt.
private struct PermissionBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Simmer can’t change volumes yet", systemImage: "lock")
                .font(.headline)
            Text("Turn on Simmer in System Settings, under Screen & System Audio Recording, in the “System Audio Recording Only” list.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") { AudioPermission.openSettings() }
        }
    }
}
