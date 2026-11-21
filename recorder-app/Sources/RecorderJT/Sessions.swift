import AppKit
import Foundation

enum SessionState: Equatable {
    case recording, processing, ready, failed(String)
}

struct SessionInfo: Identifiable, Equatable {
    let id: String
    let dir: URL
    let title: String
    let date: Date?
    let ended: Date?
    let state: SessionState
    let labels: [String]
    /// "Persona 2" → "Testigo" (lo pone el usuario; se aplica al ver y copiar)
    let speakerNames: [String: String]
    /// De dónde viene: "Audio subido", "Reunión de Teams", "Micrófono"…
    var origin: String = "Grabación"
    var isUpload = false
    /// Audio para escuchar (playback.m4a) y su forma de onda, si ya existen.
    var playbackDuration: Double?
    var peaks: [Float] = []
    var playbackVersion: Date?
    /// Resumen: summary.md, y su estado si se pidió (running | done | failed).
    var hasSummary = false
    var summaryStatus: String?
    var summaryError: String?
    var summaryProvider: String?

    var playbackURL: URL { dir.appendingPathComponent("playback.m4a") }

    /// Duración en segundos (del audio de reproducción o de las horas de inicio y fin).
    var duration: Double? {
        if let playbackDuration { return playbackDuration }
        guard let date, let ended else { return nil }
        return ended.timeIntervalSince(date)
    }

    var isFailed: Bool { if case .failed = state { return true } else { return false } }

    func displayName(_ speaker: String) -> String { speakerNames[speaker] ?? speaker }

    var subtitle: String {
        let d = date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        let dur: String = {
            guard let date, let ended else { return "" }
            let m = Int(ended.timeIntervalSince(date) / 60)
            return m >= 60 ? " · \(m / 60) h \(m % 60) min" : " · \(max(m, 1)) min"
        }()
        switch state {
        case .recording: return hasTranscript ? "Grabando… (texto por bloques)" : "Grabando…"
        case .processing: return "Transcribiendo… · \(d)"
        case .ready: return d + dur
        case let .failed(err): return "Error: \(err)"
        }
    }

    var transcript: URL { dir.appendingPathComponent("transcript.txt") }
    var hasTranscript: Bool { FileManager.default.fileExists(atPath: transcript.path) }
}

