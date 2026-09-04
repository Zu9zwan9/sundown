import AppKit
import ServiceManagement
import SwiftUI

@main
struct SundownApp: App {

    @State private var model = SessionModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            // Deliberately static.
            //
            // A badge or count here would require polling the process table
            // forever in the background — which is exactly the behaviour this
            // app exists to clean up. The menu bar item is a door, not a
            // dashboard. We look when you open it.
            Image(systemName: "moon.stars")
                .accessibilityLabel("Sundown")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

/// Bring the Settings window to the front.
///
/// `LSUIElement` apps are accessory apps: they have no Dock tile, so macOS
/// does not activate them when a window opens. Without this, `openSettings()`
/// puts the window *behind* whatever you were doing, and it looks like
/// nothing happened.
///
/// The async hop matters — the window doesn't exist yet on the turn
/// `openSettings()` is called, so activating immediately activates nothing.
@MainActor
func focusSettingsWindow() {
    DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`: an
        // accessory app may not be allowed to take key status, and this works
        // either way.
        NSApp.windows
            .first {
                $0.identifier?.rawValue.contains("Settings") == true
                    || $0.title.localizedCaseInsensitiveContains("settings")
            }?
            .orderFrontRegardless()
    }
}

struct SettingsView: View {

    /// Mirrors `SMAppService`, never leads it. Read on appear, rewritten from
    /// the service after every change, so the switch can't show a state the
    /// system doesn't actually have.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Open Sundown at login",
                    isOn: Binding(get: { launchAtLogin }, set: setLoginItem)
                )
                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text(
                    """
                    Sundown never ends system processes, applications, shells, \
                    or anything owned by another user. It stops containers \
                    through Docker rather than touching the daemon.

                    Every process is asked to quit first. Only what refuses \
                    is forced.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("What Sundown will not touch")
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            failure = nil
        } catch {
            failure = "Couldn’t update the login item. \(error.localizedDescription)"
        }
        // Whatever happened, show what is now true.
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
