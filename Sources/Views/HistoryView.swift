import SwiftUI

/// Disques préparés ou mis à jour, avec leur rapport et leur journal.
struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var selected: HistoryEntry.ID?

    var body: some View {
        HSplitView {
            List(model.history.entries, selection: $selected) { entry in
                HStack {
                    Image(systemName: entry.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(entry.success ? .green : .orange)
                    VStack(alignment: .leading) {
                        Text("\(entry.kind) — \(entry.disks.joined(separator: ", "))").lineLimit(1)
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(entry.id)
                .contextMenu {
                    Button("Supprimer de l'historique", role: .destructive) { model.history.remove(entry) }
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            .overlay {
                if model.history.entries.isEmpty {
                    ContentUnavailableView("Aucun disque préparé", systemImage: "clock.arrow.circlepath")
                }
            }

            ScrollView {
                if let entry = model.history.entries.first(where: { $0.id == selected }) {
                    detail(entry).padding(24)
                } else {
                    ContentUnavailableView("Choisissez une préparation", systemImage: "clock")
                        .frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity)
        }
        .onAppear { if selected == nil { selected = model.history.entries.first?.id } }
    }

    private func detail(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(entry.success ? "Réussie" : "Terminée avec des erreurs",
                  systemImage: entry.success ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold)).foregroundStyle(entry.success ? .green : .orange)
            Card(title: "Résumé", icon: "info.circle") {
                InfoRow(label: "Date", value: entry.date.formatted(date: .complete, time: .shortened))
                InfoRow(label: "Opération", value: entry.kind)
                InfoRow(label: "Durée", value: formatDuration(entry.duration))
                InfoRow(label: "Disques", value: entry.disks.joined(separator: "\n"))
                InfoRow(label: "macOS", value: entry.versions.joined(separator: "\n").ifEmpty("—"))
                InfoRow(label: "Fichiers", value: entry.extras.joined(separator: "\n").ifEmpty("—"))
            }
            if !entry.checks.isEmpty {
                Card(title: "Vérification", icon: "checklist") { ChecksList(checks: entry.checks) }
            }
            Card(title: "Journal", icon: "text.alignleft") {
                Button("Exporter…") {
                    saveText(model.history.log(of: entry),
                             suggestedName: "PrepareDisk \(entry.date.formatted(.iso8601.year().month().day())).log")
                }
                .controlSize(.small)
            } content: {
                Text(model.history.log(of: entry))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(400)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
