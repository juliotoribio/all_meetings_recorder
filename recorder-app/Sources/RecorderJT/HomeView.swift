import SwiftUI

/// Inicio: resumen del periodo, recientes, actividad y captura (diseño "Inicio").
struct HomeView: View {
    @ObservedObject var model: AppModel
    let openSetup: () -> Void
    /// Abre Grabaciones (con una grabación seleccionada, o la lista).
    let open: (String?) -> Void
    @AppStorage("homePeriod") private var period = 30
    @ObservedObject private var setup = SetupModel.shared
    @State private var settingsOpen = false

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Buenos días" : h < 19 ? "Buenas tardes" : "Buenas noches"
    }

    private var today: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "es_ES"); f.dateFormat = "EEEE, d 'de' MMMM"
        let s = f.string(from: Date())
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    private var inPeriod: [SessionInfo] {
        let since = Calendar.current.date(byAdding: .day, value: -(period - 1), to: Calendar.current.startOfDay(for: Date()))!
        return model.sessions.filter { ($0.date ?? .distantPast) >= since }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                head
                kpis
                HStack(alignment: .top, spacing: 16) {
                    recent.frame(maxWidth: .infinity)
                    VStack(spacing: 16) {
                        ActivityCard(sessions: model.sessions)
                        if !setup.allGood && !setup.checking && (!setup.components.isEmpty || !setup.workerFound) {
                            banner("Falta instalar algo para transcribir", action: "Abrir", run: openSetup)
                        }
                        let errors = model.sessions.filter(\.isFailed).count
                        if errors > 0 {
                            banner(errors == 1 ? "1 grabación sin transcribir" : "\(errors) grabaciones sin transcribir",
                                   action: "Revisar") { open(model.sessions.first(where: \.isFailed)?.id) }
                        }
                        capture
                    }
                    .frame(width: 340)
                }
            }
            .frame(maxWidth: 1120)
            .padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }

    // MARK: cabecera

    private var head: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(greeting).font(T.display(44)).tracking(-0.9)
                Text(today).font(.system(size: 14)).foregroundStyle(T.muted)
            }
            Spacer()
            HStack(spacing: 0) {
                ForEach([(7, "7 días"), (30, "30 días"), (90, "90 días"), (365, "1 año")], id: \.0) { days, label in
                    let on = period == days
                    Button { period = days } label: {
                        Text(label).font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(on ? T.ink : T.muted2)
                            .padding(.horizontal, 14).frame(height: 32)
                            .background(on ? T.text : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(3)
            .background(T.panel, in: Capsule())
            .overlay(Capsule().strokeBorder(T.field, lineWidth: 1))
        }
        .padding(.horizontal, 4).padding(.bottom, 8)
    }

    // MARK: cifras

    private var kpis: some View {
        let list = inPeriod
        let total = list.compactMap(\.duration).reduce(0, +)
        let h = Int(total) / 3600, m = Int((total.truncatingRemainder(dividingBy: 3600) / 60).rounded())
        let errors = list.filter(\.isFailed).count
        let items: [(String, String, Color)] = [
            ("\(list.count)", "Grabaciones", T.text),
            (h > 0 ? "\(h)h \(m)m" : "\(m)m", "Tiempo grabado", T.text),
            ("\(list.filter { !$0.isUpload }.count)", "Reuniones", T.text),
            ("\(errors)", "Sin transcribir", errors > 0 ? T.errText : T.text),
        ]
        return HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                HStack(spacing: 0) {
                    if i > 0 { Rectangle().fill(T.field).frame(width: 1) }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(it.0).font(T.display(56)).tracking(-1.7).monospacedDigit()
                            .foregroundStyle(it.2).lineLimit(1).minimumScaleFactor(0.5)
                        Text(it.1).font(.system(size: 13)).foregroundStyle(T.muted)
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 28).padding(.horizontal, 4)
        .background(T.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: recientes

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recientes").font(.system(size: 13, weight: .medium)).foregroundStyle(T.muted)
                Spacer()
                Button { open(nil) } label: {
                    HStack(spacing: 6) {
                        Text("Ver todas")
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12.5)).foregroundStyle(T.text2)
                    .padding(.horizontal, 12).frame(height: 30)
                    .overlay(Capsule().strokeBorder(T.border, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.bottom, 10)
            if model.sessions.isEmpty {
                Text("Aún no hay grabaciones. Pulsa Grabar o arrastra un audio a la ventana.")
                    .font(.system(size: 14)).foregroundStyle(T.muted).padding(8)
            }
            ForEach(model.sessions.prefix(6)) { s in
                RecentRow(session: s) { open(s.id) }
            }
        }
        .padding(.top, 16).padding(.horizontal, 10).padding(.bottom, 10)
        .background(T.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: captura

    private var capture: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Captura").font(.system(size: 13, weight: .medium)).foregroundStyle(T.muted)
            onOff("Mi micrófono", model.micOn, model.setMic)
            onOff("Audio de la reunión", model.systemOn, model.setSystem)
            Rectangle().fill(Color(hex: 0x262626)).frame(height: 1)
            Button { settingsOpen.toggle() } label: {
                HStack {
                    Text("Idioma y calidad").font(.system(size: 14)).foregroundStyle(T.text2)
                    Spacer()
                    Text("\(languageName(model.language)) · \(qualityName(model.quality))")
                        .font(.system(size: 13)).foregroundStyle(T.muted2)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(T.muted2)
                }
                .frame(height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $settingsOpen, arrowEdge: .trailing) { TranscriptionSettings(model: model) }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(T.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private func onOff(_ label: String, _ on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(label).font(.system(size: 14)).foregroundStyle(T.text2)
            Spacer()
            HStack(spacing: 4) {
                pill("ON", selected: on) { set(true) }
                pill("OFF", selected: !on) { set(false) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func pill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? T.ink : T.dim)
                .frame(minWidth: 46).frame(height: 28).padding(.horizontal, 2)
                .background(selected ? T.text : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? T.text : T.border, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func banner(_ text: String, action: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 12) {
                Circle().fill(T.errFg).frame(width: 8, height: 8)
                Text(text).font(.system(size: 14)).foregroundStyle(T.text)
                Spacer()
                Text(action).font(.system(size: 13)).foregroundStyle(T.errText)
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .background(Color(hex: 0x1E1411), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(T.errBorder, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

struct RecentRow: View {
    let session: SessionInfo
    let open: () -> Void
    @State private var hover = false

    private var meta: String {
        switch session.state {
        case .recording: return "Grabando…"
        case .processing: return "Transcribiendo…"
        case .failed: return "\(dayGroup(session.date)), \(esTime(session.date)) · Error"
        case .ready: return "\(dayGroup(session.date)), \(esTime(session.date)) · \(session.origin)"
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                let err = session.isFailed
                HStack(spacing: 2) {
                    ForEach(Array(seeded(session.id, 5).enumerated()), id: \.offset) { _, v in
                        RoundedRectangle(cornerRadius: 1).fill(err ? T.errFg : Color(hex: 0x8A8A8A))
                            .frame(width: 2, height: 7 + v * 17)
                    }
                }
                .frame(width: 40, height: 40)
                .background(err ? T.errBg : T.thumb, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title).font(.system(size: 15)).lineLimit(1)
                    Text(meta).font(.system(size: 12.5)).foregroundStyle(err ? T.errText : T.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(durationText(session.duration)).font(.system(size: 13).monospacedDigit()).foregroundStyle(T.muted)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(hex: 0x6A6A6A))
            }
            .padding(.horizontal, 8).padding(.vertical, 10)
            .background(hover ? T.rowSel.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Mapa de actividad: 15 semanas, intensidad según los minutos grabados cada día.
struct ActivityCard: View {
    let sessions: [SessionInfo]
    private let weeks = 15

    private func key(_ d: Date) -> Date { Calendar.current.startOfDay(for: d) }

    var body: some View {
        let cal = Calendar.current
        var minutes: [Date: Double] = [:]
        for s in sessions { if let d = s.date { minutes[key(d), default: 0] += max(1, (s.duration ?? 60) / 60) } }
        let todayKey = key(Date())
        let dow = (cal.component(.weekday, from: todayKey) + 5) % 7  // lunes = 0
        let start = cal.date(byAdding: .day, value: -dow - (weeks - 1) * 7, to: todayKey)!
        var streak = 0
        while minutes[cal.date(byAdding: .day, value: -streak, to: todayKey)!] != nil { streak += 1 }
        let active = minutes.count

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Actividad").font(.system(size: 13, weight: .medium)).foregroundStyle(T.muted)
                Spacer()
                if streak > 0 {
                    Text("Racha de \(streak) \(streak == 1 ? "día" : "días")").font(.system(size: 12.5)).foregroundStyle(T.accent)
                }
            }
            HStack(spacing: 4) {
                ForEach(0..<weeks, id: \.self) { w in
                    VStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { d in
                            let day = cal.date(byAdding: .day, value: w * 7 + d, to: start)!
                            RoundedRectangle(cornerRadius: 3)
                                .fill(day > todayKey ? Color.clear : shade(minutes[day]))
                                .frame(width: 15, height: 15)
                        }
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(active) días con grabaciones")
            HStack {
                HStack(spacing: 4) {
                    Text("Menos")
                    ForEach([nil, 5.0, 30, 90, 200], id: \.self) { m in
                        RoundedRectangle(cornerRadius: 3).fill(shade(m)).frame(width: 11, height: 11)
                    }
                    Text("Más")
                }
                Spacer()
                Text("\(active) \(active == 1 ? "día activo" : "días activos")")
            }
            .font(.system(size: 12)).foregroundStyle(T.muted)
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
        .background(T.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private func shade(_ m: Double?) -> Color {
        guard let m else { return T.thumb }
        if m < 15 { return T.accent.opacity(0.3) }
        if m < 60 { return T.accent.opacity(0.55) }
        if m < 120 { return T.accent.opacity(0.8) }
        return T.accent
    }
}
