import SwiftUI

/// Shown once, on first launch.
struct WelcomeView: View {
    let mixer: Mixer
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Simmer").font(.title2.bold())
                    Text("A volume knob for every app.").foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                step("slider.vertical.3", "Click the sliders icon in the menu bar.")
                step("speaker.wave.2", "Every app that plays sound gets its own slider.")
                step("memorychip", "Simmer remembers each app’s volume for next time.")
                step("lock", "macOS asks once to let Simmer hear other apps. That is how it turns them up or down. Nothing is recorded.")
            }

            Spacer(minLength: 0)

            HStack {
                if mixer.permission != .granted {
                    Button("Allow Now") { mixer.askForPermission() }
                }
                Spacer()
                Button("Got It", action: finish)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 400)
    }

    private func step(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 20)
                .foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
