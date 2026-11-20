import AVFoundation
import Speech

/// Una línea de texto en vivo (reconocimiento de Apple, sólo en el Mac).
struct LiveLine: Identifiable, Equatable {
    let id: String
    let speaker: String
    /// Segundos desde el inicio de la grabación.
    let start: TimeInterval
    var text: String
    var final: Bool
}

/// Texto provisional mientras se graba, como hace el dictado de macOS: aparece
/// al instante y se reemplaza por la transcripción de Whisper bloque a bloque.
///
/// - Sólo reconocimiento EN EL MAC (`requiresOnDeviceRecognition`): si el idioma
///   no está disponible sin conexión, no se muestra nada (nunca se envía audio a Apple).
/// - Una fuente por pista (tu micrófono / la reunión), así ya se ve quién es quién.
/// - Cada línea termina en una pausa (~1 s) o a los 30 s y empieza otra.
final class LiveSource {
    let speaker: String
    var localeID: String { recognizer.locale.identifier }
    private let recognizer: SFSpeechRecognizer
    private let clock: () -> TimeInterval
    private let emit: (LiveLine) -> Void
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finishing: [SFSpeechRecognitionTask] = []   // líneas cerradas esperando su resultado final
    private var lineStart: TimeInterval = 0
    private var lineNo = 0
    private var heard = false
    private var quietSince: TimeInterval?
    private var stopped = false

    static let maxLine: TimeInterval = 30
    static let pause: TimeInterval = 1.0
    static let quietLevel: Float = 0.015

    init?(speaker: String, locales: [Locale], clock: @escaping () -> TimeInterval, emit: @escaping (LiveLine) -> Void) {
        guard let r = locales.lazy.compactMap({ SFSpeechRecognizer(locale: $0) })
            .first(where: { $0.supportsOnDeviceRecognition }) else { return nil }
        self.speaker = speaker
        self.recognizer = r
        self.clock = clock
        self.emit = emit
    }

    /// Llamado desde el hilo de audio con cada buffer capturado.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else { return }
        let now = clock()
        let loud = Self.peak(copy) >= Self.quietLevel
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        if request == nil { begin(at: now) }
        request?.append(copy)
        if loud { heard = true; quietSince = nil } else if quietSince == nil { quietSince = now }
        let paused = heard && (quietSince.map { now - $0 >= Self.pause } ?? false)
        if paused || now - lineStart >= Self.maxLine { endLine() }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        endLine()
        stopped = true
    }

    // MARK: - privado (con `lock`)

    private func begin(at now: TimeInterval) {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        lineNo += 1
        lineStart = now
        heard = false
        quietSince = nil
        let id = "\(speaker)-\(lineNo)"
        let start = now
        let speaker = speaker
        let emit = emit
        request = req
        task = recognizer.recognitionTask(with: req) { result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let first = result.bestTranscription.segments.first?.timestamp ?? 0
            emit(LiveLine(id: id, speaker: speaker, start: start + first, text: text, final: result.isFinal))
        }
    }

    private func endLine() {
        request?.endAudio()   // el reconocedor entrega el resultado final de esta línea
        if let task { finishing.append(task); if finishing.count > 4 { finishing.removeFirst() } }
        request = nil
        task = nil
    }

    private static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard b.frameLength > 0, let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        out.frameLength = b.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: b.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sp = s.mData, let dp = d.mData else { continue }
            memcpy(dp, sp, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return out
    }

    private static func peak(_ b: AVAudioPCMBuffer) -> Float {
        guard let ch = b.floatChannelData else { return 1 }   // formato no float: se asume voz
        let n = Int(b.frameLength) * (b.format.isInterleaved ? Int(b.format.channelCount) : 1)
        var m: Float = 0
        var i = 0
        while i < n { m = max(m, abs(ch[0][i])); i += 4 }
        return m
    }
}

enum LiveSpeech {
    /// Variantes del idioma elegido, en orden: la primera que funcione SIN CONEXIÓN
    /// se usa (cada Mac descarga variantes distintas: es-MX, es-ES, en-US…).
    static func candidates(for language: String) -> [Locale] {
        let es = ["es-MX", "es-ES", "es-US", "es-419", "es-CO", "es-CL"]
        let en = ["en-US", "en-GB", "en-AU", "en-CA", "en-IN"]
        let mine = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let ids: [String]
        switch language {
        case "en": ids = en
        case "es": ids = es
        default: ids = Locale.current.language.languageCode?.identifier == "en" ? en + es : es + en
        }
        let ordered = ids.contains(mine) ? [mine] + ids.filter { $0 != mine } : ids
        return ordered.map(Locale.init(identifier:))
    }

    /// Pide el permiso la primera vez. Sin permiso, se graba igual pero sin texto en vivo.
    static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }
}
