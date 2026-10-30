import Foundation
import Observation

/// Une partition macOS prévue.
struct PlannedSystem: Identifiable, Hashable {
    let installer: Installer
    let local: LocalInstaller?
    let partitionGB: Int
    var id: String { installer.version }
}

/// Un fichier prévu sur DataExternalDrive.
struct DataItem: Identifiable {
    let category: String        // "Mac Apple Silicon", "iPad 10ème Gen", "Loops"
    let label: String
    let source: String          // chemin local (peut ne pas encore exister)
    let destination: String     // chemin relatif sur DataExternalDrive
    let size: Int64
    let download: DownloadJob.Kind?
    var id: String { destination }
    var isAvailable: Bool { FileManager.default.fileExists(atPath: source) }
}

/// Ce qui va être écrit sur un disque.
struct Plan {
    var systems: [PlannedSystem] = []
    var dataItems: [DataItem] = []
    var warnings: [String] = []
    /// IPSW écartés car plus signés par Apple (jamais copiés sur le disque).
    var blocked: [String] = []

    var systemsBytes: Int64 { Int64(systems.reduce(0) { $0 + $1.partitionGB }) * 1_000_000_000 }
    var dataBytes: Int64 { dataItems.reduce(0) { $0 + $1.size } }
    var requiredBytes: Int64 { systemsBytes + dataBytes + 1_000_000_000 }

    var downloads: [(label: String, size: Int64, kind: DownloadJob.Kind)] {
        systems.filter { $0.local == nil }.map { ("macOS \($0.installer.name) \($0.installer.version)", $0.installer.sizeBytes, .macOS($0.installer)) }
            + dataItems.filter { !$0.isAvailable }.compactMap { item in item.download.map { (item.label, item.size, $0) } }
    }
    var downloadBytes: Int64 { downloads.reduce(0) { $0 + $1.size } }

    func fits(_ disk: ExternalDisk) -> Bool { disk.size >= requiredBytes }
}

enum RunPhase: Equatable {
    case idle, downloading, writing, verifying
    case finished(success: Bool)
    case failed(String)
}

/// Prépare (efface et crée) ou met à jour des disques.
@MainActor
@Observable
final class Preparer {
    private let settings: AppSettings
    private let catalog: Catalog
    private let library: Library
    private let downloads: DownloadManager
    private let disks: DiskStore
    private let history: HistoryStore
    private let log: LogStore
    private let notifier: Notifier

    var phase: RunPhase = .idle
    var title = ""
    var currentStep = ""
    var stepIndex = 0
    var stepCount = 0
    var startedAt: Date?
    var estimatedDuration: TimeInterval = 0
    var runDownloads: [DownloadJob] = []
    var checks: [String: [CheckResult]] = [:]   // disque → vérifications
    var stopRequested = false
    private var stopFile: URL?

    init(settings: AppSettings, catalog: Catalog, library: Library, downloads: DownloadManager,
         disks: DiskStore, history: HistoryStore, log: LogStore, notifier: Notifier) {
        self.settings = settings
        self.catalog = catalog
        self.library = library
        self.downloads = downloads
        self.disks = disks
        self.history = history
        self.log = log
        self.notifier = notifier
    }

    var isRunning: Bool {
        switch phase { case .downloading, .writing, .verifying: return true; default: return false }
    }
    var progress: Double { stepCount == 0 ? 0 : Double(stepIndex) / Double(stepCount) }
    var remaining: TimeInterval? {
        guard phase == .writing, let startedAt else { return nil }
        return max(0, estimatedDuration - Date().timeIntervalSince(startedAt))
    }

    func reset() {
        guard !isRunning else { return }
        phase = .idle
        checks = [:]
        runDownloads = []
    }

    /// Arrête le script après l'étape en cours (impossible d'interrompre createinstallmedia proprement).
    func requestStop() {
        stopRequested = true
        if let stopFile { FileManager.default.createFile(atPath: stopFile.path, contents: nil) }
        for job in runDownloads where !job.isFinished { downloads.cancel(job) }
    }

    // MARK: Plan

