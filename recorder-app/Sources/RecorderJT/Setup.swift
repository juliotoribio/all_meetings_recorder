import AppKit
import SwiftUI

/// Una pieza necesaria para transcribir (la describe `recorder doctor --json`).
struct Component: Decodable, Identifiable {
    let id: String
    let name: String
    let detail: String
    let path: String
    let ok: Bool
    var brew: String?
    var url: String?
    var size_mb: Int?
    var optional: Bool?

    var isOptional: Bool { optional ?? false }
}

/// Estado de instalación: whisper, modelos y ffmpeg. Instala lo que falte
/// (Homebrew para programas, descarga directa para modelos) sólo cuando el usuario lo pide.
@MainActor
final class SetupModel: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = SetupModel()

    @Published var components: [Component] = []
    @Published var checking = false
    @Published var workerFound = true
    @Published var checkError: String?
    @Published var busy: String?            // id de lo que se está instalando
    @Published var progress: Double = 0     // 0-1 en descargas
    @Published var receivedMB: Double = 0
    @Published var log: String = ""
    @Published var failure: String?

    nonisolated(unsafe) private var downloadTarget: URL?
    private var session: URLSession?

    var missingRequired: [Component] { components.filter { !$0.ok && !$0.isOptional } }
    var allGood: Bool { workerFound && checkError == nil && missingRequired.isEmpty }

    static let brewPath: String? = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    func check() {
        guard !checking else { return }
        guard FileManager.default.isExecutableFile(atPath: Worker.cliPath) else {
            workerFound = false
            components = []
            return
        }
        workerFound = true
        checking = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Worker.cliPath)
        p.arguments = ["doctor", "--json"]
        p.environment = Self.env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.terminationHandler = { _ in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            struct R: Decodable { let components: [Component] }
            let r = try? JSONDecoder().decode(R.self, from: data)
            DispatchQueue.main.async {
                self.checking = false
                if let r {
                    self.components = r.components
                    self.checkError = nil
                } else {
                    self.checkError = "No se pudo leer el estado del worker."
                }
            }
        }
        do { try p.run() } catch {
            checking = false
            checkError = "No se pudo ejecutar el worker: \(error.localizedDescription)"
        }
    }

    static var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        return e
    }

    func install(_ c: Component) {
        guard busy == nil else { return }
        failure = nil
        if let formula = c.brew { brewInstall(c.id, formula) } else if let url = c.url { download(c, from: url) }
    }

    // MARK: Homebrew

    private func brewInstall(_ id: String, _ formula: String) {
        guard let brew = Self.brewPath else { return }
        busy = id
        log = "$ brew install \(formula)\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: brew)
        p.arguments = ["install", formula]
        var env = Self.env
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.log = String((self.log + s).suffix(6000)) }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.busy = nil
                if proc.terminationStatus != 0 {
                    self.failure = "Homebrew no pudo instalar \(formula). Revisa el registro de abajo."
                }
                self.check()
            }
        }
        do { try p.run() } catch {
            busy = nil
            failure = "No se pudo ejecutar Homebrew: \(error.localizedDescription)"
        }
    }

    // MARK: descargas

    private func download(_ c: Component, from url: String) {
        guard let u = URL(string: url), !c.path.isEmpty else { return }
        busy = c.id
        progress = 0
        receivedMB = 0
        log = ""
        downloadTarget = URL(fileURLWithPath: c.path)
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        s.downloadTask(with: u).resume()
    }

    func cancel() {
        session?.invalidateAndCancel()
        session = nil
        busy = nil
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        DispatchQueue.main.async {
            self.receivedMB = Double(totalBytesWritten) / 1_048_576
            if totalBytesExpectedToWrite > 0 {
                self.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // El archivo temporal se borra al volver de este método: se mueve aquí mismo.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let target = downloadTarget
        var error: String?
        if let target, (200..<300).contains(status) {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: location, to: target)
            } catch let e {
                error = "No se pudo guardar el archivo: \(e.localizedDescription)"
            }
        } else {
            error = "La descarga falló (código \(status))."
        }
        DispatchQueue.main.async { if let error { self.failure = error } }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            if let error, (error as NSError).code != NSURLErrorCancelled {
                self.failure = "La descarga se interrumpió: \(error.localizedDescription)"
            }
            self.busy = nil
            self.session = nil
            self.check()
        }
    }
}

