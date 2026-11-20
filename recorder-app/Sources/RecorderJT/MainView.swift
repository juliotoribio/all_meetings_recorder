import AppKit
import AVFoundation
import SwiftUI

// MARK: - tema (valores del diseño "Transcripción")

enum T {
    static let bg = Color(hex: 0x111111)
    static let panel = Color(hex: 0x171717)
    static let line = Color(hex: 0x222222)
    static let field = Color(hex: 0x2A2A2A)
    static let border = Color(hex: 0x333333)
    static let text = Color(hex: 0xF2F2F2)
    static let text2 = Color(hex: 0xE6E6E6)
    static let muted = Color(hex: 0x8C8C8C)
    static let muted2 = Color(hex: 0xB5B5B5)
    static let dim = Color(hex: 0x9A9A9A)
    static let rowSel = Color(hex: 0x262626)
    static let thumb = Color(hex: 0x222222)
    static let thumbFg = Color(hex: 0x7A7A7A)
    static let wave = Color(hex: 0x4D4D4D)
    static let accent = Color(hex: 0xD4F53C)
    static let ink = Color(hex: 0x0A0A0A)
    static let errBg = Color(hex: 0x3A1A12)
    static let errFg = Color(hex: 0xFF6B4A)
    static let errText = Color(hex: 0xFF8A65)
    static let errBorder = Color(hex: 0x5A2A1C)
    static let rec = Color(hex: 0xFF5A4A)

    /// Títulos grandes (el diseño usa Inter Tight Light; aquí la fuente del sistema en ligera).
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .light) }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Color estable por voz: "Yo" en el acento, cada "Persona N" con el suyo.
func speakerColor(_ raw: String) -> Color {
    if raw == "Yo" { return T.accent }
    let palette: [UInt32] = [0x7DA2FF, 0xFF8A3D, 0xC792EA, 0x4FD1C5, 0xF78FB3, 0xFFD166, 0xA0E77D, 0xFF6B6B]
    if raw.hasPrefix("Persona "), let n = Int(raw.dropFirst(8)) { return Color(hex: palette[(n - 1) % palette.count]) }
    return T.muted
}

/// Valores pseudoaleatorios estables por id (miniaturas del historial).
func seeded(_ id: String, _ n: Int) -> [Double] {
    var x: UInt64 = 0
    for c in id.unicodeScalars { x = (x &* 31 &+ UInt64(c.value)) % 2147483647 }
    if x == 0 { x = 1 }
    return (0..<n).map { _ in x = (x &* 48271) % 2147483647; return Double(x % 1000) / 1000 }
}

func clock(_ t: Double) -> String {
    let s = Int(max(0, t))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

func hms(_ t: Double) -> String {
    let s = Int(max(0, t))
    return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
}

func seconds(_ hms: String) -> Double {
    hms.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
}

func durationText(_ d: Double?) -> String {
    guard let d else { return "" }
    let m = Int((d / 60).rounded())
    if d < 60 { return "\(max(1, Int(d))) s" }
    return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
}

private let esLocale = Locale(identifier: "es_ES")

func esTime(_ d: Date?) -> String {
    guard let d else { return "" }
    let f = DateFormatter(); f.locale = esLocale; f.dateFormat = "h:mm a"
    return f.string(from: d)
}

func esDate(_ d: Date?) -> String {
    guard let d else { return "" }
    let f = DateFormatter(); f.locale = esLocale; f.dateFormat = "d MMM yyyy"
    return f.string(from: d)
}

func dayGroup(_ d: Date?) -> String {
    guard let d else { return "Sin fecha" }
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Hoy" }
    if cal.isDateInYesterday(d) { return "Ayer" }
    let f = DateFormatter(); f.locale = esLocale
    f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "d MMM" : "d MMM yyyy"
    return f.string(from: d)
}

// MARK: - reproductor

@MainActor
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    private var player: AVAudioPlayer?
    private var key: String?
    private var timer: Timer?

    func load(_ s: SessionInfo?) {
        let k = s.flatMap { s in s.playbackDuration.map { _ in "\(s.id)|\(s.playbackVersion?.timeIntervalSince1970 ?? 0)" } }
        guard k != key else { return }
        stop()
        key = k
        guard let s, k != nil else { player = nil; duration = 0; time = 0; return }
        player = try? AVAudioPlayer(contentsOf: s.playbackURL)
        player?.delegate = self
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        time = 0
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
        player.play(); isPlaying = true
        timer?.invalidate()
        // 4 veces por segundo: suficiente para el reloj y el cursor (en 1 h de audio
        // la onda avanza menos de 1 px por segundo) y la mitad de trabajo que a 10.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.time = self?.player?.currentTime ?? 0 }
        }
    }

    func pause() { player?.pause(); isPlaying = false; timer?.invalidate() }

    func stop() { pause(); player?.currentTime = 0; time = 0 }

    func seek(_ t: Double, play shouldPlay: Bool = true) {
        guard let player else { return }
        player.currentTime = min(max(0, t), player.duration)
        time = player.currentTime
        if shouldPlay && !isPlaying { play() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false; self.timer?.invalidate(); self.time = self.duration }
    }
}

// MARK: - ventana principal

enum HistoryFilter: String, CaseIterable {
    case all = "Todas", meetings = "Reuniones", uploads = "Subidas", errors = "Errores"
}

enum AppSection { case home, library }

struct MainView: View {
    @ObservedObject var model: AppModel
    /// @State (no @StateObject): la ventana no se suscribe al reproductor, que
    /// publica 10 veces por segundo; sólo lo observan la tarjeta de audio y la lista.
    @State private var player = AudioPlayer()
    @State private var selection: String?
    @State private var search = ""
    @State private var filter: HistoryFilter = .all
    @State private var dropping = false
    @State private var section: AppSection = .home
    @State private var showSetup = false
    @ObservedObject private var setup = SetupModel.shared

