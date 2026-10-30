import CryptoKit
import Foundation
import Network
import Observation

/// Un téléchargement de la file d'attente.
@MainActor
@Observable
final class DownloadJob: Identifiable {
    enum Kind {
        case macOS(Installer)
        case ipsw(Firmware, destination: String)
    }
    enum State: Equatable {
        case queued, running, verifying, done, failed(String), cancelled
    }

    let id = UUID()
    let kind: Kind
    let title: String
    var state: State = .queued
    var progress: Double = 0
    var totalBytes: Int64
    var speed: Double = 0          // octets / seconde
    var startedAt: Date?
    /// Essai en cours (un téléchargement raté est relancé tout seul, jusqu'à `maxAttempts`).
    var attempt = 1
    static let maxAttempts = 3
    /// Raison du dernier échec, affichée pendant l'attente du nouvel essai.
    var retryReason: String?
    /// Le dernier échec vient d'une coupure réseau : on attend le retour de la connexion, sans compter d'essai.
    var networkLost = false
    /// Dernière mesure (date, octets reçus) pour calculer la vitesse actuelle.
    var sample: (date: Date, bytes: Double)?

    var cancel: (() -> Void)?

    init(kind: Kind) {
        self.kind = kind
        switch kind {
        case let .macOS(i):
            title = "macOS \(i.name) \(i.version)"
            totalBytes = i.sizeBytes
        case let .ipsw(f, destination):
            title = "IPSW \((destination as NSString).deletingLastPathComponent.split(separator: "/").last.map(String.init) ?? f.identifier) \(f.version)"
            totalBytes = f.filesize
        }
    }

    var isFinished: Bool {
        switch state { case .done, .failed, .cancelled: return true; default: return false }
    }
    var eta: TimeInterval? {
        guard state == .running, speed > 0 else { return nil }
        return Double(totalBytes) * (1 - progress) / speed
    }
    /// Clé pour ne pas mettre deux fois la même chose en file.
    var key: String {
        switch kind {
        case let .macOS(i): return "macos-" + i.version
        case let .ipsw(f, d): return "ipsw-" + f.id + d
        }
    }
}

/// Suit la connexion réseau (Wi-Fi coupé, câble débranché…).
final class NetworkWatcher: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.lock(); self?.online = path.status == .satisfied; self?.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "reseau"))
    }

    var isOnline: Bool { lock.lock(); defer { lock.unlock() }; return online }

    /// Erreurs dues à la connexion (et non au fichier ou au serveur).
    static func isConnectionError(_ error: Error) -> Bool {
        let codes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                                      .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
                                      .secureConnectionFailed, .cannotLoadFromNetwork]
        return (error as? URLError).map { codes.contains($0.code) } ?? false
    }
}

/// Un téléchargement vu par un autre processus (l'icône de la barre des menus voit ceux de l'app, et inversement).
struct SharedDownload: Codable, Identifiable {
    let key: String
    let title: String
    let progress: Double
    let verifying: Bool
    var total: Int64 = 0
    var speed: Double = 0          // octets / seconde
    var eta: TimeInterval?
    var pid: Int32 = 0             // processus qui télécharge (pour lui demander d'annuler)
    var id: String { key }
}

/// État des téléchargements de chaque processus, dans un petit fichier par processus, réécrit chaque seconde.
enum SharedDownloads {
    private static let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/PrepareDisk/downloads")

    @MainActor
    static func shared(_ job: DownloadJob) -> SharedDownload {
        SharedDownload(key: job.key, title: job.title, progress: job.progress, verifying: job.state == .verifying,
                       total: job.totalBytes, speed: job.speed, eta: job.eta, pid: getpid())
    }

    @MainActor
    static func publish(_ jobs: [DownloadJob]) {
        let file = folder.appendingPathComponent("\(getpid()).json")
        let active = jobs.filter { !$0.isFinished }
        if active.isEmpty { try? FileManager.default.removeItem(at: file); return }
        let shared = active.map(shared)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(shared).write(to: file, options: .atomic)
    }

