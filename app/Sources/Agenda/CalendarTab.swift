import AppKit
import SwiftUI
import WispCore

struct CalendarTab: View {
    let profile: Profile
    @Bindable private var model = CalendarModel.shared
    @FocusState private var gridFocus: Bool
    @Environment(\.openTabSettings) private var openTabSettings

    var body: some View {
        VStack(spacing: 0) {
            if model.access == .granted {
                toolbar
                if model.quickOpen { QuickBar(model: model) }
                if model.showsGoogleHint { GoogleHint(model: model) }
                ZStack {
                    content
                    overlays
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
                .padding([.horizontal, .bottom], Theme.Space.s)
            } else {
                AccessCard(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .focusable()
        .focused($gridFocus)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in model.handleKey(press) }
        .background { shortcuts }
        .onAppear {
            model.brainRoot = profile.blocks?.memory?.root
            model.start()
            gridFocus = true
            Task { await model.refreshUpcoming() }
        }
        .task(id: model.message) {
            guard model.message != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            model.message = nil
        }
    }

    private var shortcuts: some View {
        Group {
            Button("") { model.undo() }.keyboardShortcut("z", modifiers: .command)
            Button("") { model.joinNext() }.keyboardShortcut("j", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if model.searchOpen && !model.searchQuery.isEmpty {
            SearchResults(model: model)
        } else {
            switch model.mode {
            case .day, .week: TimeGridView(model: model)
            case .month: MonthView(model: model)
            case .schedule: ScheduleView(model: model)
            }
        }
    }

    private var overlays: some View {
        ZStack {
            HStack(spacing: 0) {
                if model.sidebarOpen {
                    CalendarSidebar(model: model).transition(.move(edge: .leading))
                }
                Spacer(minLength: 0)
                if let detail = model.detail {
                    EventDetailView(model: model, detail: detail).transition(.move(edge: .trailing))
                }
            }
            VStack(spacing: Theme.Space.s) {
                Spacer()
                if model.availabilityOn { AvailabilityBar(model: model) }
                if let message = model.message {
                    Text(message)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, Theme.Space.m)
                        .frame(height: 28)
                        .background(Theme.surfaceHi, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
                        .transition(.opacity)
                }
            }
            .padding(Theme.Space.s)
            .allowsHitTesting(model.availabilityOn)
            if let pending = model.pendingScope { ScopeSheet(model: model, pending: pending) }
            if let event = model.pendingDelete { DeleteSheet(model: model, event: event) }
        }
        .animation(.easeOut(duration: 0.18), value: model.detail != nil)
        .animation(.easeOut(duration: 0.18), value: model.sidebarOpen)
    }

    private var toolbar: some View {
        HStack(spacing: Theme.Space.s) {
            Button { model.toggleSidebar() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(CircleButtonStyle(kind: model.sidebarOpen ? .accent : .plain, size: Theme.Control.compactHeight))
                .help("Calendários, lembretes e fusos")
            Button("Hoje") { model.goToday() }
                .buttonStyle(CapsuleButtonStyle(kind: .ghost, size: .compact))
                .help("Hoje (T)")
            Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                .help("Anterior (K)")
            Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                .help("Próximo (J)")
            if model.searchOpen {
                SearchField(text: $model.searchQuery, placeholder: "Buscar título, local ou notas")
                    .frame(maxWidth: 260)
                Button("Fechar") {
                    model.searchOpen = false
                    model.searchQuery = ""
                    gridFocus = true
                }
                .buttonStyle(CapsuleButtonStyle(kind: .ghost, size: .compact))
            } else {
                Text(model.title)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }
            Spacer(minLength: Theme.Space.xs)
            if let next = model.upcoming, MeetingLinks.detect(next.event) != nil {
                Button { model.join(next.event) } label: { Image(systemName: "video.fill") }
                    .buttonStyle(CircleButtonStyle(kind: .accent, size: Theme.Control.compactHeight))
                    .help("Entrar em \(next.event.title) (⌘J)")
            }
            modePicker
            Button { model.quickOpen.toggle() } label: { Image(systemName: "plus") }
                .buttonStyle(CircleButtonStyle(kind: .accent, size: Theme.Control.compactHeight))
                .help("Novo evento (N)")
            IconMenu(systemImage: "ellipsis", help: "Mais", compact: true) {
                Button { model.searchOpen.toggle(); if model.searchOpen { model.loadForSearch() } } label: { Label("Buscar", systemImage: "magnifyingglass") }
                Toggle(isOn: $model.availabilityOn) { Label("Disponibilidade", systemImage: "clock.badge.checkmark") }
                if TabSettings.hasSettings(PanelTab.agenda.rawValue) {
                    Divider()
                    Button { openTabSettings(.agenda) } label: { Label("Ajustes da Agenda", systemImage: "gearshape") }
                }
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(height: 44)
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach([(CalendarViewMode.day, "D", "Dia (D)"), (.week, "S", "Semana (W)"), (.month, "M", "Mês (M)"), (.schedule, "A", "Agenda (A)")], id: \.0) { item in
                Button { model.setMode(item.0) } label: {
                    Text(item.1)
                        .font(Theme.Font.caption)
                        .foregroundStyle(model.mode == item.0 ? Theme.accentText : Theme.textSecondary)
                        .frame(width: 24, height: 22)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(model.mode == item.0 ? Theme.accentFill : .clear))
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(item.2)
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.surfaceHi))
    }
}

private struct QuickBar: View {
    @Bindable var model: CalendarModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(Theme.accent)
                TextField("", text: $model.quickText, prompt: Text("almoço amanhã 13h por 1h · reunião sexta 10-11 no calendário Trabalho").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focused)
                    .onSubmit { model.commitQuick() }
                Button("Criar") { model.commitQuick() }
                    .buttonStyle(CapsuleButtonStyle(kind: .accent, size: .compact))
                    .disabled(model.quickText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(height: 32)
            .background(Capsule().fill(Theme.surfaceHi))
            .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
            if let parsed = model.quickPreview() {
                Text(summary(parsed)).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).padding(.leading, Theme.Space.m).lineLimit(1)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.bottom, Theme.Space.s)
        .onAppear { focused = true }
        .onExitCommand { model.quickOpen = false }
    }

    private func summary(_ parsed: QuickEvent) -> String {
        let zone = model.zone
        let day = parsed.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Locale(identifier: "pt_BR")))
        let when = parsed.allDay ? "\(day) · dia todo" : "\(day) · \(TimeZoneKit.clock(parsed.start, in: zone))–\(TimeZoneKit.clock(parsed.end, in: zone))"
        return [parsed.title.isEmpty ? "Sem título" : parsed.title, when, parsed.calendarName, parsed.location].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct AvailabilityBar: View {
    @Bindable var model: CalendarModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Text("Disponibilidade").font(Theme.Font.bodyMedium).foregroundStyle(Theme.textPrimary)
                Text("Arraste na grade para marcar horários livres, ou gere a partir do expediente.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer()
                Button { model.availabilityOn = false } label: { Image(systemName: "xmark") }.buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
            }
            ScrollView {
                Text(model.availabilityText)
                    .font(Theme.Font.tool)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 70)
            HStack(spacing: Theme.Space.s) {
                Button("Gerar do expediente") { model.generateAvailability() }.buttonStyle(CapsuleButtonStyle(kind: .ghost, size: .compact))
                Button("Limpar") { model.availabilitySlots = [] }.buttonStyle(CapsuleButtonStyle(kind: .ghost, size: .compact))
                Picker("", selection: Binding(get: { model.prefs.availabilityLanguage }, set: { value in AppSettings.shared.setAgenda { $0.availabilityLanguage = value } })) {
                    Text("pt-BR").tag(AvailabilityLanguage.pt)
                    Text("English").tag(AvailabilityLanguage.en)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
                hoursControls
                Spacer()
                Button("Copiar texto") { model.copyAvailability() }
                    .buttonStyle(CapsuleButtonStyle(kind: .accent, size: .compact))
                    .disabled(model.availabilitySlots.isEmpty)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .frame(maxWidth: 520)
    }

    private var hoursControls: some View {
        HStack(spacing: 4) {
            Stepper("", value: Binding(get: { model.prefs.workingHours.startMinute / 60 }, set: { hour in
                AppSettings.shared.setAgenda { $0.workingHours = WorkingHours(weekdays: $0.workingHours.weekdays, startMinute: hour * 60, endMinute: $0.workingHours.endMinute) }
            }), in: 0...22).labelsHidden()
            Text("\(model.prefs.workingHours.startMinute / 60)h–\(model.prefs.workingHours.endMinute / 60)h").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            Stepper("", value: Binding(get: { model.prefs.workingHours.endMinute / 60 }, set: { hour in
                AppSettings.shared.setAgenda { $0.workingHours = WorkingHours(weekdays: $0.workingHours.weekdays, startMinute: $0.workingHours.startMinute, endMinute: hour * 60) }
            }), in: 1...24).labelsHidden()
        }
    }
}

private struct SearchResults: View {
    let model: CalendarModel

    var body: some View {
        let found = model.search()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if found.isEmpty { TabMessage(text: "Nada encontrado").frame(height: 160) }
                ForEach(found, id: \.uid) { event in
                    Button { model.reveal(event); model.searchOpen = false; model.searchQuery = "" } label: {
                        HStack(spacing: Theme.Space.m) {
                            RoundedRectangle(cornerRadius: 1.5).fill(model.color(for: event)).frame(width: 3, height: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title).font(Theme.Font.bodyMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Text(event.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute().locale(Locale(identifier: "pt_BR"))))
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(RowButtonStyle(height: 46))
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

private struct ScopeSheet: View {
    let model: CalendarModel
    let pending: CalendarModel.PendingScope

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).onTapGesture { model.pendingScope = nil }
            VStack(spacing: Theme.Space.s) {
                Text(isDelete ? "Apagar evento recorrente" : "Alterar evento recorrente").font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
                Text(pending.event.title).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                ForEach(RecurrenceScope.allCases, id: \.self) { scope in
                    Button(scope.label) { model.resolve(scope) }
                        .buttonStyle(CapsuleButtonStyle(kind: scope == .thisOnly ? .accent : .ghost))
                        .frame(width: 200)
                }
                Button("Cancelar") { model.pendingScope = nil; model.invalidate() }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost, size: .compact))
            }
            .padding(Theme.Space.l)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
        }
    }

    private var isDelete: Bool { pending.action == .delete }
}

private struct DeleteSheet: View {
    let model: CalendarModel
    let event: CalEvent

    var body: some View {
        let prompt = DeletePrompt.make(for: event)
        ZStack {
            Color.black.opacity(0.4).onTapGesture { model.pendingDelete = nil }
            VStack(spacing: Theme.Space.s) {
                Text(prompt.title).font(Theme.Font.title).foregroundStyle(Theme.textPrimary).lineLimit(2).multilineTextAlignment(.center)
                Text(prompt.detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(prompt.notifiesGuests ? Theme.error : Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                Button("Apagar") { model.confirmDelete() }
                    .buttonStyle(CapsuleButtonStyle(kind: .error))
                    .frame(width: 200)
                Button("Cancelar") { model.pendingDelete = nil }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost, size: .compact))
            }
            .padding(Theme.Space.l)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
        }
    }
}

private struct GoogleHint: View {
    let model: CalendarModel

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "info.circle").foregroundStyle(Theme.accent)
            Text("Não vejo uma conta Google na Agenda do Mac. Adicione em Ajustes do Sistema > Contas de Internet e ela aparece aqui.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("Abrir Contas de Internet") { model.openInternetAccounts() }.buttonStyle(CapsuleButtonStyle(kind: .accent, size: .compact))
            Button("Dispensar") { model.dismissGoogleHint() }.buttonStyle(CapsuleButtonStyle(kind: .ghost, size: .compact))
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 6)
        .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
        .padding(.horizontal, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
    }
}

private struct AccessCard: View {
    let model: CalendarModel

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "calendar.badge.exclamationmark").font(.system(size: 30)).foregroundStyle(Theme.accent)
            Text("O Wisp precisa de acesso à sua agenda").font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
            Text(sentence).font(Theme.Font.body).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            Button(model.access == .notDetermined ? "Permitir acesso" : "Abrir Ajustes do Sistema") {
                if model.access == .notDetermined { model.requestAccess() } else { model.openPrivacyPane() }
            }
            .buttonStyle(CapsuleButtonStyle(kind: .accent))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.start() }
    }

    private var sentence: String {
        switch model.access {
        case .notDetermined: "Permita uma vez para ver e organizar seus compromissos do iCloud, Google e Exchange aqui."
        case .writeOnly: "O Wisp só tem acesso de escrita. Libere o acesso total em Ajustes do Sistema > Privacidade e Segurança > Calendários."
        default: "O acesso foi negado. Libere o Wisp em Ajustes do Sistema > Privacidade e Segurança > Calendários."
        }
    }
}