// MARK: - vista

enum SetupSection: String, CaseIterable, Identifiable {
    case transcription = "Transcripción", recording = "Grabación", ai = "IA",
         agents = "Agentes", components = "Componentes", privacy = "Privacidad"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .transcription: "text.bubble"
        case .recording: "mic"
        case .ai: "sparkles"
        case .components: "shippingbox"
        case .agents: "terminal"
        case .privacy: "hand.raised"
        }
    }
    var subtitle: String {
        switch self {
        case .transcription: "Cómo se transcriben las grabaciones y los audios que subas. Todo ocurre en este Mac."
        case .recording: "Qué audio se graba y cuánto se guarda."
        case .ai: "Conecta tu IA para resumir. Con tu suscripción de ChatGPT o Claude no pagas API; una IA local es gratis y privada; con una clave de API pagas por uso."
        case .agents: "Conecta Claude Code, Codex, Cursor u otro agente que ejecute comandos en este Mac. Usa el CLI local: sin servidor ni claves, y el audio no sale del Mac."
        case .components: "Lo que necesita la app para transcribir. Una vez instalado, funciona sin internet."
        case .privacy: "Dónde están tus datos y qué permisos de macOS usa la app."
        }
    }
    /// Palabras para el buscador de la barra lateral.
    var keywords: String {
        rawValue + " " + {
            switch self {
            case .transcription: "idioma calidad whisper modelo turbo máxima rápida español english auto texto definitivo bloques minutos segundos vivo"
            case .recording: "micrófono audio reunión sistema fuentes grabar teams zoom meet botón flotante espacio disco borrar audio original liberar"
            case .ai: "resumen resumir suscripción chatgpt codex plan openai gemini deepseek groq mistral openrouter claude anthropic ollama lm studio clave api key plantilla"
            case .components: "whisper ffmpeg modelos instalar descargar homebrew voces pyannote"
            case .agents: "agente claude codex cursor cli api mcp comandos json terminal automatizar resumen"
            case .privacy: "privacidad datos carpeta permisos micrófono pantalla local finder"
            }
        }()
    }
}