    private var selected: SessionInfo? { model.sessions.first { $0.id == selection } }
    /// Mientras se graba se muestra siempre la vista de grabaciones (como el diseño).
    private var showLibrary: Bool { section == .library || model.isRecording }

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model, filter: $filter, showFilters: showLibrary)
            Rectangle().fill(T.line).frame(height: 1)
            HStack(spacing: 0) {
                NavRail(current: showLibrary ? .library : .home, go: { section = $0 }, openSettings: { showSetup = true })
                Rectangle().fill(T.line).frame(width: 1)
                if showLibrary {
                    HStack(alignment: .top, spacing: 16) {
                        Sidebar(model: model, selection: $selection, search: $search, filter: filter)
                            .frame(width: 300)
                        detail
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .padding(16)
                } else {
                    HomeView(model: model, openSetup: { showSetup = true }) { id in
                        filter = .all
                        if let id { selection = id }
                        section = .library
                    }
                }
            }
        }
        .background(T.bg)
        .ignoresSafeArea(edges: .top)
        .foregroundStyle(T.text)
        .tint(T.accent)
        .preferredColorScheme(.dark)
        .frame(minWidth: 980, minHeight: 600)
        .dropDestination(for: URL.self) { urls, _ in
            section = .library
            model.importAudio(urls)
            return true
        } isTargeted: { dropping = $0 }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(T.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .background(T.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        Label("Suelta el audio para transcribirlo", systemImage: "waveform.badge.plus")
                            .font(.system(size: 17, weight: .medium))
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .background(T.panel, in: Capsule())
                    )
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showSetup) { SetupView { showSetup = false } }
        .onAppear {
            setup.check()
            let env = ProcessInfo.processInfo.environment
            if env["RJT_SECTION"] == "library" { section = .library }  // capturas
            if selection == nil { selection = model.sessions.first?.id }
            player.load(selected)
            // Medición (sólo con datos de demostración): reproduce la primera grabación.
            if env["RJT_HOME"] != nil, env["RJT_TEST_PLAY"] != nil {
                section = .library
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { player.play() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSetup)) { _ in showSetup = true }
        .onChange(of: model.sessions.first?.id) { _, newest in
            if model.isRecording || model.importing > 0 {
                selection = newest
                section = .library
            }
        }
        .onChange(of: model.importing) { _, n in if n > 0 { section = .library } }
        .onChange(of: selected) { _, s in player.load(s) }
    }

    @ViewBuilder private var detail: some View {
        if let s = selected {
            switch s.state {
            case .recording where model.isRecording:
                RecordingView(model: model, session: s)
            case .failed(let err):
                ErrorView(model: model, session: s, error: err)
            case .processing where !s.hasTranscript:
                ProcessingView(session: s)
            default:
                TranscriptView(model: model, session: s, player: player)
            }
        } else if model.isRecording {
            RecordingView(model: model, session: nil)
        } else {
            VStack(spacing: 14) {
                Text("All Meetings Recorder").font(T.display(56)).tracking(-1.2).lineLimit(1).minimumScaleFactor(0.5).padding(.horizontal, 24)
                Text("Graba una reunión o sube un audio para transcribirlo.")
                    .font(.system(size: 15)).foregroundStyle(T.muted2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - navegación

struct NavRail: View {
    let current: AppSection
    let go: (AppSection) -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            item("Inicio", icon: "house", on: current == .home) { go(.home) }
            item("Grabaciones", icon: "waveform", on: current == .library) { go(.library) }
            Spacer()
            item("Ajustes", icon: "slider.horizontal.3", on: false, action: openSettings)
                .help("Configuración: Whisper y los modelos (⌘,)")
        }
        .padding(.vertical, 16).padding(.horizontal, 8)
        .frame(width: 80)
        .frame(maxHeight: .infinity)
    }

    private func item(_ label: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 17, weight: .regular))
                    .foregroundStyle(on ? T.accent : T.muted)
                    .frame(height: 20)
                Text(label).font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(on ? T.text : T.muted)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 64, height: 60)
            .background(on ? Color(hex: 0x1E1E1E) : .clear, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// Permite arrastrar la ventana desde la cabecera (la barra de título es transparente).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - cabecera

struct Header: View {
    @ObservedObject var model: AppModel
    @Binding var filter: HistoryFilter
    let showFilters: Bool

    var body: some View {
        ZStack {
            WindowDragArea()
            if showFilters {
                HStack(spacing: 4) {
                    ForEach(HistoryFilter.allCases, id: \.self) { f in
                        Button { filter = f } label: {
                            Text(f.rawValue)
                                .font(.system(size: 14.5))
                                .foregroundStyle(filter == f ? T.text : T.dim)
                                .padding(.horizontal, 14).frame(height: 34)
                                .overlay(Capsule().strokeBorder(filter == f ? T.text : .clear, lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 6) {
                Text("All Meetings Recorder").font(.system(size: 15, weight: .medium))
                    .padding(.leading, 84)  // deja sitio a los botones de la ventana
                    .allowsHitTesting(false)
                Spacer()
                SourceToggle(kind: .mic, on: model.micOn) { model.setMic(!model.micOn) }
                SourceToggle(kind: .meeting, on: model.systemOn) { model.setSystem(!model.systemOn) }
                SettingsPill(model: model)
                RecordButton(model: model).padding(.leading, 4)
            }
            .padding(.trailing, 16)
        }
        .frame(height: AppDelegate.headerHeight)
    }
}

/// Botón redondo para encender/apagar una fuente (micrófono o audio de la reunión).
struct SourceToggle: View {
    enum Kind { case mic, meeting }
    let kind: Kind
    let on: Bool
    let toggle: () -> Void

    private var label: String { kind == .mic ? "Mi micrófono" : "Audio de la reunión" }

    var body: some View {
        Button(action: toggle) {
            ZStack {
                Image(systemName: kind == .mic ? "mic" : "speaker.wave.2")
                    .font(.system(size: 15, weight: .regular))
                if !on {
                    Rectangle().frame(width: 1.8, height: 24).rotationEffect(.degrees(-45))
                }
            }
            .foregroundStyle(on ? T.accent : T.muted)
            .frame(width: 40, height: 40)
            .background(on ? T.accent.opacity(0.14) : .clear, in: Circle())
            .overlay(Circle().strokeBorder(on ? T.accent.opacity(0.5) : T.border, lineWidth: 1))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(label): \(on ? "encendido" : "apagado")")
        .accessibilityLabel(label)
        .accessibilityValue(on ? "Encendido" : "Apagado")
        .accessibilityAddTraits(.isToggle)
    }
}

func languageName(_ code: String) -> String { ["auto": "Auto", "es": "Español", "en": "English"][code] ?? code }
func qualityName(_ code: String) -> String { ["max": "Máxima", "fast": "Rápida"][code] ?? code }

/// "Auto · Rápida ⌄": idioma y calidad de la transcripción.
struct SettingsPill: View {
    @ObservedObject var model: AppModel
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Text("\(languageName(model.language)) · \(qualityName(model.quality))")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 13.5)).foregroundStyle(Color(hex: 0xCFCFCF))
            .padding(.leading, 14).padding(.trailing, 12).frame(height: 40)
            .overlay(Capsule().strokeBorder(T.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Idioma y calidad de la transcripción")
        .popover(isPresented: $open, arrowEdge: .bottom) { TranscriptionSettings(model: model) }
    }
}

/// Panel de idioma y calidad (cabecera e Inicio).
struct TranscriptionSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            group("Idioma", [("auto", "Auto"), ("es", "Español"), ("en", "English")], model.language, model.setLanguage)
            group("Calidad", [("max", "Máxima"), ("fast", "Rápida")], model.quality, model.setQuality)
            Text(model.isRecording ? "Se aplica desde la próxima grabación."
                 : "Auto detecta el idioma cada pocos minutos. Rápida es ~2,5× más veloz y algo menos precisa.")
                .font(.system(size: 11.5)).foregroundStyle(T.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
        .background(Color(hex: 0x1B1B1B))
        .environment(\.colorScheme, .dark)
    }

    private func group(_ label: String, _ options: [(String, String)], _ value: String,
                       _ set: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(T.muted)
            HStack(spacing: 0) {
                ForEach(options, id: \.0) { code, title in
                    let sel = code == value
                    Button { set(code) } label: {
                        Text(title).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(sel ? T.ink : T.muted2)
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .background(sel ? T.accent : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(sel ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(3)
            .background(Color(hex: 0x111111), in: Capsule())
            .overlay(Capsule().strokeBorder(T.field, lineWidth: 1))
        }
    }
}

struct RecordButton: View {
    @ObservedObject var model: AppModel
    var label: String?

    var body: some View {
        Button(action: model.toggle) {
            HStack(spacing: 10) {
                if model.isRecording {
                    RoundedRectangle(cornerRadius: 2).fill(T.ink).frame(width: 10, height: 10)
                    if let label { Text(label) } else { Text(hms(model.elapsed)).monospacedDigit() }
                } else {
                    Circle().fill(T.ink).frame(width: 10, height: 10)
                    Text("Grabar")
                }
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(T.ink)
            .padding(.horizontal, label == nil ? 20 : 22).frame(height: label == nil ? 40 : 44)
            .background(T.accent, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: [.command])
        .disabled(!model.isRecording && !model.micOn && !model.systemOn)
        .opacity(!model.isRecording && !model.micOn && !model.systemOn ? 0.4 : 1)
        .help(model.isRecording ? "Detener (⌘R)" : "Grabar (⌘R)")
    }
}

// MARK: - barra lateral

struct Sidebar: View {
    @ObservedObject var model: AppModel
    @Binding var selection: String?
    @Binding var search: String
    let filter: HistoryFilter
    @State private var toDelete: SessionInfo?
    @ObservedObject private var setup = SetupModel.shared

    private var filtered: [SessionInfo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.sessions.filter { s in
            switch filter {
            case .all: break
            case .meetings: if s.isUpload { return false }
            case .uploads: if !s.isUpload { return false }
            case .errors: if !s.isFailed { return false }
            }
            guard !q.isEmpty else { return true }
            let tag = q.hasPrefix("#") ? String(q.dropFirst()) : q
            return s.title.lowercased().contains(q) || s.labels.contains { $0.lowercased().contains(tag) }
                || (!q.hasPrefix("#") && model.transcriptBody(s).lowercased().contains(q))
        }
    }

    private var groups: [(String, [SessionInfo])] {
        var out: [(String, [SessionInfo])] = []
        for s in filtered {
            let g = dayGroup(s.date)
            if let i = out.firstIndex(where: { $0.0 == g }) { out[i].1.append(s) } else { out.append((g, [s])) }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !setup.allGood && !setup.checking && (!setup.components.isEmpty || !setup.workerFound) {
                Button { NotificationCenter.default.post(name: .openSetup, object: nil) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(T.errFg)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Falta instalar algo para transcribir").font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(T.text2)
                            Text("Abrir Configuración").font(.system(size: 11.5)).foregroundStyle(T.errText)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(T.errBg, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(T.errBorder, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !model.isRecording && !model.micOn && !model.systemOn {
                Text("Activa el micrófono o el audio de la reunión (arriba a la derecha).")
                    .font(.system(size: 11.5)).foregroundStyle(T.errText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(T.muted)
                    TextField("Buscar", text: $search)
                        .textFieldStyle(.plain).font(.system(size: 14))
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(T.muted) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).frame(height: 36)
                .background(T.bg, in: Capsule())
                .overlay(Capsule().strokeBorder(T.field, lineWidth: 1))
                .help("Buscar en títulos y texto · #etiqueta para filtrar por etiqueta")

                Button(action: model.chooseAudio) {
                    Group {
                        if model.importing > 0 { ProgressView().controlSize(.small) }
                        else { Image(systemName: "square.and.arrow.up").font(.system(size: 14)) }
                    }
                    .foregroundStyle(T.text2)
                    .frame(width: 36, height: 36)
                    .background(T.bg, in: Circle())
                    .overlay(Circle().strokeBorder(T.field, lineWidth: 1))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("o", modifiers: [.command])
                .help("Subir audio… (⌘O) · también puedes arrastrarlo a la ventana")
            }
            .padding(.horizontal, 6)

            if let msg = model.message {
                VStack(alignment: .leading, spacing: 6) {
                    Text(msg).font(.system(size: 12)).foregroundStyle(T.errText)
                        .fixedSize(horizontal: false, vertical: true)
                    if msg.contains("permiso") || msg.contains("sistema") {
                        HStack {
                            PillButton(title: "Micrófono") { model.openPrivacySettings("Privacy_Microphone") }
                            PillButton(title: "Audio del sistema") { model.openPrivacySettings("Privacy_ScreenCapture") }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groups, id: \.0) { g in
                        VStack(spacing: 2) {
                            HStack {
                                Text(g.0)
                                Spacer()
                                Text("\(g.1.count) \(g.1.count == 1 ? "grabación" : "grabaciones")")
                            }
                            .font(.system(size: 12)).foregroundStyle(T.muted)
                            .padding(.horizontal, 6).padding(.bottom, 6)
                            ForEach(g.1) { s in
                                HistoryRow(model: model, session: s, selected: s.id == selection,
                                           pick: { selection = s.id }, askDelete: { toDelete = s })
                            }
                        }
                    }
                    if groups.isEmpty {
                        Text(model.sessions.isEmpty ? "Aún no hay grabaciones." : "Sin resultados")
                            .font(.system(size: 14)).foregroundStyle(T.muted).padding(.horizontal, 6)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.top, 14).padding(.horizontal, 10).padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(T.panel, in: RoundedRectangle(cornerRadius: 16))
        .sheet(item: $toDelete) { s in
            DeleteConfirm(session: s) {
                let list = filtered
                if selection == s.id, let i = list.firstIndex(where: { $0.id == s.id }) {
                    let rest = list.filter { $0.id != s.id }
                    selection = rest.isEmpty ? nil : rest[min(i, rest.count - 1)].id
                }
                model.delete(s)
            }
        }
    }
}

/// Confirmación para borrar: hay que escribir ELIMINAR (las grabaciones pueden ser sensibles).
struct DeleteConfirm: View {
    let session: SessionInfo
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @FocusState private var focused: Bool

    private var ok: Bool { typed.trimmingCharacters(in: .whitespaces) == "ELIMINAR" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Circle().fill(T.errFg).frame(width: 7, height: 7)
                Text("ELIMINAR GRABACIÓN").font(.system(size: 12.5, weight: .medium)).tracking(0.5)
            }
            .foregroundStyle(T.errText)
            .padding(.horizontal, 14).frame(height: 30)
            .overlay(Capsule().strokeBorder(T.errBorder, lineWidth: 1))

            Text(session.title).font(T.display(30)).tracking(-0.5).lineLimit(2)
            Text("Se borran el audio, la transcripción y su copia en Resúmenes. Irán a la Papelera de macOS: puedes recuperarlos de ahí hasta que la vacíes.")
                .font(.system(size: 14)).foregroundStyle(T.muted2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                (Text("Escribe ") + Text("ELIMINAR").fontWeight(.semibold).foregroundColor(T.text) + Text(" para confirmar"))
                    .font(.system(size: 12.5)).foregroundStyle(T.muted)
                TextField("ELIMINAR", text: $typed)
                    .textFieldStyle(.plain).font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 14).frame(height: 40)
                    .background(T.bg, in: Capsule())
                    .overlay(Capsule().strokeBorder(ok ? T.errFg : T.field, lineWidth: 1))
                    .focused($focused)
                    .onSubmit { if ok { confirm(); dismiss() } }
            }
            HStack(spacing: 8) {
                Spacer()
                PillButton(title: "Cancelar", height: 40) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button { confirm(); dismiss() } label: {
                    Text("Eliminar").font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(ok ? Color.white : T.muted)
                        .padding(.horizontal, 20).frame(height: 40)
                        .background(ok ? T.errFg : T.rowSel, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!ok)
            }
        }
        .padding(28)
        .frame(width: 440)
        .background(T.panel)
        .foregroundStyle(T.text)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }
}

struct SourceSwitch: View {
    let label: String
    let on: Bool
    let set: (Bool) -> Void

    var body: some View {
        Button { set(!on) } label: {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 14)).foregroundStyle(on ? T.text2 : T.dim)
                Spacer()
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? T.accent : Color(hex: 0x2A2A2A))
                        .overlay(Capsule().strokeBorder(on ? .clear : T.border, lineWidth: 1))
                    Circle().fill(on ? T.ink : Color(hex: 0x8A8A8A))
                        .frame(width: 20, height: 20)
                        .padding(3)
                }
                .frame(width: 46, height: 26)
                .animation(.easeOut(duration: 0.15), value: on)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "Apagar \(label.lowercased())" : "Encender \(label.lowercased())")
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(on ? "Encendido" : "Apagado")
    }
}

struct SegmentedRow: View {
    let label: String
    let options: [(String, String)]
    let value: String
    let disabled: Bool
    let set: (String) -> Void
    let help: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 14)).foregroundStyle(T.text2)
            Spacer()
            HStack(spacing: 2) {
                ForEach(options, id: \.0) { code, title in
                    let sel = code == value
                    Button { set(code) } label: {
                        Text(title).font(.system(size: 12, weight: sel ? .semibold : .regular))
                            .foregroundStyle(sel ? T.ink : T.muted)
                            .padding(.horizontal, 7).frame(height: 24)
                            .background(Capsule().fill(sel ? T.accent : .clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(sel ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(2)
            .background(Capsule().fill(Color(hex: 0x2A2A2A)))
            .overlay(Capsule().strokeBorder(T.border, lineWidth: 1))
        }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .help(help)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

struct HistoryRow: View {
    @ObservedObject var model: AppModel
    let session: SessionInfo
    let selected: Bool
    let pick: () -> Void
    let askDelete: () -> Void
    @State private var hover = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var canDelete: Bool { session.state != .recording }

    var body: some View {
        HStack(spacing: 12) {
            thumb
            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    TextField("Nombre", text: $draft)
                        .textFieldStyle(.plain).font(.system(size: 14))
                        .focused($focused)
                        .onSubmit(commit)
                        .onExitCommand { editing = false }
                        .onChange(of: focused) { _, f in if !f && editing { commit() } }
                } else {
                    Text(session.title).font(.system(size: 14)).lineLimit(1).truncationMode(.tail)
                }
                Text(editing ? "Enter para guardar · Esc para cancelar" : meta).font(.system(size: 12))
                    .foregroundStyle(session.isFailed && !editing ? T.errText : T.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hover && !editing {
                HStack(spacing: 2) {
                    iconButton("pencil", help: "Cambiar el nombre", action: startEditing)
                    if canDelete {
                        iconButton("trash", help: "Eliminar", tint: T.errFg, action: askDelete)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 8)
        .background(selected ? T.rowSel : (hover ? T.rowSel.opacity(0.5) : .clear),
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { if !editing { pick() } }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .contextMenu {
            Button("Cambiar el nombre", action: startEditing)
            if canDelete { Button("Eliminar…", role: .destructive, action: askDelete) }
        }
    }

    private func iconButton(_ name: String, help: String, tint: Color = T.text2, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12.5))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(T.bg.opacity(0.9), in: Circle())
                .overlay(Circle().strokeBorder(T.field, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func startEditing() {
        draft = session.title
        editing = true
        pick()
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        if !t.isEmpty && t != session.title { model.rename(session, to: t) }
    }

    private var meta: String {
        let t = esTime(session.date)
        switch session.state {
        case .recording: return "Grabando…"
        case .processing: return "Transcribiendo…"
        case .failed: return t + " · Error"
        case .ready:
            let src = session.isUpload ? "Audio subido" : durationText(session.duration)
            return src.isEmpty ? t : "\(t) · \(src)"
        }
    }

    private var thumb: some View {
        let err = session.isFailed
        let rec = session.state == .recording
        let bg = err ? T.errBg : (selected ? T.accent : T.thumb)
        let fg = err ? T.errFg : (rec ? T.rec : (selected ? T.ink : T.thumbFg))
        return HStack(spacing: 2) {
            ForEach(Array(seeded(session.id, 5).enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1).fill(fg).frame(width: 2, height: 6 + v * 16)
            }
        }
        .frame(width: 36, height: 36)
        .background(bg, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - piezas comunes

struct PillButton: View {
    let title: String
    var icon: String?
    var filled = false
    var height: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 13)) }
                Text(title)
            }
            .font(.system(size: 13.5, weight: filled ? .medium : .regular))
            .foregroundStyle(filled ? T.ink : T.text)
            .padding(.horizontal, 14).frame(height: height)
            .background(filled ? T.text : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(filled ? .clear : T.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct StatRow: View {
    let items: [(String, String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                HStack(spacing: 0) {
                    if i > 0 { Rectangle().fill(Color(hex: 0x2E2E2E)).frame(width: 1) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(it.0).font(.system(size: 12)).foregroundStyle(T.muted)
                        Text(it.1).font(.system(size: 16)).foregroundStyle(T.text)
                    }
                    .padding(.horizontal, 20)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

func stats(_ s: SessionInfo) -> [(String, String)] {
    var list = [("Fecha", esDate(s.date)), ("Hora", esTime(s.date)), ("Origen", s.origin)]
    let d = durationText(s.duration)
    if !d.isEmpty { list.append(("Duración", d)) }
    return list
}

// MARK: - transcripción

struct TranscriptView: View {
    @ObservedObject var model: AppModel
    let session: SessionInfo
    /// Sin @ObservedObject: el reproductor cambia 10 veces por segundo y sólo
    /// la tarjeta de audio y la lista (filas que cambian) deben redibujarse.
    let player: AudioPlayer
    @State private var title = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        let lines = model.transcriptLines(session)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    head
                    AudioCard(model: model, session: session, player: player, lines: lines)
                    TranscriptList(model: model, session: session, player: player, lines: lines)
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
            .onChange(of: session.id) { _, _ in proxy.scrollTo("top", anchor: .top) }
        }
        .onAppear { title = session.title }
        .onChange(of: session.id) { _, _ in title = session.title }
        .onChange(of: session.title) { _, t in if !titleFocused { title = t } }
        .onChange(of: titleFocused) { _, f in if !f { commitTitle() } }
    }

    private func commitTitle() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { title = session.title; return }
        if t != session.title { model.rename(session, to: t) }
    }

    private var head: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Nombre de la grabación", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(T.display(44)).tracking(-0.9)
                    .lineLimit(1...3)
                    .focused($titleFocused)
                    .onSubmit { titleFocused = false }
                    .help("Haz clic para cambiar el nombre")
                    .id("top")
                FlowLayout(spacing: 8) {
                    HStack(spacing: 0) {
                        ForEach(Array(stats(session).map(\.1).enumerated()), id: \.offset) { i, v in
                            if i > 0 { Rectangle().fill(T.border).frame(width: 1, height: 14) }
                            Text(v).font(.system(size: 14)).foregroundStyle(Color(hex: 0xCFCFCF))
                                .padding(.leading, i == 0 ? 0 : 14).padding(.trailing, 14)
                        }
                    }
                    TagChips(model: model, session: session)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button { model.openFolderOf(session) } label: {
                    Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(T.text2)
                        .frame(width: 40, height: 40)
                        .overlay(Circle().strokeBorder(T.border, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Mostrar en Finder")
                Button { model.copy(session) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.copiedID == session.id ? "checkmark" : "doc.on.doc").font(.system(size: 13))
                        Text(model.copiedID == session.id ? "Copiado" : "Copiar texto")
                    }
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(T.ink)
                    .frame(minWidth: 136).padding(.horizontal, 16).frame(height: 40)
                    .background(T.text, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!session.hasTranscript)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copiar la transcripción (⇧⌘C)")
            }
        }
        .padding(.top, 20).padding(.horizontal, 8).padding(.bottom, 8)
    }

}

/// Lista de la transcripción. Observa el reproductor sólo para resaltar la línea
/// que suena; cada fila es Equatable y no se redibuja si no cambia.
struct TranscriptList: View {
    @ObservedObject var model: AppModel
    let session: SessionInfo
    @ObservedObject var player: AudioPlayer
    let lines: [TranscriptLine]

    var body: some View {
        let current = currentLine()
        VStack(alignment: .leading, spacing: 2) {
            if session.state == .processing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Terminando de transcribir…").font(.system(size: 13)).foregroundStyle(T.muted2)
                }
                .padding(12)
            }
            if lines.isEmpty {
                Text("Sin texto.").font(.system(size: 16)).foregroundStyle(T.muted).padding(12)
            }
            TranscriptRows(lines: lines, current: current, session: session, model: model, player: player)
                .equatable()
        }
        .frame(maxWidth: 820, alignment: .leading)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private func currentLine() -> Int? {
        guard player.isPlaying || player.time > 0 else { return nil }
        return lineIndex(at: player.time + 0.2, in: lines).map { lines[$0].id }
    }
}

/// Las filas sólo se recalculan si cambia la línea que suena (no en cada tic del reproductor).
struct TranscriptRows: View, Equatable {
    let lines: [TranscriptLine]
    let current: Int?
    let session: SessionInfo
    let model: AppModel
    let player: AudioPlayer

    static func == (a: TranscriptRows, b: TranscriptRows) -> Bool {
        a.current == b.current && a.session == b.session && a.lines.count == b.lines.count
            && a.lines.last?.text == b.lines.last?.text
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(lines) { line in
                TranscriptRow(line: line, active: line.id == current, name: session.displayName(line.speaker),
                              canSeek: session.playbackDuration != nil, session: session, model: model,
                              seek: { player.seek(line.start) })
                    .equatable()
            }
        }
    }
}

struct TranscriptRow: View, Equatable {
    let line: TranscriptLine
    let active: Bool
    let name: String
    let canSeek: Bool
    let session: SessionInfo
    let model: AppModel
    let seek: () -> Void

    static func == (a: TranscriptRow, b: TranscriptRow) -> Bool {
        a.line.id == b.line.id && a.line.text == b.line.text && a.line.speaker == b.line.speaker
            && a.active == b.active && a.name == b.name && a.canSeek == b.canSeek && a.session.id == b.session.id
    }

    var body: some View {
        if line.time.isEmpty {
            Text(line.text).font(.system(size: 14)).foregroundStyle(T.muted).padding(12)
        } else {
            let me = line.speaker == "Yo"
            HStack(alignment: .top, spacing: 12) {
                Button(action: seek) {
                    Text(line.time).font(.system(size: 12.5).monospacedDigit())
                        .foregroundStyle(active ? T.text : T.muted)
                        .frame(width: 64, height: 24, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .disabled(!canSeek)
                .help(canSeek ? "Escuchar desde \(line.time)" : "")
                Text(initials(name))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(me ? T.ink : Color(hex: 0xCFCFCF))
                    .frame(width: 28, height: 28)
                    .background(me ? T.accent : T.field, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    SpeakerName(raw: line.speaker, session: session, model: model)
                        .padding(.top, 4)
                    transcriptText(line.text)
                        .font(.system(size: 16))
                        .lineSpacing(16 * 0.65 - 3)
                        .foregroundStyle(Color(hex: 0xECECEC))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(active ? Color(hex: 0x202020) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Tarjeta de audio: reproductor con la forma de onda coloreada según quién habla.
struct AudioCard: View {
    @ObservedObject var model: AppModel
    let session: SessionInfo
    @ObservedObject var player: AudioPlayer
    let lines: [TranscriptLine]

    /// Tramos (inicio en segundos, ¿soy yo?) para colorear la onda.
    private var turns: [(Double, Bool)] {
        lines.compactMap { $0.start < 0 ? nil : ($0.start, $0.speaker == "Yo") }
    }

    var body: some View {
        if session.playbackDuration != nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Button(action: player.toggle) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15)).foregroundStyle(T.ink)
                            .frame(width: 44, height: 44)
                            .background(T.accent, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(player.isPlaying ? "Pausa" : "Reproducir")
                    Text(clock(player.time)).font(.system(size: 12.5).monospacedDigit())
                        .foregroundStyle(Color(hex: 0xCFCFCF)).frame(width: 48, alignment: .leading)
                    Waveform(peaks: session.peaks, progress: player.duration > 0 ? player.time / player.duration : 0,
                             turns: turns, duration: player.duration) {
                        player.seek($0 * player.duration)
                    }
                    .frame(height: 56)
                    Text(clock(player.duration)).font(.system(size: 12.5).monospacedDigit())
                        .foregroundStyle(T.muted).frame(width: 48, alignment: .trailing)
                }
                let hasMe = turns.contains { $0.1 }, hasOthers = turns.contains { !$0.1 }
                if hasMe && hasOthers {
                    HStack(spacing: 16) {
                        legend("Participantes", Color(hex: 0x9A9A9A))
                        legend(session.displayName("Yo"), T.accent)
                    }
                    .padding(.leading, 58)
                }
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)
            .background(T.panel, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func legend(_ label: String, _ c: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8)
            Text(label).font(.system(size: 12)).foregroundStyle(T.muted2)
        }
    }
}

struct Waveform: View {
    let peaks: [Float]
    let progress: Double
    var turns: [(Double, Bool)] = []
    var duration: Double = 0
    let seek: (Double) -> Void

    static let count = 140

    /// Altura de cada barra (0…1). Depende sólo de los picos.
    private var bars: [Double] {
        let n = Self.count
        guard !peaks.isEmpty else { return Array(repeating: 0.05, count: n) }
        return (0..<n).map { i in
            let a = i * peaks.count / n, b = max(a + 1, (i + 1) * peaks.count / n)
            return Double(peaks[a..<min(b, peaks.count)].max() ?? 0)
        }
    }

    /// ¿Cada barra es mía? Un solo recorrido por los turnos (están en orden).
    private var mine: [Bool] {
        let n = Self.count
        guard duration > 0, !turns.isEmpty else { return Array(repeating: false, count: n) }
        var out = [Bool](repeating: false, count: n)
        var k = -1
        for i in 0..<n {
            let t = Double(i) / Double(n) * duration
            while k + 1 < turns.count && turns[k + 1].0 <= t { k += 1 }
            out[i] = k >= 0 && turns[k].1
        }
        return out
    }

    var body: some View {
        let b = bars, me = mine
        // Canvas: un solo dibujo en vez de 140 vistas (se repinta 10 veces por segundo al reproducir).
        Canvas { ctx, size in
            let n = b.count
            let gap: CGFloat = 2
            let w = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            for i in 0..<n {
                let played = Double(i) / Double(n) < progress
                let c: Color = me[i] ? (played ? T.accent : T.accent.opacity(0.45))
                                     : (played ? T.text2 : Color(hex: 0x5A5A5A))
                let h = max(4, CGFloat(b[i]) * size.height)
                let r = CGRect(x: CGFloat(i) * (w + gap), y: (size.height - h) / 2, width: w, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: min(2, w / 2)), with: .color(c))
            }
            let x = max(0, min(size.width - 2, size.width * progress))
            ctx.fill(Path(CGRect(x: x, y: 0, width: 2, height: size.height)), with: .color(T.text))
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onEnded { v in
            // el ancho real lo da el GeometryReader de fondo
            seek(max(0, min(1, v.location.x / max(width, 1))))
        })
        .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }
            .onChange(of: g.size.width) { _, w in width = w } })
        .help("Clic para ir a ese momento")
    }

    @State private var width: CGFloat = 1
}

/// Iniciales para el avatar: "Yo", "P" (Participantes), "LM" (Laura Martín)…
func initials(_ name: String) -> String {
    if name == "Yo" { return "Yo" }
    if name.hasPrefix("Persona "), let n = Int(name.dropFirst(8)) { return "P\(n)" }
    let parts = name.split(separator: " ").prefix(2)
    return parts.map { String($0.prefix(1)).uppercased() }.joined()
}

/// Texto de un turno; "(a la vez)" (dos personas hablando a la vez) se muestra como etiqueta.
func transcriptText(_ s: String) -> Text {
    let mark = "(a la vez)"
    let parts = s.components(separatedBy: mark)
    var out = Text(parts[0])
    for p in parts.dropFirst() {
        out = out + Text("⟷ a la vez").font(.system(size: 12, weight: .semibold)).foregroundColor(T.accent) + Text(p)
    }
    return out
}

struct TranscriptLine: Identifiable {
    let id: Int
    let time: String
    let speaker: String
    let text: String
    /// Segundos de `time`, calculados una vez al leer (se usan 10 veces por segundo al reproducir).
    let start: Double

    init(id: Int, time: String, speaker: String, text: String) {
        self.id = id; self.time = time; self.speaker = speaker; self.text = text
        self.start = time.isEmpty ? -1 : seconds(time)
    }
}

/// Índice de la última línea con hora que empieza antes de `t` (búsqueda binaria; las líneas van en orden).
func lineIndex(at t: Double, in lines: [TranscriptLine]) -> Int? {
    var lo = 0, hi = lines.count - 1, found: Int?
    while lo <= hi {
        let mid = (lo + hi) / 2
        if lines[mid].start <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
    }
    guard var i = found else { return nil }
    while i >= 0 && lines[i].start < 0 { i -= 1 }   // saltar cabeceras sin hora
    return i >= 0 ? i : nil
}

// MARK: - etiquetas

/// Etiquetas en línea junto a los datos de la grabación (diseño "Transcripción").
struct TagChips: View {
    @ObservedObject var model: AppModel
    let session: SessionInfo
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(session.labels, id: \.self) { label in
                HStack(spacing: 4) {
                    Text(label.uppercased()).font(.system(size: 11.5, weight: .medium)).tracking(0.46)
                    Button { model.removeLabel(label, from: session) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(T.muted).frame(width: 20, height: 20).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Quitar etiqueta \(label)")
                }
                .padding(.leading, 10).padding(.trailing, 2).frame(height: 26)
                .overlay(Capsule().strokeBorder(T.border, lineWidth: 1))
            }
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(T.muted)
                TextField("Etiqueta", text: $draft)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .frame(width: 72)
                    .focused($focused)
                    .onSubmit {
                        for part in draft.split(separator: ",") { model.addLabel(String(part), to: session) }
                        draft = ""
                        focused = true
                    }
            }
            .padding(.horizontal, 10).frame(height: 26)
            .overlay(Capsule().strokeBorder(Color(hex: 0x3A3A3A), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .help(model.allLabels.isEmpty ? "Añadir etiqueta" : "Añadir etiqueta · usadas: \(model.allLabels.prefix(6).joined(separator: ", "))")
        }
    }
}

struct TagRow: View {
    @ObservedObject var model: AppModel
    let session: SessionInfo
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var suggestions: [String] {
        let q = draft.trimmingCharacters(in: .whitespaces).lowercased()
        return model.allLabels
            .filter { !session.labels.contains($0) && (q.isEmpty || $0.lowercased().contains(q)) }
            .prefix(6).map { $0 }
    }

    var body: some View {
        VStack(spacing: 10) {
            FlowLayout(spacing: 8, centered: true) {
                ForEach(session.labels, id: \.self) { label in
                    HStack(spacing: 6) {
                        Circle().fill(T.accent).frame(width: 7, height: 7)
                        Text(label.uppercased()).font(.system(size: 12.5, weight: .medium)).tracking(0.5)
                        Button { model.removeLabel(label, from: session) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(T.muted).frame(width: 22, height: 22).contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Quitar etiqueta \(label)")
                    }
                    .padding(.leading, 12).padding(.trailing, 4).frame(height: 30)
                    .overlay(Capsule().strokeBorder(T.border, lineWidth: 1))
                }
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(T.muted)
                    TextField("Etiqueta", text: $draft)
                        .textFieldStyle(.plain).font(.system(size: 12.5))
                        .frame(width: 88)
                        .focused($focused)
                        .onSubmit { add(draft) }
                }
                .padding(.horizontal, 12).frame(height: 30)
                .overlay(Capsule().strokeBorder(Color(hex: 0x3A3A3A), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            }
            if focused && !suggestions.isEmpty {
                HStack(spacing: 10) {
                    Text("Usadas:").font(.system(size: 11.5)).foregroundStyle(T.muted)
                    ForEach(suggestions, id: \.self) { s in
                        Button(s.uppercased()) { add(s) }
                            .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(T.accent)
                    }
                }
            }
        }
    }

    private func add(_ text: String) {
        for part in text.split(separator: ",") { model.addLabel(String(part), to: session) }
        draft = ""
        focused = true
    }
}

/// Layout que acomoda los chips en varias líneas.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var centered = false

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, s))
            x += s.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let r = rows(width, subviews)
        var h: CGFloat = spacing * CGFloat(max(0, r.count - 1))
        for row in r { h += row.map { $0.1.height }.max() ?? 0 }
        return CGSize(width: width, height: h)
    }

    // Sin alineaciones propias: evita recorrer los hijos en cada pasada de diseño.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            let w = row.map(\.1.width).reduce(0, +) + spacing * CGFloat(max(0, row.count - 1))
            var x = centered ? bounds.minX + (bounds.width - w) / 2 : bounds.minX
            let h = row.map(\.1.height).max() ?? 0
            for (i, s) in row {
                subviews[i].place(at: CGPoint(x: x, y: y + (h - s.height) / 2), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += h + spacing
        }
    }
}

/// Nombre de quien habla; clic para ponerle nombre (se aplica a toda la grabación).
struct SpeakerName: View {
    let raw: String
    let session: SessionInfo
    @ObservedObject var model: AppModel
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        Button {
            draft = session.speakerNames[raw] ?? ""
            editing = true
        } label: {
            Text(session.displayName(raw)).font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(raw == "Yo" ? T.accent : T.muted2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Clic para ponerle nombre a \(raw)")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(speakerColor(raw)).frame(width: 8, height: 8)
                    Text(raw == "Yo" ? "¿Cómo te llamas?" : "¿Quién es \(raw)?")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(T.text)
                }
                TextField("", text: $draft, prompt: Text(raw == "Yo" ? "Tu nombre" : "Ej.: María, Carlos…")
                    .foregroundStyle(T.muted))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14)).foregroundStyle(T.text)
                    .padding(.horizontal, 14).frame(width: 260, height: 38)
                    .background(T.field, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(T.border, lineWidth: 1))
                    .onSubmit { save() }
                Text("Se cambia en toda esta grabación.").font(.system(size: 12)).foregroundStyle(T.muted)
                HStack(spacing: 8) {
                    if session.speakerNames[raw] != nil {
                        PillButton(title: "Quitar nombre", height: 32) { draft = ""; save() }
                    }
                    Spacer()
                    Button { save() } label: {
                        Text("Guardar").font(.system(size: 13, weight: .medium)).foregroundStyle(T.ink)
                            .padding(.horizontal, 18).frame(height: 32)
                            .background(T.accent, in: Capsule()).contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .background(T.panel)
            .environment(\.colorScheme, .dark)
        }
    }

    private func save() {
        model.renameSpeaker(raw, to: draft, in: session)
        editing = false
    }
}

// MARK: - grabando / transcribiendo / error

struct RecordingView: View {
    @ObservedObject var model: AppModel
    let session: SessionInfo?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 24) {
                    HStack(spacing: 8) {
                        Circle().fill(T.rec).frame(width: 8, height: 8)
                            .opacity(Int(model.elapsed) % 2 == 0 ? 1 : 0.3)
                        Text("Grabando").font(.system(size: 13)).foregroundStyle(T.muted2)
                    }
                    Text(hms(model.elapsed))
                        .font(.system(size: 112, weight: .light).monospacedDigit())
                        .tracking(-3)
                        .minimumScaleFactor(0.5).lineLimit(1)
                    StatRow(items: [("Micrófono", model.micOn ? "ON" : "OFF"),
                                    ("Reunión", model.systemOn ? "ON" : "OFF"),
                                    ("Idioma", languageName(model.language)),
                                    ("Calidad", qualityName(model.quality))])
                }
                .padding(.top, 48).padding(.horizontal, 24).padding(.bottom, 16)

                VStack(spacing: 20) {
                    let anyOn = model.micOn || model.systemOn
                    HStack(alignment: .center, spacing: 3) {
                        ForEach(Array(model.levelHistory.enumerated()), id: \.offset) { _, v in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(anyOn ? T.accent : T.border)
                                .frame(height: anyOn ? max(4, CGFloat(sqrt(v)) * 136) : 3)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 140)
                    .animation(.linear(duration: 0.2), value: model.levelHistory)
                    HStack(spacing: 12) {
                        Text(model.liveLines.isEmpty && !model.liveAvailable
                             ? "Se transcribe por bloques de ~2 min mientras grabas; al detener, el texto queda listo en segundos."
                             : "Ves el texto al instante; cada ~2 min se reemplaza por la transcripción precisa.")
                            .font(.system(size: 13.5)).foregroundStyle(T.muted2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        RecordButton(model: model, label: "Detener y transcribir")
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 24)
                .background(T.panel, in: RoundedRectangle(cornerRadius: 16))

                if (session?.hasTranscript ?? false) || !model.liveLines.isEmpty {
                    LiveText(model: model, session: session)
                }
            }
        }
    }
}

/// Durante la grabación: el texto de Whisper de los bloques ya procesados y,
/// debajo, el texto en vivo (Apple, en el Mac) de lo que Whisper aún no cubre.
struct LiveText: View {
    @ObservedObject var model: AppModel
    let session: SessionInfo?

    var body: some View {
        let whisper = session.map { s in s.hasTranscript ? model.transcriptLines(s) : [] } ?? []
        let live = model.pendingLive(session)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Lo que va").font(.system(size: 12)).foregroundStyle(T.muted)
                Spacer()
                if let session, session.hasTranscript {
                    PillButton(title: model.copiedID == session.id ? "Copiado" : "Copiar lo que va", icon: "doc.on.doc") {
                        model.copy(session)
                    }
                }
            }
            ForEach(whisper.suffix(30)) { line in
                HStack(alignment: .top, spacing: 16) {
                    Text(line.time).font(.system(size: 12).monospacedDigit()).foregroundStyle(T.muted)
                        .frame(width: 70, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        if let session {
                            SpeakerName(raw: line.speaker, session: session, model: model)
                        }
                        transcriptText(line.text).font(.system(size: 15)).foregroundStyle(T.text2)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !live.isEmpty {
                HStack(spacing: 6) {
                    Circle().fill(T.rec).frame(width: 6, height: 6)
                    Text("En vivo · provisional, se reemplaza por el texto preciso cada ~2 min")
                        .font(.system(size: 11.5)).foregroundStyle(T.muted)
                }
                .padding(.top, whisper.isEmpty ? 0 : 6)
                ForEach(live.suffix(30)) { line in
                    HStack(alignment: .top, spacing: 16) {
                        Text(hms(line.start)).font(.system(size: 12).monospacedDigit()).foregroundStyle(T.muted)
                            .frame(width: 70, alignment: .leading)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(line.speaker).font(.system(size: 12.5)).foregroundStyle(T.muted)
                            Text(line.text).font(.system(size: 15))
                                .foregroundStyle(line.final ? T.text2.opacity(0.8) : T.muted)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.panel, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ProcessingView: View {
    let session: SessionInfo

    var body: some View {
        VStack(spacing: 16) {
            Text("Transcribiendo…").font(T.display(56)).tracking(-1.1)
            Text(session.title).font(.system(size: 15)).foregroundStyle(T.muted2)
            ProgressView().controlSize(.small).padding(.top, 8)
        }
        .padding(.horizontal, 24).padding(.vertical, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorView: View {
    @ObservedObject var model: AppModel
    let session: SessionInfo
    let error: String
    @State private var showDetail = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                HStack(spacing: 8) {
                    Circle().fill(T.errFg).frame(width: 7, height: 7)
                    Text("ERROR AL TRANSCRIBIR").font(.system(size: 12.5, weight: .medium)).tracking(0.5)
                }
                .foregroundStyle(T.errText)
                .padding(.horizontal, 14).frame(height: 30)
                .overlay(Capsule().strokeBorder(T.errBorder, lineWidth: 1))

                Text(session.title).font(T.display(session.title.count > 22 ? 44 : 64)).tracking(-1.2)
                    .multilineTextAlignment(.center)
                StatRow(items: stats(session))
                Text("El audio sigue guardado. Reintenta la transcripción.")
                    .font(.system(size: 15)).foregroundStyle(T.muted2)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
                HStack(spacing: 8) {
                    PillButton(title: "Mostrar en Finder", height: 40) { model.openFolderOf(session) }
                    Button { model.retry(session) } label: {
                        Text("Reintentar").font(.system(size: 14.5, weight: .medium)).foregroundStyle(T.ink)
                            .padding(.horizontal, 20).frame(height: 40)
                            .background(T.accent, in: Capsule()).contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Button { showDetail.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showDetail ? "chevron.down" : "chevron.right").font(.system(size: 10))
                            Text("Detalle técnico")
                        }
                        .font(.system(size: 12.5)).foregroundStyle(T.muted).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showDetail {
                        Text(error)
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Color(hex: 0xD0D0D0))
                            .textSelection(.enabled)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(T.panel, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .frame(maxWidth: 520)
            }
            .padding(.horizontal, 24).padding(.vertical, 56)
            .frame(maxWidth: .infinity)
        }
    }
}

extension Notification.Name {
    static let openSetup = Notification.Name("RJTOpenSetup")
}
