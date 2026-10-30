import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.page) {
                Section("Versions") { row(.versions) }
                Section("Préparation des disques bootables") { row(.prepare); row(.disks) }
                Section("Contenu") { row(.library); row(.ipsw) }
                Section("Suivi") { row(.downloads); row(.history); row(.log) }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    UpdateFooter(model: model)
                    statusFooter
                    // Numéro de version, toujours visible en bas à gauche.
                    Text("Prepare Disk v\(model.updater.currentVersion)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                }
            }
        } detail: {
            detail
                // Les réglages manquants, en rouge, tout en haut de chaque page.
                .safeAreaInset(edge: .top) {
                    SetupChecklist(model: model).padding([.horizontal, .top], 16).frame(maxWidth: 932)
                }
                .navigationTitle(model.page.title)
                .toolbar {
                    ToolbarItem {
                        Button { Task { await model.refreshAll() } } label: {
                            Label("Actualiser", systemImage: "arrow.clockwise")
                        }
                        .help("Actualiser les versions Apple, les fichiers locaux et les disques (⌘R)")
                        .disabled(model.preparer.isRunning)
                    }
                }
        }
    }

    private func row(_ page: Page) -> some View {
        Label(page.title, systemImage: page.icon)
            .badge(badge(for: page))
            .tag(page)
    }

    private func badge(for page: Page) -> Int {
        switch page {
        case .downloads: return model.downloads.active.count + model.downloads.external.count
        case .disks: return model.disks.disks.count
        case .library: return model.library.suggestions.filter(\.isInstaller).count
        case .ipsw: return model.library.suggestions.filter { !$0.isInstaller }.count
        default: return 0
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.page {
        case .prepare: PrepareView(model: model)
        case .versions: VersionsView(model: model)
        case .library: LibraryView(model: model)
        case .ipsw: IPSWView(model: model)
        case .disks: DisksView(model: model)
        case .downloads: DownloadsView(model: model)
        case .history: HistoryView(model: model)
        case .log: LogView(model: model)
        }
    }

    /// Activité en cours, visible depuis toutes les pages.
    @ViewBuilder
    private var statusFooter: some View {
        let preparer = model.preparer
        if preparer.isRunning || model.downloads.current != nil || !model.downloads.external.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if preparer.isRunning {
                    Text(preparer.title).font(.caption.weight(.semibold))
                    ProgressView(value: preparer.progress).controlSize(.small)
                    Text(preparer.currentStep).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else if let job = model.downloads.current {
                    Text(job.title).font(.caption.weight(.semibold)).lineLimit(1)
                    ProgressView(value: job.progress).controlSize(.small)
                } else if let other = model.downloads.external.first {
                    Text(other.title).font(.caption.weight(.semibold)).lineLimit(1)
                    ProgressView(value: other.progress).controlSize(.small)
                    Text("en arrière-plan").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
        }
    }
}

/// Mise à jour de l'app : disponible, en cours, ou résultat d'une recherche manuelle.
private struct UpdateFooter: View {
    @Bindable var model: AppModel

    var body: some View {
        let updater = model.updater
        let content: AnyView? = switch updater.state {
        case .available:
            AnyView(VStack(alignment: .leading, spacing: 6) {
                Label("Version \(updater.release?.version ?? "") disponible", systemImage: "arrow.down.app.fill").font(.caption.weight(.semibold))
                if let notes = updater.release?.notes, !notes.isEmpty {
                    Text(notes).font(.caption2).foregroundStyle(.secondary).lineLimit(4)
                }
                Button("Installer et relancer") { Task { await updater.install() } }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                    .disabled(model.preparer.isRunning)
            })
        case let .downloading(progress):
            AnyView(VStack(alignment: .leading) {
                Text("Mise à jour de Prepare Disk…").font(.caption.weight(.semibold))
                ProgressView(value: progress).controlSize(.small)
            })
        case .installing, .checking:
            AnyView(HStack { ProgressView().controlSize(.small); Text(updater.state == .checking ? "Recherche de mise à jour…" : "Installation…").font(.caption) })
        case .upToDate:
            AnyView(Label("Prepare Disk \(updater.currentVersion) est à jour", systemImage: "checkmark.circle").font(.caption))
        case let .failed(message):
            AnyView(Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange))
        case .idle:
            nil
        }
        if let content {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .padding([.horizontal, .top], 10)
        }
    }
}
