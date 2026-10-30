import SwiftUI

@main
struct PrepareDiskApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Prepare Disk", id: "main") {
            RootView(model: model)
                .frame(minWidth: 960, minHeight: 640)
                .task { await model.start() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Rechercher des mises à jour…") { Task { await model.updater.check() } }
            }
            CommandGroup(after: .newItem) {
                Button("Actualiser tout") { Task { await model.refreshAll() } }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