    /// Demande au processus qui télécharge d'annuler ce téléchargement.
    static func requestCancel(_ download: SharedDownload) {
        let folder = folder.appendingPathComponent("cancel-\(download.pid)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = Data(download.key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: nil)
    }

    /// Annulations demandées à ce processus par un autre (lues puis effacées).
    static func takeCancelRequests() -> Set<String> {
        let folder = folder.appendingPathComponent("cancel-\(getpid())")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        try? FileManager.default.removeItem(at: folder)
        return Set(names.compactMap { Data(base64Encoded: $0.replacingOccurrences(of: "_", with: "/")).map { String(decoding: $0, as: UTF8.self) } })
    }

    /// Les téléchargements des autres processus encore en vie (fichier récent).
    static func others() -> [SharedDownload] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.flatMap { name -> [SharedDownload] in
            let url = folder.appendingPathComponent(name)
            guard let pid = Int32((name as NSString).deletingPathExtension), pid != getpid() else { return [] }
            let fresh = ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
                .map { Date().timeIntervalSince($0) < 10 } ?? false
            guard kill(pid, 0) == 0, fresh else { try? FileManager.default.removeItem(at: url); return [] }
            return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([SharedDownload].self, from: $0) } ?? []
        }
    }
}

/// File d'attente des téléchargements, un à la fois.
@MainActor
@Observable
final class DownloadManager {
    private let settings: AppSettings
    private let library: Library
    private let notifier: Notifier
    var jobs: [DownloadJob] = []
    /// Téléchargements faits par un autre processus (l'icône de la barre des menus), relus toutes les 2 secondes.
    var external: [SharedDownload] = []
    /// Pour trouver le paquet officiel d'un macOS dans le catalogue d'Apple.
    weak var catalog: Catalog?
    /// Appelé quand la file est vide après au moins un téléchargement réussi (nettoyage des anciennes versions).
    var onFinished: (() async -> Void)?
    /// Téléchargements simultanés (un seul macOS à la fois : softwareupdate ne sait pas en faire deux).
    static let maxParallel = 3
    private var runningCount = 0
    /// Empêche la mise en veille tant qu'un téléchargement tourne.
    private var awake: NSObjectProtocol?
    private var succeededSinceIdle = false

    init(settings: AppSettings, library: Library, notifier: Notifier) {
        self.settings = settings
        self.library = library
        self.notifier = notifier
    }

    var active: [DownloadJob] { jobs.filter { !$0.isFinished } }
    var current: DownloadJob? { jobs.first { $0.state == .running || $0.state == .verifying } }

    /// Ajoute un téléchargement (ou renvoie celui déjà en cours pour la même chose).
    @discardableResult
    func enqueue(_ kind: DownloadJob.Kind) -> DownloadJob {
        let job = DownloadJob(kind: kind)
        if let existing = jobs.first(where: { $0.key == job.key && !$0.isFinished }) { return existing }
        jobs.append(job)
        schedule()
        return job
    }

    func retry(_ job: DownloadJob) { enqueue(job.kind) }

    func clearFinished() { jobs.removeAll { $0.isFinished } }

    /// Attend la fin des téléchargements donnés ; true s'ils ont tous réussi.
    func wait(for jobs: [DownloadJob]) async -> Bool {
        while jobs.contains(where: { !$0.isFinished }) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        return jobs.allSatisfy { $0.state == .done }
    }

