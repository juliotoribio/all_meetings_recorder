import SwiftUI

/// Trae la ventana al frente, centrada en la pantalla donde está el mouse
/// (con varios monitores podía abrirse en otra pantalla y parecer que no abría).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        BundleQuarantine.prepare()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Self.showMainWindow() }
        // Diagnóstico del diseño: `RJT_SNAPSHOT=/ruta.png` guarda una imagen de la ventana.
        if let out = ProcessInfo.processInfo.environment["RJT_SNAPSHOT"],
           ProcessInfo.processInfo.environment["RJT_TEST_RECORD"] == nil {
            let sheet = ProcessInfo.processInfo.environment["RJT_SNAPSHOT_SETUP"] != nil
            if sheet {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    NotificationCenter.default.post(name: .openSetup, object: nil)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (sheet ? 4 : 2.5)) { Self.snapshot(to: out, sheet: sheet) }
        }
    }

    /// Centra los botones de la ventana (cerrar/minimizar/zoom) en la cabecera de 52 pt
    /// del diseño. macOS los recoloca al cambiar de tamaño, así que se repite.
    static let headerHeight: CGFloat = 64
    private static var observing = false

    static func placeTrafficLights(_ w: NSWindow) {
        guard let close = w.standardWindowButton(.closeButton),
              let container = close.superview?.superview, !w.styleMask.contains(.fullScreen) else { return }
        var f = container.frame
        f.size.height = headerHeight
        f.origin.y = w.frame.height - headerHeight
        container.frame = f
        for (i, t) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let b = w.standardWindowButton(t) else { continue }
            b.setFrameOrigin(NSPoint(x: 20 + CGFloat(i) * 20, y: (headerHeight - b.frame.height) / 2))
        }
    }

    static func styleMainWindow(_ w: NSWindow) {
        w.backgroundColor = NSColor(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255, alpha: 1)
        placeTrafficLights(w)
        guard !observing else { return }
        observing = true
        let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                          NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                                          NSWindow.didResignKeyNotification]
        for n in names {
            NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { note in
                guard let w = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { placeTrafficLights(w) }
            }
        }
    }

    static func snapshot(to path: String, sheet: Bool = false) {
        let win = sheet ? NSApp.windows.first(where: { $0.isSheet && $0.isVisible })
                        : NSApp.windows.first(where: { $0.title == "All Meetings Recorder" })
        guard let view = win?.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        AppLog.write("snapshot → \(path)")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.showMainWindow()
        return true
    }

    static func showMainWindow() {
        guard let window = NSApp.windows.first(where: { $0.title == "All Meetings Recorder" }) else { return }
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + vf.height / 6))
        }
        styleMainWindow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct RecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        // Ventana principal: se abre al lanzar la app y al hacer clic en el Dock
        // (la barra de menú puede quedar oculta tras el notch).
        Window("All Meetings Recorder", id: "main") {
            MainView(model: model)
                .onAppear {
                    model.requestMicAtLaunch()
                    FloatingRecorder.shared.attach(model)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Configuración…") {
                    AppDelegate.showMainWindow()
                    NotificationCenter.default.post(name: .openSetup, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            if model.isRecording {
                Label(timeString(model.elapsed), systemImage: "record.circle.fill")
                    .labelStyle(.titleAndIcon)
            } else if model.isProcessing {
                Image(systemName: "waveform.badge.ellipsis")
            } else {
                Image(systemName: "waveform")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

func timeString(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                     : String(format: "%02d:%02d", s / 60, s % 60)
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            recordButton
            levels
            if let msg = model.message {
                Text(msg).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if msg.contains("permiso") || msg.contains("sistema") {
                    HStack {
                        Button("Ajustes: Micrófono") { model.openPrivacySettings("Privacy_Microphone") }
                        Button("Ajustes: Audio del sistema") { model.openPrivacySettings("Privacy_ScreenCapture") }
                    }
                    .controlSize(.small)
                }
            }
            Divider()
            sessionsList
            Divider()
            HStack {
                Button("Subir audio…") { model.chooseAudio() }
                Button("Configuración…") {
                    AppDelegate.showMainWindow()
                    NotificationCenter.default.post(name: .openSetup, object: nil)
                }
                Button("Abrir carpeta") { model.openFolder() }
                Spacer()
                Button("Salir") {
                    if model.isRecording { model.stop() }
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 340)
    }

    private var recordButton: some View {
        Button(action: model.toggle) {
            HStack(spacing: 8) {
                Image(systemName: model.isRecording ? "stop.fill" : "record.circle")
                Text(model.isRecording ? "Detener  \(timeString(model.elapsed))" : "Grabar")
                    .monospacedDigit()
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isRecording ? .red : .accentColor)
        .controlSize(.large)
        .keyboardShortcut("r", modifiers: [.command])
        .disabled(!model.isRecording && !model.micOn && !model.systemOn)
    }

    private var levels: some View { SourceToggles(model: model) }

    @ViewBuilder private var sessionsList: some View {
        if model.sessions.isEmpty {
            Text("Aún no hay grabaciones.").font(.callout).foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.sessions.prefix(6)) { s in SessionRow(session: s, model: model) }
                }
            }
            .frame(maxHeight: 300)
        }
    }
}

/// Interruptores de las dos fuentes, con su nivel mientras se graba.
struct SourceToggles: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SourceRow(icon: "mic", label: "Mi micrófono", on: model.micOn,
                      level: model.micLevel, recording: model.isRecording, set: model.setMic)
            SourceRow(icon: "speaker.wave.2", label: "Audio de la reunión", on: model.systemOn,
                      level: model.systemLevel, recording: model.isRecording, set: model.setSystem)
            if !model.micOn && !model.systemOn {
                Text(model.isRecording ? "En pausa: no se graba nada." : "Activa al menos una fuente.")
                    .font(.caption).foregroundStyle(.orange)
            } else if !model.isRecording && !model.systemOn {
                Text("Sólo micrófono: para reuniones presenciales; se separan las voces de la sala.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SourceRow: View {
    let icon: String
    let label: String
    let on: Bool
    let level: Float
    let recording: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: on ? icon : (icon == "mic" ? "mic.slash" : "speaker.slash"))
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .frame(width: 18)
            Text(label).font(.caption).foregroundStyle(on ? .primary : .secondary)
                .frame(width: 118, alignment: .leading)
            if recording && on {
                LevelBar(level: level)
            } else {
                Text(on ? "" : "apagado").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Toggle("", isOn: Binding(get: { on }, set: set))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .help(on ? "Apagar \(label.lowercased())" : "Encender \(label.lowercased())")
        }
    }
}

struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(level > 0.02 ? Color.green : Color.gray)
                    .frame(width: max(3, g.size.width * CGFloat(min(1, sqrt(level)))))
            }
        }
        .frame(height: 6)
    }
}