    func plan() -> Plan {
        var plan = Plan()
        let chosen = settings.selected.compactMap { v in v.isEmpty ? nil : catalog.installer(version: v) }

        for installer in chosen {
            plan.systems.append(PlannedSystem(installer: installer, local: library.installer(matching: installer),
                                              partitionGB: max(settings.partitionSizeGB, installer.requiredPartitionGB)))
            if let latest = catalog.latestInstaller(major: installer.major), latest.version.isNewerVersion(than: installer.version) {
                plan.warnings.append("macOS \(installer.name) \(latest.version) est disponible (choisi : \(installer.version)).")
            }
        }
        let majors = chosen.map(\.major)
        if Set(majors).count < majors.count {
            plan.warnings.append("Deux versions du même macOS sont choisies : leurs installateurs portent le même nom et s'écrasent dans /Applications.")
        }
        for (slot, version) in settings.selected.enumerated() where !version.isEmpty && catalog.installer(version: version) == nil {
            plan.warnings.append("macOS \(slot + 1) : la version \(version) n'est plus proposée par Apple.")
        }

        if settings.includeMacIPSW {
            let macKnown = catalog.firmwares[settings.macIdentifier] != nil
            for (slot, version) in settings.selected.enumerated() where !version.isEmpty && settings.macIPSWSlots[slot] {
                let pinned = settings.macIPSWVersions[slot]
                let fw = catalog.macFirmware(identifier: settings.macIdentifier, version: version, pinned: pinned)
                let wanted = fw?.version ?? (pinned.isEmpty ? version : pinned)
                if let fw, !fw.signed {
                    plan.blocked.append("IPSW Apple Silicon \(fw.version) : plus signé par Apple, il ne sera pas installé. Choisissez une autre version.")
                    continue
                }
                if macKnown && fw == nil {
                    plan.blocked.append("IPSW Apple Silicon pour macOS \(version) : aucune version signée par Apple, rien ne sera installé.")
                    continue
                }
                let name = settings.macIPSWPath(wanted)
                let local = fw.map { library.ipsw($0, device: nil) } ?? library.macIPSW(version: wanted)
                guard local != nil || fw != nil else {
                    plan.warnings.append("Aucun IPSW Apple Silicon trouvé pour macOS \(version).")
                    continue
                }
                if fw == nil {
                    plan.warnings.append("Apple injoignable : impossible de vérifier que l'IPSW Apple Silicon \(wanted) est encore signé.")
                }
                if pinned.isEmpty, let fw, fw.version != version {
                    plan.warnings.append("Pas d'IPSW Apple Silicon \(version) signé chez Apple : la \(fw.version) sera utilisée.")
                }
                let source = local?.path ?? name
                plan.dataItems.append(DataItem(category: "Mac Apple Silicon", label: "IPSW Apple Silicon \(wanted)",
                                               source: source, destination: "OS/MacOS/Silicon/" + (name as NSString).lastPathComponent,
                                               size: local?.size ?? fw?.filesize ?? 0,
                                               download: fw.map { .ipsw($0, destination: name) }))
            }
        }

        if settings.includeIPadIPSW {
            for device in settings.enabledDevices {
                let files = library.iPadIPSWs[device.name] ?? []
                let pinned = device.version ?? ""
                let known = catalog.firmwares[device.identifier] != nil
                if let fw = catalog.iPadFirmware(device), !fw.signed {
                    plan.blocked.append("\(device.name) : iPadOS \(fw.version) n'est plus signé par Apple, il ne sera pas installé. Choisissez une autre version.")
                } else if known && catalog.iPadFirmware(device) == nil {
                    plan.blocked.append(pinned.isEmpty ? "\(device.name) : aucune version signée par Apple, rien ne sera installé."
                                                       : "\(device.name) : la version \(pinned) est inconnue chez Apple, rien ne sera installé.")
                } else if let fw = catalog.iPadFirmware(device) {
                    let local = library.ipsw(fw, device: device)
                    let name = settings.ipswPath(device, fw.version)
                    let source = local?.path ?? name
                    plan.dataItems.append(DataItem(category: device.name, label: "\(device.name) — iPadOS \(fw.version)",
                                                   source: source, destination: "OS/iOS/\(device.name)/" + (name as NSString).lastPathComponent,
                                                   size: local?.size ?? fw.filesize, download: .ipsw(fw, destination: name)))
                } else if let local = files.first(where: { pinned.isEmpty || $0.version == pinned }) {
                    plan.dataItems.append(DataItem(category: device.name, label: "\(device.name) — \(local.name)",
                                                   source: local.path, destination: "OS/iOS/\(device.name)/"
                                                       + (local.version.map { (settings.ipswPath(device, $0) as NSString).lastPathComponent } ?? local.name),
                                                   size: local.size, download: nil))
                    plan.warnings.append("\(device.name) : Apple injoignable, impossible de vérifier que \(local.name) est encore signé.")
                } else {
                    plan.warnings.append("\(device.name) : aucun IPSW disponible.")
                }
            }
        }

        if settings.includeLoops {
            if let loops = library.loops.first {
                plan.dataItems.append(DataItem(category: "Loops", label: "Loops GarageBand (\(loops.name))", source: loops.path,
                                               destination: "Others/" + loops.name, size: loops.size, download: nil))
            } else {
                plan.warnings.append("Loops GarageBand choisies mais aucun fichier dans \(settings.othersFolder).")
            }
        }
        return plan
    }

