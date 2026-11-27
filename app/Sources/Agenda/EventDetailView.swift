import SwiftUI
import WispCore

struct EventForm: Equatable {
    var title = ""
    var allDay = false
    var start = Date()
    var end = Date()
    var calendarID = ""
    var timeZoneID = ""
    var location = ""
    var url = ""
    var notes = ""
    var alarm: Int?
    var rec = RecurrenceForm(original: nil)

    init() {}

    init(draft: EventDraft) {
        title = draft.title
        allDay = draft.allDay
        start = draft.start
        end = draft.end
        calendarID = draft.calendarID ?? ""
        timeZoneID = draft.timeZoneID ?? ""
        location = draft.location ?? ""
        url = draft.url?.absoluteString ?? ""
        notes = draft.notes ?? ""
        alarm = draft.alarmOffsets.first
        rec = RecurrenceForm(original: draft.recurrence, fallbackUntil: draft.start)
    }

    init(event: CalEvent) { self.init(draft: EventDraft(event)) }

    var recurrence: CalRecurrence? { rec.resolved }

    func draft() -> EventDraft {
        EventDraft(title: title, start: start, end: max(end, start), allDay: allDay, calendarID: calendarID.isEmpty ? nil : calendarID,
                   timeZoneID: timeZoneID.isEmpty ? nil : timeZoneID, location: location.isEmpty ? nil : location,
                   url: URL(string: url), notes: notes.isEmpty ? nil : notes, alarmOffsets: alarm.map { [$0] } ?? [], recurrence: recurrence)
    }

    func edit(from event: CalEvent) -> EventEdit {
        var change = EventEdit()
        if title != event.title { change.title = title }
        if allDay != event.allDay { change.allDay = allDay }
        if start != event.start { change.start = start }
        if end != event.end { change.end = max(end, start) }
        if calendarID != event.calendarID, !calendarID.isEmpty { change.calendarID = calendarID }
        if timeZoneID != (event.timeZoneID ?? "") { change.timeZoneID = timeZoneID }
        if location != (event.location ?? "") { change.location = location }
        if url != (event.url?.absoluteString ?? "") { change.url = url }
        if notes != (event.notes ?? "") { change.notes = notes }
        if (alarm.map { [$0] } ?? []) != event.alarmOffsets { change.alarmOffsets = alarm.map { [$0] } ?? [] }
        change.recurrence = rec.change()
        return change
    }
}

struct EventDetailView: View {
    @Bindable var model: CalendarModel
    let detail: CalendarModel.Detail
    @State private var form = EventForm()
    @State private var loadedKey = ""
    @FocusState private var titleFocused: Bool
    @State private var rsvpBusy = false
    @State private var rsvpError: String?
    private let google = GoogleModel.shared

    private var event: CalEvent? {
        if case .event(let event) = detail { return event }
        return nil
    }

    private var key: String {
        switch detail {
        case .event(let event): event.uid + "|\(event.start.timeIntervalSince1970)|\(event.end.timeIntervalSince1970)|\(event.title)|\(event.notes ?? "")"
        case .draft(let draft): "draft|\(draft.start.timeIntervalSince1970)|\(draft.end.timeIntervalSince1970)"
        }
    }

