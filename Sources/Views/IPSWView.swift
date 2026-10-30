import SwiftUI

/// IPSW Mac Apple Silicon, IPSW iPad et loops GarageBand.
struct IPSWView: View {
    @Bindable var model: AppModel
    @State private var importing = false
    @State private var pendingTrash: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.catalog.isLoadingFirmwares { HStack { ProgressView().controlSize(.small); Text("Lecture des IPSW chez Apple…") } }
                if let error = model.catalog.firmwaresError { Banner(text: error) }
                SuggestionsCard(model: model, installers: false)
                macCard
                ForEach(model.settings.devices) { iPadCard($0) }
                loopsCard
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem {
                Button { downloadAllMissing() } label: { Label("Tout télécharger", systemImage: "arrow.down.circle") }
                    .help("Télécharge les IPSW manquants pour les versions choisies et la dernière version de chaque iPad")
            }
        }
        .confirmationDialog("Mettre \(pendingTrash.count) fichier(s) à la corbeille ?", isPresented: Binding(
            get: { !pendingTrash.isEmpty }, set: { if !$0 { pendingTrash = [] } })) {
            Button("Mettre à la corbeille", role: .destructive) {
                let paths = pendingTrash
                pendingTrash = []
                Task { await model.library.trash(paths) }
            }
        } message: {
            Text(pendingTrash.map { ($0 as NSString).lastPathComponent }.joined(separator: "\n"))
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .diskImage, .item]) { result in
            if case let .success(url) = result {
                Task {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    try? await model.library.importLoops(from: url)
                }
            }
        }
    }

    // MARK: Mac

    private var macCard: some View {
        let settings = model.settings
        let wanted = settings.selected.indices.filter { !settings.selected[$0].isEmpty }
            .compactMap { model.catalog.macFirmware(identifier: settings.macIdentifier, version: settings.selected[$0],
                                                    pinned: settings.macIPSWVersions[$0])?.version }
        let old = model.library.macIPSWs.filter { !wanted.contains($0.version ?? "") }
        return Card(title: "Mac Apple Silicon", icon: "laptopcomputer",
                    subtitle: "\(model.catalog.deviceNames[settings.macIdentifier] ?? settings.macIdentifier) · \(settings.siliconFolder)") {
            Button("Afficher") { model.library.reveal(settings.siliconFolder) }.controlSize(.small)
        } content: {
            ForEach(Array(settings.selected.enumerated()).filter { !$0.element.isEmpty }, id: \.offset) { slot, version in
                let fw = model.catalog.macFirmware(identifier: settings.macIdentifier, version: version, pinned: settings.macIPSWVersions[slot])
                let destination = settings.macIPSWPath(fw?.version ?? version)
                FirmwareRow(model: model, title: "Pour macOS \(version)", firmware: fw,
                            local: model.library.macIPSW(version: fw?.version ?? version), destination: destination,
                            note: settings.macIPSWSlots[slot] ? nil : "non copié sur le disque")
            }
            if !old.isEmpty {
                Divider()
                OldFiles(files: old, signed: { f in f.version.flatMap { model.catalog.firmware(identifier: settings.macIdentifier, version: $0)?.signed } },
                         onTrash: { pendingTrash = $0 })
            }
        }
    }

    // MARK: iPad

    private func iPadCard(_ device: Device) -> some View {
        let latest = model.catalog.iPadFirmware(device)
        let files = model.library.iPadIPSWs[device.name] ?? []
        let old = files.filter { $0.version != latest?.version }
        return Card(title: device.name, icon: "ipad",
                    subtitle: "\(model.catalog.deviceNames[device.identifier] ?? "") \(device.identifier)\(device.enabled ? "" : " · désactivé")") {
            Button("Afficher") { model.library.reveal(model.settings.folder(for: device)) }.controlSize(.small)
        } content: {
            FirmwareRow(model: model, title: device.version == nil ? "Dernière version signée" : "Version choisie", firmware: latest,
                        local: files.first { $0.version == latest?.version },
                        destination: latest.map { model.settings.ipswPath(device, $0.version) } ?? "",
                        note: nil)
            if !old.isEmpty {
                Divider()
                OldFiles(files: old, signed: { f in f.version.flatMap { model.catalog.firmware(identifier: device.identifier, version: $0)?.signed } },
                         onTrash: { pendingTrash = $0 })
            }
        }
        .opacity(device.enabled ? 1 : 0.6)
    }

    // MARK: Loops

    private var loopsCard: some View {
        Card(title: "Loops GarageBand", icon: "music.note", subtitle: model.settings.othersFolder) {
            Toggle("Copier sur les disques", isOn: $model.settings.includeLoops).toggleStyle(.switch).controlSize(.small)
        } content: {
            ForEach(model.library.loops) { file in
                HStack {
                    Image(systemName: "doc.zipper")
                    Text(file.name)
                    Text(file.size.fileSize).foregroundStyle(.secondary)
                    Spacer()
                    Button("Afficher") { model.library.reveal(file.path) }.controlSize(.small)
                    Button(role: .destructive) { pendingTrash = [file.path] } label: { Image(systemName: "trash") }.controlSize(.small)
                }
            }
            if model.library.loops.isEmpty {
                Text("Aucun fichier de loops (nom contenant « loop »).").foregroundStyle(.secondary)
            }
            Button("Importer un fichier de loops…") { importing = true }
        }
    }

    private func downloadAllMissing() {
        let settings = model.settings
        for (slot, version) in settings.selected.enumerated() where !version.isEmpty {
            if let fw = model.catalog.macFirmware(identifier: settings.macIdentifier, version: version, pinned: settings.macIPSWVersions[slot]),
               fw.signed, model.library.macIPSW(version: fw.version) == nil {
                model.downloads.enqueue(.ipsw(fw, destination: settings.macIPSWPath(fw.version)))
            }
        }
        for device in settings.enabledDevices {
            if let fw = model.catalog.iPadFirmware(device), fw.signed,
               !(model.library.iPadIPSWs[device.name] ?? []).contains(where: { $0.version == fw.version }) {
                model.downloads.enqueue(.ipsw(fw, destination: settings.ipswPath(device, fw.version)))
            }
        }
        model.page = .downloads
    }
}

