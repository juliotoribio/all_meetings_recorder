import AppKit
import Combine
import SwiftUI

/// Botón flotante para grabar: siempre visible sobre las demás apps (también en
/// pantalla completa y en todos los escritorios). Clic = grabar / detener;
/// arrastrar = moverlo; clic derecho = menú. Se recuerda dónde lo dejaste.
@MainActor
final class FloatingRecorder: ObservableObject {
    static let shared = FloatingRecorder()

    @Published var enabled = UserDefaults.standard.object(forKey: "floatingButton") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "floatingButton")
            enabled ? show() : hide()
        }
    }

    private var panel: NSPanel?
    private weak var model: AppModel?
    private var observers: Set<AnyCancellable> = []

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        // Al cambiar entre «Grabar» y «Detener · 12:34» cambia el tamaño.
        model.$isRecording.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.fit() }
        }.store(in: &observers)
        // Las capturas automáticas de la ventana no lo necesitan.
        if enabled && ProcessInfo.processInfo.environment["RJT_SNAPSHOT"] == nil { show() }
        // Diagnóstico del diseño (sólo con datos de demostración en RJT_HOME):
        // RJT_SNAPSHOT_FLOAT=/ruta guarda /ruta-idle.png y /ruta-rec.png.
        let env = ProcessInfo.processInfo.environment
        if let out = env["RJT_SNAPSHOT_FLOAT"], env["RJT_HOME"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Self.snapshot(model, to: out) }
        }
    }

    private static func snapshot(_ model: AppModel, to out: String) {
        func render(_ name: String) {
            let r = ImageRenderer(content: FloatingRecorderView(model: model).padding(20).background(Color(hex: 0x6A5ACD)))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: out + "-" + name + ".png"))
            }
        }
        render("idle")
        model.isRecording = true
        model.elapsed = 754
        render("rec")
        model.isRecording = false
        model.elapsed = 0
    }

    func show() {
        guard let model else { return }
        if panel == nil { panel = makePanel(model) }
        fit()
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel(_ model: AppModel) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 56, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        let host = FloatingHostView(rootView: FloatingRecorderView(model: model))
        host.onClick = { [weak model] in model?.toggle() }
        host.onMoved = { [weak self] in self?.savePosition() }
        host.menuProvider = { [weak self] in self?.contextMenu() }
        p.contentView = host
        p.setFrameOrigin(savedOrigin() ?? defaultOrigin(size: p.frame.size))
        return p
    }

    /// Ajusta el tamaño al contenido manteniendo el centro vertical y el borde izquierdo.
    private func fit() {
        guard let p = panel, let host = p.contentView else { return }
        let size = host.fittingSize
        var f = p.frame
        f.origin.y += (f.height - size.height) / 2
        f.size = size
        p.setFrame(clampToScreen(f), display: true)
        host.toolTip = (model?.isRecording ?? false) ? "Detener la grabación" : "Grabar (arrastra para mover)"
    }

    private func clampToScreen(_ f: NSRect) -> NSRect {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(f) }) ?? NSScreen.main else { return f }
        let vf = screen.visibleFrame
        var r = f
        r.origin.x = min(max(r.origin.x, vf.minX + 4), vf.maxX - r.width - 4)
        r.origin.y = min(max(r.origin.y, vf.minY + 4), vf.maxY - r.height - 4)
        return r
    }

    private func defaultOrigin(size: NSSize) -> NSPoint {
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: vf.maxX - size.width - 24, y: vf.minY + 120)
    }

    private func savedOrigin() -> NSPoint? {
        guard let s = UserDefaults.standard.string(forKey: "floatingButtonOrigin") else { return nil }
        let p = NSPointFromString(s)
        // Si esa pantalla ya no está conectada, vuelve a la posición por defecto.
        return NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -10, dy: -10).contains(p) }) ? p : nil
    }

    private func savePosition() {
        guard let p = panel else { return }
        p.setFrame(clampToScreen(p.frame), display: true)
        UserDefaults.standard.set(NSStringFromPoint(p.frame.origin), forKey: "floatingButtonOrigin")
    }

    private func contextMenu() -> NSMenu {
        let m = NSMenu()
        let recording = model?.isRecording ?? false
        m.addItem(withTitle: recording ? "Detener la grabación" : "Grabar", action: #selector(MenuTarget.toggle), keyEquivalent: "")
        m.addItem(withTitle: "Abrir All Meetings Recorder", action: #selector(MenuTarget.open), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Ocultar el botón flotante", action: #selector(MenuTarget.hideButton), keyEquivalent: "")
        for item in m.items { item.target = MenuTarget.shared }
        return m
    }
}

/// Destino de las acciones del menú contextual (NSMenu necesita un objeto Objective-C).
@MainActor
final class MenuTarget: NSObject {
    static let shared = MenuTarget()
    @objc func toggle() { FloatingRecorder.shared.toggleRecording() }
    @objc func open() { AppDelegate.showMainWindow() }
    @objc func hideButton() { FloatingRecorder.shared.enabled = false }
}

extension FloatingRecorder {
    func toggleRecording() { model?.toggle() }
}

/// Recibe el clic aunque la app no esté activa, y distingue clic de arrastre.
final class FloatingHostView: NSHostingView<FloatingRecorderView> {
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private var start: NSPoint = .zero
    private var origin: NSPoint = .zero
    private var dragged = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        origin = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        let dx = p.x - start.x, dy = p.y - start.y
        if !dragged && hypot(dx, dy) < 3 { return }
        dragged = true
        window?.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { onMoved?() } else { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

struct FloatingRecorderView: View {
    @ObservedObject var model: AppModel
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(model.isRecording ? T.rec : T.accent)
                if model.isRecording {
                    RoundedRectangle(cornerRadius: 3.5).fill(.white).frame(width: 14, height: 14)
                } else {
                    Circle().fill(T.ink).frame(width: 15, height: 15)
                }
            }
            .frame(width: 44, height: 44)
            .scaleEffect(hover ? 1.06 : 1)
            if model.isRecording {
                Text(timeString(model.elapsed))
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .foregroundStyle(T.text)
                    .padding(.trailing, 10)
            }
        }
        .padding(5)
        .background(Capsule().fill(Color(hex: 0x161616).opacity(0.95)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .fixedSize()
        .animation(.easeOut(duration: 0.12), value: hover)
        .onHover { hover = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.isRecording ? "Detener la grabación, \(timeString(model.elapsed))" : "Grabar")
        .accessibilityAddTraits(.isButton)
    }
}
