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
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
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

struct MainView: View {
    @ObservedObject var model: AppModel
    @StateObject private var player = AudioPlayer()
    @State private var selection: String?
    @State private var search = ""
    @State private var filter: HistoryFilter = .all
    @State private var dropping = false

    private var selected: SessionInfo? { model.sessions.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model, filter: $filter)
            Rectangle().fill(T.line).frame(height: 1)
            HStack(alignment: .top, spacing: 16) {
                Sidebar(model: model, selection: $selection, search: $search, filter: filter)
                    .frame(width: 300)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(16)
        }
        .background(T.bg)
        .ignoresSafeArea(edges: .top)
        .foregroundStyle(T.text)
        .tint(T.accent)
        .preferredColorScheme(.dark)
        .frame(minWidth: 900, minHeight: 560)
        .dropDestination(for: URL.self) { urls, _ in
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
        .onAppear {
            if selection == nil { selection = model.sessions.first?.id }
            player.load(selected)
        }
        .onChange(of: model.sessions.first?.id) { _, newest in
            if model.isRecording || model.importing > 0 { selection = newest }
        }
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

    var body: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: 4) {
                ForEach(HistoryFilter.allCases, id: \.self) { f in
                    Button { filter = f } label: {
                        Text(f.rawValue)
                            .font(.system(size: 14.5))
                            .foregroundStyle(filter == f ? T.text : T.dim)
                            .padding(.horizontal, 14).frame(height: 32)
                            .overlay(Capsule().strokeBorder(filter == f ? T.text : .clear, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("All Meetings Recorder").font(.system(size: 15, weight: .medium))
                    .padding(.leading, 84)  // deja sitio a los botones de la ventana
                    .allowsHitTesting(false)
                Spacer()
                RecordButton(model: model)
            }
            .padding(.trailing, 16)
        }
        .frame(height: 52)
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
                    Text(label ?? "Detener")
                    if label == nil { Text(hms(model.elapsed)).monospacedDigit().opacity(0.75) }
                } else {
                    Circle().fill(T.ink).frame(width: 10, height: 10)
                    Text("Grabar")
                }
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(T.ink)
            .padding(.horizontal, 20).frame(height: label == nil ? 38 : 44)
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
    @State private var showSetup = false
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
                Button { showSetup = true } label: {
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
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Fuentes").font(.system(size: 12)).foregroundStyle(T.muted)
                    Spacer()
                    Button { showSetup = true } label: {
                        Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(T.muted)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Configuración: estado de Whisper y los modelos (⌘,)")
                }
                SourceSwitch(label: "Mi micrófono", on: model.micOn, set: model.setMic)
                SourceSwitch(label: "Audio de la reunión", on: model.systemOn, set: model.setSystem)
                LanguagePicker(value: model.language, disabled: model.isRecording, set: model.setLanguage)
                if !model.isRecording && model.micOn && !model.systemOn {
                    Text("Sólo micrófono: para reuniones presenciales; se separan las voces de la sala.")
                        .font(.system(size: 11.5)).foregroundStyle(T.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !model.micOn && !model.systemOn {
                    Text(model.isRecording ? "En pausa: no se graba nada." : "Activa al menos una fuente.")
                        .font(.system(size: 11.5)).foregroundStyle(T.errText)
                }
            }
            .padding(.horizontal, 6)

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
        .padding(.top, 18).padding(.horizontal, 12).padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(T.panel, in: RoundedRectangle(cornerRadius: 16))
        .sheet(isPresented: $showSetup) { SetupView { showSetup = false } }
        .onAppear { setup.check() }
        .onReceive(NotificationCenter.default.publisher(for: .openSetup)) { _ in showSetup = true }
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

struct LanguagePicker: View {
    let value: String
    let disabled: Bool
    let set: (String) -> Void
    private let options = [("auto", "Auto"), ("es", "Español"), ("en", "English")]

    var body: some View {
        HStack(spacing: 8) {
            Text("Idioma").font(.system(size: 14)).foregroundStyle(T.text2)
            Spacer()
            HStack(spacing: 2) {
                ForEach(options, id: \.0) { code, label in
                    let sel = code == value
                    Button { set(code) } label: {
                        Text(label).font(.system(size: 12, weight: sel ? .semibold : .regular))
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
        .help(disabled ? "El idioma se elige antes de grabar."
              : "Auto detecta el idioma cada pocos minutos: sirve si la reunión mezcla español e inglés.")
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
    @ObservedObject var player: AudioPlayer
    @State private var title = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        let lines = model.transcriptLines(session)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    head
                    AudioCard(model: model, session: session, player: player, lines: lines)
                    transcript(lines)
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
        VStack(spacing: 24) {
            TextField("Nombre de la grabación", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(T.display(title.count > 22 ? 44 : 72))
                .tracking(title.count > 22 ? -0.9 : -1.4)
                .multilineTextAlignment(.center)
                .lineLimit(1...3)
                .frame(maxWidth: 820)
                .focused($titleFocused)
                .onSubmit { titleFocused = false }
                .help("Haz clic para cambiar el nombre")
                .id("top")
            StatRow(items: stats(session))
            TagRow(model: model, session: session)
        }
        .padding(.top, 36).padding(.horizontal, 24).padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func transcript(_ lines: [TranscriptLine]) -> some View {
        let current = currentLine(lines)
        VStack(alignment: .leading, spacing: 22) {
            if session.state == .processing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Terminando de transcribir…").font(.system(size: 13)).foregroundStyle(T.muted2)
                }
            }
            if lines.isEmpty {
                Text("Sin texto.").font(.system(size: 16)).foregroundStyle(T.muted)
            }
            ForEach(lines) { line in
                if line.time.isEmpty {
                    Text(line.text).font(.system(size: 14)).foregroundStyle(T.muted)
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        Button { player.seek(seconds(line.time)) } label: {
                            Text(line.time).font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(line.id == current ? T.ink : T.muted2)
                                .padding(.horizontal, 10).frame(height: 26)
                                .background(line.id == current ? T.accent : .clear, in: Capsule())
                                .overlay(Capsule().strokeBorder(line.id == current ? .clear : T.border, lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(session.playbackDuration == nil)
                        .help(session.playbackDuration == nil ? "" : "Escuchar desde \(line.time)")
                        .frame(width: 84, alignment: .leading)
                        VStack(alignment: .leading, spacing: 8) {
                            SpeakerName(raw: line.speaker, session: session, model: model)
                                .padding(.top, 4)
                            Text(line.text)
                                .font(.system(size: 16))
                                .lineSpacing(16 * 0.7 - 4)
                                .foregroundStyle(T.text2)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private func currentLine(_ lines: [TranscriptLine]) -> Int? {
        guard player.isPlaying || player.time > 0 else { return nil }
        return lines.last { !$0.time.isEmpty && seconds($0.time) <= player.time + 0.2 }?.id
    }
}

/// Tarjeta de audio: quién habla, Carpeta / Copiar, reproductor con forma de onda.
struct AudioCard: View {
    @ObservedObject var model: AppModel
    let session: SessionInfo
    @ObservedObject var player: AudioPlayer
    let lines: [TranscriptLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Rectangle().fill(Color(hex: 0x4A4A4A)).frame(width: 1, height: 14)
                    Text(nowLabel).font(.system(size: 12.5)).foregroundStyle(T.muted2).lineLimit(1)
                }
                Spacer()
                PillButton(title: "Carpeta", icon: "folder") { model.openFolderOf(session) }
                Button { model.copy(session) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.copiedID == session.id ? "checkmark" : "doc.on.doc").font(.system(size: 13))
                        Text(model.copiedID == session.id ? "Copiado" : "Copiar texto")
                    }
                    .font(.system(size: 13.5, weight: .medium)).foregroundStyle(T.ink)
                    .frame(minWidth: 128).padding(.horizontal, 14).frame(height: 34)
                    .background(T.text, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!session.hasTranscript)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copiar la transcripción (⇧⌘C)")
            }
            if session.playbackDuration != nil {
                HStack(spacing: 12) {
                    Button(action: player.toggle) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13)).foregroundStyle(T.ink)
                            .frame(width: 34, height: 34)
                            .background(T.accent, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(player.isPlaying ? "Pausa" : "Reproducir")
                    Text(clock(player.time)).frame(minWidth: 38, alignment: .trailing)
                    Waveform(peaks: session.peaks, progress: player.duration > 0 ? player.time / player.duration : 0) {
                        player.seek($0 * player.duration)
                    }
                    .frame(height: 36)
                    Text(clock(player.duration)).frame(minWidth: 38, alignment: .leading)
                }
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(T.muted)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(T.panel, in: RoundedRectangle(cornerRadius: 14))
    }

    private var nowLabel: String {
        let speakers = model.speakers(session).map { session.displayName($0) }
        guard player.isPlaying || player.time > 0 else {
            return speakers.isEmpty ? session.origin : speakers.joined(separator: " · ")
        }
        let line = lines.last { !$0.time.isEmpty && seconds($0.time) <= player.time + 0.2 }
        return "\(line.map { session.displayName($0.speaker) } ?? session.origin) · \(hms(player.time))"
    }
}

struct Waveform: View {
    let peaks: [Float]
    let progress: Double
    let seek: (Double) -> Void

    private var bars: [Double] {
        let n = 120
        guard !peaks.isEmpty else { return Array(repeating: 0.05, count: n) }
        return (0..<n).map { i in
            let a = i * peaks.count / n, b = max(a + 1, (i + 1) * peaks.count / n)
            return Double(peaks[a..<min(b, peaks.count)].max() ?? 0)
        }
    }

    var body: some View {
        GeometryReader { g in
            let b = bars
            ZStack(alignment: .leading) {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(b.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Double(i) / Double(b.count) < progress ? Color(hex: 0xBDBDBD) : T.wave)
                            .frame(height: max(3, b[i] * g.size.height))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
                Rectangle().fill(T.accent).frame(width: 2)
                    .offset(x: max(0, min(g.size.width - 2, g.size.width * progress)))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                seek(max(0, min(1, v.location.x / g.size.width)))
            })
        }
        .help("Clic para ir a ese momento")
    }
}

struct TranscriptLine: Identifiable {
    let id: Int
    let time: String
    let speaker: String
    let text: String
}

// MARK: - etiquetas

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
            HStack(spacing: 6) {
                Circle().fill(speakerColor(raw)).frame(width: 6, height: 6)
                Text(session.displayName(raw)).font(.system(size: 12)).foregroundStyle(T.muted)
            }
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
                                    ("Audio de la reunión", model.systemOn ? "ON" : "OFF")])
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
                        Text("Se transcribe por bloques mientras grabas; al detener, el texto queda listo en ~1 min.")
                            .font(.system(size: 13.5)).foregroundStyle(T.muted2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        RecordButton(model: model, label: "Detener y transcribir")
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 24)
                .background(T.panel, in: RoundedRectangle(cornerRadius: 16))

                if let session, session.hasTranscript {
                    LiveText(model: model, session: session)
                }
            }
        }
    }
}

/// Lo transcrito hasta ahora (bloques ya procesados) durante la grabación.
struct LiveText: View {
    @ObservedObject var model: AppModel
    let session: SessionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Lo que va").font(.system(size: 12)).foregroundStyle(T.muted)
                Spacer()
                PillButton(title: model.copiedID == session.id ? "Copiado" : "Copiar lo que va", icon: "doc.on.doc") {
                    model.copy(session)
                }
            }
            ForEach(model.transcriptLines(session).suffix(30)) { line in
                HStack(alignment: .top, spacing: 16) {
                    Text(line.time).font(.system(size: 12).monospacedDigit()).foregroundStyle(T.muted)
                        .frame(width: 70, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        SpeakerName(raw: line.speaker, session: session, model: model)
                        Text(line.text).font(.system(size: 15)).foregroundStyle(T.text2)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