private struct FirmwareRow: View {
    @Bindable var model: AppModel
    let title: String
    let firmware: Firmware?
    let local: LocalFile?
    let destination: String
    let note: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                if let firmware {
                    Text("\(firmware.version) (\(firmware.buildid)) · \(firmware.filesize.fileSize)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Aucun IPSW connu chez Apple").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let firmware { signedPill(firmware.signed) }
            if let note { Pill(text: note, color: .secondary) }
            Spacer()
            if let local {
                Pill(text: "Téléchargé", color: .green, icon: "checkmark.circle")
                Button("Afficher") { model.library.reveal(local.path) }.controlSize(.small)
            } else if let firmware {
                if let job = model.downloads.active.first(where: { $0.key == "ipsw-" + firmware.id + destination }) {
                    ProgressView(value: job.progress).frame(width: 120)
                    Button("Annuler") { model.downloads.cancel(job) }.controlSize(.small)
                } else if firmware.signed {
                    Button("Télécharger") { model.downloads.enqueue(.ipsw(firmware, destination: destination)) }.controlSize(.small)
                } else {
                    Pill(text: "Plus signé : choisissez une autre version", color: .red, icon: "nosign")
                }
            }
        }
    }
}

/// Anciens fichiers locaux, avec leur état de signature.
private struct OldFiles: View {
    let files: [LocalFile]
    let signed: (LocalFile) -> Bool?
    let onTrash: ([String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Autres fichiers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Supprimer les anciens") { onTrash(files.map(\.path)) }.controlSize(.small)
            }
            ForEach(files) { file in
                HStack {
                    Text(file.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Text(file.size.fileSize).font(.caption).foregroundStyle(.secondary)
                    signedPill(signed(file))
                    Spacer()
                    Button(role: .destructive) { onTrash([file.path]) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }
}