struct SessionRow: View {
    let session: SessionInfo
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.callout).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            action
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(session) }
        .help("Doble clic para abrir la transcripción")
    }

    private var subtitle: String { session.subtitle }

    @ViewBuilder private var action: some View {
        switch session.state {
        case .ready:
            Button(model.copiedID == session.id ? "Copiado ✓" : "Copiar") { model.copy(session) }
                .controlSize(.small)
        case .processing:
            ProgressView().controlSize(.small)
        case .recording:
            if session.hasTranscript {
                Button(model.copiedID == session.id ? "Copiado ✓" : "Copiar lo que va") { model.copy(session) }
                    .controlSize(.small)
                    .help("Transcripción de los bloques ya procesados")
            } else {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
            }
        case .failed:
            Button("Reintentar") { model.retry(session) }.controlSize(.small)
        }
    }
}


/// App descargada (.dmg, sin firma de Apple): el usuario ya la aprobó con «Abrir igualmente»,
/// pero los programas que lleva dentro (Whisper, FFmpeg, Python) siguen marcados como
/// «descargados» y macOS los bloquearía al lanzarlos. Se quita esa marca de la propia app.
enum BundleQuarantine {
    static func prepare() {
        guard Worker.isBundled else { return }
        let bundle = Bundle.main.bundlePath
        // Abierta desde Descargas o desde el .dmg: macOS la ejecuta en una copia de solo lectura.
        if bundle.contains("/AppTranslocation/") || bundle.hasPrefix("/Volumes/") {
            AppLog.write("la app se ejecuta fuera de Aplicaciones: \(bundle)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let a = NSAlert()
                a.messageText = "Mueve la app a Aplicaciones"
                a.informativeText = "Para que pueda transcribir, arrastra All Meetings Recorder a la carpeta Aplicaciones y ábrela desde allí."
                a.addButton(withTitle: "Entendido")
                a.runModal()
            }
            return
        }
        let probe = (bundle as NSString).appendingPathComponent("Contents/Resources/worker/bin/recorder")
        guard getxattr(probe, "com.apple.quarantine", nil, 0, 0, 0) >= 0 else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", bundle]
        do {
            try p.run()
            p.waitUntilExit()
            AppLog.write("marca de descarga quitada de la app (\(p.terminationStatus))")
        } catch {
            AppLog.write("no se pudo quitar la marca de descarga: \(error.localizedDescription)")
        }
    }
}
