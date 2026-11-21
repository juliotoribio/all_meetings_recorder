import AppKit
import SwiftUI

// MARK: - ajustes de IA (se guardan en <home>/ai.json; las claves, en el Llavero)

/// Servicios compatibles con OpenAI que se ofrecen con la URL ya puesta.
struct AIPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let model: String
    let keyURL: String?

    static let compatible: [AIPreset] = [
        .init(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4.1-mini",
              keyURL: "https://platform.openai.com/api-keys"),
        .init(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
              model: "gemini-2.5-flash", keyURL: "https://aistudio.google.com/apikey"),
        .init(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com", model: "deepseek-chat",
              keyURL: "https://platform.deepseek.com/api_keys"),
        .init(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile",
              keyURL: "https://console.groq.com/keys"),
        .init(id: "mistral", name: "Mistral", baseURL: "https://api.mistral.ai/v1", model: "mistral-medium-latest",
              keyURL: "https://console.mistral.ai/api-keys"),
        .init(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "openai/gpt-4.1-mini",
              keyURL: "https://openrouter.ai/keys"),
    ]
    static let local: [AIPreset] = [
        .init(id: "lmstudio", name: "LM Studio", baseURL: "http://localhost:1234/v1", model: "qwen/qwen3.8-27b", keyURL: nil),
        .init(id: "ollama", name: "Ollama", baseURL: "http://localhost:11434/v1", model: "qwen3:14b", keyURL: nil),
    ]
}

@MainActor
final class AISettings: ObservableObject {
    static let shared = AISettings()

