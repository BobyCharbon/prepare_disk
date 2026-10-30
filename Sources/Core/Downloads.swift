import CryptoKit
import Foundation
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

/// File d'attente des téléchargements, un à la fois.
@MainActor
@Observable
final class DownloadManager {
    private let settings: AppSettings
    private let library: Library
    private let notifier: Notifier
    var jobs: [DownloadJob] = []
    /// Appelé quand la file est vide après au moins un téléchargement réussi (nettoyage des anciennes versions).
    var onFinished: (() async -> Void)?
    private var isRunning = false

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
        Task { await runQueue() }
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

    private func runQueue() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false; notifier.setDockProgress(nil) }
        var succeeded = false
        while let job = jobs.first(where: { $0.state == .queued }) {
            job.state = .running
            job.startedAt = Date()
            switch job.kind {
            case let .macOS(installer): await runMacOS(job, installer)
            case let .ipsw(firmware, destination): await runIPSW(job, firmware, destination)
            }
            // Échec : on recommence (après une pause, la connexion revient souvent), sauf au dernier essai.
            if case let .failed(reason) = job.state, job.attempt < DownloadJob.maxAttempts {
                job.attempt += 1
                job.retryReason = reason
                job.progress = 0
                job.speed = 0
                job.state = .queued        // reste « en cours » pour ceux qui attendent ce téléchargement
                try? await Task.sleep(for: .seconds(10 * (job.attempt - 1)))
                continue
            }
            if job.state == .done { succeeded = true }
            switch job.state {
            case .done: notifier.notify("Téléchargement terminé", job.title)
            case let .failed(reason): notifier.notify("Téléchargement échoué", "\(job.title) : \(reason)", isError: true)
            default: break
            }
        }
        await library.scan()
        if succeeded { await onFinished?() }
    }

    private func update(_ job: DownloadJob, progress: Double) {
        guard progress > job.progress, let start = job.startedAt else { return }
        let elapsed = Date().timeIntervalSince(start)
        job.progress = min(progress, 1)
        if elapsed > 2 { job.speed = Double(job.totalBytes) * job.progress / elapsed }
        notifier.setDockProgress(job.progress)
    }

    // MARK: macOS (softwareupdate, l'installateur arrive dans /Applications)

    private func runMacOS(_ job: DownloadJob, _ installer: Installer) async {
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

    // MARK: IPSW (URLSession, avec contrôle SHA-1)

    private func runIPSW(_ job: DownloadJob, _ firmware: Firmware, _ destination: String) async {
        guard let url = URL(string: firmware.url) else { job.state = .failed("adresse invalide"); return }
        let downloader = FileDownloader()
        job.cancel = { downloader.cancel() }
        let result = await downloader.download(url) { written, total in
            Task { @MainActor in
                if total > 0 { job.totalBytes = total }
                self.update(job, progress: Double(written) / Double(max(total, 1)))
            }
        }
        job.cancel = nil
        if job.state == .cancelled { return }
        switch result {
        case let .failure(error):
            job.state = .failed(error.localizedDescription)
        case let .success(temp):
            if settings.verifyChecksums, let expected = firmware.sha1sum {
                job.state = .verifying
                let actual = await Task.detached { sha1(of: temp) }.value
                guard actual == expected.lowercased() else {
                    try? FileManager.default.removeItem(at: temp)
                    job.state = .failed("fichier corrompu (SHA-1 différent)")
                    return
                }
            }
            do {
                let dest = URL(fileURLWithPath: destination)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.moveItem(at: temp, to: dest)
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
private func sha1(of url: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    var hasher = Insecure.SHA1()
    while let chunk = try? handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
