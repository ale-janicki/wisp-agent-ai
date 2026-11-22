import SwiftUI
import WispCore

struct CalendarSidebar: View {
    @Bindable var model: CalendarModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Calendários").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                ForEach(model.sources, id: \.id) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(isOn: Binding(get: { model.sourceVisible(source.id) }, set: { model.setSource(source.id, visible: $0) })) {
                            Text(source.title.isEmpty ? "Outros" : source.title).font(Theme.Font.bodyMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        ForEach(source.calendars, id: \.id) { calendar in
                            let on = !model.prefs.hiddenCalendars.contains(calendar.id)
                            Button {
                                model.setCalendar(calendar, visible: !on)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: on ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 12))
                                        .foregroundStyle(on ? Color(hex: calendar.colorHex) : Theme.textTertiary)
                                    Text(calendar.title).font(Theme.Font.body).foregroundStyle(on ? Theme.textPrimary : Theme.textTertiary).lineLimit(1)
                                    if !calendar.writable { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.textTertiary) }
                                    Spacer(minLength: 0)
                                }
                                .frame(height: 22)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .opacity(model.sourceVisible(source.id) ? 1 : 0.4)
                        }
                    }
                }
                Divider().overlay(Theme.stroke)
                RemindersPane(model: model)
                Divider().overlay(Theme.stroke)
                ZonesPane(model: model)
            }
            .padding(Theme.Space.m)
        }
        .scrollIndicators(.hidden)
        .frame(width: 214)
        .background(Theme.surface)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.stroke).frame(width: 1) }
        .task { await model.refreshReminders() }
    }
}

struct RemindersPane: View {
    @Bindable var model: CalendarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Lembretes de hoje").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            switch model.remindersAccess {
            case .granted:
                if model.reminders.isEmpty {
                    Text(model.remindersBusy ? "Carregando…" : "Nada para hoje").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
                ForEach(model.reminders, id: \.id) { reminder in
                    let overdue = ReminderList.isOverdue(reminder, now: Date(), calendar: model.calendar)
                    HStack(alignment: .top, spacing: 6) {
                        Button { model.complete(reminder) } label: { Image(systemName: "circle").font(.system(size: 13)).foregroundStyle(overdue ? Theme.error : Theme.textSecondary) }
                            .buttonStyle(.plain)
                            .pointerStyle(.link)
                            .help("Concluir")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(reminder.title).font(Theme.Font.body).foregroundStyle(Theme.textPrimary).lineLimit(2)
                            if let due = reminder.due {
                                Text(reminder.dueHasTime ? TimeZoneKit.clock(due, in: model.zone) : (overdue ? "atrasado" : "hoje"))
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(overdue ? Theme.error : Theme.textTertiary)
                            }
                        }
                    }
                }
            case .notDetermined:
                Button("Permitir lembretes") { model.requestRemindersAccess() }.buttonStyle(CapsuleButtonStyle(kind: .ghost))
            default:
                Text("Sem acesso aos Lembretes. Libere em Ajustes do Sistema > Privacidade e Segurança.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

struct ZonesPane: View {
    @Bindable var model: CalendarModel
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fusos horários extras").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            ForEach(model.prefs.secondaryZones, id: \.self) { id in
                HStack {
                    Text(TimeZone(identifier: id).map { TimeZoneKit.label($0, at: Date()) } ?? id).font(Theme.Font.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer()
                    Button { model.setSecondaryZones(model.prefs.secondaryZones.filter { $0 != id }) } label: { Image(systemName: "xmark") }
                        .buttonStyle(CircleButtonStyle(size: 18))
                }
            }
            SearchField(text: $query, placeholder: "Adicionar fuso")
            if !query.isEmpty {
                ForEach(TimeZoneKit.search(query, limit: 5), id: \.self) { id in
                    Button {
                        if !model.prefs.secondaryZones.contains(id) { model.setSecondaryZones(model.prefs.secondaryZones + [id]) }
                        query = ""
                    } label: {
                        Text(TimeZone(identifier: id).map { TimeZoneKit.label($0, at: Date()) } ?? id).font(Theme.Font.caption).foregroundStyle(Theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                }
            }
        }
    }
}
