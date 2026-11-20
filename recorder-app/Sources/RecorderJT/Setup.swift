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

struct SetupView: View {
    @ObservedObject var setup = SetupModel.shared
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Configuración").font(T.display(30)).foregroundStyle(T.text)
                    Text("Lo que necesita la app para transcribir en este Mac. Todo funciona sin internet una vez instalado.")
                        .font(.system(size: 13)).foregroundStyle(T.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { setup.check() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13))
                        .foregroundStyle(T.text).frame(width: 32, height: 32)
                        .overlay(Circle().strokeBorder(T.border, lineWidth: 1)).contentShape(Circle())
                }
                .buttonStyle(.plain).help("Volver a comprobar").disabled(setup.checking || setup.busy != nil)
            }

            summary

            if !setup.workerFound {
                notice("No se encontró el worker de transcripción en:\n\(Worker.cliPath)\n\nEjecuta ./install.sh en la carpeta del proyecto (o vuelve a ejecutarlo si moviste la carpeta).")
            } else if let e = setup.checkError {
                notice(e)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(setup.components.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Rectangle().fill(T.line).frame(height: 1) }
                        ComponentRow(c: c, setup: setup)
                    }
                }
                .background(T.panel, in: RoundedRectangle(cornerRadius: 14))
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

            if let onClose {
                HStack { Spacer(); PillButton(title: "Cerrar", filled: true, height: 36, action: onClose) }
            }
        }
        .padding(28)
        .frame(width: 620)
        .background(T.bg)
        .preferredColorScheme(.dark)
        .onAppear { setup.check() }
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

    private func notice(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(T.errText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(T.errBg, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(T.errBorder, lineWidth: 1))
    }
}

struct ComponentRow: View {
    let c: Component
    @ObservedObject var setup: SetupModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: c.ok ? "checkmark.circle.fill" : (c.isOptional ? "minus.circle" : "xmark.circle.fill"))
                .font(.system(size: 18))
                .foregroundStyle(c.ok ? T.accent : (c.isOptional ? T.muted : T.errFg))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(c.name).font(.system(size: 14, weight: .medium)).foregroundStyle(T.text)
                    if c.isOptional { Text("opcional").font(.system(size: 11)).foregroundStyle(T.muted) }
                }
                Text(c.detail).font(.system(size: 12)).foregroundStyle(T.muted)
                if c.ok {
                    Text(c.path).font(.system(size: 11)).foregroundStyle(Color(hex: 0x6A6A6A))
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
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder private var action: some View {
        if setup.busy == c.id {
            if c.url != nil {
                PillButton(title: "Cancelar", height: 30) { setup.cancel() }
            } else {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Instalando…") }
                    .font(.system(size: 12)).foregroundStyle(T.muted)
            }
        } else if c.brew != nil && SetupModel.brewPath == nil {
            PillButton(title: "Instalar Homebrew…", height: 30) {
                NSWorkspace.shared.open(URL(string: "https://brew.sh/es/")!)
            }
            .help("Whisper y FFmpeg se instalan con Homebrew. Sigue las instrucciones de brew.sh y luego vuelve a comprobar.")
        } else {
            Button { setup.install(c) } label: {
                Text(c.url != nil ? "Descargar" + (c.size_mb.map { $0 >= 1000 ? String(format: " · %.1f GB", Double($0) / 1000).replacingOccurrences(of: ".", with: ",") : " · \($0) MB" } ?? "")
                                  : "Instalar")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(T.ink)
                    .padding(.horizontal, 14).frame(height: 30)
                    .background(T.accent, in: Capsule()).contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(setup.busy != nil)
            .help(c.brew.map { "Ejecuta: brew install \($0)" } ?? "Descarga desde \(c.url ?? "")")
        }
    }
}