struct SetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var setup = SetupModel.shared
    @ObservedObject var floating = FloatingRecorder.shared
    var onClose: (() -> Void)?
    @State private var section: SetupSection = .transcription
    @State private var query = ""

    private var visible: [SetupSection] {
        let q = query.trimmingCharacters(in: .whitespaces).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard !q.isEmpty else { return SetupSection.allCases }
        return SetupSection.allCases.filter {
            $0.keywords.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).contains(q)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(T.line).frame(width: 1)
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(section.rawValue).font(.system(size: 22, weight: .semibold)).foregroundStyle(T.text)
                        Text(section.subtitle).font(.system(size: 12.5)).foregroundStyle(T.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    Spacer(minLength: 12)
                    if section == .components {
                        Button { setup.check() } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 13))
                                .foregroundStyle(T.muted2).frame(width: 30, height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("Volver a comprobar").disabled(setup.checking || setup.busy != nil)
                    }
                    if let onClose {
                        Button(action: onClose) {
                            Image(systemName: "xmark").font(.system(size: 14, weight: .medium))
                                .foregroundStyle(T.muted2).frame(width: 30, height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Cerrar (Esc)")
                    }
                }
                .padding(.leading, 28).padding(.trailing, 14).padding(.top, 22).padding(.bottom, 18)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch section {
                        case .transcription: transcription
                        case .recording: recording
                        case .ai: AISection()
                        case .components: components
                        case .agents: AgentSection()
                        case .privacy: privacy
                        }
                    }
                    .frame(maxWidth: 600, alignment: .leading)
                    .padding(.horizontal, 28).padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: 840, height: 640)
        .background(T.bg)
        .preferredColorScheme(.dark)
        .onAppear {
            setup.check()
            AISettings.shared.refresh()
            if let p = SetupNav.pending { section = p; SetupNav.pending = nil }
            if let s = ProcessInfo.processInfo.environment["RJT_SETUP_SECTION"],
               let v = SetupSection.allCases.first(where: { $0.rawValue.lowercased() == s.lowercased() }) { section = v }
        }
        .onChange(of: setup.components.count) { _, _ in
            // Si falta algo para transcribir, se muestra Componentes.
            if !setup.allGood && setup.busy == nil && section == .transcription { section = .components }
        }
        .onChange(of: query) { _, _ in
            if let first = visible.first, !visible.contains(section) { section = first }
        }
    }

    // MARK: barra lateral

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(T.muted)
                TextField("Buscar", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 13))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(T.muted)
                    }
                    .buttonStyle(.plain).help("Borrar búsqueda")
                }
            }
            .padding(.horizontal, 9).frame(height: 28)
            .background(T.field.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 10)

            ForEach(visible) { sec in
                Button { section = sec } label: {
                    HStack(spacing: 9) {
                        Image(systemName: sec.icon).font(.system(size: 13.5))
                            .foregroundStyle(section == sec ? T.accent : T.muted2).frame(width: 20)
                        Text(sec.rawValue).font(.system(size: 13.5))
                            .foregroundStyle(section == sec ? T.text : T.muted2)
                        Spacer()
                        if sec == .components && !setup.allGood && !setup.checking {
                            Circle().fill(T.errFg).frame(width: 7, height: 7)
                                .accessibilityLabel("Falta instalar algo")
                        }
                    }
                    .padding(.horizontal, 9).frame(height: 32)
                    .background(section == sec ? T.rowSel : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == sec ? [.isButton, .isSelected] : .isButton)
            }
            if visible.isEmpty {
                Text("Sin resultados").font(.system(size: 12.5)).foregroundStyle(T.muted).padding(.horizontal, 10)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 14)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(T.panel)
    }

    // MARK: Transcripción

    @ViewBuilder private var transcription: some View {
        SettingsGroup(title: "Modelo", footer: model.isRecording ? "Los cambios se aplican desde la próxima grabación." : nil) {
            SettingsRow(title: "Idioma", detail: "Auto detecta el idioma de cada frase, útil en reuniones que mezclan español e inglés.") {
                CompactChoice(options: [("auto", "Auto"), ("es", "Español"), ("en", "English")],
                              value: model.language, set: model.setLanguage)
            }
            SettingsRow(title: "Calidad", detail: "Máxima usa large-v3. Rápida usa turbo: algo más veloz y un poco menos precisa.") {
                CompactChoice(options: [("max", "Máxima"), ("fast", "Rápida")], value: model.quality, set: model.setQuality)
            }
        }
        SettingsGroup(title: "Mientras grabas",
                      footer: "El texto en vivo aparece al instante; el definitivo (Whisper, con las voces separadas) lo sustituye por tramos. Al detener solo queda el último tramo.") {
            SettingsRow(title: "Texto definitivo cada",
                        detail: "Más seguido = lo ves antes, pero el Mac trabaja más durante la reunión y las voces se separan un poco peor.") {
                CompactChoice(options: [("30", "30 s"), ("60", "1 min"), ("120", "2 min")],
                              value: String(model.chunkSeconds), set: model.setChunkSeconds)
            }
        }
    }

    // MARK: Grabación

    @ViewBuilder private var recording: some View {
        SettingsGroup(title: "Qué se graba",
                      footer: "También se cambian con los botones de la cabecera, incluso durante una grabación. Al menos una fuente debe quedar activa.") {
            SettingsRow(title: "Mi micrófono", detail: "Tu voz. Aparece como «Yo» en la transcripción.") {
                Toggle("", isOn: Binding(get: { model.micOn }, set: { model.setMic($0) }))
                    .labelsHidden().toggleStyle(.switch).tint(T.accent)
            }
            SettingsRow(title: "Audio de la reunión", detail: "Lo que suena en el Mac: Teams, Zoom, Meet, el navegador… Se separa por voces.") {
                Toggle("", isOn: Binding(get: { model.systemOn }, set: { model.setSystem($0) }))
                    .labelsHidden().toggleStyle(.switch).tint(T.accent)
            }
        }
        SettingsGroup(title: "Botón flotante",
                      footer: "Arrástralo a donde quieras; recuerda la posición. Clic derecho para abrir la app u ocultarlo.") {
            SettingsRow(title: "Mostrar el botón flotante", detail: "Un botón siempre visible, encima de Teams, Zoom o Meet, para grabar y detener sin abrir la app.") {
                Toggle("", isOn: $floating.enabled).labelsHidden().toggleStyle(.switch).tint(T.accent)
            }
        }
        StorageSettingsGroup()
    }

    // MARK: Componentes

    @ViewBuilder private var components: some View {
        summary
        if !setup.workerFound {
            notice("No se encontró el worker de transcripción en:\n\(Worker.cliPath)\n\nEjecuta ./install.sh en la carpeta del proyecto (o vuelve a ejecutarlo si moviste la carpeta).")
        } else if let e = setup.checkError {
            notice(e)
        } else {
            SettingsGroup(title: "Para transcribir", footer: "Una vez instalado todo, la app funciona sin internet.") {
                ForEach(setup.components) { c in ComponentRow(c: c, setup: setup) }
            }
        }

        if let f = setup.failure {
            Text(f).font(.system(size: 12.5)).foregroundStyle(T.errText)
        }
        if !setup.log.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(setup.log).font(.system(size: 11, design: .monospaced)).foregroundStyle(T.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        .id("end")
                }
                .frame(height: 110)
                .padding(10)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: setup.log) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            if setup.checking && setup.components.isEmpty {
                ProgressView().controlSize(.small)
                Text("Comprobando…")
            } else if setup.allGood {
                Circle().fill(T.accent).frame(width: 8, height: 8)
                Text("Todo listo para transcribir")
            } else {
                Circle().fill(T.errFg).frame(width: 8, height: 8)
                Text(setup.workerFound ? "Falta instalar \(setup.missingRequired.count) \(setup.missingRequired.count == 1 ? "pieza" : "piezas")"
                                       : "Falta el worker")
            }
        }
        .font(.system(size: 13, weight: .medium)).foregroundStyle(T.text2)
    }

    // MARK: Privacidad

    @ViewBuilder private var privacy: some View {
        SettingsGroup(title: "Tus datos", footer: "El audio y la transcripción se procesan en este Mac. El texto solo sale si resumes con una IA externa (Configuración → IA); el audio nunca.") {
            SettingsRow(title: "Carpeta de grabaciones", detail: SessionStore.home.path) {
                PillButton(title: "Abrir en Finder", height: 28) { model.openFolder() }
            }
        }
        SettingsGroup(title: "Permisos de macOS", footer: "Si una fuente no graba, revisa que la app tenga el permiso activado.") {
            SettingsRow(title: "Micrófono", detail: "Para grabar tu voz.") {
                PillButton(title: "Abrir ajustes", height: 28) { model.openPrivacySettings("Privacy_Microphone") }
            }
            SettingsRow(title: "Audio del sistema", detail: "Para grabar el audio de la reunión.") {
                PillButton(title: "Abrir ajustes", height: 28) { model.openPrivacySettings("Privacy_ScreenCapture") }
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(T.errText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(T.errBg, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(T.errBorder, lineWidth: 1))
    }
}

// MARK: - piezas de la configuración

/// Grupo con título y filas separadas por líneas, dentro de un panel.
struct SettingsGroup<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(T.muted2).padding(.leading, 4)
            VStack(spacing: 0) {
                _VariadicView.Tree(DividedLayout()) { content }
            }
            .background(Color(hex: 0x1A1A1A), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(T.line, lineWidth: 1))
            if let footer {
                Text(footer).font(.system(size: 11.5)).foregroundStyle(T.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}

/// Pone una línea entre cada fila del grupo.
struct DividedLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last { Rectangle().fill(T.line).frame(height: 1).padding(.leading, 14) }
        }
    }
}

