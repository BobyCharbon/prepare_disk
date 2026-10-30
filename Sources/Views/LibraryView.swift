import SwiftUI

/// Installateurs macOS présents sur ce Mac et versions proposées par Apple.
struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var selection: Set<String> = []
    @State private var confirmTrash = false

    var body: some View {
        VStack(spacing: 0) {
            if model.library.suggestions.contains(where: \.isInstaller) || model.library.moveError != nil {
                SuggestionsCard(model: model, installers: true).padding(16)
            }
            localTable
            Divider()
            available
        }
        .toolbar {
            ToolbarItemGroup {
                Button { Task { for item in selectedItems { await model.library.verifySignature(item) } } } label: {
                    Label("Vérifier la signature", systemImage: "checkmark.seal")
                }
                .disabled(selection.isEmpty)
                Button { selectedItems.forEach { model.library.reveal($0.path) } } label: {
                    Label("Afficher dans le Finder", systemImage: "folder")
                }
                .disabled(selection.isEmpty)
                Button(role: .destructive) { confirmTrash = true } label: {
                    Label("Mettre à la corbeille", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            }
        }
        .confirmationDialog("Mettre \(selection.count) installateur(s) à la corbeille ?", isPresented: $confirmTrash) {
            Button("Mettre à la corbeille", role: .destructive) {
                let paths = Array(selection)
                selection = []
                Task { await model.library.trash(paths) }
            }
        }
    }

    private var selectedItems: [LocalInstaller] {
        model.library.installers.filter { selection.contains($0.id) }
    }

    private var localTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sur ce Mac").font(.headline)
                if model.library.isScanning { ProgressView().controlSize(.small) }
                Spacer()
                Text("/Applications et \(model.settings.intelFolder)").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Table(model.library.installers, selection: $selection) {
                TableColumn("Nom") { item in
                    HStack {
                        Image(systemName: "apple.logo").foregroundStyle(.secondary)
                        Text(item.name)
                        if model.settings.selected.contains(item.version ?? "-") { Pill(text: "Choisi", color: .blue) }
                    }
                }
                TableColumn("Version") { Text($0.version ?? "?") }.width(80)
                TableColumn("Build") { Text($0.build ?? "") }.width(70)
                TableColumn("Taille") { Text($0.size.fileSize) }.width(80)
                TableColumn("Date") { Text($0.date, format: .dateTime.day().month().year()) }.width(90)
                TableColumn("Signature") { item in signature(item) }.width(150)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Afficher dans le Finder") { ids.forEach(model.library.reveal) }
                Button("Vérifier la signature") {
                    Task { for item in model.library.installers where ids.contains(item.id) { await model.library.verifySignature(item) } }
                }
                Divider()
                Button("Mettre à la corbeille", role: .destructive) { selection = ids; confirmTrash = true }
            }
            .overlay {
                if model.library.installers.isEmpty && !model.library.isScanning {
                    ContentUnavailableView("Aucun installateur", systemImage: "shippingbox",
                                           description: Text("Téléchargez une version ci-dessous ou depuis l'assistant."))
                }
            }
        }
        .frame(minHeight: 220)
    }

    @ViewBuilder
    private func signature(_ item: LocalInstaller) -> some View {
        switch model.library.signatures[item.path] ?? .unknown {
        case .unknown: Text("Non vérifiée").foregroundStyle(.secondary)
        case .checking: HStack { ProgressView().controlSize(.mini); Text("Vérification…") }
        case let .valid(authority): Pill(text: "Apple", color: .green, icon: "checkmark.seal").help(authority)
        case let .invalid(reason): Pill(text: "Invalide", color: .red, icon: "xmark.seal").help(reason)
        }
    }

    private var available: some View {
        let installers = model.catalog.installers
        let majors = installers.reduce(into: [String]()) { if !$0.contains($1.major) { $0.append($1.major) } }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Disponibles chez Apple").font(.headline)
                if model.catalog.isLoadingInstallers { ProgressView().controlSize(.small) }
                Spacer()
                if let date = model.catalog.lastCheck {
                    Text("Vérifié à \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            List {
                ForEach(majors, id: \.self) { major in
                    Section(installers.first { $0.major == major }.map { "macOS \($0.name) (\(major))" } ?? major) {
                        ForEach(installers.filter { $0.major == major }) { AvailableRow(model: model, installer: $0) }
                    }
                }
            }
        }
    }
}

private struct AvailableRow: View {
    @Bindable var model: AppModel
    let installer: Installer

    var body: some View {
        let isLatest = model.catalog.latestInstaller(major: installer.major)?.version == installer.version
        HStack {
            Text(installer.version).fontWeight(.medium).frame(width: 70, alignment: .leading)
            Text(installer.build).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(installer.sizeText).foregroundStyle(.secondary)
            if isLatest { Pill(text: "Dernière", color: .blue) }
            if model.settings.selected.contains(installer.version) { Pill(text: "Choisi", color: .purple) }
            Spacer()
            if model.library.installer(for: installer.version) != nil {
                Pill(text: "Téléchargé", color: .green, icon: "checkmark.circle")
            } else if let job = model.downloads.active.first(where: { $0.key == "macos-" + installer.version }) {
                ProgressView(value: job.progress).frame(width: 120)
                Button("Annuler") { model.downloads.cancel(job) }.controlSize(.small)
            } else {
                Button("Télécharger") { model.downloads.enqueue(.macOS(installer)) }.controlSize(.small)
            }
        }
    }
}