    // MARK: Préparation complète (efface les disques)

    func prepare(diskIDs: [String]) async {
        guard !isRunning else { return }
        begin("Préparation de \(diskIDs.count) disque\(diskIDs.count > 1 ? "s" : "")")
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: title)
        defer { ProcessInfo.processInfo.endActivity(activity) }

        guard await downloadMissing(plan()) else { return }
        await library.scan()
        await disks.load()
        let plan = plan()
        let targets = diskIDs.compactMap { disks.disk($0) }
        guard !plan.systems.isEmpty else { return fail("Aucune version macOS choisie.") }
        guard plan.systems.allSatisfy({ $0.local != nil }) else { return fail("Un installateur macOS manque après le téléchargement.") }
        guard targets.count == diskIDs.count else { return fail("Un disque a été débranché.") }
        if let small = targets.first(where: { !plan.fits($0) }) {
            return fail("\(small.label) est trop petit : il faut \(plan.requiredBytes.fileSize).")
        }

        var script = ScriptBuilder()
        for disk in targets { script.erase(disk: disk.id, plan: plan) }
        estimatedDuration = history.averageSecondsPerSystem * Double(plan.systems.count * targets.count)
            + Double(plan.dataBytes * Int64(targets.count)) / 80_000_000
        let failedDisks = await runScript(script)
        guard !stopRequested else { return fail("Arrêté à la demande. Les disques sont incomplets.") }

