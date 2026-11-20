import AVFoundation
import CoreAudio

enum AudioError: LocalizedError {
    case osStatus(String, OSStatus)
    case format

    var errorDescription: String? {
        switch self {
        case let .osStatus(what, st): return "\(what) falló (OSStatus \(st))"
        case .format: return "formato de audio no soportado"
        }
    }
}

@inline(__always)
private func check(_ st: OSStatus, _ what: String) throws {
    if st != noErr { throw AudioError.osStatus(what, st) }
}

/// Captura el audio que suena en el Mac (Teams, Zoom, navegador…) con un
/// Core Audio Process Tap (macOS 14.4+), sin drivers virtuales.
final class SystemAudioTap {
    let writer: TrackWriter
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "recorderjt.systemtap", qos: .userInitiated)
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var running = false

    init(writer: TrackWriter) { self.writer = writer }

    func start() throws {
        try startTap()
        running = true
        listenForOutputChanges()
    }

    func stop() {
        running = false
        removeOutputListener()
        stopTap()
    }

    // MARK: - tap + aggregate device

    private func startTap() throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "crear el tap de audio del sistema")

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "leer el formato del tap")
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw AudioError.format }

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "RecorderJT Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                  "crear el dispositivo agregado")

        let writer = self.writer
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, inputTime, _, _ in
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            writer.write(buf, hostTime: inputTime.pointee.mHostTime)
        }, "crear el IOProc")
        try check(AudioDeviceStart(aggregateID, procID), "iniciar la captura del sistema")
    }

    private func stopTap() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - cambio de salida (AirPods, monitor…) → reconstruir el tap

    private static var outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func listenForOutputChanges() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + 0.5) {
                guard self.running else { return }
                NSLog("RecorderJT: cambió la salida de audio; reconstruyendo el tap")
                self.stopTap()
                do { try self.startTap() } catch { NSLog("RecorderJT: no se pudo reconstruir el tap: \(error)") }
            }
        }
        outputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.outputAddress, queue, block)
    }

    private func removeOutputListener() {
        if let outputListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.outputAddress, queue, outputListener)
        }
        outputListener = nil
    }

    static func defaultOutputUID() throws -> String {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = outputAddress
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device),
                  "leer la salida de audio por defecto")
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(device, &uidAddr, 0, nil, &size, &uid), "leer el UID de la salida")
        guard let uid else { throw AudioError.format }
        return uid.takeRetainedValue() as String
    }
}
