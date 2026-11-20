import AVFoundation
import CoreAudio

/// Escribe una pista a CAF (PCM 16 bits). Acepta buffers de cualquier formato
/// y los convierte al formato del archivo, así un cambio de dispositivo
/// (p. ej. conectar AirPods) no rompe la grabación.
final class TrackWriter {
    struct Chunk {
        let url: URL
        let firstHostSeconds: Double
        let frames: AVAudioFramePosition
    }

    private(set) var url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private(set) var firstHostTime: UInt64 = 0
    private(set) var framesWritten: AVAudioFramePosition = 0
    /// Pico reciente (0…1) para el indicador de nivel.
    private(set) var level: Float = 0
    private(set) var lastError: String?

    /// Recibe cada buffer capturado (texto en vivo). Se llama fuera del candado.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    init(url: URL) { self.url = url }

    /// Segundos (reloj de la máquina) del primer buffer: sirve para alinear pistas.
    var firstHostSeconds: Double {
        firstHostTime == 0 ? 0 : Double(AudioConvertHostTimeToNanos(firstHostTime)) / 1e9
    }

    func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard buffer.frameLength > 0 else { return }
        onBuffer?(buffer)
        lock.lock(); defer { lock.unlock() }
        do {
            if file == nil {
                let src = buffer.format
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: src.sampleRate,
                    AVNumberOfChannelsKey: min(src.channelCount, 2),
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
                file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
                firstHostTime = hostTime
            }
            guard let file else { return }
            level = max(level * 0.8, Self.peak(buffer))
            let target = file.processingFormat
            if buffer.format == target {
                try file.write(from: buffer)
                framesWritten += AVAudioFramePosition(buffer.frameLength)
                return
            }
            if converter == nil || converterInput != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: target)
                converterInput = buffer.format
            }
            guard let converter else { return }
            let ratio = target.sampleRate / buffer.format.sampleRate
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
            var consumed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if let err { throw err }
            if out.frameLength > 0 {
                try file.write(from: out)
                framesWritten += AVAudioFramePosition(out.frameLength)
            }
        } catch {
            lastError = error.localizedDescription
            NSLog("RecorderJT: error escribiendo \(url.lastPathComponent): \(error)")
        }
    }

    /// Rellena con silencio hasta `hostTime` (al reactivar una fuente apagada a
    /// mitad de bloque), así el audio siguiente queda en su minuto real.
    func padSilence(untilHost hostTime: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard let file, firstHostTime != 0 else { return }  // sin archivo: el próximo bloque se alinea solo
        let sr = file.processingFormat.sampleRate
        let written = Double(framesWritten) / sr
        let gap = hostSeconds(hostTime) - hostSeconds(firstHostTime) - written
        guard gap > 0.1, gap < 6 * 3600 else { return }
        var remaining = AVAudioFramePosition(gap * sr)
        let block = AVAudioFrameCount(sr)  // 1 s por escritura
        guard let zeros = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block) else { return }
        zeros.frameLength = block
        for buf in UnsafeMutableAudioBufferListPointer(zeros.mutableAudioBufferList) {
            if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) }
        }
        do {
            while remaining > 0 {
                zeros.frameLength = AVAudioFrameCount(min(AVAudioFramePosition(block), remaining))
                try file.write(from: zeros)
                framesWritten += AVAudioFramePosition(zeros.frameLength)
                remaining -= AVAudioFramePosition(zeros.frameLength)
            }
        } catch {
            lastError = error.localizedDescription
        }
        level = 0
    }

    /// Cierra el archivo actual y continúa en `next` sin perder muestras
    /// (el siguiente buffer abre el archivo nuevo). Devuelve el bloque cerrado.
    func rotate(to next: URL) -> Chunk {
        lock.lock(); defer { lock.unlock() }
        let done = Chunk(url: url, firstHostSeconds: hostSeconds(firstHostTime), frames: framesWritten)
        if #available(macOS 15.0, *) { file?.close() }
        file = nil
        url = next
        firstHostTime = 0
        framesWritten = 0
        return done
    }

    /// Cierra definitivamente y devuelve el último bloque.
    func finish() -> Chunk {
        lock.lock()
        let done = Chunk(url: url, firstHostSeconds: hostSeconds(firstHostTime), frames: framesWritten)
        lock.unlock()
        close()
        return done
    }

    private func hostSeconds(_ t: UInt64) -> Double {
        t == 0 ? 0 : Double(AudioConvertHostTimeToNanos(t)) / 1e9
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if #available(macOS 15.0, *) { file?.close() }
        file = nil  // al liberarse, AVAudioFile cierra y finaliza la cabecera
        converter = nil
    }

    func decayLevel() { lock.lock(); level *= 0.6; lock.unlock() }

    private static func peak(_ b: AVAudioPCMBuffer) -> Float {
        guard let ch = b.floatChannelData else { return 0 }
        let n = Int(b.frameLength) * (b.format.isInterleaved ? Int(b.format.channelCount) : 1)
        var m: Float = 0
        let p = ch[0]
        var i = 0
        while i < n { m = max(m, abs(p[i])); i += 4 }
        return min(m, 1)
    }
}
