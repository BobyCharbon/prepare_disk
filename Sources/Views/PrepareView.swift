import SwiftUI
import UniformTypeIdentifiers

/// Assistant en 5 étapes : versions, contenu, disques, récapitulatif, création.
struct PrepareView: View {
    @Bindable var model: AppModel
    @State private var confirmErase = false

    /// Gardée dans le modèle pour revenir à la même étape après être passé sur une autre page.
    private var step: Int {
        get { model.wizardStep }
        nonmutating set { model.wizardStep = newValue }
    }

    private let steps = ["Versions", "Contenu", "Disques", "Récapitulatif", "Création"]

    var body: some View {
        VStack(spacing: 0) {
            stepper
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch currentStep {
                    case 0: VersionsStep(model: model)
                    case 1: ContentStep(model: model)
                    case 2: DisksStep(model: model)
                    case 3: SummaryStep(model: model)
                    default: RunView(model: model, onRestart: { model.preparer.reset(); step = 2 })
                    }
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            if currentStep < 4 {
                Divider()
                footer
            }
        }
        .confirmationDialog("Effacer \(selectedDisks.count) disque\(selectedDisks.count > 1 ? "s" : "") ?", isPresented: $confirmErase) {
            Button("Effacer et préparer", role: .destructive) {
                step = 4
                Task { await model.preparer.prepare(diskIDs: selectedDisks.map(\.id)) }
            }
        } message: {
            Text("Toutes les données de \(selectedDisks.map(\.label).joined(separator: ", ")) seront définitivement perdues.")
        }
    }

    /// Pendant ou après une préparation, on reste sur l'étape Création.
    private var currentStep: Int {
        model.preparer.phase == .idle ? step : 4
    }

    private var selectedDisks: [ExternalDisk] {
        model.disks.disks.filter { model.selectedDisks.contains($0.id) }
    }

