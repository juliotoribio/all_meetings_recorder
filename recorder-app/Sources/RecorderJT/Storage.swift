import Foundation
import SwiftUI

/// Qué audio se conserva cuando una reunión ya está transcrita.
/// La elección se guarda en <home>/storage.json y la aplica el worker
/// (ver worker/recorder_worker/storage.py).
@MainActor
final class StorageSettings: ObservableObject {
    static let shared = StorageSettings()

    @Published private(set) var keepAudio = "delete"
    @Published private(set) var reclaimBytes: Int64 = 0
    @Published private(set) var reclaimSessions = 0
    @Published private(set) var working = false
    @Published var message: String?

    private var url: URL { SessionStore.home.appendingPathComponent("storage.json") }

    init() {
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let v = obj["keep_audio"] as? String, ["delete", "7d", "always"].contains(v) {
            keepAudio = v
        }
    }

    func setKeepAudio(_ v: String) {
        keepAudio = v
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { obj = old }
        obj["keep_audio"] = v
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: SessionStore.home, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Cuánto audio original de reuniones ya terminadas se puede borrar.
    func refresh() {
        guard FileManager.default.isExecutableFile(atPath: Worker.cliPath) else { return }
        Task {
            let (code, out) = await Worker.capture(["storage", "--json"])
            guard code == 0, let line = out.split(separator: "\n").last,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
            reclaimBytes = (obj["bytes"] as? NSNumber)?.int64Value ?? 0
            reclaimSessions = (obj["sessions"] as? Int) ?? 0
        }
    }

    func freeSpace() {
        working = true
        message = nil
        Task {
            let (code, out) = await Worker.capture(["free-space", "--yes", "--json"])
            working = false
            if code == 0, let line = out.split(separator: "\n").last,
               let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                let b = (obj["bytes"] as? NSNumber)?.int64Value ?? 0
                message = "Listo: se liberaron \(Self.size(b))."
            } else {
                message = "No se pudo liberar el espacio. " + (out.split(separator: "\n").last.map(String.init) ?? "")
            }
            refresh()
        }
    }

    static func size(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}

struct StorageSettingsGroup: View {
    @ObservedObject var s = StorageSettings.shared
    @State private var confirm = false

    var body: some View {
        SettingsGroup(title: "Espacio en disco",
                      footer: "Siempre se conservan la transcripción, el resumen y el audio comprimido para escucharla (unos 20 MB por hora). El audio original ocupa ~1,2 GB por hora y solo sirve para volver a transcribir con calidad completa.") {
            SettingsRow(title: "Borrar el audio original",
                        detail: "La grabación sin comprimir, una vez transcrita la reunión.") {
                CompactChoice(options: [("delete", "Al terminar"), ("7d", "A los 7 días"), ("always", "Nunca")],
                              value: s.keepAudio, set: s.setKeepAudio)
            }
            if s.reclaimSessions > 0 || s.message != nil {
                SettingsRow(title: "Reuniones anteriores",
                            detail: s.message ?? "\(s.reclaimSessions) reuniones terminadas aún guardan el audio original: \(StorageSettings.size(s.reclaimBytes)).") {
                    if s.working {
                        ProgressView().controlSize(.small)
                    } else if s.reclaimSessions > 0 {
                        Button("Liberar \(StorageSettings.size(s.reclaimBytes))") { confirm = true }
                            .controlSize(.small)
                    }
                }
            }
        }
        .onAppear { s.refresh() }
        .confirmationDialog("¿Borrar el audio original de \(s.reclaimSessions) reuniones?",
                            isPresented: $confirm, titleVisibility: .visible) {
            Button("Borrar \(StorageSettings.size(s.reclaimBytes))", role: .destructive) { s.freeSpace() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se conservan las transcripciones, los resúmenes y el audio para escucharlas. No se puede deshacer.")
        }
    }
}