    private var readOnly: Bool { event.map { !$0.writable } ?? false }
    private var zone: TimeZone { TimeZone(identifier: form.timeZoneID) ?? model.zone }
    private var dirty: Bool {
        switch detail {
        case .event(let event): !form.edit(from: event).isEmpty
        case .draft: true
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                topBar
                TextField("", text: $form.title, prompt: Text("Título").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                    .focused($titleFocused)
                    .disabled(readOnly)
                    .onSubmit(save)
                if readOnly {
                    InlineError(text: "Este calendário é somente leitura.")
                }
                meetingSection
                timeSection
                calendarSection
                fieldRow("mappin.and.ellipse", "Local") {
                    TextField("", text: $form.location, prompt: Text("Adicionar local").foregroundStyle(Theme.textTertiary)).textFieldStyle(.plain).disabled(readOnly)
                }
                fieldRow("link", "Link") {
                    TextField("", text: $form.url, prompt: Text("URL ou link da reunião").foregroundStyle(Theme.textTertiary)).textFieldStyle(.plain).disabled(readOnly)
                }
                alertSection
                recurrenceSection
                attendeesSection
                notesSection
                brainSection
                actions
            }
            .padding(Theme.Space.m)
        }
        .scrollIndicators(.hidden)
        .frame(width: 300)
        .background(Theme.surface)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.stroke).frame(width: 1) }
        .onAppear(perform: load)
        .onChange(of: key) { _, _ in load() }
    }

    private func load() {
        guard loadedKey != key else { return }
        loadedKey = key
        switch detail {
        case .event(let event): form = EventForm(event: event)
        case .draft(let draft):
            form = EventForm(draft: draft)
            titleFocused = true
        }
    }

    private var topBar: some View {
        HStack {
            Text(event == nil ? "Novo evento" : "Evento").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            Spacer()
            Button { model.closeDetail() } label: { Image(systemName: "xmark") }
                .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                .help("Fechar")
        }
    }

    @ViewBuilder
    private var meetingSection: some View {
        if let event {
            let link = MeetingLinks.detect(event)
            let saved = model.links.link(for: event.uid)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let link {
                        Button { model.join(event) } label: { Label("Entrar", systemImage: "video.fill").font(Theme.Font.bodyMedium) }
                            .buttonStyle(CapsuleButtonStyle(kind: .accent))
                            .help(link.provider.name)
                    }
                    Button { model.recordAndTranscribe(event) } label: { Label("Gravar e transcrever", systemImage: "record.circle").font(Theme.Font.caption) }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                }
                if let folder = saved?.recordingFolder {
                    Text("Gravação: \(folder)").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
        }
    }

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { form.allDay }, set: setAllDay)) {
                Text("Dia todo").font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(readOnly)
            DatePicker("Início", selection: $form.start, displayedComponents: form.allDay ? [.date] : [.date, .hourAndMinute])
                .environment(\.timeZone, zone)
                .disabled(readOnly)
                .onChange(of: form.start) { old, new in
                    if !form.allDay, form.end <= new { form.end = new.addingTimeInterval(max(900, form.end.timeIntervalSince(old))) }
                }
            DatePicker("Fim", selection: $form.end, in: form.start..., displayedComponents: form.allDay ? [.date] : [.date, .hourAndMinute])
                .environment(\.timeZone, zone)
                .disabled(readOnly)
            if !form.allDay {
                HStack {
                    Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    CapsuleMenu(title: form.timeZoneID.isEmpty ? "Fuso do Mac (\(TimeZoneKit.offsetLabel(model.zone, at: form.start)))" : TimeZoneKit.label(zone, at: form.start), help: "Fuso horário") {
                        Button("Fuso do Mac (\(TimeZoneKit.label(model.zone, at: form.start)))") { form.timeZoneID = "" }
                        Divider()
                        ForEach(zoneChoices, id: \.self) { id in
                            if let tz = TimeZone(identifier: id) { Button(TimeZoneKit.label(tz, at: form.start)) { form.timeZoneID = id } }
                        }
                    }
                    .disabled(readOnly)
                }
            }
        }
        .font(Theme.Font.body)
        .foregroundStyle(Theme.textPrimary)
    }

    private var zoneChoices: [String] {
        var list = TimeZoneKit.common
        if !form.timeZoneID.isEmpty, !list.contains(form.timeZoneID) { list.insert(form.timeZoneID, at: 0) }
        return list
    }

    private func setAllDay(_ on: Bool) {
        guard on != form.allDay else { return }
        let cal = model.calendar
        if on {
            let day = cal.startOfDay(for: form.start)
            let lastDay = cal.startOfDay(for: form.end)
            form.start = day
            form.end = CalendarDates.allDayEnd(lastDay: max(day, lastDay), calendar: cal)
        } else {
            let day = cal.startOfDay(for: form.start)
            form.start = cal.date(byAdding: .hour, value: 9, to: day) ?? day
            form.end = form.start.addingTimeInterval(3_600)
        }
        form.allDay = on
    }

    private var calendarSection: some View {
        let writable = model.calendars.filter { $0.writable || $0.id == form.calendarID }
        return fieldRow("calendar", "Calendário") {
            Picker("", selection: $form.calendarID) {
                ForEach(writable, id: \.id) { calendar in
                    Text("\(calendar.title) · \(calendar.sourceTitle)").tag(calendar.id)
                }
            }
            .labelsHidden()
            .disabled(readOnly || event != nil && !(event?.writable ?? false))
        }
    }

    private static let alarmChoices: [(String, Int?)] = [
        ("Nenhum", nil), ("Na hora", 0), ("5 min antes", -300), ("10 min antes", -600), ("15 min antes", -900),
        ("30 min antes", -1_800), ("1 hora antes", -3_600), ("1 dia antes", -86_400),
    ]

    private var alertSection: some View {
        fieldRow("bell", "Alerta") {
            Picker("", selection: $form.alarm) {
                ForEach(Self.alarmChoices, id: \.0) { choice in Text(choice.0).tag(choice.1) }
                if let current = form.alarm, !Self.alarmChoices.contains(where: { $0.1 == current }) {
                    Text("\(abs(current) / 60) min antes").tag(Optional(current))
                }
            }
            .labelsHidden()
            .disabled(readOnly)
        }
    }

    private func touching<T>(_ keyPath: WritableKeyPath<RecurrenceForm, T>) -> Binding<T> {
        Binding(get: { form.rec[keyPath: keyPath] }, set: { value in form.rec.edit { $0[keyPath: keyPath] = value } })
    }

    private var recurrenceLocked: Bool { readOnly || (event?.hasMultipleRules ?? false) }

    private var recurrenceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldRow("repeat", "Repetir") {
                Picker("", selection: touching(\.frequency)) {
                    Text("Nunca").tag(Optional<RecurrenceFrequency>.none)
                    Text("Diariamente").tag(Optional(RecurrenceFrequency.daily))
                    Text("Semanalmente").tag(Optional(RecurrenceFrequency.weekly))
                    Text("Mensalmente").tag(Optional(RecurrenceFrequency.monthly))
                    Text("Anualmente").tag(Optional(RecurrenceFrequency.yearly))
                }
                .labelsHidden()
                .disabled(recurrenceLocked)
            }
            if form.rec.frequency != nil {
                HStack(spacing: 8) {
                    Stepper("A cada \(form.rec.interval)", value: touching(\.interval), in: 1...max(30, form.rec.interval)).font(Theme.Font.caption)
                    Picker("", selection: touching(\.endMode)) {
                        Text("Sem fim").tag(RecurrenceForm.EndMode.never)
                        Text("Após N vezes").tag(RecurrenceForm.EndMode.count)
                        Text("Até a data").tag(RecurrenceForm.EndMode.until)
                    }
                    .labelsHidden()
                }
                .disabled(recurrenceLocked)
                if form.rec.endMode == .count {
                    Stepper("Termina após \(form.rec.endCount) vezes", value: touching(\.endCount), in: 1...max(999, form.rec.endCount)).font(Theme.Font.caption).disabled(recurrenceLocked)
                }
                if form.rec.endMode == .until {
                    DatePicker("Termina em", selection: touching(\.endUntil), displayedComponents: [.date]).font(Theme.Font.caption).disabled(recurrenceLocked)
                }
                if event?.hasMultipleRules == true {
                    Text("Regra personalizada mantida: este evento tem mais de uma regra de repetição e o Wisp não as altera.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                } else if !form.rec.touched, form.rec.original?.hasDetail == true {
                    Text("Regra personalizada (dias da semana ou do mês) mantida como está.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var attendeesSection: some View {
        if let event, !event.attendees.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Convidados").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                ForEach(Array(event.attendees.enumerated()), id: \.offset) { _, person in
                    HStack(spacing: 6) {
                        Image(systemName: icon(person.status)).font(.system(size: 11)).foregroundStyle(color(person.status))
                        Text(person.name + (person.isOrganizer ? " (organizador)" : "") + (person.isMe ? " (você)" : ""))
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                }
                rsvpSection(event)
                Text("O macOS não permite editar convidados por aqui.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
            .onChange(of: event.attendees) { _, _ in google.reconcile(event) }
        }
    }

    private func isInvitee(_ event: CalEvent) -> Bool {
        event.attendees.contains { $0.isMe && !$0.isOrganizer }
    }

    @ViewBuilder
    private func rsvpSection(_ event: CalEvent) -> some View {
        if isInvitee(event) {
            VStack(alignment: .leading, spacing: 6) {
                if google.account(for: event) != nil {
                    let current = google.syncing(event) ?? event.attendees.first(where: \.isMe).flatMap { GoogleRSVPChoice($0.status) }
                    HStack(spacing: 8) {
                        Text("Vai?").font(Theme.Font.bodyMedium).foregroundStyle(Theme.textPrimary)
                        Picker("", selection: Binding<GoogleRSVPChoice?>(get: { current }, set: { if let choice = $0 { respond(event, choice) } })) {
                            ForEach(GoogleRSVPChoice.allCases, id: \.self) { choice in Text(choice.label).tag(Optional(choice)) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(rsvpBusy)
                    }
                    if google.syncing(event) != nil {
                        Text("sincronizando com o macOS…").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    }
                } else if !google.isConnected {
                    Text("Conecte o Google em Ajustes > Automações para responder").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    Button { MeetingsCoordinator.shared.openGoogleSettings() } label: { Label("Abrir Automações", systemImage: "gearshape").font(Theme.Font.caption) }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                } else {
                    Text("Nenhuma conta Google conectada corresponde a este convite.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
                if let rsvpError { InlineError(text: rsvpError) }
            }
        }
    }

    private func respond(_ event: CalEvent, _ choice: GoogleRSVPChoice) {
        guard !rsvpBusy else { return }
        rsvpBusy = true
        rsvpError = nil
        Task {
            let failure = await google.respond(to: event, choice: choice, calendar: model.calendar) { model.invalidate() }
            rsvpError = failure
            rsvpBusy = false
            if failure == nil { model.invalidate() }
        }
    }

    private func icon(_ status: AttendeeStatus) -> String {
        switch status {
        case .accepted: "checkmark.circle.fill"
        case .declined: "xmark.circle.fill"
        case .tentative: "questionmark.circle.fill"
        case .pending: "circle.dotted"
        }
    }

    private func color(_ status: AttendeeStatus) -> Color {
        switch status {
        case .accepted: Theme.ok
        case .declined: Theme.error
        case .tentative: Theme.busy
        case .pending: Theme.textTertiary
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notas").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            TextEditor(text: $form.notes)
                .font(Theme.Font.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 70, maxHeight: 130)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous).fill(Theme.surfaceHi))
                .disabled(readOnly)
        }
    }

    @ViewBuilder
    private var brainSection: some View {
        if let event {
            let names = Array(Set(BrainLinks.wikilinks(in: form.notes) + model.brainLinks(for: event))).sorted()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(names, id: \.self) { name in
                    Button { model.openBrainNote(name) } label: { Label(name, systemImage: "doc.text").font(Theme.Font.caption).lineLimit(1) }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                        .help("Abrir nota no Obsidian")
                }
                if names.isEmpty, model.brainRoot != nil {
                    Button { model.createMeetingNote(for: event) } label: { Label("Criar nota da reunião", systemImage: "square.and.pencil").font(Theme.Font.caption) }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(event == nil ? "Criar" : "Salvar", action: save)
                .buttonStyle(CapsuleButtonStyle(kind: .accent))
                .disabled(readOnly || !dirty)
                .keyboardShortcut(.return, modifiers: .command)
            if let event {
                Button("Apagar") { model.requestDelete(event) }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                    .disabled(readOnly)
            }
            Spacer()
        }
    }

    private func save() {
        switch detail {
        case .draft: model.commitDraft(form.draft())
        case .event(let event):
            let change = form.edit(from: event)
            guard !change.isEmpty else { return }
            model.edit(event, change)
        }
    }

    private func fieldRow<Content: View>(_ symbol: String, _ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).frame(width: 16)
            content().font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(minHeight: 30)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous).fill(Theme.surfaceHi.opacity(0.6)))
        .help(label)
    }
}
