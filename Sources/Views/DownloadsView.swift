import SwiftUI

/// File d'attente des téléchargements.
struct DownloadsView: View {
    @Bindable var model: AppModel

    var body: some View {
        List {
            ForEach(model.downloads.jobs.reversed()) { job in
                DownloadRow(model: model, job: job, compact: false).padding(.vertical, 4)
            }
        }
        .overlay {
            if model.downloads.jobs.isEmpty {
                ContentUnavailableView("Aucun téléchargement", systemImage: "arrow.down.circle",
                                       description: Text("Les installateurs macOS et les IPSW téléchargés apparaissent ici."))
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Effacer les terminés") { model.downloads.clearFinished() }
                    .disabled(!model.downloads.jobs.contains { $0.isFinished })
            }
        }
    }
}

struct DownloadRow: View {
    @Bindable var model: AppModel
    let job: DownloadJob
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(job.title).fontWeight(.medium)
                Spacer()
                Text(stateText).font(.caption).foregroundStyle(color)
                if !job.isFinished {
                    Button { model.downloads.cancel(job) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).help("Annuler")
                } else if job.state != .done {
                    Button { model.downloads.retry(job) } label: { Image(systemName: "arrow.clockwise.circle") }
                        .buttonStyle(.borderless).help("Réessayer")
                }
            }
            if job.state == .running || job.state == .verifying {
                ProgressView(value: job.state == .verifying ? nil : job.progress)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    HStack {
                        Text("\((Int64(Double(job.totalBytes) * job.progress)).fileSize) sur \(job.totalBytes.fileSize)")
                        if job.speed > 0 { Text("· \(Int64(job.speed).fileSize)/s") }
                        if let eta = job.eta { Text("· reste \(formatDuration(eta))") }
                    }
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else if !compact, case let .ipsw(_, destination) = job.kind, job.state == .done {
                Button("Afficher dans le Finder") { model.library.reveal(destination) }.controlSize(.small)
            }
        }
    }

    private var stateText: String {
        switch job.state {
        case .queued: return job.retryReason.map { "Échec (\($0)) : nouvel essai \(job.attempt)/\(DownloadJob.maxAttempts)…" } ?? "En attente"
        case .running: return "\(Int(job.progress * 100)) %" + (job.attempt > 1 ? " · essai \(job.attempt)/\(DownloadJob.maxAttempts)" : "")
        case .verifying: return "Vérification SHA-1…"
        case .done: return "Terminé"
        case let .failed(reason): return "Échec : \(reason)" + (job.attempt > 1 ? " (après \(job.attempt) essais)" : "")
        case .cancelled: return "Annulé"
        }
    }

    private var icon: String {
        switch job.state {
        case .queued: return "clock"
        case .running, .verifying: return "arrow.down.circle"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "minus.circle"
        }
    }

    private var color: Color {
        switch job.state {
        case .done: return .green
        case .failed: return .red
        case .running, .verifying: return .accentColor
        default: return .secondary
        }
    }
}
