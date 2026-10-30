import SwiftUI

/// Inspection d'un disque branché et mise à jour sans effacer.
struct DisksView: View {
    @Bindable var model: AppModel
    @State private var selected: String?
    @State private var confirmUpdate = false

    var body: some View {
        HSplitView {
            List(model.disks.disks, selection: $selected) { disk in
                HStack {
                    Image(systemName: "externaldrive.fill").foregroundStyle(disk.looksPrepared ? Color.accentColor : .secondary)
                    VStack(alignment: .leading) {
                        Text(disk.name)
                        Text("\(disk.id) · \(disk.size.fileSize)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(disk.id)
            }
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 300)
            .overlay {
                if model.disks.disks.isEmpty {
                    ContentUnavailableView("Aucun disque", systemImage: "externaldrive.badge.questionmark",
                                           description: Text("Branchez un disque externe."))
                }
            }

            ScrollView {
                if let id = selected, let disk = model.disks.disk(id) {
                    detail(disk).padding(24)
                } else {
                    ContentUnavailableView("Choisissez un disque", systemImage: "externaldrive")
                        .frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .frame(minWidth: 500, maxWidth: .infinity)
        }
        .onAppear { if selected == nil { selected = model.disks.disks.first?.id } }
        .onChange(of: selected) { _, id in
            if let id, model.disks.inspections[id] == nil { Task { await model.disks.inspect(id) } }
        }
        .task(id: selected) {
            if let id = selected, model.disks.inspections[id] == nil { await model.disks.inspect(id) }
        }
        .confirmationDialog("Mettre à jour \(selected ?? "") sans l'effacer ?", isPresented: $confirmUpdate) {
            Button("Mettre à jour") {
                if let id = selected { Task { await model.preparer.update(diskID: id) } }
            }
        } message: {
            Text("Seules les partitions macOS obsolètes sont réécrites. Les autres données sont conservées.")
        }
    }

    @ViewBuilder
    private func detail(_ disk: ExternalDisk) -> some View {
        let inspection = model.disks.inspections[disk.id]
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Image(systemName: "externaldrive.fill").font(.system(size: 36)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(disk.name).font(.title2.weight(.semibold))
                    Text("\(disk.id) · \(disk.size.fileSize) · \(disk.partitions.count) partitions").foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.disks.inspect(disk.id) } } label: { Label("Inspecter", systemImage: "magnifyingglass") }
                Button { Task { _ = await model.disks.eject(disk.id); selected = model.disks.disks.first?.id } } label: {
                    Label("Éjecter", systemImage: "eject")
                }
            }
            .disabled(model.preparer.isRunning)

            PartitionBar(segments: disk.partitions.filter { $0.content != "EFI" }.enumerated().map { i, p in
                PartitionBar.Segment(label: p.name.ifEmpty(p.id), size: p.size,
                                     color: p.name == "DataExternalDrive" ? .green : systemColors[i % systemColors.count])
            }, total: disk.size)

            if model.disks.inspecting.contains(disk.id) {
                HStack { ProgressView().controlSize(.small); Text("Inspection du contenu…") }
            }

            if let inspection {
                if !disk.looksPrepared {
                    Banner(text: "Ce disque n'a pas été préparé par Prepare Disk (pas de partition DataExternalDrive).", color: .blue, icon: "info.circle")
                    Button("Préparer ce disque…") {
                        model.selectedDisks = [disk.id]
                        model.page = .prepare
                    }
                }
                systems(inspection)
                files(inspection)
                if disk.looksPrepared { updateCard(inspection) }
            }

            if model.preparer.phase != .idle && model.preparer.title.contains(disk.id) {
                RunView(model: model, onRestart: { model.preparer.reset() })
            }
        }
    }

    private func systems(_ inspection: DiskInspection) -> some View {
        Card(title: "Installateurs macOS", icon: "apple.logo") {
            if inspection.systems.isEmpty { Text("Aucun installateur sur ce disque.").foregroundStyle(.secondary) }
            ForEach(inspection.systems) { os in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(os.partition.name).fontWeight(.medium)
                        Text("\(os.version ?? "?") \(os.build.map { "(\($0))" } ?? "") · partition de \(os.partition.size.fileSize)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    os.bootable ? Pill(text: "Bootable", color: .green, icon: "power") : Pill(text: "Non bootable", color: .red)
                    os.status.pill
                }
            }
        }
    }

    private func files(_ inspection: DiskInspection) -> some View {
        let categories = inspection.files.reduce(into: [String]()) { if !$0.contains($1.category) { $0.append($1.category) } }
        return Card(title: "DataExternalDrive", icon: "folder",
                    subtitle: inspection.dataFree.map { "\($0.fileSize) libres" }) {
            if inspection.files.isEmpty { Text("Aucun fichier reconnu.").foregroundStyle(.secondary) }
            ForEach(categories, id: \.self) { category in
                VStack(alignment: .leading, spacing: 4) {
                    Text(category).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(inspection.files.filter { $0.category == category }) { file in
                        HStack {
                            Text(file.name).lineLimit(1).truncationMode(.middle)
                            Text(file.size.fileSize).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            signedPill(file.signed)
                            if category != "Others" { file.status.pill }
                        }
                    }
                }
            }
        }
    }

    private func updateCard(_ inspection: DiskInspection) -> some View {
        let replacements = model.preparer.updateTargets(inspection)
        let tooSmall = model.preparer.tooSmall(inspection)
        let missing = model.preparer.missingItems(inspection)
        let obsolete = model.settings.removeOldOnUpdate ? inspection.outdatedFiles : []
        let nothing = replacements.isEmpty && missing.isEmpty && obsolete.isEmpty
        return Card(title: "Mise à jour sans effacer", icon: "arrow.triangle.2.circlepath") {
            if nothing && tooSmall.isEmpty {
                Label("Ce disque est à jour par rapport aux versions choisies.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            }
            ForEach(replacements, id: \.0.id) { os, installer in
                Label("Remplacer « \(os.partition.name) » par macOS \(installer.name) \(installer.version)", systemImage: "arrow.right.circle")
            }
            ForEach(tooSmall) { os in
                Banner(text: "« \(os.partition.name) » est trop petite pour la nouvelle version : il faut effacer et repréparer le disque.")
            }
            ForEach(missing) { item in
                Label("Ajouter \(item.label) (\(item.size.fileSize))", systemImage: "plus.circle")
            }
            ForEach(obsolete) { file in
                Label("Supprimer \(file.name)", systemImage: "minus.circle").foregroundStyle(.secondary)
            }
            if !nothing {
                Button {
                    confirmUpdate = true
                } label: {
                    Label("Mettre à jour le disque", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.preparer.isRunning)
            }
        }
    }
}