    private var stepper: some View {
        HStack(spacing: 0) {
            ForEach(steps.indices, id: \.self) { i in
                Button {
                    if model.preparer.phase == .idle && i < 4 { step = i }
                } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle().fill(i <= currentStep ? Color.accentColor : Color.secondary.opacity(0.2))
                            if i < currentStep {
                                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                            } else {
                                Text("\(i + 1)").font(.caption.bold()).foregroundStyle(i == currentStep ? .white : .secondary)
                            }
                        }
                        .frame(width: 22, height: 22)
                        Text(steps[i]).fontWeight(i == currentStep ? .semibold : .regular)
                            .foregroundStyle(i == currentStep ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                if i < steps.count - 1 {
                    Rectangle().fill(i < currentStep ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(height: 2).frame(maxWidth: 60).padding(.horizontal, 10)
                }
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Précédent") { step -= 1 }
            }
            Spacer()
            if let problem = blocker {
                Text(problem).font(.callout).foregroundStyle(.secondary)
            }
            if step < 3 {
                Button("Suivant") { step += 1 }
                    .keyboardShortcut(.defaultAction)
                    .disabled(blocker != nil)
            } else {
                Button {
                    confirmErase = true
                } label: {
                    Label("Préparer \(selectedDisks.count) disque\(selectedDisks.count > 1 ? "s" : "")", systemImage: "externaldrive.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(blocker != nil)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    /// Ce qui empêche de passer à l'étape suivante.
    private var blocker: String? {
        let plan = model.preparer.plan()
        if step >= 0 && plan.systems.isEmpty { return "Choisissez au moins une version macOS." }
        if step >= 2 {
            if selectedDisks.isEmpty { return "Cochez au moins un disque." }
            if let small = selectedDisks.first(where: { !plan.fits($0) }) {
                return "\(small.label) est trop petit (\(plan.requiredBytes.fileSize) nécessaires)."
            }
        }
        return nil
    }
}

// MARK: - Étape 1 : versions

private struct VersionsStep: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choisissez les versions de macOS à installer. Une partition bootable est créée pour chacune.")
                .foregroundStyle(.secondary)
            if model.catalog.isLoadingInstallers && model.catalog.installers.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Recherche des versions chez Apple…") }
            }
            if let error = model.catalog.installersError { Banner(text: error, color: .red) }
            ForEach(0..<3, id: \.self) { slot in
                SlotCard(model: model, slot: slot)
            }
        }
    }
}

private struct SlotCard: View {
    @Bindable var model: AppModel
    let slot: Int

    var body: some View {
        let version = model.settings.selected[slot]
        let installer = model.catalog.installer(version: version)
        Card(title: installer.map { "macOS \($0.name) \($0.version)" } ?? "Emplacement \(slot + 1) vide",
             icon: "\(slot + 1).circle.fill",
             subtitle: installer.map { "Build \($0.build) · \($0.sizeText) · partition de \(max(model.settings.partitionSizeGB, $0.requiredPartitionGB)) Go" }) {
            VersionPicker(model: model, slot: slot).frame(width: 260)
        } content: {
            if let installer {
                HStack {
                    if let local = model.library.installer(matching: installer) {
                        Pill(text: "Téléchargé", color: .green, icon: "checkmark.circle")
                        Text(local.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    } else if let job = model.downloads.active.first(where: { $0.key == "macos-" + installer.version }) {
                        ProgressView(value: job.progress).frame(width: 160)
                        Text("\(Int(job.progress * 100)) %").font(.caption).monospacedDigit()
                    } else {
                        Pill(text: "Sera téléchargé (\(installer.sizeText))", color: .orange, icon: "arrow.down.circle")
                        Button("Télécharger maintenant") { model.downloads.enqueue(.macOS(installer)) }
                            .controlSize(.small)
                    }
                    Spacer()
                    if let latest = model.catalog.latestInstaller(major: installer.major), latest.version.isNewerVersion(than: installer.version) {
                        Button("Passer à \(latest.version)") { model.settings.selected[slot] = latest.version }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

struct VersionPicker: View {
    @Bindable var model: AppModel
    let slot: Int

    var body: some View {
        let majors = model.catalog.installers.reduce(into: [String]()) { if !$0.contains($1.major) { $0.append($1.major) } }
        Picker("macOS \(slot + 1)", selection: $model.settings.selected[slot]) {
            Text("Aucun").tag("")
            ForEach(majors, id: \.self) { major in
                Section(model.catalog.installers.first { $0.major == major }.map { "macOS \($0.name)" } ?? major) {
                    ForEach(model.catalog.installers.filter { $0.major == major }) { i in
                        let isLocal = model.library.installer(matching: i) != nil
                        Label { Text(isLocal ? "\(i.version) (\(i.build)) — sur ce Mac" : "\(i.version) (\(i.build))") } icon: {
                            Image(systemName: isLocal ? "checkmark.circle.fill" : "arrow.down.circle")
                                .foregroundStyle(isLocal ? .green : .secondary)
                        }
                        .tag(i.version)
                    }
                }
            }
            let current = model.settings.selected[slot]
            if !current.isEmpty && model.catalog.installer(version: current) == nil {
                Text("\(current) (plus proposée)").tag(current)
            }
        }
        .labelsHidden()
        .disabled(!model.canEditVersions)
    }
}

// MARK: - Étape 2 : contenu de DataExternalDrive

private struct ContentStep: View {
    @Bindable var model: AppModel
    @State private var importing = false

    var body: some View {
        let settings = model.settings
        VStack(alignment: .leading, spacing: 16) {
            Text("Choisissez ce qui est copié sur la partition DataExternalDrive. Les fichiers manquants seront téléchargés avant l'écriture.")
                .foregroundStyle(.secondary)
            ForEach(model.preparer.plan().blocked, id: \.self) { Banner(text: $0, color: .red, icon: "nosign") }

            Card(title: "IPSW Mac Apple Silicon", icon: "laptopcomputer", subtitle: "Pour restaurer les MacBook Air M1 / M2 / M3 — seules les versions signées sont proposées") {
                Toggle("", isOn: $model.settings.includeMacIPSW).toggleStyle(.switch).labelsHidden()
            } content: {
                if settings.includeMacIPSW {
                    ForEach(0..<3, id: \.self) { slot in
                        let version = settings.selected[slot]
                        if !version.isEmpty {
                            MacIPSWRow(model: model, slot: slot, version: version)
                        }
                    }
                }
            }

            Card(title: "IPSW iPad", icon: "ipad", subtitle: "Version validée pour chaque génération — seules les versions signées sont proposées") {
                Toggle("", isOn: $model.settings.includeIPadIPSW).toggleStyle(.switch).labelsHidden()
            } content: {
                if settings.includeIPadIPSW {
                    ForEach($model.settings.devices) { $device in
                        IPadRow(model: model, device: $device)
                    }
                    if model.catalog.isLoadingFirmwares { ProgressView().controlSize(.small) }
                    if let error = model.catalog.firmwaresError { Banner(text: error) }
                }
            }

            Card(title: "Loops GarageBand", icon: "music.note", subtitle: "Optionnel : à importer ou non sur ce disque") {
                Toggle("", isOn: $model.settings.includeLoops).toggleStyle(.switch).labelsHidden()
            } content: {
                if settings.includeLoops {
                    if let loops = model.library.loops.first {
                        HStack {
                            Pill(text: "Prêt", color: .green, icon: "checkmark.circle")
                            Text(loops.name)
                            Text(loops.size.fileSize).foregroundStyle(.secondary)
                            Spacer()
                            Button("Remplacer…") { importing = true }.controlSize(.small)
                        }
                    } else {
                        HStack {
                            Banner(text: "Aucun fichier de loops dans le dossier Others.")
                            Button("Importer un fichier…") { importing = true }
                        }
                    }
                }
            }
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
}

struct MacIPSWRow: View {
    @Bindable var model: AppModel
    let slot: Int
    let version: String

    var body: some View {
        let settings = model.settings
        let pinned = settings.macIPSWVersions[slot]
        let fw = model.catalog.macFirmware(identifier: settings.macIdentifier, version: version, pinned: pinned)
        let local = fw.flatMap { model.library.ipsw($0, device: nil) }
        let auto = model.catalog.macFirmware(identifier: settings.macIdentifier, version: version)
        HStack {
            Toggle(isOn: $model.settings.macIPSWSlots[slot]) {
                Text("macOS \(version)")
            }
            .frame(width: 160, alignment: .leading)
            IPSWVersionPicker(firmwares: model.catalog.signedFirmwares(identifier: settings.macIdentifier)
                                .filter { $0.version.majorVersion == version.majorVersion },
                              selection: $model.settings.macIPSWVersions[slot],
                              automatic: auto.map { "Automatique (\($0.version))" } ?? "Automatique",
                              automaticVersion: auto?.version,
                              downloaded: Set(model.library.macIPSWs.compactMap(\.version)))
                .disabled(!model.canEditVersions)
            if let fw { signedPill(fw.signed) }
            Spacer()
            let included = settings.includeMacIPSW && settings.macIPSWSlots[slot]
            if !included {
                Pill(text: "Non inclus", color: .secondary, icon: "minus.circle")
            } else if let fw, !fw.signed {
                Pill(text: "Ne sera pas installé", color: .red, icon: "nosign")
            } else if let fw {
                let latest = model.catalog.signedFirmwares(identifier: settings.macIdentifier).first { $0.version.majorVersion == version.majorVersion }
                LatestPill(chosen: fw.version, latest: latest?.version)
                LocalPill(path: local?.path, folder: settings.siliconFolder, size: fw.filesize)
            } else {
                Text("Aucun IPSW signé").foregroundStyle(.secondary)
            }
        }
        .opacity(settings.includeMacIPSW && settings.macIPSWSlots[slot] ? 1 : 0.45)
        .disabled(!model.settings.includeMacIPSW)
    }
}

struct IPadRow: View {
    @Bindable var model: AppModel
    @Binding var device: Device

    var body: some View {
        let fw = model.catalog.iPadFirmware(device)
        let latest = model.catalog.latestSigned(identifier: device.identifier)
        let local = model.library.iPadIPSWs[device.name] ?? []
        let version = Binding(get: { device.version ?? "" }, set: { device.version = $0.isEmpty ? nil : $0 })
        HStack {
            Toggle(isOn: $device.enabled) { Text(device.name) }
                .frame(width: 160, alignment: .leading)
            IPSWVersionPicker(firmwares: model.catalog.signedFirmwares(identifier: device.identifier),
                              selection: version,
                              automatic: latest.map { "Dernière signée (\($0.version))" } ?? "Dernière signée",
                              automaticVersion: latest?.version,
                              downloaded: Set(local.compactMap(\.version)))
                .disabled(!model.canEditVersions)
            if let fw { signedPill(fw.signed) }
            Spacer()
            if !device.enabled || !model.settings.includeIPadIPSW {
                Pill(text: "Non inclus", color: .secondary, icon: "minus.circle")
            } else if let fw, !fw.signed {
                Pill(text: "Ne sera pas installé", color: .red, icon: "nosign")
            } else if let fw {
                LatestPill(chosen: fw.version, latest: latest?.version)
                LocalPill(path: model.library.ipsw(fw, device: device)?.path, folder: model.settings.folder(for: device), size: fw.filesize)
            } else if let file = local.first {
                Pill(text: "Local : \(file.version ?? file.name)", color: .secondary)
            }
        }
        .opacity(device.enabled && model.settings.includeIPadIPSW ? 1 : 0.45)
    }
}

/// Choix de la version IPSW : automatique ou une version précise, uniquement parmi les versions signées.
struct IPSWVersionPicker: View {
    let firmwares: [Firmware]
    @Binding var selection: String
    let automatic: String
    var automaticVersion: String?
    /// Versions déjà téléchargées sur ce Mac (marquées d'un ✓ vert).
    var downloaded: Set<String> = []

    var body: some View {
        Picker("Version", selection: $selection) {
            item(automatic, version: automaticVersion).tag("")
            Divider()
            ForEach(firmwares) { item("\($0.version) (\($0.buildid))", version: $0.version).tag($0.version) }
            // Version choisie auparavant mais plus signée depuis : affichée pour qu'on la change.
            if !selection.isEmpty && !firmwares.contains(where: { $0.version == selection }) {
                Text("\(selection) — plus signée").tag(selection)
            }
        }
        .labelsHidden()
        .frame(width: 230)
    }

    /// ✓ vert si la version est sur ce Mac, flèche grise si elle sera téléchargée.
    private func item(_ title: String, version: String?) -> some View {
        let isLocal = version.map(downloaded.contains) ?? false
        return Label {
            Text(isLocal ? "\(title) — sur ce Mac" : title)
        } icon: {
            Image(systemName: isLocal ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(isLocal ? .green : .secondary)
        }
    }
}

// MARK: - Étape 3 : disques

private struct DisksStep: View {
    @Bindable var model: AppModel

    var body: some View {
        let plan = model.preparer.plan()
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Cochez le ou les disques externes à préparer. Ils seront préparés l'un après l'autre avec les mêmes réglages.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task {
                        await model.disks.load()
                        for disk in model.disks.disks where disk.looksPrepared { await model.disks.inspect(disk.id) }
                    }
                } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
            }
            if model.disks.disks.isEmpty {
                ContentUnavailableView("Aucun disque externe", systemImage: "externaldrive.badge.questionmark",
                                       description: Text("Branchez un disque : il apparaîtra ici automatiquement."))
                    .frame(maxWidth: .infinity)
            }
            ForEach(model.disks.disks) { disk in
                DiskChoiceRow(model: model, disk: disk, fits: plan.fits(disk), required: plan.requiredBytes)
            }
        }
    }
}

private struct DiskChoiceRow: View {
    @Bindable var model: AppModel
    let disk: ExternalDisk
    let fits: Bool
    let required: Int64

    var body: some View {
        let isOn = Binding(
            get: { model.selectedDisks.contains(disk.id) },
            set: { if $0 { model.selectedDisks.insert(disk.id) } else { model.selectedDisks.remove(disk.id) } })
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 14) {
            Toggle("", isOn: isOn).labelsHidden().disabled(!fits)
            Image(systemName: "externaldrive.fill").font(.title).foregroundStyle(fits ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(disk.name).font(.headline)
                    Text(disk.id).font(.caption).foregroundStyle(.secondary)
                    if disk.looksPrepared { Pill(text: "Déjà préparé", color: .blue) }
                    if let summary = comparisonSummary(model.disks.inspections[disk.id], model: model) {
                        Pill(text: summary.text, color: summary.color)
                    }
                }
                Text(disk.partitions.filter { !$0.name.isEmpty }.map(\.name).joined(separator: " · ").ifEmpty("Aucun volume"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(disk.size.fileSize).font(.headline)
                if !fits { Text("Trop petit (\(required.fileSize) nécessaires)").font(.caption).foregroundStyle(.red) }
            }
        }
        if disk.looksPrepared { DiskComparison(model: model, disk: disk).padding(.leading, 34) }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isOn.wrappedValue ? Color.accentColor : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { if fits { isOn.wrappedValue.toggle() } }
        .task(id: disk.id) {
            if disk.looksPrepared && model.disks.inspections[disk.id] == nil { await model.disks.inspect(disk.id) }
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

// MARK: - Étape 4 : récapitulatif

private struct SummaryStep: View {
    @Bindable var model: AppModel

    var body: some View {
        let plan = model.preparer.plan()
        let disks = model.disks.disks.filter { model.selectedDisks.contains($0.id) }
        VStack(alignment: .leading, spacing: 16) {
            ForEach(plan.blocked, id: \.self) { Banner(text: $0, color: .red, icon: "nosign") }
            ForEach(plan.warnings, id: \.self) { Banner(text: $0) }

            ForEach(disks) { disk in
                Card(title: "\(disk.name) — \(disk.size.fileSize)", icon: "externaldrive.fill", subtitle: "\(disk.id) · sera entièrement effacé") {
                    PartitionBar(segments: segments(plan: plan, disk: disk), total: disk.size)
                }
            }

            Card(title: "Partitions macOS", icon: "apple.logo") {
                ForEach(Array(plan.systems.enumerated()), id: \.element.id) { i, s in
                    HStack {
                        Circle().fill(systemColors[i % systemColors.count]).frame(width: 8, height: 8)
                        Text("« \(s.installer.volumeLabel) »").fontWeight(.medium)
                        Text("\(s.partitionGB) Go").foregroundStyle(.secondary)
                        Spacer()
                        s.local == nil ? Pill(text: "À télécharger", color: .orange) : Pill(text: "Prêt", color: .green)
                    }
                }
            }

            Card(title: "DataExternalDrive", icon: "folder", subtitle: plan.dataItems.isEmpty ? "Partition vide" : "\(plan.dataItems.count) fichier(s) · \(plan.dataBytes.fileSize)") {
                ForEach(plan.dataItems) { item in
                    HStack {
                        Text(item.label)
                        Text(item.size.fileSize).foregroundStyle(.secondary)
                        Spacer()
                        item.isAvailable ? Pill(text: "Prêt", color: .green) : Pill(text: "À télécharger", color: .orange)
                    }
                }
            }

            Card(title: "Durée estimée", icon: "clock") {
                let perSystem = model.history.averageSecondsPerSystem
                let writing = perSystem * Double(plan.systems.count * max(disks.count, 1)) + Double(plan.dataBytes) * Double(max(disks.count, 1)) / 80_000_000
                VStack(alignment: .leading, spacing: 4) {
                    if !plan.downloads.isEmpty {
                        InfoRow(label: "Téléchargements", value: "\(plan.downloads.count) élément(s), \(plan.downloadBytes.fileSize)")
                    }
                    InfoRow(label: "Écriture", value: "≈ \(formatDuration(writing))")
                    InfoRow(label: "Mot de passe", value: "Demandé une seule fois, au début de l'écriture")
                }
            }
        }
    }

    private func segments(plan: Plan, disk: ExternalDisk) -> [PartitionBar.Segment] {
        var result = plan.systems.enumerated().map { i, s in
            PartitionBar.Segment(label: s.installer.volumeLabel, size: Int64(s.partitionGB) * 1_000_000_000,
                                 color: systemColors[i % systemColors.count], used: s.installer.sizeBytes)
        }
        let rest = max(disk.size - plan.systemsBytes - 210_000_000, 0)
        result.append(PartitionBar.Segment(label: "DataExternalDrive", size: rest, color: .green, used: plan.dataBytes))
        return result
    }
}

// MARK: - Étape 5 : création (aussi utilisée pour les mises à jour)

struct RunView: View {
    @Bindable var model: AppModel
    var onRestart: (() -> Void)?

    var body: some View {
        let preparer = model.preparer
        VStack(alignment: .leading, spacing: 16) {
            header

            if !preparer.runDownloads.isEmpty {
                Card(title: "Téléchargements", icon: "arrow.down.circle") {
                    ForEach(preparer.runDownloads) { DownloadRow(model: model, job: $0, compact: true) }
                }
            }

            if preparer.phase == .writing || preparer.stepCount > 0 {
                Card(title: "Écriture", icon: "externaldrive.badge.timemachine",
                     subtitle: preparer.stepCount > 0 ? "Étape \(preparer.stepIndex) sur \(preparer.stepCount)" : nil) {
                    if preparer.isRunning && !preparer.stopRequested {
                        Button("Arrêter après l'étape en cours", role: .destructive) { preparer.requestStop() }
                            .controlSize(.small)
                    }
                } content: {
                    ProgressView(value: preparer.progress)
                    Text(preparer.currentStep.ifEmpty("En attente du mot de passe administrateur…"))
                        .font(.callout)
                    if preparer.phase == .writing {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            HStack {
                                if let start = preparer.startedAt { Text("Écoulé : \(formatDuration(Date().timeIntervalSince(start)))") }
                                if let remaining = preparer.remaining { Text("· reste ≈ \(formatDuration(remaining))") }
                            }
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }

            ForEach(preparer.checks.keys.sorted(), id: \.self) { disk in
                Card(title: "Vérification de \(disk)", icon: "checklist") {
                    ChecksList(checks: preparer.checks[disk] ?? [])
                }
            }

            Card(title: "Journal", icon: "text.alignleft") {
                Button("Ouvrir le journal complet") { model.page = .log }.controlSize(.small)
            } content: {
                LogTail(lines: Array(model.log.lines.suffix(14)))
            }

            if case .finished = preparer.phase, let onRestart {
                Button("Préparer un autre disque", action: onRestart).buttonStyle(.borderedProminent)
            } else if case .failed = preparer.phase, let onRestart {
                Button("Revenir à l'assistant", action: onRestart)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        let preparer = model.preparer
        switch preparer.phase {
        case .idle:
            EmptyView()
        case .downloading:
            Label("Téléchargement des éléments manquants…", systemImage: "arrow.down.circle").font(.title3.weight(.semibold))
        case .writing:
            Label("Écriture sur le disque — ne le débranchez pas", systemImage: "externaldrive.fill.badge.timemachine")
                .font(.title3.weight(.semibold))
        case .verifying:
            Label("Vérification du disque…", systemImage: "checklist").font(.title3.weight(.semibold))
        case let .finished(success):
            Label(success ? "\(preparer.title) : terminé, disque éjecté" : "\(preparer.title) : terminé avec des erreurs",
                  systemImage: success ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold)).foregroundStyle(success ? .green : .orange)
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon.fill").font(.title3.weight(.semibold)).foregroundStyle(.red)
        }
    }
}

/// Dernières lignes du journal.
struct LogTail: View {
    let lines: [LogLine]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines) { line in
                Text(line.text).foregroundStyle(line.level.color).lineLimit(1).truncationMode(.middle)
            }
            if lines.isEmpty { Text("Rien pour l'instant.").foregroundStyle(.secondary) }
        }
        .font(.system(.caption, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

extension LogLevel {
    var color: Color {
        switch self {
        case .step: return .accentColor
        case .info: return .primary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// « Dernière version Apple », ou la version plus récente qu'Apple propose.
struct LatestPill: View {
    let chosen: String
    let latest: String?

    var body: some View {
        if let latest, latest.isNewerVersion(than: chosen) {
            Pill(text: "\(latest) chez Apple", color: .appleLatest, icon: "sparkles")
        } else if latest != nil {
            Pill(text: "Dernière version Apple", color: .appleLatest, icon: "apple.logo")
        }
    }
}

/// « Sur ce Mac » (bien rangé), « Sur ce Mac, à ranger » (ailleurs sur le Mac) ou « Sera téléchargé ».
struct LocalPill: View {
    let path: String?
    let folder: String
    let size: Int64

    var body: some View {
        if let path {
            path.hasPrefix(folder + "/")
                ? Pill(text: "Sur ce Mac", color: .green, icon: "checkmark.circle")
                : Pill(text: "Sur ce Mac, à ranger", color: .orange, icon: "tray.and.arrow.down")
        } else {
            Pill(text: "Sera téléchargé (\(size.fileSize))", color: .orange, icon: "arrow.down.circle")
        }
    }
}