/// Lee y escribe sesiones en ~/RecorderJT/sessions (mismo formato que el worker).
enum SessionStore {
    /// Carpeta de datos. `RJT_HOME` permite otra (p. ej. datos de demostración para capturas).
    static let home: URL = ProcessInfo.processInfo.environment["RJT_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("RecorderJT")
    static let sessionsDir = home.appendingPathComponent("sessions")

    static func manifest(_ dir: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func writeManifest(_ m: [String: Any], to dir: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
    }

    static func update(_ dir: URL, _ fields: [String: Any]) {
        guard var m = manifest(dir) else { return }
        for (k, v) in fields { m[k] = v }
        try? writeManifest(m, to: dir)
    }

    /// playback.json ya leídos (la forma de onda no cambia salvo que se regenere).
    @MainActor private static var playbackCache: [String: (Date, Double?, [Float])] = [:]

    @MainActor private static func playback(_ url: URL, _ mtime: Date) -> (Double?, [Float])? {
        if let c = playbackCache[url.path], c.0 == mtime { return (c.1, c.2) }
        guard let data = try? Data(contentsOf: url),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let v = ((j["duration_s"] as? NSNumber)?.doubleValue, ((j["peaks"] as? [NSNumber]) ?? []).map { $0.floatValue })
        playbackCache[url.path] = (mtime, v.0, v.1)
        return v
    }

    @MainActor static func list(limit: Int = 1000) -> [SessionInfo] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else { return [] }
        let iso = ISO8601DateFormatter()
        return dirs
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .compactMap { dir -> SessionInfo? in
                guard let m = manifest(dir) else { return nil }
                let state: SessionState
                let status = m["status"] as? String
                if status == "recording" {
                    state = .recording
                } else if (m["pipeline"] as? String) == "done" ||
                            (fm.fileExists(atPath: dir.appendingPathComponent("transcript.txt").path) && m["pipeline"] == nil && status != "recorded" && status != "recovered") {
                    state = .ready
                } else if (m["pipeline"] as? String) == "failed" {
                    state = .failed((m["pipeline_error"] as? String) ?? "error")
                } else {
                    state = .processing
                }
                let started = (m["started_at"] as? String).flatMap { iso.date(from: $0) }
                let ended = (m["ended_at"] as? String).flatMap { iso.date(from: $0) }
                var info = SessionInfo(id: dir.lastPathComponent, dir: dir,
                                       title: (m["title"] as? String) ?? dir.lastPathComponent,
                                       date: started, ended: ended, state: state,
                                       labels: (m["labels"] as? [String]) ?? [],
                                       speakerNames: (m["speaker_names"] as? [String: String]) ?? [:])
                let tracks = (m["tracks"] as? [String: Any]) ?? [:]
                if (m["source"] as? String) == "import" {
                    info.isUpload = true; info.origin = "Audio subido"
                } else if let app = (m["source_apps"] as? [String])?.first {
                    info.origin = "Reunión de \(app)"
                } else if tracks.keys.contains(where: { $0.hasPrefix("mixed") }) {
                    info.origin = "Micrófono"
                }
                info.hasSummary = fm.fileExists(atPath: dir.appendingPathComponent("summary.md").path)
                info.summaryStatus = m["summary_status"] as? String
                info.summaryError = m["summary_error"] as? String
                info.summaryProvider = m["summary_provider"] as? String
                let pj = dir.appendingPathComponent("playback.json")
                if let mtime = (try? fm.attributesOfItem(atPath: pj.path))?[.modificationDate] as? Date,
                   fm.fileExists(atPath: info.playbackURL.path),
                   let p = playback(pj, mtime) {
                    info.playbackDuration = p.0
                    info.peaks = p.1
                    info.playbackVersion = mtime
                }
                return info
            }
    }

    static func newSessionDir(title: String) throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmm"
        let slug = title.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        let id = "\(f.string(from: Date()))_\(slug.prefix(30))_\(String(format: "%04x", Int.random(in: 0..<0xffff)))"
        let dir = sessionsDir.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Nombre de la app de reunión abierta, para titular la sesión.
    static func detectMeetingApp() -> String? {
        let known: [String: String] = [
            "us.zoom.xos": "Zoom",
            "com.microsoft.teams2": "Teams",
            "com.microsoft.teams": "Teams",
            "com.cisco.webexmeetingsapp": "Webex",
            "Cisco-Systems.Spark": "Webex",
        ]
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, let name = known[id] { return name }
        }
        return nil
    }
}

/// Registro propio en ~/RecorderJT/logs/app.log (diagnóstico de permisos, errores).
enum AppLog {
    static let url = SessionStore.home.appendingPathComponent("logs/app.log")

    static func write(_ msg: String) {
        NSLog("RecorderJT: \(msg)")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); try? fh.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }
}

/// Ejecuta el worker de Python (`recorder`) para transcribir.
enum Worker {
    static var cliPath: String {
        // install.sh / bundle_app.sh escriben aquí la ruta del worker de esta copia del repo.
        (Bundle.main.object(forInfoDictionaryKey: "RJTWorkerCLI") as? String) ?? "/usr/local/bin/recorder"
    }

    static func run(_ args: [String], background: Bool = false, completion: @escaping (Int32) -> Void) {
        let p = Process()
        p.qualityOfService = background ? .utility : .userInitiated
        p.executableURL = URL(fileURLWithPath: cliPath)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let log = SessionStore.home.appendingPathComponent("logs/app-worker.log")
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        if let fh = try? FileHandle(forWritingTo: log) {
            fh.seekToEndOfFile()
            p.standardOutput = fh
            p.standardError = fh
        }
        p.terminationHandler = { proc in DispatchQueue.main.async { completion(proc.terminationStatus) } }
        do { try p.run() } catch {
            NSLog("RecorderJT: no se pudo ejecutar \(cliPath): \(error)")
            DispatchQueue.main.async { completion(-1) }
        }
    }
}