    /// Lance les téléchargements en attente, jusqu'à `maxParallel` à la fois.
    private func schedule() {
        while runningCount < Self.maxParallel, let job = nextJob() {
            if awake == nil {
                awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                              reason: "Téléchargement des versions validées")
                // Partage l'avancement chaque seconde (l'icône de la barre des menus l'affiche en direct).
                Task {
                    while awake != nil {
                        SharedDownloads.publish(jobs)
                        // Annulations demandées depuis l'app (ou depuis l'icône).
                        let cancels = SharedDownloads.takeCancelRequests()
                        for job in jobs where cancels.contains(job.key) && !job.isFinished { cancel(job) }
                        try? await Task.sleep(for: .seconds(1))
                    }
                    SharedDownloads.publish([])
                }
            }
            runningCount += 1
            job.state = .running
            Task {
                await run(job)
                runningCount -= 1
                schedule()
                if runningCount == 0 {
                    if let awake { ProcessInfo.processInfo.endActivity(awake); self.awake = nil }
                    notifier.setDockProgress(nil)
                    await library.scan()
                    if succeededSinceIdle { succeededSinceIdle = false; await onFinished?() }
                }
            }
        }
    }

    private func nextJob() -> DownloadJob? {
        let macOSRunning = jobs.contains { job in
            if case .macOS = job.kind, job.state == .running || job.state == .verifying { return true }
            return false
        }
        return jobs.first { job in
            guard job.state == .queued else { return false }
            if case .macOS = job.kind { return !macOSRunning }
            return true
        }
    }

    /// Un téléchargement, relancé tout seul en cas d'échec (jusqu'à `maxAttempts` essais).
    private func run(_ job: DownloadJob) async {
        while true {
            job.state = .running
            job.startedAt = Date()
            job.sample = nil
            job.speed = 0
            switch job.kind {
            case let .macOS(installer): await runMacOS(job, installer)
            case let .ipsw(firmware, destination): await runIPSW(job, firmware, destination)
            }
            // Coupure réseau : ce n'est pas un échec. On attend que la connexion revienne, puis on reprend
            // où on en était (fichier partiel), aussi longtemps qu'il faut.
            if case .failed = job.state, job.networkLost {
                job.networkLost = false
                job.retryReason = "connexion perdue : reprise dès le retour du réseau"
                job.speed = 0
                job.state = .queued
                while !network.isOnline && job.state != .cancelled { try? await Task.sleep(for: .seconds(2)) }
                if job.state == .cancelled { return }
                try? await Task.sleep(for: .seconds(3))   // laisse la connexion se stabiliser
                continue
            }
            // Vraie erreur : on recommence (après une pause), sauf au dernier essai.
            guard case let .failed(reason) = job.state, job.attempt < DownloadJob.maxAttempts else { break }
            job.attempt += 1
            job.retryReason = reason
            job.progress = 0
            job.speed = 0
            job.state = .queued        // reste « en cours » pour ceux qui attendent ce téléchargement
            try? await Task.sleep(for: .seconds(10 * (job.attempt - 1)))
            if job.state == .cancelled { return }
        }
        switch job.state {
        case .done:
            succeededSinceIdle = true
            notifier.notify("Téléchargement terminé", job.title)
        case let .failed(reason): notifier.notify("Téléchargement échoué", "\(job.title) : \(reason)", isError: true)
        default: break
        }
    }

    /// État du réseau, suivi en continu.
    private let network = NetworkWatcher()

    /// Échec d'un téléchargement : coupure réseau (on attendra) ou vraie erreur (comptée).
    private func fail(_ job: DownloadJob, _ error: Error) {
        job.networkLost = NetworkWatcher.isConnectionError(error) || !network.isOnline
        job.state = .failed(error.localizedDescription)
    }

    private func update(_ job: DownloadJob, progress: Double) {
        guard progress > job.progress else { return }
        job.progress = min(progress, 1)
        // Vitesse actuelle : octets reçus depuis la dernière mesure, lissée sur quelques secondes. (Une moyenne
        // depuis le début se trompe après une reprise et quand les téléchargements se partagent la connexion.)
        let bytes = Double(job.totalBytes) * job.progress, now = Date()
        if let sample = job.sample {
            let elapsed = now.timeIntervalSince(sample.date)
            if elapsed >= 1 {
                let current = max(0, (bytes - sample.bytes) / elapsed)
                job.speed = job.speed == 0 ? current : job.speed * 0.85 + current * 0.15
                job.sample = (now, bytes)
            }
        } else {
            job.sample = (now, bytes)
        }
        // Progression globale de tous les téléchargements en cours, dans le Dock.
        let running = jobs.filter { $0.state == .running }
        let total = running.reduce(0) { $0 + Double($1.totalBytes) }
        if total > 0 { notifier.setDockProgress(running.reduce(0) { $0 + Double($1.totalBytes) * $1.progress } / total) }
    }

    // MARK: macOS (softwareupdate, l'installateur arrive dans /Applications)

    private func runMacOS(_ job: DownloadJob, _ installer: Installer) async {
        if let package = catalog?.packages[installer.build] { return await runPackage(job, installer, package) }
        var process: Process?
        job.cancel = { process?.terminate() }
        let status = await Shell.stream("/usr/sbin/softwareupdate",
                                        ["--fetch-full-installer", "--full-installer-version", installer.version],
                                        onStart: { process = $0 }) { text in
            Task { @MainActor in
                if let m = text.matches(of: #/([\d.]+)%/#).last, let value = Double(m.1) {
                    self.update(job, progress: value / 100)
                }
            }
        }
        job.cancel = nil
        if job.state == .cancelled { return }
        await library.scan()
        // softwareupdate dépose l'installateur dans /Applications : on le range dans OS/MacOS/Intel.
        if status == 0, let app = library.installers.first(where: { $0.version == installer.version && $0.path.hasPrefix("/Applications/") }) {
            await library.move(app.path, to: settings.installerPath(name: installer.name, version: installer.version))
            await library.scan()
        }
        if status == 0, library.installer(matching: installer) != nil {
            job.progress = 1
            job.state = .done
        } else {
            job.state = .failed(status == 0 ? "installateur introuvable après téléchargement" : "softwareupdate a échoué (code \(status))")
        }
    }

    // MARK: macOS (paquet officiel d'Apple, sans mot de passe)

    /// Télécharge InstallAssistant.pkg (en morceaux parallèles), vérifie la signature d'Apple, puis assemble
    /// « Install macOS ….app » directement dans OS/MacOS/Intel : ni /Applications, ni mot de passe.
    private func runPackage(_ job: DownloadJob, _ installer: Installer, _ package: InstallerPackage) async {
        let fm = FileManager.default
        // Dossier de travail au nom du build : un téléchargement interrompu y reprend.
        let work = URL(fileURLWithPath: settings.intelFolder).appendingPathComponent(".\(package.build).work")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        var keepForResume = true
        defer { if !keepForResume { try? fm.removeItem(at: work) } }
        // Le paquet, puis son contenu extrait : il faut environ deux fois sa taille.
        let free = (try? work.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? .max
        let already = (try? fm.attributesOfItem(atPath: work.appendingPathComponent("InstallAssistant.pkg").path)[.size] as? Int64) ?? 0
        guard free + already > package.size * 21 / 10 else {
            job.state = .failed("espace disque insuffisant (\((package.size * 21 / 10).fileSize) nécessaires)")
            return
        }
        let pkg = work.appendingPathComponent("InstallAssistant.pkg")
        let downloader = SegmentedDownloader()
        job.cancel = { downloader.cancel() }
        job.totalBytes = package.size
        let result = await downloader.download(package.url, size: package.size, to: pkg) { written, total in
            Task { @MainActor in self.update(job, progress: Double(written) / Double(max(total, 1)) * 0.95) }
        }
        job.cancel = nil
        if job.state == .cancelled { return }
        if case let .failure(error) = result { fail(job, error); return }
        keepForResume = false   // téléchargé : quoi qu'il arrive ensuite, on ne réutilisera pas ce dossier

        // Certification : paquet signé par Apple (sa table des matières, signée, contient l'empreinte de chaque
        // fichier, que l'extraction vérifie), puis image système lisible avec la bonne version et le bon build.
        job.state = .verifying
        let signature = await Shell.run("/usr/sbin/pkgutil", ["--check-signature", pkg.path])
        guard signature.status == 0, signature.output.contains("signed Apple Software") else {
            job.state = .failed("paquet non signé par Apple, il sera retéléchargé")
            return
        }
        let out = work.appendingPathComponent("out")
        try? fm.removeItem(at: out)
        guard await Shell.run("/usr/sbin/pkgutil", ["--expand-full", pkg.path, out.path]).status == 0 else {
            job.state = .failed("paquet abîmé, il sera retéléchargé")
            return
        }
        try? fm.removeItem(at: pkg)
        let apps = out.appendingPathComponent("Payload/Applications")
        guard let name = (try? fm.contentsOfDirectory(atPath: apps.path))?.first(where: { $0.hasSuffix(".app") }) else {
            job.state = .failed("installateur absent du paquet")
            return
        }
        let app = apps.appendingPathComponent(name)
        let destination = URL(fileURLWithPath: settings.installerPath(name: installer.name, version: installer.version))
        do {
            let shared = app.appendingPathComponent("Contents/SharedSupport")
            try fm.createDirectory(at: shared, withIntermediateDirectories: true)
            try fm.moveItem(at: out.appendingPathComponent("SharedSupport.dmg"), to: shared.appendingPathComponent("SharedSupport.dmg"))
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: app, to: destination)
        } catch {
            job.state = .failed(error.localizedDescription)
            return
        }
        await library.scan()
        if let local = library.installer(matching: installer), await library.certifyInstaller(local) {
            job.progress = 1
            job.state = .done
        } else {
            try? fm.removeItem(at: destination)
            job.state = .failed("installateur assemblé mais invalide (version, build ou signature)")
        }
    }

    // MARK: IPSW (URLSession, avec contrôle SHA-1)

    private func runIPSW(_ job: DownloadJob, _ firmware: Firmware, _ destination: String) async {
        guard let url = URL(string: firmware.url) else { job.state = .failed("adresse invalide"); return }
        let progress: @Sendable (Int64, Int64) -> Void = { written, total in
            Task { @MainActor in
                if total > 0 { job.totalBytes = total }
                self.update(job, progress: Double(written) / Double(max(total, 1)))
            }
        }
        let result: Result<URL, Error>
        if let size = await SegmentedDownloader.size(of: url) {
            // En plusieurs morceaux en parallèle, écrits directement dans le dossier de destination.
            let folder = (destination as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            // Nom fixe : un téléchargement interrompu reprend sur ce même fichier partiel.
            let part = URL(fileURLWithPath: folder).appendingPathComponent("." + (destination as NSString).lastPathComponent + ".part")
            let downloader = SegmentedDownloader()
            job.cancel = { downloader.cancel() }
            result = await downloader.download(url, size: size, to: part, onProgress: progress)
        } else {
            let downloader = FileDownloader()
            job.cancel = { downloader.cancel() }
            result = await downloader.download(url, onProgress: progress)
        }
        job.cancel = nil
        if job.state == .cancelled { return }
        switch result {
        case let .failure(error):
            fail(job, error)
        case let .success(temp):
            // Certification obligatoire : l'empreinte SHA-1 doit être celle publiée pour ce firmware.
            job.state = .verifying
            if let expected = firmware.sha1sum {
                let actual = await Task.detached { sha1(of: temp) }.value
                guard actual == expected.lowercased() else {
                    try? FileManager.default.removeItem(at: temp)
                    try? FileManager.default.removeItem(at: SegmentedDownloader.stateURL(for: temp))
                    job.state = .failed("fichier corrompu (SHA-1 différent), il sera retéléchargé")
                    return
                }
            }
            // Et le contenu : bons modèles, bon build.
            let check = LocalFile(path: temp.path, size: itemSize(temp.path), date: Date())
            guard check.matches(firmware) else {
                try? FileManager.default.removeItem(at: temp)
                job.state = .failed("ce n'est pas le bon firmware (modèle ou build différent)")
                return
            }
            do {
                let dest = URL(fileURLWithPath: destination)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.moveItem(at: temp, to: dest)
                library.markCertified(dest.path)
                job.progress = 1
                job.state = .done
            } catch {
                job.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel(_ job: DownloadJob) {
        let wasRunning = job.state == .running || job.state == .verifying
        job.state = .cancelled
        if wasRunning { job.cancel?() }
    }
}

/// SHA-1 d'un gros fichier, lu par morceaux.
func sha1(of url: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    var hasher = Insecure.SHA1()
    while let chunk = try? handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Téléchargement en plusieurs morceaux en parallèle (requêtes Range), chacun écrit directement à sa place
/// dans le fichier. Interrompu (réseau, app quittée, Mac redémarré), il reprend où il en était : l'avancement
/// de chaque morceau est noté dans « fichier.state » à côté du fichier partiel.
final class SegmentedDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let parts = 12

    /// Un morceau : de `start` à `end` (inclus), écrit jusqu'à `next`.
    struct Segment: Codable {
        let start: Int64
        let end: Int64
        var next: Int64
        var isDone: Bool { next > end }
    }
    private struct State: Codable {
        let url: String
        let size: Int64
        var segments: [Segment]
    }

    // Tout est manipulé sur la file (série) des délégués de la session.
    private var session: URLSession?
    private var handle: FileHandle?
    private var state: State?
    private var taskSegment: [Int: Int] = [:]   // tâche → numéro du morceau
    private var written: Int64 = 0
    private var remaining = 0
    private var failure: Error?
    private var lastReport = Date.distantPast
    private var lastSave = Date.distantPast
    private var file: URL?
    private var onProgress: ((Int64, Int64) -> Void)?
    private var continuation: CheckedContinuation<Result<URL, Error>, Never>?

    struct DownloadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Taille du fichier si le serveur accepte les morceaux ; nil sinon (téléchargement simple).
    static func size(of url: URL) async -> Int64? {
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: head),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").contains("bytes"),
              http.expectedContentLength > 0 else { return nil }
        return http.expectedContentLength
    }

    static func stateURL(for file: URL) -> URL { file.appendingPathExtension("state") }

    func download(_ url: URL, size: Int64, to file: URL, onProgress: @escaping (Int64, Int64) -> Void) async -> Result<URL, Error> {
        self.file = file
        self.onProgress = onProgress
        let fm = FileManager.default
        // Reprise : même adresse, même taille, fichier partiel présent.
        var state = (try? Data(contentsOf: Self.stateURL(for: file))).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        if state?.url != url.absoluteString || state?.size != size || !fm.fileExists(atPath: file.path) { state = nil }
        if state == nil {
            guard fm.createFile(atPath: file.path, contents: nil) else { return .failure(DownloadError(message: "impossible de créer le fichier")) }
            let chunk = (size + Int64(Self.parts) - 1) / Int64(Self.parts)
            var segments: [Segment] = []
            var start: Int64 = 0
            while start < size {
                let end = min(start + chunk, size) - 1
                segments.append(Segment(start: start, end: end, next: start))
                start = end + 1
            }
            state = State(url: url.absoluteString, size: size, segments: segments)
        }
        guard let state, let handle = try? FileHandle(forWritingTo: file) else {
            return .failure(DownloadError(message: "impossible d'ouvrir le fichier"))
        }
        try? handle.truncate(atOffset: UInt64(size))
        self.handle = handle
        written = state.segments.reduce(0) { $0 + ($1.next - $1.start) }
        let todo = state.segments.indices.filter { !state.segments[$0].isDone }
        self.state = state
        if todo.isEmpty { return finishNow() }

        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = Self.parts
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        return await withCheckedContinuation { continuation in
            session.delegateQueue.addOperation {
                self.continuation = continuation
                self.onProgress?(self.written, size)
                var tasks: [URLSessionDataTask] = []
                for index in todo {
                    let segment = state.segments[index]
                    var request = URLRequest(url: url)
                    request.setValue("bytes=\(segment.next)-\(segment.end)", forHTTPHeaderField: "Range")
                    let task = session.dataTask(with: request)
                    self.taskSegment[task.taskIdentifier] = index
                    tasks.append(task)
                }
                self.remaining = tasks.count
                tasks.forEach { $0.resume() }
            }
        }
    }

    /// Tous les morceaux étaient déjà là (reprise d'un téléchargement terminé).
    private func finishNow() -> Result<URL, Error> {
        try? handle?.close()
        if let file { try? FileManager.default.removeItem(at: Self.stateURL(for: file)) }
        return file.map { .success($0) } ?? .failure(DownloadError(message: "fichier introuvable"))
    }

    private func saveState() {
        guard let state, let file, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.stateURL(for: file), options: .atomic)
        lastSave = Date()
    }

    func cancel() { session?.invalidateAndCancel() }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard (response as? HTTPURLResponse)?.statusCode == 206 else {
            failure = failure ?? DownloadError(message: "le serveur refuse les morceaux")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let index = taskSegment[dataTask.taskIdentifier], var segment = state?.segments[index], let handle else { return }
        do {
            try handle.seek(toOffset: UInt64(segment.next))
            try handle.write(contentsOf: data)
        } catch {
            failure = failure ?? error
            session.invalidateAndCancel()
            return
        }
        segment.next += Int64(data.count)
        state?.segments[index] = segment
        written += Int64(data.count)
        if Date().timeIntervalSince(lastSave) > 2 { saveState() }
        if Date().timeIntervalSince(lastReport) > 0.25 {
            lastReport = Date()
            onProgress?(written, state?.size ?? 0)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, failure == nil {
            failure = error
            session.invalidateAndCancel()   // un morceau raté : on arrête, l'essai suivant reprend où on en est
        }
        remaining -= 1
        guard remaining == 0 else { return }
        try? handle?.synchronize()
        try? handle?.close()
        session.finishTasksAndInvalidate()
        let complete = state?.segments.allSatisfy(\.isDone) == true
        if failure == nil && !complete { failure = DownloadError(message: "fichier incomplet") }
        if let failure {
            saveState()   // le fichier partiel est gardé pour reprendre
            finish(.failure(failure))
        } else if let file {
            try? FileManager.default.removeItem(at: Self.stateURL(for: file))
            onProgress?(written, state?.size ?? 0)
            finish(.success(file))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// Téléchargement d'un fichier avec suivi de la progression.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Result<URL, Error>, Never>?
    private var onProgress: ((Int64, Int64) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    func download(_ url: URL, onProgress: @escaping (Int64, Int64) -> Void) async -> Result<URL, Error> {
        self.onProgress = onProgress
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            task = session.downloadTask(with: url)
            task?.resume()
        }
    }

    func cancel() { task?.cancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Le fichier temporaire est supprimé au retour : on le déplace tout de suite.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipsw")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        session.finishTasksAndInvalidate()
    }

    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
