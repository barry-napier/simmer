import SwiftUI

@main
struct SimmerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Simmer", systemImage: "slider.vertical.3") {
            MixerView(mixer: appDelegate.mixer, app: appDelegate)
        }
        .menuBarExtraStyle(.window)
    }
}