        phase = .verifying
        var allChecks: [CheckResult] = []
        for disk in targets {
            let result = await verify(disk: disk.id, systems: plan.systems.map(\.installer), items: plan.dataItems,
                                      scriptFailed: failedDisks.contains(disk.id))
            checks[disk.id] = result
            allChecks += result.map { CheckResult(label: "\(disk.id) — \($0.label)", ok: $0.ok, detail: $0.detail) }
        }
        let success = allChecks.allSatisfy(\.ok)
        if success { for disk in targets { _ = await disks.eject(disk.id) } }
        finish(kind: "Création", disks: targets.map(\.label), versions: plan.systems.map(\.installer.volumeLabel),
               extras: plan.dataItems.map(\.label), checks: allChecks, success: success)
    }

    // MARK: Mise à jour sans effacer

    /// Remplace les macOS obsolètes et met à jour les fichiers de DataExternalDrive d'un disque déjà préparé.
    func update(diskID: String) async {
        guard !isRunning else { return }
        begin("Mise à jour de \(diskID)")
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: title)
        defer { ProcessInfo.processInfo.endActivity(activity) }

        guard let inspection = await disks.inspect(diskID) else { return fail("Disque introuvable.") }
        let replacements = updateTargets(inspection)
        var plan = plan()
        plan.systems = plan.systems.filter { s in replacements.contains { $0.1.version == s.installer.version } }
        let newItems = missingItems(inspection, plan: plan)
        plan.dataItems = newItems
        guard await downloadMissing(plan) else { return }
        await library.scan()

        var script = ScriptBuilder()
        let installers = replacements.compactMap { os, installer in
            library.installer(matching: installer).map { (os.partition, installer, $0) }
        }
        let obsolete = settings.removeOldOnUpdate ? inspection.outdatedFiles.map(\.path) : []
        script.update(disk: diskID, systems: installers, items: newItems,
                      dataPartition: inspection.disk.dataPartition?.id, remove: obsolete)
        estimatedDuration = history.averageSecondsPerSystem * Double(installers.count) + Double(plan.dataBytes) / 80_000_000
        let failed = await runScript(script)
        guard !stopRequested else { return fail("Arrêté à la demande.") }

        phase = .verifying
        let result = await verify(disk: diskID, systems: installers.map(\.1), items: newItems, scriptFailed: !failed.isEmpty)
        checks[diskID] = result
        finish(kind: "Mise à jour", disks: [inspection.disk.label], versions: installers.map(\.1.volumeLabel),
               extras: newItems.map(\.label) + obsolete.map { "Supprimé : " + ($0 as NSString).lastPathComponent },
               checks: result, success: result.allSatisfy(\.ok))
    }

    /// Partitions macOS obsolètes à remplacer, avec la version qui les remplace.
    func updateTargets(_ inspection: DiskInspection) -> [(InspectedOS, Installer)] {
        inspection.outdatedSystems.compactMap { os in
            guard case let .outdated(version) = os.status, let installer = catalog.installer(version: version),
                  os.partition.size >= Int64(installer.requiredPartitionGB - 1) * 1_000_000_000 else { return nil }
            return (os, installer)
        }
    }

    /// Partitions obsolètes trop petites pour la nouvelle version.
    func tooSmall(_ inspection: DiskInspection) -> [InspectedOS] {
        inspection.outdatedSystems.filter { os in !updateTargets(inspection).contains { $0.0.id == os.id } }
    }

    /// Fichiers prévus qui ne sont pas encore sur le disque.
    func missingItems(_ inspection: DiskInspection, plan: Plan? = nil) -> [DataItem] {
        guard let mount = inspection.disk.dataPartition?.mountPoint else { return [] }
        return (plan ?? self.plan()).dataItems.filter { !FileManager.default.fileExists(atPath: mount + "/" + $0.destination) }
    }

    // MARK: Étapes communes

    private func begin(_ title: String) {
        self.title = title
        stopRequested = false
        checks = [:]
        runDownloads = []
        stepIndex = 0
        stepCount = 0
        currentStep = ""
        startedAt = Date()
        log.add("==> \(title)")
    }

    private func fail(_ message: String) {
        log.add("ERREUR : \(message)")
        phase = .failed(message)
        notifier.notify("Préparation interrompue", message, isError: true, sound: true)
        notifier.setDockProgress(nil)
    }

    private func downloadMissing(_ plan: Plan) async -> Bool {
        let needed = plan.downloads
        guard !needed.isEmpty else { return true }
        phase = .downloading
        log.add("==> Téléchargement de \(needed.count) élément(s) (\(plan.downloadBytes.fileSize))")
        runDownloads = needed.map { downloads.enqueue($0.kind) }
        let ok = await downloads.wait(for: runDownloads)
        if !ok {
            fail(stopRequested ? "Téléchargements annulés." : "Un téléchargement a échoué : voir l'onglet Téléchargements.")
        }
        return ok
    }

    /// Lance le script en administrateur et suit son journal. Renvoie les disques en échec.
    private func runScript(_ builder: ScriptBuilder) async -> Set<String> {
        phase = .writing
        stepCount = builder.steps
        stepIndex = 0
        startedAt = Date()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PrepareDisk-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scriptURL = dir.appendingPathComponent("prepare.sh")
        let logURL = dir.appendingPathComponent("prepare.log")
        stopFile = dir.appendingPathComponent("stop")
        try? builder.script(stopFile: stopFile!.path).write(to: scriptURL, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        var failed: Set<String> = []
        var offset: UInt64 = 0
        func readLog() {
            guard let handle = try? FileHandle(forReadingFrom: logURL) else { return }
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.readToEnd(), !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            offset += UInt64(data.count)
            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix("==> ") {
                    stepIndex = min(stepIndex + 1, stepCount)
                    currentStep = String(line.dropFirst(4))
                    notifier.setDockProgress(progress)
                }
                if line.hasPrefix("@@FAIL ") { failed.insert(String(line.dropFirst(7))) }
            }
            log.ingest(text)
        }
        let tail = Task { @MainActor in
            while !Task.isCancelled {
                readLog()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        let result = await Shell.runAsAdmin("/bin/bash \(Shell.quote(scriptURL.path)) > \(Shell.quote(logURL.path)) 2>&1")
        tail.cancel()
        readLog()
        log.ingest("\n")
        stopFile = nil
        notifier.setDockProgress(nil)
        if result.cancelled {
            stopRequested = true
            log.add("ATTENTION : mot de passe administrateur refusé, rien n'a été modifié.")
        }
        return failed
    }

    /// Contrôle le disque après écriture : installateurs, versions, démarrage, fichiers copiés.
    private func verify(disk id: String, systems: [Installer], items: [DataItem], scriptFailed: Bool) async -> [CheckResult] {
        log.add("==> Vérification de \(id)")
        var results: [CheckResult] = []
        if scriptFailed { results.append(CheckResult(label: "Script", ok: false, detail: "Une étape a échoué, voir le journal.")) }
        guard let inspection = await disks.inspect(id) else {
            return results + [CheckResult(label: "Disque", ok: false, detail: "Disque introuvable après l'écriture.")]
        }
        for installer in systems {
            let label = "macOS \(installer.name) \(installer.version)"
            if let os = inspection.systems.first(where: { $0.version == installer.version }) {
                let ok = os.bootable && os.partition.name == installer.volumeLabel
                results.append(CheckResult(label: label, ok: ok,
                                           detail: ok ? "Installateur présent, bootable, partition « \(os.partition.name) »"
                                                      : (os.bootable ? "Nom de partition inattendu : \(os.partition.name)" : "Partition non bootable")))
            } else {
                results.append(CheckResult(label: label, ok: false, detail: "Installateur absent du disque"))
            }
        }
        if let mount = inspection.disk.dataPartition?.mountPoint {
            for item in items {
                let size = itemSize(mount + "/" + item.destination)
                let expected = itemSize(item.source)
                let ok = size > 0 && (expected == 0 || abs(size - expected) < max(expected / 100, 1_000_000))
                results.append(CheckResult(label: item.label, ok: ok, detail: ok ? "Copié (\(size.fileSize))" : "Fichier absent ou incomplet"))
            }
        } else if !items.isEmpty {
            results.append(CheckResult(label: "DataExternalDrive", ok: false, detail: "Partition de données introuvable"))
        }
        for r in results { log.add((r.ok ? "✓ " : "ERREUR : ") + "\(r.label) — \(r.detail)") }
        return results
    }

    private func finish(kind: String, disks: [String], versions: [String], extras: [String], checks: [CheckResult], success: Bool) {
        let duration = Date().timeIntervalSince(startedAt ?? Date())
        phase = .finished(success: success)
        log.add(success ? "✓ \(title) terminée en \(formatDuration(duration))" : "ERREUR : \(title) terminée avec des erreurs")
        history.add(kind: kind, disks: disks, versions: versions, extras: extras, duration: duration,
                    success: success, checks: checks, log: log.text())
        notifier.notify(success ? "Disque prêt" : "Préparation terminée avec des erreurs",
                        success ? "\(disks.joined(separator: ", ")) : \(versions.joined(separator: ", "))" : "Voir le rapport de vérification.",
                        isError: !success, sound: true)
    }
}

/// Construit le script bash lancé en root. Chaque "==> " compte comme une étape.
struct ScriptBuilder {
    private(set) var steps = 0
    private var body = ""

    private mutating func step(_ text: String) {
        steps += 1
        body += "    check_stop; echo \(Shell.quote("==> " + text))\n"
    }

    private mutating func line(_ text: String) { body += "    " + text + "\n" }

    mutating func erase(disk: String, plan: Plan) {
        let dev = "/dev/" + disk
        body += "prepare_\(disk)() {\n"
        line("RC=0")
        step("\(disk) : effacement et partitionnement")
        let parts = plan.systems.enumerated().map { "JHFS+ OS\($0.offset + 1) \($0.element.partitionGB)g" }.joined(separator: " ")
        line("diskutil unmountDisk force \(dev)")
        line("diskutil partitionDisk \(dev) GPT \(parts) JHFS+ DataExternalDrive 0b || return 1")
        for (i, system) in plan.systems.enumerated() {
            guard let app = system.local else { continue }
            step("\(disk) : création de l'installateur macOS \(system.installer.name) \(system.installer.version)")
            line("PART=$(part_named \(disk) OS\(i + 1)); VOL=$(mount_of \"$PART\")")
            // Une étape ratée n'empêche pas les suivantes : les autres macOS et les fichiers sont quand même écrits.
            line("if [ -z \"$VOL\" ]; then echo \"ERREUR : partition OS\(i + 1) introuvable\"; RC=1")
            line("elif \(Shell.quote(app.createInstallMedia)) --volume \"$VOL\" --nointeraction; then")
            line("    diskutil rename \"$PART\" \(Shell.quote(system.installer.volumeLabel))")
            line("else echo \(Shell.quote("ERREUR : createinstallmedia a échoué pour " + system.installer.version)); RC=1; fi")
        }
        copy(disk: disk, items: plan.dataItems, data: "$(part_named \(disk) DataExternalDrive)")
        line("return $RC")
        body += "}\n"
        body += "prepare_\(disk) || { echo \"@@FAIL \(disk)\"; echo \"ERREUR : échec sur \(disk)\"; FAILED=1; }\n\n"
    }

    mutating func update(disk: String, systems: [(Partition, Installer, LocalInstaller)], items: [DataItem],
                         dataPartition: String?, remove: [String]) {
        body += "update_\(disk)() {\n"
        line("RC=0")
        for (part, installer, app) in systems {
            step("\(disk) : remplacement de « \(part.name) » par macOS \(installer.name) \(installer.version)")
            line("VOL=$(mount_of \(part.id)); [ -z \"$VOL\" ] && diskutil mount \(part.id) >/dev/null && VOL=$(mount_of \(part.id))")
            line("if \(Shell.quote(app.createInstallMedia)) --volume \"$VOL\" --nointeraction; then")
            line("    diskutil rename \(part.id) \(Shell.quote(installer.volumeLabel))")
            line("else echo \"ERREUR : createinstallmedia a échoué pour \(installer.version)\"; RC=1; fi")
        }
        if let dataPartition {
            if !remove.isEmpty {
                step("\(disk) : suppression des anciens fichiers")
                for path in remove { line("rm -f \(Shell.quote(path)) && echo \(Shell.quote("Supprimé : " + path))") }
            }
            copy(disk: disk, items: items, data: dataPartition)
        }
        line("return $RC")
        body += "}\n"
        body += "update_\(disk) || { echo \"@@FAIL \(disk)\"; FAILED=1; }\n\n"
    }

    private mutating func copy(disk: String, items: [DataItem], data: String) {
        guard !items.isEmpty else { return }
        line("DATA=$(mount_of \(data))")
        for item in items {
            step("\(disk) : copie de \(item.label) (\(item.size.fileSize))")
            let dest = "\"$DATA\"/" + Shell.quote(item.destination)
            line("mkdir -p \"$(dirname \(dest))\" && ditto \(Shell.quote(item.source)) \(dest) || { echo \(Shell.quote("ERREUR : copie de " + item.label)); RC=1; }")
        }
    }

    func script(stopFile: String) -> String {
        """
        #!/bin/bash
        FAILED=0
        mount_of() { diskutil info -plist "$1" 2>/dev/null | plutil -extract MountPoint raw - 2>/dev/null; }
        # Identifiant de la partition qui porte ce nom sur ce disque (disk4 OS1 → disk4s2).
        part_named() {
            for n in $(seq 1 16); do
                name=$(diskutil info -plist "$1s$n" 2>/dev/null | plutil -extract VolumeName raw - 2>/dev/null)
                [ "$name" = "$2" ] && { echo "$1s$n"; return; }
            done
        }
        check_stop() { [ -f \(Shell.quote(stopFile)) ] && { echo "ATTENTION : arrêt demandé"; exit 3; }; }

        \(body)
        echo "@@END $FAILED"
        exit $FAILED

        """
    }
}
