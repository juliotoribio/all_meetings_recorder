import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Grabación por bloques: cada ~5 min (en un silencio) se cierra un bloque de
/// cada pista y se transcribe en segundo plano mientras sigue la reunión.
/// Al detener sólo falta transcribir el último bloque (~1 min, dure lo que dure).
enum ChunkPolicy {
    /// Duración objetivo de un bloque (2 min: el texto de Whisper llega cada ~2 min;
    /// mientras tanto se ve el texto en vivo). Para pruebas:
    /// `defaults write com.jt.recorderjt chunkSeconds 30`
    static var target: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "chunkSeconds")
        return v >= 10 ? v : 120
    }
    static let maxExtra: TimeInterval = 45       // espera máxima extra buscando un silencio
    static let quietLevel: Float = 0.02          // nivel considerado silencio
    static let quietNeeded: TimeInterval = 0.5   // silencio continuo necesario para cortar
}

@MainActor
final class AppModel: ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var sessions: [SessionInfo] = []
    @Published var message: String?
    @Published var copiedID: String?
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    /// Últimos niveles (para las barras de la vista "Grabando").
    @Published private(set) var levelHistory: [Float] = Array(repeating: 0, count: 72)
    /// Archivos subidos que aún se están copiando (para seleccionar el nuevo al aparecer).
    @Published private(set) var importing = 0
    /// Fuentes a grabar (se recuerdan). Se pueden cambiar también durante la grabación.
    @Published private(set) var micOn = UserDefaults.standard.object(forKey: "micOn") as? Bool ?? true
    @Published private(set) var systemOn = UserDefaults.standard.object(forKey: "systemOn") as? Bool ?? true
    /// Idioma para transcribir: "auto", "es" o "en" (se recuerda; vale para grabar y para subir audios).
    @Published private(set) var language = UserDefaults.standard.string(forKey: "language") ?? "auto"

    /// Calidad: "max" (large-v3, el más preciso) o "fast" (turbo, ~2,5× más rápido).
    @Published private(set) var quality = UserDefaults.standard.string(forKey: "quality") ?? "max"

    /// Cada cuánto llega el texto definitivo (Whisper) mientras se graba: 30, 60 o 120 s.
    @Published private(set) var chunkSeconds = Int(ChunkPolicy.target)

    func setChunkSeconds(_ value: String) {
        guard let s = Int(value), s != chunkSeconds else { return }
        chunkSeconds = s
        UserDefaults.standard.set(Double(s), forKey: "chunkSeconds")
        AppLog.write("texto definitivo cada \(s) s\(isRecording ? " (desde el próximo bloque)" : "")")
    }

    func setQuality(_ code: String) {
        guard code != quality else { return }
        quality = code
        UserDefaults.standard.set(code, forKey: "quality")
        AppLog.write("calidad: \(code)")
    }

    func setLanguage(_ code: String) {
        guard code != language else { return }
        language = code
        UserDefaults.standard.set(code, forKey: "language")
        AppLog.write("idioma: \(code)\(isRecording ? " (se aplica desde la próxima grabación)" : "")")
    }

    /// Texto en vivo (reconocimiento de Apple en el Mac) de la grabación en curso.
    @Published private(set) var liveLines: [LiveLine] = []
    /// Segundo (desde el inicio) en que se cerró cada bloque: lo anterior ya lo cubre Whisper.
    private var chunkEnds: [TimeInterval] = []
    private var liveSources: [String: LiveSource] = [:]
    /// Hay reconocimiento en vivo funcionando en esta grabación.
    var liveAvailable: Bool { !liveSources.isEmpty }

    private var sessionDir: URL?
    private var startDate: Date?
    private var mic: MicCapture?
    private var system: SystemAudioTap?
    private var micWriter: TrackWriter?
    private var systemWriter: TrackWriter?
    private var tick: Timer?
    private var poll: Timer?

    private var chunkIndex = 0
    /// "mic" si también se graba la reunión; "mixed" si sólo el micrófono
    /// (reunión presencial: el micrófono capta a todos y se separan las voces).
    private var micTrack = "mic"
    private var chunkStart = Date()
    private var quietSince: Date?

    /// Cola serial de trabajos del transcriptor (nunca dos a la vez).
    private var jobs: [[String]] = []
    private var workerRunning = false

    init() {
        AppLog.write("app iniciada · micrófono: \(MicCapture.statusName)")
        recoverInterrupted()
        // Prueba automática (sólo con datos de demostración en RJT_HOME):
        // RJT_TEST_RECORD=<segundos> graba, guarda RJT_SNAPSHOT al final y se detiene.
        let env = ProcessInfo.processInfo.environment
        if env["RJT_HOME"] != nil, let secs = env["RJT_TEST_RECORD"].flatMap(Double.init) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                await self?.start()
                try? await Task.sleep(for: .seconds(secs))
                if let out = env["RJT_SNAPSHOT"] { AppDelegate.snapshot(to: out) }
                self?.stop()
            }
        }
        refresh()
        // Si la app se cierra grabando (Salir, apagar el Mac…), cerrar bien los archivos.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.isRecording == true {
                    AppLog.write("cierre de la app durante la grabación: se detiene y guarda")
                    self?.stop()
                }
            }
        }
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfNeeded() }
        }
    }

    // MARK: - permisos

    func toggle() {
        AppLog.write("clic en \(isRecording ? "Detener" : "Grabar")")
        if isRecording { stop() } else {
            message = "Iniciando…"
            Task { await start() }
        }
    }

    /// Pide el permiso del micrófono al abrir la app (así el aviso sale de inmediato).
    func requestMicAtLaunch() {
        Task {
            _ = await MicCapture.requestPermission()
            probeSystemAudioPermission()
        }
    }

    /// macOS no tiene una API para *pedir* el permiso de audio del sistema: el
    /// aviso sólo aparece al empezar a capturar. Se hace una captura de medio
    /// segundo (y se descarta) para que el aviso salga al abrir la app.
    private func probeSystemAudioPermission() {
        guard !isRecording else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rjt-probe-\(UUID().uuidString).caf")
        let writer = TrackWriter(url: tmp)
        let tap = SystemAudioTap(writer: writer)
        do {
            try tap.start()
            AppLog.write("prueba de audio del sistema: tap iniciado")
        } catch {
            AppLog.write("prueba de audio del sistema falló: \(error.localizedDescription)")
            message = "No se pudo acceder al audio del sistema: \(error.localizedDescription)"
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            tap.stop()
            writer.close()
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    func openPrivacySettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    // MARK: - texto en vivo

    private func startLive(enabled: Bool, mic: TrackWriter, system: TrackWriter) {
        liveLines = []
        chunkEnds = []
        liveSources = [:]
        guard enabled else {
            AppLog.write("texto en vivo: sin permiso de reconocimiento de voz")
            return
        }
        let t0 = Date()
        let locales = LiveSpeech.candidates(for: language)
        let emit: (LiveLine) -> Void = { [weak self] line in
            DispatchQueue.main.async { self?.upsertLive(line) }
        }
        let pairs: [(String, TrackWriter)] = [(micTrack == "mic" ? "Yo" : "Participantes", mic), ("Participantes", system)]
        for (i, (speaker, writer)) in pairs.enumerated() {
            guard let src = LiveSource(speaker: speaker, locales: locales,
                                       clock: { Date().timeIntervalSince(t0) }, emit: emit) else {
                AppLog.write("texto en vivo: ningún reconocedor sin conexión para «\(language)»; sólo se usa Whisper")
                return
            }
            liveSources[i == 0 ? "mic" : "system"] = src
            writer.onBuffer = { [weak src] in src?.append($0) }
        }
        AppLog.write("texto en vivo: \(liveSources.values.first?.localeID ?? "?") en el Mac")
    }

    private func upsertLive(_ line: LiveLine) {
        if let i = liveLines.lastIndex(where: { $0.id == line.id }) {
            liveLines[i] = line
        } else {
            liveLines.append(line)
            liveLines.sort { $0.start < $1.start }
            if liveLines.count > 400 { liveLines.removeFirst(liveLines.count - 400) }
        }
    }

    /// Hasta qué segundo de la grabación ya hay texto de Whisper (bloques transcritos).
    private var coveredCache: (String, Date, Int)?

    func whisperCovered(_ s: SessionInfo) -> TimeInterval {
        // Se pide 4 veces por segundo al grabar: sólo se relee si el worker reescribió el archivo.
        let url = s.dir.appendingPathComponent("transcript.json")
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return 0 }
        let idx: Int
        if let c = coveredCache, c.0 == s.id, c.1 == mtime { idx = c.2 } else {
            idx = readCoveredIndex(url)
            coveredCache = (s.id, mtime, idx)
        }
        return idx >= 0 && idx < chunkEnds.count ? chunkEnds[idx] : 0
    }

    private func readCoveredIndex(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = obj["tracks"] as? [String] else { return -1 }
        return tracks.compactMap { Int($0.split(separator: ".").last ?? "") }.max() ?? -1
    }

    /// Líneas en vivo que Whisper aún no ha cubierto.
    func pendingLive(_ s: SessionInfo?) -> [LiveLine] {
        let covered = s.map(whisperCovered) ?? 0
        return liveLines.filter { $0.start >= covered - 1 }
    }

    // MARK: - grabación

    private func chunkURL(_ dir: URL, _ track: String, _ i: Int) -> URL {
        dir.appendingPathComponent("chunks").appendingPathComponent(String(format: "%@_%03d.caf", track, i))
    }

    func start() async {
        message = nil
        let wantMic = micOn, wantSystem = systemOn
        guard wantMic || wantSystem else {
            message = "Activa el micrófono o el audio de la reunión."
            return
        }
        if wantMic, !(await MicCapture.requestPermission()) {
            message = "Sin permiso de micrófono (\(MicCapture.statusName)). Actívalo en Ajustes › Privacidad › Micrófono."
            AppLog.write("grabación cancelada: sin permiso de micrófono")
            return
        }
        let liveOK = await LiveSpeech.authorize()
        let app = SessionStore.detectMeetingApp()
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"
        let title = "\(app ?? "Grabación") \(timeFmt.string(from: Date()))"
        do {
            let dir = try SessionStore.newSessionDir(title: title)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("chunks"), withIntermediateDirectories: true)
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
            try SessionStore.writeManifest([
                "id": dir.lastPathComponent, "title": title, "status": "recording",
                "started_at": iso.string(from: Date()), "language": language, "quality": quality,
                "source": "app", "source_apps": app.map { [$0] } ?? [], "tracks": [String: Any](),
                "chunk_seconds": ChunkPolicy.target,
            ], to: dir)

            chunkIndex = 0
            micTrack = wantSystem ? "mic" : "mixed"
            let mw = TrackWriter(url: chunkURL(dir, micTrack, 0))
            let sw = TrackWriter(url: chunkURL(dir, "system", 0))
            startLive(enabled: liveOK, mic: mw, system: sw)
            var errors: [String] = []
            if wantSystem {
                let sys = SystemAudioTap(writer: sw)
                do { try sys.start(); system = sys } catch { errors.append("audio del sistema: \(error.localizedDescription)") }
            }
            if wantMic {
                let m = MicCapture(writer: mw)
                do { try m.start(); mic = m } catch { errors.append("micrófono: \(error.localizedDescription)") }
            }
            AppLog.write("inicio · sistema: \(wantSystem ? (system != nil ? "ok" : "falló") : "apagado") · mic: \(wantMic ? (mic != nil ? "ok" : "falló") : "apagado") \(errors)")
            if mic == nil && system == nil {
                message = "No se pudo grabar: " + errors.joined(separator: "; ")
                try? FileManager.default.removeItem(at: dir)
                return
            }
            if !errors.isEmpty { message = "Grabando sin " + errors.joined(separator: "; ") }

            micWriter = mw; systemWriter = sw; sessionDir = dir
            startDate = Date(); chunkStart = Date(); quietSince = nil
            elapsed = 0; isRecording = true
            levelHistory = Array(repeating: 0, count: 72)
            tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.onTick() }
            }
            refresh()
        } catch {
            message = "Error al iniciar: \(error.localizedDescription)"
            AppLog.write("error al iniciar: \(error)")
        }
    }

    private func onTick() {
        guard let startDate else { return }
        elapsed = Date().timeIntervalSince(startDate)
        micLevel = micWriter?.level ?? 0
        systemLevel = systemWriter?.level ?? 0
        micWriter?.decayLevel(); systemWriter?.decayLevel()
        levelHistory.append(max(micLevel, systemLevel))
        if levelHistory.count > 72 { levelHistory.removeFirst(levelHistory.count - 72) }

        // ¿Toca cerrar bloque? Se espera un silencio para no partir palabras.
        let quiet = micLevel < ChunkPolicy.quietLevel && systemLevel < ChunkPolicy.quietLevel
        quietSince = quiet ? (quietSince ?? Date()) : nil
        let age = Date().timeIntervalSince(chunkStart)
        if age >= ChunkPolicy.target {
            let silentEnough = quietSince.map { Date().timeIntervalSince($0) >= ChunkPolicy.quietNeeded } ?? false
            if silentEnough || age >= ChunkPolicy.target + ChunkPolicy.maxExtra {
                rotateChunk(reason: silentEnough ? "silencio" : "tiempo máximo")
            }
        }
    }

    /// Cierra el bloque actual de ambas pistas, lo registra y lo manda a transcribir.
    private func rotateChunk(reason: String) {
        guard let dir = sessionDir else { return }
        let next = chunkIndex + 1
        var finished: [(String, TrackWriter.Chunk)] = []
        if let w = micWriter { finished.append((micTrack, w.rotate(to: chunkURL(dir, micTrack, next)))) }
        if let w = systemWriter { finished.append(("system", w.rotate(to: chunkURL(dir, "system", next)))) }
        register(finished, index: chunkIndex, in: dir)
        AppLog.write("bloque \(chunkIndex) cerrado (\(reason)) a los \(Int(elapsed))s")
        chunkIndex = next
        chunkEnds.append(elapsed)
        chunkStart = Date()
        quietSince = nil
        enqueue(["chunks", dir.lastPathComponent])
    }

    /// Añade al manifest las pistas de un bloque terminado (sólo si tienen audio).
    private func register(_ finished: [(String, TrackWriter.Chunk)], index: Int, in dir: URL) {
        var tracks = (SessionStore.manifest(dir)?["tracks"] as? [String: Any]) ?? [:]
        for (name, c) in finished where c.frames > 0 {
            tracks[String(format: "%@.%03d", name, index)] = [
                "file": "chunks/\(c.url.lastPathComponent)", "first_host_time_s": c.firstHostSeconds,
            ]
        }
        SessionStore.update(dir, ["tracks": tracks])
    }

    // MARK: - fuentes (encender / apagar)

    /// Enciende o apaga el micrófono. Durante la grabación se detiene la captura
    /// de verdad (macOS quita el indicador); al volver, el hueco queda en silencio
    /// para que el texto siga en su minuto real.
    func setMic(_ on: Bool) {
        guard on != micOn else { return }
        guard on || systemOn || isRecording else { message = "Al menos una fuente debe quedar activa."; return }
        micOn = on
        UserDefaults.standard.set(on, forKey: "micOn")
        AppLog.write("micrófono \(on ? "activado" : "apagado")\(isRecording ? " durante la grabación" : "")")
        guard isRecording, let w = micWriter else { return }
        if on {
            Task {
                guard await MicCapture.requestPermission() else {
                    micOn = false
                    message = "Sin permiso de micrófono. Actívalo en Ajustes › Privacidad › Micrófono."
                    return
                }
                guard isRecording, micOn, mic == nil else { return }
                w.padSilence(untilHost: mach_absolute_time())
                let m = MicCapture(writer: w)
                do { try m.start(); mic = m } catch {
                    micOn = false
                    message = "No se pudo activar el micrófono: \(error.localizedDescription)"
                }
            }
        } else {
            mic?.stop(); mic = nil; micLevel = 0
        }
    }

    /// Igual para el audio de la reunión (lo que suena en el Mac).
    func setSystem(_ on: Bool) {
        guard on != systemOn else { return }
        guard on || micOn || isRecording else { message = "Al menos una fuente debe quedar activa."; return }
        systemOn = on
        UserDefaults.standard.set(on, forKey: "systemOn")
        AppLog.write("audio del sistema \(on ? "activado" : "apagado")\(isRecording ? " durante la grabación" : "")")
        guard isRecording, let w = systemWriter else { return }
        if on {
            guard system == nil else { return }
            w.padSilence(untilHost: mach_absolute_time())
            let sys = SystemAudioTap(writer: w)
            do { try sys.start(); system = sys } catch {
                systemOn = false
                message = "No se pudo activar el audio del sistema: \(error.localizedDescription)"
            }
        } else {
            system?.stop(); system = nil; systemLevel = 0
        }
    }

    func stop() {
        tick?.invalidate(); tick = nil
        mic?.stop(); system?.stop()
        liveSources.values.forEach { $0.stop() }
        liveSources = [:]
        isRecording = false; micLevel = 0; systemLevel = 0

        if let dir = sessionDir {
            var finished: [(String, TrackWriter.Chunk)] = []
            if let w = micWriter { finished.append((micTrack, w.finish())) }
            if let w = systemWriter { finished.append(("system", w.finish())) }
            register(finished, index: chunkIndex, in: dir)
            let tracks = (SessionStore.manifest(dir)?["tracks"] as? [String: Any]) ?? [:]
            AppLog.write("detenido · \(chunkIndex + 1) bloque(s) · \(tracks.count) pistas con audio")
            if tracks.isEmpty {
                SessionStore.update(dir, ["status": "empty", "pipeline": "failed", "pipeline_error": "no se capturó audio"])
                message = "No se capturó audio."
            } else {
                SessionStore.update(dir, ["status": "recorded", "ended_at": ISO8601DateFormatter().string(from: Date())])
                enqueue(["once"])
            }
        }
        mic = nil; system = nil; micWriter = nil; systemWriter = nil; sessionDir = nil
        refresh()
    }

    // MARK: - subir audio

    static let importTypes: [UTType] = [.audio, .movie, .mpeg4Audio, .mpeg4Movie, .quickTimeMovie, .wav, .mp3, .aiff]

    /// Abre el selector de archivos (audio o video: m4a, mp3, wav, mp4, mov…).
    func chooseAudio() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Subir audio para transcribir"
        panel.prompt = "Transcribir"
        panel.allowedContentTypes = Self.importTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importAudio(panel.urls)
    }

    /// Crea una sesión por archivo y la transcribe (el original no se toca: se copia).
    func importAudio(_ urls: [URL]) {
        let files = urls.filter { u in
            guard let t = UTType(filenameExtension: u.pathExtension.lowercased()) else { return false }
            return t.conforms(to: .audio) || t.conforms(to: .movie) || t.conforms(to: .audiovisualContent)
        }
        guard !files.isEmpty else {
            message = "Ese archivo no es de audio ni de video."
            return
        }
        message = nil
        jobs.removeAll { $0 == ["once"] }   // se vuelve a poner al final, tras las importaciones
        for f in files {
            importing += 1
            AppLog.write("subir audio: \(f.lastPathComponent)")
            jobs.append(["import", f.path, "--queue-only", "--no-copy", "--language", language, "--quality", quality])
        }
        jobs.append(["once"])
        runNextJob()
    }

    // MARK: - transcriptor (cola serial)

    private func enqueue(_ args: [String]) {
        if !jobs.contains(args) { jobs.append(args) }
        runNextJob()
    }

    private func runNextJob() {
        guard !workerRunning, !jobs.isEmpty else { return }
        let args = jobs.removeFirst()
        workerRunning = true
        // Los bloques en vivo corren con prioridad baja para no afectar la llamada.
        Worker.run(args, background: args.first == "chunks") { [weak self] status in
            guard let self else { return }
            self.workerRunning = false
            if args.first == "import" && status != 0 {
                self.message = "No se pudo subir \((args[1] as NSString).lastPathComponent)."
            } else if status != 0 && args.first != "chunks" {
                self.message = "El transcriptor terminó con error (ver ~/RecorderJT/logs)."
            }
            AppLog.write("transcriptor \(args.joined(separator: " ")) → \(status)")
            self.refresh()
            if args.first == "import" { self.importing = max(0, self.importing - 1) }
            self.runNextJob()
        }
    }

    func retry(_ s: SessionInfo) {
        SessionStore.update(s.dir, ["pipeline": NSNull(), "pipeline_error": NSNull()])
        refresh()
        enqueue(["retry", s.id])
    }

    /// Sesiones que quedaron en "recording" porque la app se cerró a mitad:
    /// se registran los bloques que existan en disco y se transcriben.
    private func recoverInterrupted() {
        let fm = FileManager.default
        var recovered = false
        for s in SessionStore.list(limit: 50) where s.state == .recording {
            let manifest = SessionStore.manifest(s.dir)
            var tracks = (manifest?["tracks"] as? [String: Any]) ?? [:]
            // inicio aproximado de cada bloque, con la duración con la que se grabó
            let chunkLen = (manifest?["chunk_seconds"] as? NSNumber)?.doubleValue ?? ChunkPolicy.target
            let chunksDir = s.dir.appendingPathComponent("chunks")
            let files = ((try? fm.contentsOfDirectory(atPath: chunksDir.path)) ?? []).sorted()
            for f in files where f.hasSuffix(".caf") {
                let stem = (f as NSString).deletingPathExtension   // "mic_003"
                let parts = stem.split(separator: "_")
                guard parts.count == 2, let i = Int(parts[1]) else { continue }
                let key = String(format: "%@.%03d", String(parts[0]), i)
                let size = ((try? fm.attributesOfItem(atPath: chunksDir.appendingPathComponent(f).path))?[.size] as? Int) ?? 0
                if tracks[key] == nil && size > 8192 {
                    // inicio aproximado: bloques de duración objetivo
                    tracks[key] = ["file": "chunks/\(f)", "first_host_time_s": Double(i) * chunkLen]
                }
            }
            SessionStore.update(s.dir, tracks.isEmpty
                ? ["status": "empty", "pipeline": "failed", "pipeline_error": "grabación interrumpida sin audio"]
                : ["status": "recovered", "tracks": tracks])
            recovered = recovered || !tracks.isEmpty
            AppLog.write("sesión interrumpida recuperada: \(s.id) (\(tracks.count) pistas)")
        }
        if recovered || SessionStore.list(limit: 50).contains(where: { $0.state == .processing }) {
            enqueue(["once"])
        }
    }

    // MARK: - lista / copiar

    func refresh() {
        let fresh = SessionStore.list()
        if fresh != sessions { sessions = fresh }  // sin cambios no se redibuja nada
    }

    private func refreshIfNeeded() {
        if isRecording || workerRunning || sessions.contains(where: { $0.state == .processing }) { refresh() }
    }

    var isProcessing: Bool { sessions.contains { $0.state == .processing } }

    func rename(_ s: SessionInfo, to title: String) {
        SessionStore.update(s.dir, ["title": title, "title_user_set": true])
        AppLog.write("renombrada \(s.id) → \(title)")
        refresh()
    }

    /// Texto de la transcripción sin la cabecera (que lleva el título original).
    /// Transcripciones ya leídas: se vuelven a leer sólo si el archivo cambia
    /// (las vistas las piden en cada redibujado, p. ej. 10 veces por segundo al reproducir).
    private var textCache: [String: (Date, String, [TranscriptLine])] = [:]

    private func cached(_ s: SessionInfo) -> (String, [TranscriptLine]) {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: s.transcript.path))?[.modificationDate] as? Date
        guard let mtime else { return ("", []) }
        if let c = textCache[s.id], c.0 == mtime { return (c.1, c.2) }
        let body = readBody(s)
        let lines = parseLines(body)
        textCache[s.id] = (mtime, body, lines)
        return (body, lines)
    }

    /// Texto de la transcripción sin la cabecera (que lleva el título original).
    func transcriptBody(_ s: SessionInfo) -> String { cached(s).0 }

    func transcriptLines(_ s: SessionInfo) -> [TranscriptLine] { cached(s).1 }

    private func readBody(_ s: SessionInfo) -> String {
        guard let text = try? String(contentsOf: s.transcript, encoding: .utf8) else { return "" }
        var lines = text.components(separatedBy: "\n")
        if lines.first?.hasPrefix("Transcripción — ") == true {
            lines.removeFirst()
            while lines.first?.isEmpty == true { lines.removeFirst() }
        }
        return lines.joined(separator: "\n")
    }

    private func parseLines(_ body: String) -> [TranscriptLine] {
        // "[00:12:31] Participantes: texto"
        body.components(separatedBy: "\n").enumerated().compactMap { i, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else {
                return line.isEmpty ? nil : TranscriptLine(id: i, time: "", speaker: "", text: line)
            }
            let time = String(line[line.index(after: line.startIndex)..<close])
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard let colon = rest.firstIndex(of: ":") else { return TranscriptLine(id: i, time: time, speaker: "", text: rest) }
            return TranscriptLine(id: i, time: time, speaker: String(rest[..<colon]),
                                  text: rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
    }

    /// Manda la grabación (y su copia exportada en Resúmenes) a la Papelera.
    func delete(_ s: SessionInfo) {
        guard s.state != .recording else { message = "No se puede eliminar mientras se graba."; return }
        let fm = FileManager.default
        let marker = s.dir.appendingPathComponent("work/exported.json")
        if let data = try? Data(contentsOf: marker),
           let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let path = j["exported_to"] as? String, fm.fileExists(atPath: path) {
            try? fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        }
        do {
            try fm.trashItem(at: s.dir, resultingItemURL: nil)
        } catch {
            message = "No se pudo eliminar: \(error.localizedDescription)"
            AppLog.write("error al eliminar \(s.id): \(error)")
            return
        }
        jobs.removeAll { $0.contains(s.id) }
        enqueue(["forget", s.id])
        AppLog.write("eliminada (a la Papelera): \(s.id)")
        refresh()
    }

    func openFolderOf(_ s: SessionInfo) { NSWorkspace.shared.open(s.dir) }

    /// Pone nombre a una voz ("Persona 2" → "Testigo") en toda la sesión. Vacío = quitar.
    func renameSpeaker(_ raw: String, to name: String, in s: SessionInfo) {
        var names = s.speakerNames
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[raw] = (clean.isEmpty || clean == raw) ? nil : clean
        SessionStore.update(s.dir, ["speaker_names": names])
        AppLog.write("voz renombrada en \(s.id): \(raw) → \(clean)")
        refresh()
    }

    /// Voces que aparecen en la transcripción, en orden de aparición.
    func speakers(_ s: SessionInfo) -> [String] {
        var seen: [String] = []
        for l in transcriptLines(s) where !l.speaker.isEmpty && !seen.contains(l.speaker) { seen.append(l.speaker) }
        return seen
    }

    // MARK: - etiquetas (contexto para IA en el futuro)

    /// Todas las etiquetas usadas, de la más frecuente a la menos.
    var allLabels: [String] {
        var count: [String: Int] = [:]
        for s in sessions { for l in s.labels { count[l, default: 0] += 1 } }
        return count.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    static func normalizeLabel(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }

    func addLabel(_ raw: String, to s: SessionInfo) {
        let label = Self.normalizeLabel(raw)
        guard !label.isEmpty else { return }
        // reutiliza la forma ya existente (mismas mayúsculas) si coincide sin distinguirlas
        let canonical = allLabels.first { $0.caseInsensitiveCompare(label) == .orderedSame } ?? label
        guard !s.labels.contains(where: { $0.caseInsensitiveCompare(canonical) == .orderedSame }) else { return }
        SessionStore.update(s.dir, ["labels": s.labels + [canonical]])
        refresh()
    }

    func removeLabel(_ label: String, from s: SessionInfo) {
        SessionStore.update(s.dir, ["labels": s.labels.filter { $0 != label }])
        refresh()
    }

    func copy(_ s: SessionInfo) {
        let lines = transcriptLines(s)
        guard !lines.isEmpty else { return }
        let body = lines.map { l in
            l.speaker.isEmpty ? l.text : "[\(l.time)] \(s.displayName(l.speaker)): \(l.text)"
        }.joined(separator: "\n")
        var header = "Transcripción — \(s.title)"
        if !s.labels.isEmpty { header += "\nEtiquetas: " + s.labels.map { "#\($0)" }.joined(separator: " ") }
        let text = header + "\n\n" + body
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedID = s.id
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); if copiedID == s.id { copiedID = nil } }
    }

    func open(_ s: SessionInfo) {
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: s.transcript.path) ? s.transcript : s.dir)
    }

    // MARK: - resúmenes (IA del usuario; no usa la cola de Whisper)

    @Published private(set) var summarizing: Set<String> = []
    private var summaryCache: [String: (Date, String)] = [:]

    func summarize(_ s: SessionInfo) {
        guard !summarizing.contains(s.id) else { return }
        summarizing.insert(s.id)
        AppLog.write("resumir \(s.id) con \(AISettings.shared.displayName)")
        Task {
            let (code, out) = await Worker.capture(["summarize", s.id, "--template", AISettings.shared.template])
            summarizing.remove(s.id)
            if code != 0 { AppLog.write("resumen falló: \(out.suffix(300))") }
            refresh()
        }
    }

    func summaryText(_ s: SessionInfo) -> String {
        let url = s.dir.appendingPathComponent("summary.md")
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return "" }
        if let c = summaryCache[s.id], c.0 == mtime { return c.1 }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        summaryCache[s.id] = (mtime, text)
        return text
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: SessionStore.sessionsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(SessionStore.sessionsDir)
    }
}
