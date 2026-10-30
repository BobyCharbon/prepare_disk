import SwiftUI

/// Une ligne du comparatif : ce qui est sur le disque, ce qui est réglé sur ce Mac, la dernière version Apple.
struct ComparisonRow: Identifiable {
    let label: String
    let icon: String
    let onDisk: String?
    let configured: String?     // nil = non choisi dans les réglages
    let latest: String?
    var note: String?
    var id: String { label }

    enum State { case ok, differs, missing, extra }
    var state: State {
        guard let configured else { return .extra }
        guard let onDisk else { return .missing }
        return onDisk == configured ? .ok : .differs
    }
    var newerAtApple: Bool {
        guard let latest, let configured else { return false }
        return latest.isNewerVersion(than: configured)
    }
}

/// Compare le contenu d'un disque aux réglages de ce Mac et aux dernières versions d'Apple.
@MainActor
func comparisonRows(_ inspection: DiskInspection, model: AppModel) -> [ComparisonRow] {
    let settings = model.settings, catalog = model.catalog
    let newestFirst: (String, String) -> Bool = { $0.isNewerVersion(than: $1) }
    var rows: [ComparisonRow] = []

    // macOS : chaque version choisie, puis les partitions qui ne correspondent à aucun choix.
    var matched = Set<String>()
    for version in settings.selected where !version.isEmpty {
        let os = inspection.systems.first { $0.version == version }
            ?? inspection.systems.first { $0.version?.majorVersion == version.majorVersion }
        if let os { matched.insert(os.id) }
        let name = catalog.installer(version: version)?.name ?? version.majorVersion
        rows.append(ComparisonRow(label: "macOS \(name)", icon: "apple.logo", onDisk: os.map { $0.version ?? "?" },
                                  configured: version, latest: catalog.latestInstaller(major: version.majorVersion)?.version,
                                  note: os.flatMap { $0.bootable ? nil : "non bootable" }))
    }
    for os in inspection.systems where !matched.contains(os.id) {
        rows.append(ComparisonRow(label: "macOS « \(os.partition.name) »", icon: "apple.logo", onDisk: os.version ?? "?",
                                  configured: nil, latest: os.version.flatMap { catalog.latestInstaller(major: $0.majorVersion)?.version }))
    }

    // IPSW Mac Apple Silicon, un par macOS choisi.
    let macFiles = inspection.files.filter { $0.category == "Mac Apple Silicon" }.compactMap { $0.name.versionInName }.sorted(by: newestFirst)
    for (slot, version) in settings.selected.enumerated() where !version.isEmpty {
        let wanted = settings.includeMacIPSW && settings.macIPSWSlots[slot]
            ? (catalog.macFirmware(identifier: settings.macIdentifier, version: version, pinned: settings.macIPSWVersions[slot])?.version
               ?? settings.macIPSWVersions[slot].ifEmpty(version))
            : nil
        let onDisk = macFiles.first { $0 == wanted } ?? macFiles.first { $0.majorVersion == version.majorVersion }
        guard wanted != nil || onDisk != nil else { continue }
        let latest = catalog.signedFirmwares(identifier: settings.macIdentifier).first { $0.version.majorVersion == version.majorVersion }
        rows.append(ComparisonRow(label: "IPSW Mac · macOS \(version.majorVersion)", icon: "laptopcomputer",
                                  onDisk: onDisk, configured: wanted, latest: latest?.version))
    }

    // IPSW iPad
    for device in settings.devices {
        let files = inspection.files.filter { $0.category == device.name }.compactMap { $0.name.versionInName }.sorted(by: newestFirst)
        let wanted = settings.includeIPadIPSW && device.enabled ? (catalog.iPadFirmware(device)?.version ?? device.version) : nil
        let onDisk = files.first { $0 == wanted } ?? files.first
        guard wanted != nil || onDisk != nil else { continue }
        rows.append(ComparisonRow(label: device.name, icon: "ipad", onDisk: onDisk, configured: wanted,
                                  latest: catalog.latestSigned(identifier: device.identifier)?.version,
                                  note: files.count > 1 ? "\(files.count) fichiers" : nil))
    }

    // Loops GarageBand
    let loops = inspection.files.contains { $0.category == "Others" && $0.name.localizedCaseInsensitiveContains("loop") }
    if settings.includeLoops || loops {
        rows.append(ComparisonRow(label: "Loops GarageBand", icon: "music.note", onDisk: loops ? "Présentes" : nil,
                                  configured: settings.includeLoops ? "Présentes" : nil, latest: nil))
    }
    return rows
}

/// Tableau « sur le disque / réglé sur ce Mac / dernière Apple » d'un disque déjà préparé.
struct DiskComparison: View {
    @Bindable var model: AppModel
    let disk: ExternalDisk

    var body: some View {
        if let inspection = model.disks.inspections[disk.id] {
            let rows = comparisonRows(inspection, model: model)
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("")
                        Text("Élément")
                        Text("Sur le disque")
                        Text("Réglé sur ce Mac")
                        Text("Dernière chez Apple")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(rows) { row in
                        GridRow {
                            stateIcon(row.state)
                            Label(row.label, systemImage: row.icon).lineLimit(1)
                            HStack(spacing: 4) {
                                Text(row.onDisk ?? "Absent").foregroundStyle(row.onDisk == nil ? .secondary : .primary)
                                if let note = row.note { Text("(\(note))").foregroundStyle(.orange) }
                            }
                            Text(row.configured ?? "Non choisi").foregroundStyle(row.configured == nil ? .secondary : .primary)
                            HStack(spacing: 4) {
                                Text(row.latest ?? "—").foregroundStyle(.secondary)
                                if row.newerAtApple { Pill(text: "Plus récent", color: .blue, icon: "sparkles") }
                            }
                        }
                    }
                }
                .font(.callout)
                Text(footer(inspection, rows: rows)).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        } else if model.disks.inspecting.contains(disk.id) {
            HStack { ProgressView().controlSize(.small); Text("Lecture du contenu du disque…").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func stateIcon(_ state: ComparisonRow.State) -> some View {
        let (name, color): (String, Color) = switch state {
        case .ok: ("checkmark.circle.fill", .green)
        case .differs: ("arrow.triangle.2.circlepath.circle.fill", .orange)
        case .missing: ("xmark.circle.fill", .red)
        case .extra: ("minus.circle", .secondary)
        }
        return Image(systemName: name).foregroundStyle(color)
    }

    private func footer(_ inspection: DiskInspection, rows: [ComparisonRow]) -> String {
        var parts = ["\(inspection.systems.count) partition(s) macOS"]
        if let free = inspection.dataFree { parts.append("DataExternalDrive : \(free.fileSize) libres") }
        let newer = rows.filter(\.newerAtApple).count
        if newer > 0 { parts.append("\(newer) version(s) plus récente(s) chez Apple que vos réglages") }
        return parts.joined(separator: " · ")
    }
}

/// Résumé pour la pastille : à jour, ou nombre d'éléments à changer.
@MainActor
func comparisonSummary(_ inspection: DiskInspection?, model: AppModel) -> (text: String, color: Color)? {
    guard let inspection else { return nil }
    let todo = comparisonRows(inspection, model: model).filter { $0.state == .differs || $0.state == .missing }.count
    return todo == 0 ? ("Conforme aux réglages", .green) : ("\(todo) différence\(todo > 1 ? "s" : "") avec les réglages", .orange)
}
