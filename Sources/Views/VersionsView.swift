import SwiftUI

/// Les versions validées, toutes au même endroit et modifiables en un clic.
struct VersionsView: View {
    @Bindable var model: AppModel
    @State private var organizing = false

    var body: some View {
        let settings = model.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let items = checklist()
                let toDownload = items.compactMap(\.download)
                HStack(alignment: .top) {
                    Text("Les versions validées par l'entreprise. Dès qu'une nouvelle version est validée, changez-la ici : elle sert à préparer les disques et à les comparer.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { toDownload.forEach { model.downloads.enqueue($0) } } label: {
                        Label(toDownload.isEmpty ? "Tout est téléchargé" : "Tout télécharger (\(toDownload.count))", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(toDownload.isEmpty)
                    .help("Télécharge tout ce qui manque et le range dans ~/prepare_disk. Un téléchargement raté recommence tout seul.")
                }
                ForEach(model.updateNotices, id: \.self) { Banner(text: $0, color: .blue, icon: "sparkles") }
                ForEach(model.preparer.plan().blocked, id: \.self) { Banner(text: $0, color: .red, icon: "nosign") }

                Card(title: "macOS", icon: "apple.logo", subtitle: "Une partition bootable par version") {
                    if model.catalog.isLoadingInstallers { ProgressView().controlSize(.small) }
                } content: {
                    ForEach(0..<3, id: \.self) { slot in macOSRow(slot) }
                    HStack {
                        Button("Les 3 derniers macOS") {
                            model.settings.selected = Array((model.catalog.latestMajors(3).map(\.version) + ["", "", ""]).prefix(3))
                            model.checkForUpdates(notify: false)
                        }
                        Button("Dernière version de chacun") { model.useLatestVersions() }
                        Spacer()
                        Button("Vérifier chez Apple") { Task { await model.refreshAll() } }
                    }
                    .controlSize(.small)
                }

                Card(title: "IPSW Mac Apple Silicon", icon: "laptopcomputer", subtitle: "Seules les versions encore signées par Apple sont proposées") {
                    Toggle("", isOn: $model.settings.includeMacIPSW).toggleStyle(.switch).labelsHidden()
                } content: {
                    if settings.includeMacIPSW {
                        ForEach(0..<3, id: \.self) { slot in
                            if !settings.selected[slot].isEmpty { MacIPSWRow(model: model, slot: slot, version: settings.selected[slot]) }
                        }
                    }
                }

                Card(title: "IPSW iPad", icon: "ipad", subtitle: "Une version par génération — « Dernière signée » suit Apple automatiquement") {
                    Toggle("", isOn: $model.settings.includeIPadIPSW).toggleStyle(.switch).labelsHidden()
                } content: {
                    if settings.includeIPadIPSW {
                        ForEach($model.settings.devices) { $device in IPadRow(model: model, device: $device) }
                        if model.catalog.isLoadingFirmwares { ProgressView().controlSize(.small) }
                        if let error = model.catalog.firmwaresError { Banner(text: error) }
                    }
                }

                Card(title: "Loops GarageBand", icon: "music.note", subtitle: "Copiées sur les disques ou non") {
                    Toggle("", isOn: $model.settings.includeLoops).toggleStyle(.switch).labelsHidden()
                } content: { EmptyView() }

                summary(items)
                Toggle("Mettre les anciennes versions à la corbeille dès que les nouvelles sont téléchargées",
                       isOn: $model.settings.removeOldVersions)
                    .font(.callout)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func macOSRow(_ slot: Int) -> some View {
        let version = model.settings.selected[slot]
        let latest = version.isEmpty ? nil : model.catalog.latestInstaller(major: version.majorVersion)
        return HStack {
            Text("macOS \(slot + 1)").frame(width: 70, alignment: .leading)
            VersionPicker(model: model, slot: slot).frame(width: 260)
            Spacer()
            if !version.isEmpty {
                LatestPill(chosen: version, latest: latest?.version)
                if let local = model.library.installer(for: version) {
                    local.path.hasPrefix(model.settings.intelFolder + "/")
                        ? Pill(text: "Sur ce Mac", color: .green, icon: "checkmark.circle")
                        : Pill(text: "Sur ce Mac, à ranger", color: .orange, icon: "tray.and.arrow.down")
                } else {
                    Pill(text: "Sera téléchargé", color: .orange, icon: "arrow.down.circle")
                }
            }
        }
    }

    // MARK: Bilan

    /// Un élément validé et coché : sur ce Mac au bon endroit, sur ce Mac ailleurs, ou à télécharger.
    private struct Needed: Identifiable {
        enum State { case ok, misplaced, missing }
        let label: String
        let state: State
        var download: DownloadJob.Kind?
        var id: String { label }
    }

    private func checklist() -> [Needed] {
        let settings = model.settings, catalog = model.catalog, library = model.library
        func inFolder(_ path: String?, _ folder: String) -> Needed.State {
            guard let path else { return .missing }
            return path.hasPrefix(folder + "/") ? .ok : .misplaced
        }
        var items: [Needed] = []
        for version in settings.selected where !version.isEmpty {
            let state = inFolder(library.installer(for: version)?.path, settings.intelFolder)
            items.append(Needed(label: "macOS \(version)", state: state,
                                download: state == .missing ? catalog.installer(version: version).map { .macOS($0) } : nil))
        }
        if settings.includeMacIPSW {
            for (slot, version) in settings.selected.enumerated() where !version.isEmpty && settings.macIPSWSlots[slot] {
                guard let fw = catalog.macFirmware(identifier: settings.macIdentifier, version: version,
                                                   pinned: settings.macIPSWVersions[slot]), fw.signed else { continue }
                let state = inFolder(library.macIPSW(version: fw.version)?.path, settings.siliconFolder)
                items.append(Needed(label: "IPSW Mac \(fw.version)", state: state,
                                    download: state == .missing ? .ipsw(fw, destination: settings.macIPSWPath(fw.version)) : nil))
            }
        }
        if settings.includeIPadIPSW {
            for device in settings.enabledDevices {
                guard let fw = catalog.iPadFirmware(device), fw.signed else { continue }
                let local = library.iPadIPSWs[device.name]?.first { $0.version == fw.version }
                let state = inFolder(local?.path, settings.folder(for: device))
                items.append(Needed(label: "\(device.name) \(fw.version)", state: state,
                                    download: state == .missing ? .ipsw(fw, destination: settings.ipswPath(device, fw.version)) : nil))
            }
        }
        if settings.includeLoops {
            items.append(Needed(label: "Loops GarageBand", state: library.loops.isEmpty ? .missing : .ok))
        }
        return items
    }

    /// Bandeau du bas : vert si tout est sur ce Mac et bien rangé, sinon ce qui manque.
    @ViewBuilder
    private func summary(_ items: [Needed]) -> some View {
        let missing = items.filter { $0.state == .missing }
        let misplaced = items.filter { $0.state == .misplaced }
        let downloading = model.downloads.active.count
        let old = model.obsoleteFiles()
        if !old.isEmpty {
            HStack {
                Banner(text: "Anciennes versions encore sur ce Mac : " + old.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") + ".",
                       color: .secondary, icon: "clock.arrow.circlepath")
                Button("Mettre à la corbeille") { Task { await model.library.trash(old) } }
            }
        }
        if missing.isEmpty && misplaced.isEmpty {
            Banner(text: "Toutes les versions validées sont sur ce Mac et rangées au bon endroit (\(items.count) éléments).",
                   color: .green, icon: "checkmark.circle.fill")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if downloading > 0 {
                    Banner(text: "\(downloading) téléchargement(s) en cours : la page se met à jour dès qu'ils sont terminés.",
                           color: .blue, icon: "arrow.down.circle")
                }
                if !missing.isEmpty {
                    Banner(text: "Manquant : " + missing.map(\.label).joined(separator: ", ") + ".")
                }
                if let error = model.library.moveError { Banner(text: error, color: .red, icon: "xmark.octagon") }
                if !misplaced.isEmpty {
                    HStack {
                        Banner(text: "Sur ce Mac mais pas dans ~/prepare_disk : " + misplaced.map(\.label).joined(separator: ", ") + ".")
                        if organizing {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Tout ranger") {
                                organizing = true
                                Task { await model.library.organize(model.library.suggestions); organizing = false }
                            }
                            .help("Déplace tout dans ~/prepare_disk et renomme « Modèle - Version ». Un seul mot de passe pour les installateurs.")
                        }
                    }
                }
            }
        }
    }
}