/// Fila: título y explicación a la izquierda, control a la derecha.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5)).foregroundStyle(T.text)
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(T.muted)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            control.fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

/// Selector compacto para una fila (2-3 opciones).
struct CompactChoice: View {
    let options: [(String, String)]
    let value: String
    let set: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { code, title in
                let sel = code == value
                Button { set(code) } label: {
                    Text(title).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(sel ? T.ink : T.muted2)
                        .padding(.horizontal, 12).frame(minWidth: 64).frame(height: 24)
                        .background(sel ? T.accent : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(sel ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(Color(hex: 0x111111), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(T.field, lineWidth: 1))
    }
}

// MARK: - Agentes

/// Cómo conectar un agente (Claude Code, Codex, Cursor…) al servicio: con el CLI local.
struct AgentSection: View {
    @State private var showPrompt = false

    private var cli: String { Worker.cliPath }
    private var home: String { SessionStore.home.path }

    var body: some View {

        SettingsGroup(title: "Conectar un agente",
                      footer: "Pega las instrucciones en CLAUDE.md, AGENTS.md o en las reglas de tu agente. Ya incluyen las rutas de este Mac.") {
            SettingsRow(title: "Instrucciones para tu agente", detail: "Qué puede hacer, con qué comandos y qué reglas seguir (solo lectura, privacidad).") {
                HStack(spacing: 8) {
                    PillButton(title: showPrompt ? "Ocultar" : "Ver", height: 28) { withAnimation(.easeOut(duration: 0.15)) { showPrompt.toggle() } }
                    CopyButton(text: promptText, label: "Copiar", filled: true)
                }
            }
            if showPrompt {
                CodeBlock(text: promptText, showCopy: false).padding(.horizontal, 14).padding(.vertical, 10)
            }
            SettingsRow(title: "CLI", detail: cli) { CopyButton(text: cli, iconOnly: true) }
            SettingsRow(title: "Carpeta de grabaciones", detail: home + "/sessions") { CopyButton(text: home + "/sessions", iconOnly: true) }
        }

        SettingsGroup(title: "Comandos", footer: "Imprimen texto o JSON por la salida estándar. list, show, search y template solo leen; save-summary guarda un resumen e import crea una grabación nueva.") {
            ForEach(commands, id: \.1) { title, cmd in
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.system(size: 13.5)).foregroundStyle(T.text)
                        Text("recorder " + cmd).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(T.accent.opacity(0.85))
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 12)
                    CopyButton(text: "\(cli) \(cmd)", iconOnly: true)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }

        SettingsGroup(title: "Archivos de cada grabación", footer: "Para agentes que prefieran leer archivos directamente.") {
            ForEach(files, id: \.0) { name, what in
                SettingsRow(title: name, detail: what) { EmptyView() }
            }
        }
    }

    private var commands: [(String, String)] {
        [
            ("Listar grabaciones: id, título, fecha, duración, estado y rutas", "list --json"),
            ("Leer la transcripción de la última (o de un id)", "show last"),
            ("Frases con tiempos y voz (también md, info, summary)", "show <id> --format json"),
            ("Buscar un texto en todas las transcripciones", "search \"presupuesto\" --json"),
            ("Instrucciones para resumir igual que la app (prompt + formato)", "template general"),
            ("Guardar el resumen que hizo tu agente (JSON o Markdown)", "save-summary <id> --by \"Claude Code\" < resumen.json"),
            ("Resumir con la IA conectada en la app", "summarize <id>"),
            ("Transcribir un audio", "import /ruta/al/audio.m4a --language auto --no-copy"),
            ("Ver la cola de trabajo", "status"),
        ]
    }

    private var files: [(String, String)] {
        [
            ("manifest.json", "Título, fechas, estado, idioma y nombres de las voces."),
            ("transcript.txt", "Transcripción en texto: [hh:mm:ss] Voz: frase."),
            ("transcript.md", "La misma transcripción en Markdown."),
            ("transcript.json", "Frases con inicio y fin (segundos), voz y pista."),
            ("summary.md", "Resumen, si se pidió."),
            ("playback.m4a", "Audio de la grabación."),
        ]
    }

    private var promptText: String {
        """
        ## All Meetings Recorder

        En este Mac está instalada All Meetings Recorder, una app que graba y transcribe reuniones en local. Para consultar las reuniones, usa su CLI:

        \(cli)

        - Listar grabaciones: `\(cli) list --json` (id, title, started_at, duration_s, status y rutas de los archivos).
        - Leer una transcripción: `\(cli) show <id>` (o `show last` para la más reciente). Con `--format json` obtienes cada frase con tiempos y voz; con `--format info`, los datos de la grabación.
        - Buscar en todas: `\(cli) search "texto" --json`.
        - Transcribir un audio: `\(cli) import <archivo> --language auto --no-copy`. Tarda alrededor de 1/5 de la duración del audio.
        - Las grabaciones están en \(home)/sessions/<id>/ (transcript.txt, transcript.json, manifest.json).

        Resúmenes (los haces tú, con tu propio modelo):
        1. `\(cli) template` imprime las instrucciones y el JSON Schema del resumen (plantillas: `\(cli) templates`; elige una con `template comercial`, `template tecnica`…).
        2. Lee la transcripción con `\(cli) show <id>`.
        3. Guarda el JSON: `\(cli) save-summary <id> --by "<tu nombre>" < resumen.json`. Aparece en la app junto a la grabación. También acepta Markdown.

        Reglas:
        - Solo lectura: no borres, muevas ni edites grabaciones.
        - Si status es "recording" o "processing", la transcripción aún no está completa: avisa o espera.
        - Las transcripciones son privadas: no envíes su contenido a servicios externos sin permiso explícito.
        - Al citar, indica la grabación (título y fecha) y el minuto [hh:mm:ss].
        """
    }
}

/// Botón de copiar al portapapeles (cambia a «Copiado» un momento). `iconOnly` para listas largas.
struct CopyButton: View {
    let text: String
    var label = "Copiar"
    var filled = false
    var iconOnly = false
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Group {
                if iconOnly {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                } else {
                    Label(copied ? "Copiado" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).frame(height: 28)
                }
            }
            .foregroundStyle(copied || filled ? T.ink : T.text2)
            .background(copied || filled ? T.accent : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(copied || filled ? .clear : T.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(copied ? "Copiado" : "Copiar al portapapeles")
        .accessibilityLabel(label)
    }
}

/// Bloque de texto monoespaciado con botón de copiar.
struct CodeBlock: View {
    let text: String
    var copyLabel = "Copiar"
    var showCopy = true
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(text)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(T.text2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14).padding(.trailing, showCopy ? 110 : 0)
            if showCopy { Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? "Copiado" : copyLabel, systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(copied ? T.ink : T.text)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(copied ? T.accent : T.field, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(8) }
        }
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(T.line, lineWidth: 1))
    }
}

struct ComponentRow: View {
    let c: Component
    @ObservedObject var setup: SetupModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: c.ok ? "checkmark.circle.fill" : (c.isOptional ? "minus.circle" : "xmark.circle.fill"))
                .font(.system(size: 15))
                .foregroundStyle(c.ok ? T.accent : (c.isOptional ? T.muted : T.errFg))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.name).font(.system(size: 13.5)).foregroundStyle(T.text)
                    if c.isOptional { Text("opcional").font(.system(size: 10.5)).foregroundStyle(T.muted) }
                }
                Text(c.detail).font(.system(size: 11.5)).foregroundStyle(T.muted)
                if c.ok {
                    Text(c.path).font(.system(size: 10.5)).foregroundStyle(Color(hex: 0x6A6A6A))
                        .lineLimit(1).truncationMode(.middle).help(c.path)
                }
                if setup.busy == c.id, c.url != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: setup.progress).tint(T.accent)
                        Text(String(format: "%.0f de %d MB", setup.receivedMB, c.size_mb ?? 0))
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(T.muted)
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            if !c.ok { action }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private var action: some View {
        if setup.busy == c.id {
            if c.url != nil {
                PillButton(title: "Cancelar", height: 28) { setup.cancel() }
            } else {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Instalando…") }
                    .font(.system(size: 12)).foregroundStyle(T.muted)
            }
        } else if c.brew != nil && SetupModel.brewPath == nil {
            PillButton(title: "Instalar Homebrew…", height: 28) {
                NSWorkspace.shared.open(URL(string: "https://brew.sh/es/")!)
            }
            .help("Whisper y FFmpeg se instalan con Homebrew. Sigue las instrucciones de brew.sh y luego vuelve a comprobar.")
        } else {
            Button { setup.install(c) } label: {
                Text(c.url != nil ? "Descargar" + (c.size_mb.map { $0 >= 1000 ? String(format: " · %.1f GB", Double($0) / 1000).replacingOccurrences(of: ".", with: ",") : " · \($0) MB" } ?? "")
                                  : "Instalar")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(T.ink)
                    .padding(.horizontal, 14).frame(height: 28)
                    .background(T.accent, in: Capsule()).contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(setup.busy != nil)
            .help(c.brew.map { "Ejecuta: brew install \($0)" } ?? "Descarga desde \(c.url ?? "")")
        }
    }
}