    enum Provider: String, CaseIterable, Identifiable {
        case none, cli, local, openai, claude
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "Ninguna"
            case .cli: "Tu suscripción (ChatGPT o Claude)"
            case .local: "Local (LM Studio u Ollama)"
            case .openai: "Compatible con OpenAI"
            case .claude: "Anthropic (Claude)"
            }
        }
        var needsKey: Bool { self == .openai || self == .claude }
    }

    @Published var provider: Provider = .none { didSet { save(); if !loading && provider == .cli { checkAccount() } } }
    @Published var openaiBaseURL = "" { didSet { save() } }
    @Published var openaiModel = "" { didSet { save() } }
    @Published var localBaseURL = "http://localhost:1234/v1" { didSet { save() } }
    @Published var localModel = "qwen/qwen3.8-27b" { didSet { save() } }
    @Published var claudeModel = "claude-opus-5-5" { didSet { save() } }
    /// Tu suscripción: "codex" (ChatGPT) o "claude" (Claude Code). Modelo vacío = el de la herramienta.
    @Published var cliTool = "codex" { didSet { save(); if !loading { checkAccount() } } }
    @Published var cliModel = "" { didSet { save() } }
    @Published var template = "general" { didSet { save() } }
    @Published var auto = false { didSet { save() } }

    @Published private(set) var templates: [String] = ["general"]
    @Published private(set) var hasKey: [Provider: Bool] = [:]
    @Published private(set) var testing = false
    @Published private(set) var testResult: (ok: Bool, message: String)?
    @Published private(set) var keyMessage: String?

    /// Sesión de Codex / Claude Code (opción «Tu suscripción»).
    struct Account: Decodable, Equatable { let tool: String; let installed: Bool; let logged_in: Bool; let login_command: String? }
    @Published private(set) var account: Account?
    @Published private(set) var checkingAccount = false
    @Published private(set) var waitingLogin = false
    private var loginPoll: Task<Void, Never>?

    private var loading = false
    private var url: URL { SessionStore.home.appendingPathComponent("ai.json") }

    init() { load() }

    /// Texto que sale del Mac con este proveedor (nil si es local o ninguno).
    var externalHost: String? {
        switch provider {
        case .openai: return URL(string: openaiBaseURL)?.host ?? "el servicio"
        case .claude: return "api.anthropic.com"
        case .cli: return cliTool == "codex" ? "OpenAI (tu cuenta de ChatGPT)" : "Anthropic (tu cuenta de Claude)"
        default: return nil
        }
    }

    var displayName: String {
        switch provider {
        case .none: return "ninguna"
        case .cli: return cliTool == "codex" ? "ChatGPT (Codex)" : "Claude Code"
        case .local: return localModel
        case .openai:
            let p = AIPreset.compatible.first { $0.baseURL == openaiBaseURL }
            return p.map { "\($0.name) · \(openaiModel)" } ?? openaiModel
        case .claude: return "Claude · \(claudeModel)"
        }
    }

    var isReady: Bool {
        switch provider {
        case .none: return false
        case .cli: return true
        case .local: return !localBaseURL.isEmpty && !localModel.isEmpty
        case .openai: return !openaiBaseURL.isEmpty && !openaiModel.isEmpty && hasKey[.openai] == true
        case .claude: return hasKey[.claude] == true
        }
    }

    func load() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: url),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        provider = Provider(rawValue: j["provider"] as? String ?? "") ?? .none
        openaiBaseURL = j["openai_base_url"] as? String ?? ""
        openaiModel = j["openai_model"] as? String ?? ""
        localBaseURL = j["local_base_url"] as? String ?? localBaseURL
        localModel = j["local_model"] as? String ?? localModel
        claudeModel = j["claude_model"] as? String ?? claudeModel
        cliTool = j["cli_tool"] as? String ?? "codex"
        cliModel = j["cli_model"] as? String ?? ""
        template = j["template"] as? String ?? "general"
        auto = j["auto"] as? Bool ?? false
    }

    private func save() {
        guard !loading else { return }
        testResult = nil
        let j: [String: Any] = [
            "provider": provider.rawValue, "auto": auto, "template": template,
            "openai_base_url": openaiBaseURL, "openai_model": openaiModel,
            "local_base_url": localBaseURL, "local_model": localModel, "claude_model": claudeModel,
            "cli_tool": cliTool, "cli_model": cliModel,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func apply(_ p: AIPreset) {
        if provider == .local {
            localBaseURL = p.baseURL
            if localModel.isEmpty || AIPreset.local.contains(where: { $0.model == localModel }) { localModel = p.model }
        } else {
            openaiBaseURL = p.baseURL
            openaiModel = p.model
        }
    }

    /// Lee del worker qué plantillas hay y si hay claves guardadas.
    func refresh() {
        checkAccount()
        Task {
            let (st, out) = await Worker.capture(["templates", "--json"])
            if st == 0, let d = out.data(using: .utf8), let names = try? JSONDecoder().decode([String].self, from: d), !names.isEmpty {
                templates = names
            }
            for p in [Provider.openai, .claude] {
                let (code, _) = await Worker.capture(["set-key", p.rawValue, "--status"])
                hasKey[p] = code == 0
            }
        }
    }

    func saveKey(_ key: String, for p: Provider) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        keyMessage = nil
        Task {
            let (code, out) = await Worker.capture(["set-key", p.rawValue, "--stdin"], input: k + "\n")
            hasKey[p] = code == 0
            keyMessage = code == 0 ? nil : out.trimmingCharacters(in: .whitespacesAndNewlines)
            testResult = nil
        }
    }

    func deleteKey(for p: Provider) {
        Task {
            _ = await Worker.capture(["set-key", p.rawValue, "--delete"])
            hasKey[p] = false
            testResult = nil
        }
    }

    var toolName: String { cliTool == "codex" ? "ChatGPT" : "Claude" }

    func checkAccount() {
        guard provider == .cli else { return }
        let tool = cliTool
        checkingAccount = true
        Task {
            let (_, out) = await Worker.capture(["ai-account", "--tool", tool])
            if tool == cliTool,
               let d = out.split(separator: "\n").last.map(String.init)?.data(using: .utf8),
               let a = try? JSONDecoder().decode(Account.self, from: d) {
                account = a
            }
            checkingAccount = false
        }
    }

    /// Abre Terminal con el comando oficial de inicio de sesión (se abre el navegador)
    /// y espera a que la sesión quede iniciada para probar la conexión.
    func startLogin() {
        guard let cmd = account?.login_command else { return }
        let name = toolName
        let script = """
        #!/bin/zsh
        clear
        echo "Inicio de sesión en \(name) para All Meetings Recorder."
        echo "Se abrirá el navegador: entra con tu cuenta y vuelve a la app."
        echo
        \(cmd)
        echo
        echo "Listo. Ya puedes cerrar esta ventana."
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rjt-login-\(cliTool).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            testResult = (false, "No se pudo preparar el inicio de sesión: \(error.localizedDescription)")
            return
        }
        NSWorkspace.shared.open(url)
        waitingLogin = true
        testResult = nil
        loginPoll?.cancel()
        let tool = cliTool
        loginPoll = Task {
            for _ in 0..<100 {   // hasta 5 minutos
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                let (code, out) = await Worker.capture(["ai-account", "--tool", tool])
                if code == 0 {
                    if let d = out.split(separator: "\n").last.map(String.init)?.data(using: .utf8) {
                        account = try? JSONDecoder().decode(Account.self, from: d)
                    }
                    waitingLogin = false
                    test()
                    return
                }
            }
            waitingLogin = false
        }
    }

    func cancelLogin() {
        loginPoll?.cancel()
        waitingLogin = false
        checkAccount()
    }

    func test() {
        guard !testing else { return }
        testing = true
        testResult = nil
        Task {
            let (_, out) = await Worker.capture(["ai-test", "--json"])
            struct R: Decodable { let ok: Bool; let message: String }
            if let d = out.split(separator: "\n").last.map(String.init)?.data(using: .utf8),
               let r = try? JSONDecoder().decode(R.self, from: d) {
                testResult = (r.ok, r.message)
            } else {
                testResult = (false, "No se pudo ejecutar la prueba.")
            }
            testing = false
        }
    }
}

extension Worker {
    /// Ejecuta el worker y devuelve el código de salida y la salida estándar (y de error).
    static func capture(_ args: [String], input: String? = nil) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cliPath)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            let inPipe = Pipe()
            p.standardInput = inPipe
            p.terminationHandler = { proc in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: (proc.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
            }
            do {
                try p.run()
                if let input { inPipe.fileHandleForWriting.write(input.data(using: .utf8)!) }
                try? inPipe.fileHandleForWriting.close()
            } catch {
                cont.resume(returning: (-1, error.localizedDescription))
            }
        }
    }
}

// MARK: - sección «IA» de Configuración

struct AISection: View {
    @ObservedObject var ai = AISettings.shared
    @State private var key = ""

    var body: some View {

        SettingsGroup(title: "Proveedor", footer: footer) {
            SettingsRow(title: "IA para resúmenes", detail: providerDetail) {
                Picker("", selection: $ai.provider) {
                    ForEach(AISettings.Provider.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
        }

        if ai.provider != .none {
            SettingsGroup(title: "Conexión", footer: nil) {
                if ai.provider == .openai || ai.provider == .local {
                    SettingsRow(title: "Servicio", detail: "Rellena la URL y un modelo sugerido. Puedes cambiarlos.") {
                        Menu("Elegir…") {
                            ForEach(ai.provider == .local ? AIPreset.local : AIPreset.compatible) { p in
                                Button(p.name) { ai.apply(p) }
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    SettingsRow(title: "URL", detail: nil) {
                        field(ai.provider == .local ? $ai.localBaseURL : $ai.openaiBaseURL, "https://…/v1")
                    }
                    SettingsRow(title: "Modelo", detail: nil) {
                        field(ai.provider == .local ? $ai.localModel : $ai.openaiModel, "nombre del modelo")
                    }
                }
                if ai.provider == .claude {
                    SettingsRow(title: "Modelo", detail: nil) { field($ai.claudeModel, "claude-…") }
                }
                if ai.provider == .cli {
                    SettingsRow(title: "Cuenta", detail: ai.cliTool == "codex"
                                ? "Usa Codex, que viene con la app de ChatGPT, con la sesión de tu cuenta. Cuenta para los límites de tu plan."
                                : "Usa Claude Code con la sesión de tu cuenta (Pro o Max). Cuenta para los límites de tu plan.") {
                        CompactChoice(options: [("codex", "ChatGPT"), ("claude", "Claude")], value: ai.cliTool) { ai.cliTool = $0 }
                    }
                    sessionRow
                    SettingsRow(title: "Modelo", detail: "Opcional. Vacío = el modelo por defecto de tu cuenta.") {
                        field($ai.cliModel, "por defecto")
                    }
                }
                if ai.provider.needsKey { keyRow }
                SettingsRow(title: "Probar conexión", detail: testDetail) {
                    if ai.testing {
                        ProgressView().controlSize(.small)
                    } else {
                        PillButton(title: "Probar", height: 28) { ai.test() }
                    }
                }
            }

            SettingsGroup(title: "Resúmenes", footer: nil) {
                SettingsRow(title: "Plantilla", detail: "Qué prioriza el resumen: general, comercial, técnica o one-on-one.") {
                    Picker("", selection: $ai.template) {
                        ForEach(ai.templates, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                SettingsRow(title: "Resumir al terminar", detail: "Cada grabación nueva se resume sola cuando acaba de transcribirse. Si no, usa el botón Resumir.") {
                    Toggle("", isOn: $ai.auto).labelsHidden().toggleStyle(.switch).tint(T.accent)
                }
            }
        }
    }

    @ViewBuilder private var sessionRow: some View {
        let tool = ai.cliTool == "codex" ? "Codex" : "Claude Code"
        if ai.waitingLogin {
            SettingsRow(title: "Sesión", detail: "Completa el inicio de sesión en el navegador. Se comprueba solo cuando termines.") {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    PillButton(title: "Cancelar", height: 28) { ai.cancelLogin() }
                }
            }
        } else if ai.checkingAccount && ai.account?.tool != ai.cliTool {
            SettingsRow(title: "Sesión", detail: "Comprobando…") { ProgressView().controlSize(.small) }
        } else if let a = ai.account, a.tool == ai.cliTool {
            if !a.installed {
                SettingsRow(title: "Sesión", detail: ai.cliTool == "codex"
                            ? "No se encontró Codex. Instala la app de ChatGPT (lo incluye) e inicia sesión en ella."
                            : "No se encontró Claude Code. Instálalo y vuelve a esta pantalla.") {
                    PillButton(title: "Descargar", height: 28) {
                        NSWorkspace.shared.open(URL(string: ai.cliTool == "codex" ? "https://openai.com/chatgpt/desktop/" : "https://claude.com/claude-code")!)
                    }
                }
            } else if a.logged_in {
                SettingsRow(title: "Sesión", detail: "✓ \(tool) tiene la sesión de tu cuenta de \(ai.toolName) iniciada.") {
                    EmptyView()
                }
            } else {
                SettingsRow(title: "Sesión", detail: "\(tool) aún no tiene sesión. Se inicia una vez con tu cuenta de \(ai.toolName), en el navegador.") {
                    Button { ai.startLogin() } label: {
                        Text("Iniciar sesión en \(ai.toolName)").font(.system(size: 12.5, weight: .medium)).foregroundStyle(T.ink)
                            .padding(.horizontal, 12).frame(height: 28)
                            .background(T.accent, in: Capsule()).contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Abre Terminal con el comando oficial de inicio de sesión")
                }
            }
        }
    }

    private var providerDetail: String {
        switch ai.provider {
        case .none: return "No se envía nada. Puedes pedir el resumen a tu agente."
        case .cli: return "Sin API ni claves: usa la sesión de tu cuenta de ChatGPT o Claude en este Mac."
        case .local: return "Gratis y privado. Necesita LM Studio u Ollama abiertos con un modelo descargado."
        case .openai: return "OpenAI, Gemini, DeepSeek, Groq, Mistral, OpenRouter… con tu clave."
        case .claude: return "Con tu clave de la consola de Anthropic."
        }
    }

    private var footer: String? {
        guard let host = ai.externalHost else { return nil }
        if ai.provider == .cli {
            return "Al resumir se envía el texto de la transcripción (nunca el audio) a \(host). No tiene coste aparte: usa tu plan."
        }
        return "Al resumir se envía el texto de la transcripción (nunca el audio) a \(host)."
    }

    private var testDetail: String? {
        if let r = ai.testResult { return (r.ok ? "✓ " : "✗ ") + r.message }
        return "Hace una petición mínima con tu configuración."
    }

    private var keyRow: some View {
        let has = ai.hasKey[ai.provider] == true
        let preset = AIPreset.compatible.first { $0.baseURL == ai.openaiBaseURL }
        let keyURL = ai.provider == .claude ? "https://console.anthropic.com/settings/keys" : preset?.keyURL
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Clave").font(.system(size: 13.5)).foregroundStyle(T.text)
                Text(ai.keyMessage ?? (has ? "Guardada en el Llavero de macOS." : "Se guarda en el Llavero de macOS, no en archivos."))
                    .font(.system(size: 11.5)).foregroundStyle(ai.keyMessage == nil ? T.muted : T.errText)
                    .fixedSize(horizontal: false, vertical: true)
                if !has, let keyURL, let u = URL(string: keyURL) {
                    Button("Obtener una clave ↗") { NSWorkspace.shared.open(u) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(T.accent)
                }
            }
            Spacer(minLength: 12)
            if has {
                PillButton(title: "Borrar clave", height: 28) { ai.deleteKey(for: ai.provider) }
            } else {
                SecureField("pega la clave", text: $key)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .padding(.horizontal, 10).frame(width: 190, height: 28)
                    .background(Color(hex: 0x111111), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(T.field, lineWidth: 1))
                    .onSubmit { save() }
                Button(action: save) {
                    Text("Guardar").font(.system(size: 12.5, weight: .medium)).foregroundStyle(T.ink)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(T.accent.opacity(key.isEmpty ? 0.4 : 1), in: Capsule()).contentShape(Capsule())
                }
                .buttonStyle(.plain).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func save() {
        ai.saveKey(key, for: ai.provider)
        key = ""
    }

    private func field(_ text: Binding<String>, _ prompt: String) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
            .padding(.horizontal, 10).frame(width: 280, height: 28)
            .background(Color(hex: 0x111111), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(T.field, lineWidth: 1))
    }
}

// MARK: - resumen en la vista de una grabación

struct SummaryCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ai = AISettings.shared
    let session: SessionInfo
    @State private var expanded = false
    @State private var copied = false

    private var running: Bool { model.summarizing.contains(session.id) || session.summaryStatus == "running" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 14)).foregroundStyle(T.accent)
                Text("Resumen").font(.system(size: 15, weight: .medium))
                if let by = session.summaryProvider, session.hasSummary, !running {
                    Text(by).font(.system(size: 12)).foregroundStyle(T.muted).lineLimit(1)
                }
                Spacer()
                actions
            }
            content
        }
        .padding(18)
        .background(T.panel, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 20)
        .onAppear { if ai.templates.count <= 1 { ai.refresh() } }
    }

    @ViewBuilder private var actions: some View {
        if running {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Resumiendo con \(ai.displayName)…").font(.system(size: 12.5)).foregroundStyle(T.muted)
            }
        } else if session.hasSummary {
            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.summaryText(session), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(T.text)
                        .padding(.horizontal, 12).frame(height: 28)
                        .overlay(Capsule().strokeBorder(T.border, lineWidth: 1)).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                if ai.isReady {
                    PillButton(title: "Rehacer", height: 28) { model.summarize(session) }
                        .help("Volver a resumir con \(ai.displayName) (plantilla \(ai.template))")
                }
            }
        } else if ai.provider != .none {
            Button { model.summarize(session) } label: {
                Text("Resumir").font(.system(size: 13, weight: .medium)).foregroundStyle(T.ink)
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(T.accent, in: Capsule()).contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!session.hasTranscript || session.state == .recording)
            .help("Resumir con \(ai.displayName) (plantilla \(ai.template))")
        }
    }

    @ViewBuilder private var content: some View {
        if session.hasSummary && !running {
            let text = model.summaryText(session)
            SummaryMarkdown(text: text)
                .frame(maxHeight: expanded ? nil : 220, alignment: .top)
                .clipped()
                .overlay(alignment: .bottom) {
                    if !expanded {
                        LinearGradient(colors: [T.panel.opacity(0), T.panel], startPoint: .top, endPoint: .bottom).frame(height: 50)
                    }
                }
            Button(expanded ? "Ver menos" : "Ver todo") { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } }
                .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(T.accent)
        } else if session.summaryStatus == "failed", let err = session.summaryError, !running {
            VStack(alignment: .leading, spacing: 10) {
                Text(err).font(.system(size: 12.5)).foregroundStyle(T.errText).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if ai.isReady { PillButton(title: "Reintentar", height: 28) { model.summarize(session) } }
                    PillButton(title: "Configurar IA", height: 28) { SetupNav.open(.ai) }
                }
            }
        } else if !running {
            if ai.provider == .none {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Conecta tu IA para resumir desde aquí, o pídeselo a tu agente con estas instrucciones.")
                        .font(.system(size: 13)).foregroundStyle(T.muted2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        PillButton(title: "Conectar IA", height: 28) { SetupNav.open(.ai) }
                        CopyButton(text: agentPrompt, label: "Copiar para mi agente")
                    }
                }
            } else {
                Text(ai.isReady ? "Aún no hay resumen de esta grabación."
                                : "Falta completar la conexión con la IA en Configuración → IA.")
                    .font(.system(size: 13)).foregroundStyle(T.muted2)
            }
        }
    }

    private var agentPrompt: String {
        let cli = Worker.cliPath
        return """
        Resume la grabación «\(session.title)» (id \(session.id)) de All Meetings Recorder.
        1. Lee las instrucciones y el formato: \(cli) template \(ai.template)
        2. Lee la transcripción: \(cli) show \(session.id)
        3. Guarda el resultado (JSON con el esquema): \(cli) save-summary \(session.id) --by "<nombre de tu agente>" < resumen.json
        """
    }
}

/// Abre Configuración en una sección concreta.
enum SetupNav {
    @MainActor static var pending: SetupSection?
    @MainActor static func open(_ s: SetupSection) {
        pending = s
        NotificationCenter.default.post(name: .openSetup, object: nil)
    }
}

/// Muestra el summary.md que escribe el worker (títulos, listas, tablas sencillas).
struct SummaryMarkdown: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .h2(let t):
                    Text(t).font(.system(size: 14, weight: .semibold)).foregroundStyle(T.text).padding(.top, 8)
                case .h3(let t):
                    Text(inline(t)).font(.system(size: 13.5, weight: .medium)).foregroundStyle(T.text2).padding(.top, 4)
                case .bullet(let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(T.muted)
                        Text(inline(t)).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 13.5))
                case .para(let t):
                    Text(inline(t)).font(.system(size: 13.5)).foregroundStyle(T.text2)
                        .fixedSize(horizontal: false, vertical: true)
                case .note(let t):
                    Text(t).font(.system(size: 12)).foregroundStyle(T.muted).padding(.top, 6)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Block { case h2(String), h3(String), bullet(String), para(String), note(String) }

    private var blocks: [Block] {
        var out: [Block] = []
        var tableHeader = true
        for raw in text.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l == "---" || l.hasPrefix("# ") { tableHeader = true; continue }
            if l.hasPrefix("## ") { out.append(.h2(String(l.dropFirst(3)))) }
            else if l.hasPrefix("### ") { out.append(.h3(String(l.dropFirst(4)))) }
            else if l.hasPrefix("- ") || l.hasPrefix("* ") { out.append(.bullet(String(l.dropFirst(2)))) }
            else if l.hasPrefix("|") {
                // tabla de action items: la primera fila es la cabecera y la segunda el separador
                let cells = l.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if tableHeader { tableHeader = false; continue }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
                let extra = cells.dropFirst().filter { $0 != "—" }
                out.append(.bullet(cells.first.map { $0 + (extra.isEmpty ? "" : " — " + extra.joined(separator: " · ")) } ?? ""))
            }
            else if l.hasPrefix("_") && l.hasSuffix("_") {
                // la línea de fecha y app ya está en la cabecera de la grabación
                if l.dropFirst().prefix(4).allSatisfy(\.isNumber) { continue }
                out.append(.note(String(l.dropFirst().dropLast())))
            }
            else if l.hasPrefix("Transcripción completa:") { continue }
            else { out.append(.para(l)) }
        }
        return out
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
