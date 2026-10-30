import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model).tabItem { Label("Général", systemImage: "gearshape") }
            MacOSSettings(model: model).tabItem { Label("macOS", systemImage: "apple.logo") }
            IPSWSettings(model: model).tabItem { Label("IPSW", systemImage: "ipad") }
            UpdateSettings(model: model).tabItem { Label("Mise à jour", systemImage: "arrow.down.app") }
        }
        .frame(width: 620, height: 470)
        .disabled(model.preparer.isRunning)
    }
}

private struct GeneralSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Dossier prepare_disk") {
                HStack {
                    Text(model.settings.dataFolder).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choisir…", action: chooseFolder)
                    Button("Afficher") { model.library.reveal(model.settings.dataFolder) }
                }
                Text("Contient OS/MacOS/Intel, OS/MacOS/Silicon, OS/iOS et Others (créés si besoin).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Comportement") {
                Toggle("Chercher les nouvelles versions au lancement", isOn: $model.settings.checkUpdatesAtLaunch)
                Toggle("Notifications à la fin des téléchargements et des préparations", isOn: $model.settings.notificationsEnabled)
                Toggle("Vérifier le SHA-1 des IPSW téléchargés", isOn: $model.settings.verifyChecksums)
                Toggle("Supprimer les anciens IPSW lors d'une mise à jour de disque", isOn: $model.settings.removeOldOnUpdate)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.settings.dataFolder)
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.dataFolder = url.path
            Task { await model.library.scan() }
        }
    }
}

private struct MacOSSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(0..<3, id: \.self) { slot in
                    LabeledContent("macOS \(slot + 1)") { VersionPicker(model: model, slot: slot) }
                }
                HStack {
                    Button("Les 3 derniers macOS") {
                        let picks = model.catalog.latestMajors(3).map(\.version)
                        model.settings.selected = Array((picks + ["", "", ""]).prefix(3))
                        model.checkForUpdates(notify: false)
                    }
                    Button("Dernière version de chacun") { model.useLatestVersions() }
                    Spacer()
                    if model.catalog.isLoadingInstallers { ProgressView().controlSize(.small) }
                    Button("Actualiser") { Task { await model.catalog.loadInstallers() } }
                }
            } header: {
                Text("Versions à installer")
            } footer: {
                Text("Une partition bootable est créée pour chaque version, renommée « version nom » (ex. 15.8.2 Sequoia).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Partitions") {
                Stepper("Taille minimale par partition macOS : \(model.settings.partitionSizeGB) Go",
                        value: $model.settings.partitionSizeGB, in: 14...64)
                Text("Agrandie automatiquement si l'installateur est plus gros. Le reste du disque va à DataExternalDrive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct IPSWSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Mac Apple Silicon") {
                TextField("Identifiant du modèle", text: $model.settings.macIdentifier)
                TextField("Début du nom de fichier", text: $model.settings.macIPSWPrefix)
                HStack {
                    Text("IPSW copiés pour")
                    Spacer()
                    ForEach(0..<3, id: \.self) { slot in
                        Toggle("macOS \(slot + 1)", isOn: $model.settings.macIPSWSlots[slot])
                    }
                }
            }
            Section {
                ForEach($model.settings.devices) { $device in
                    HStack {
                        Toggle("", isOn: $device.enabled).labelsHidden()
                        TextField("Nom (dossier)", text: $device.name)
                        TextField("Identifiant", text: $device.identifier).frame(width: 110)
                        Text(model.catalog.deviceNames[device.identifier] ?? "").font(.caption).foregroundStyle(.secondary)
                            .frame(width: 130, alignment: .leading).lineLimit(1)
                        Button(role: .destructive) { model.settings.devices.removeAll { $0.id == device.id } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Ajouter un iPad") { model.settings.devices.append(Device(name: "Nouvel iPad", identifier: "iPad")) }
                    Button("Valeurs par défaut") { model.settings.devices = Device.defaults }
                    Spacer()
                    Button("Vérifier chez Apple") { Task { await model.refreshFirmwares(); await model.library.scan() } }
                }
            } header: {
                Text("iPad")
            } footer: {
                Text("L'identifiant (ex. iPad13,18) se trouve sur ipsw.me ou dans Apple Configurator.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Version de l'app : vérifier et installer les mises à jour publiées sur GitHub.
private struct UpdateSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        let updater = model.updater
        Form {
            Section("Prepare Disk") {
                LabeledContent("Version installée", value: "v" + updater.currentVersion)
                if !updater.currentNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Nouveautés de cette version").font(.caption.weight(.semibold))
                        Text(bullets(updater.currentNotes)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    status(updater)
                    Spacer()
                    Button("Vérifier les mises à jour") { Task { await updater.check() } }
                        .disabled(isBusy(updater.state))
                }
                if updater.state == .available, let release = updater.release {
                    if !release.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ce qui change dans la v\(release.version)").font(.caption.weight(.semibold))
                            Text(bullets(release.notes)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Button("Mettre à jour vers la version \(release.version) et relancer") { Task { await updater.install() } }
                        .buttonStyle(.borderedProminent)
                }
                if case let .downloading(progress) = updater.state { ProgressView(value: progress) }
            }
            Section {
                Toggle("Mettre à jour automatiquement au lancement", isOn: $model.settings.autoUpdate)
                Link("Toutes les versions sur GitHub", destination: URL(string: "https://github.com/\(Updater.repository)/releases")!)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func status(_ updater: Updater) -> some View {
        switch updater.state {
        case .idle: Text("Pas encore vérifié").foregroundStyle(.secondary)
        case .checking: HStack { ProgressView().controlSize(.small); Text("Vérification…") }
        case .upToDate: Label("À jour", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .available: Label("Version \(updater.release?.version ?? "") disponible", systemImage: "arrow.down.circle.fill").foregroundStyle(.blue)
        case .downloading: Text("Téléchargement…")
        case .installing: HStack { ProgressView().controlSize(.small); Text("Installation…") }
        case let .failed(message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    /// "- texte" (markdown) → "• texte".
    private func bullets(_ text: String) -> String {
        text.components(separatedBy: "\n").map { $0.hasPrefix("- ") ? "• " + $0.dropFirst(2) : $0 }.joined(separator: "\n")
    }

    private func isBusy(_ state: Updater.State) -> Bool {
        switch state { case .checking, .downloading, .installing: return true; default: return false }
    }
}
