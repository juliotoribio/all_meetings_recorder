import AVFoundation

/// Captura el micrófono por defecto. Si cambia el dispositivo (AirPods, etc.)
/// reinstala el tap y sigue escribiendo en el mismo archivo.
final class MicCapture {
    let writer: TrackWriter
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?

    init(writer: TrackWriter) { self.writer = writer }

    static var statusName: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "autorizado"
        case .notDetermined: return "sin decidir"
        case .denied: return "denegado"
        case .restricted: return "restringido"
        @unknown default: return "desconocido"
        }
    }

    static func requestPermission() async -> Bool {
        AppLog.write("permiso micrófono: \(statusName)")
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            AppLog.write("respuesta al aviso del micrófono: \(ok)")
            return ok
        default: return false
        }
    }

    func start() throws {
        try installTapAndStart()
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            NSLog("RecorderJT: cambió el micrófono; reiniciando captura")
            try? self?.installTapAndStart()
        }
    }

    private func installTapAndStart() throws {
        engine.stop()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.format }
        let writer = self.writer
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            writer.write(buffer, hostTime: when.hostTime)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
