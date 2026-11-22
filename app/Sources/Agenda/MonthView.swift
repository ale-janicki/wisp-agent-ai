import SwiftUI
import WispCore

struct MonthView: View {
    @Bindable var model: CalendarModel

    private var weeks: [Int] {
        let anchor = model.weekStart(of: model.todayNumber)
        return Array(stride(from: anchor - 7 * 200, through: anchor + 7 * 200, by: 7))
    }

    private var weekdayNames: [String] {
        var names = Calendar(identifier: .gregorian)
        names.locale = Locale(identifier: "pt_BR")
        let symbols = names.shortStandaloneWeekdaySymbols
        let first = model.calendar.firstWeekday - 1
        return (0..<7).map { symbols[(first + $0) % 7].replacingOccurrences(of: ".", with: "").uppercased() }
    }

    var body: some View {
        GeometryReader { geo in
            let rowH = max(74, (geo.size.height - 22) / 5)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(weekdayNames, id: \.self) { name in
                        Text(name).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 22)
                Divider().overlay(Theme.stroke)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(weeks, id: \.self) { week in
                                WeekRowView(model: model, firstDay: week, height: rowH).id(week)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollPosition(id: $model.topWeek, anchor: .top)
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.hidden)
                    .onAppear {
                        let target = model.topWeek ?? model.weekStart(of: model.todayNumber)
                        Task { @MainActor in proxy.scrollTo(target, anchor: .top) }
                    }
                }
            }
        }
        .onChange(of: model.topWeek) { _, week in
            guard let week else { return }
            model.ensureLoaded(days: (week - 14)...(week + 7 * 8))
        }
        .onAppear {
            let week = model.topWeek ?? model.weekStart(of: model.todayNumber)
            model.ensureLoaded(days: (week - 14)...(week + 7 * 8))
        }
    }
}

private struct WeekRowView: View {
    let model: CalendarModel
    let firstDay: Int
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ForEach(firstDay..<(firstDay + 7), id: \.self) { day in
                MonthCell(model: model, day: day, maxChips: height > 100 ? 4 : 3)
            }
        }
        .frame(height: height)
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }
}

private struct MonthCell: View {
    let model: CalendarModel
    let day: Int
    let maxChips: Int

    var body: some View {
        let date = model.index.date(forDayNumber: day)
        let parts = model.calendar.dateComponents([.day, .month], from: date)
        let today = day == model.todayNumber
        let events = model.events(onDay: day)
        let shown = events.count > maxChips ? Array(events.prefix(maxChips - 1)) : events
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Button {
                    model.focus(day: day, mode: .day)
                } label: {
                    Text(parts.day == 1 ? "\(parts.day ?? 1) \(date.formatted(.dateTime.month(.abbreviated).locale(Locale(identifier: "pt_BR"))).replacingOccurrences(of: ".", with: ""))" : "\(parts.day ?? 1)")
                        .font(Theme.Font.caption)
                        .foregroundStyle(today ? Theme.bg : Theme.textSecondary)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Capsule().fill(today ? Theme.accent : .clear))
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                Spacer(minLength: 0)
            }
            if model.isPending(day: day) {
                ForEach(0..<min(maxChips - 1, SkeletonPattern.chips(seed: day)), id: \.self) { _ in
                    Skeleton(cornerRadius: 4).frame(height: 16)
                }
            }
            ForEach(shown, id: \.uid) { event in
                MonthChip(model: model, event: event)
            }
            if events.count > shown.count {
                Text("+\(events.count - shown.count) mais")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background((parts.month ?? 1) % 2 == 0 ? Theme.surfaceHi.opacity(0.35) : Color.clear)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.stroke).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.newAllDayDraft(day: day) }
        .onTapGesture { model.closeDetail() }
    }
}

private struct MonthChip: View {
    let model: CalendarModel
    let event: CalEvent

    var body: some View {
        let color = model.color(for: event)
        HStack(spacing: 4) {
            if event.allDay {
                Text(event.title).foregroundStyle(Theme.textPrimary)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(event.title).foregroundStyle(event.declined ? Theme.textTertiary : Theme.textPrimary)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(event.allDay ? color.opacity(0.35) : (model.selection == event.uid ? Theme.accentFill : .clear)))
        .contentShape(Rectangle())
        .onTapGesture { model.select(event) }
        .help("\(event.title)")
    }
}

struct ScheduleView: View {
    @Bindable var model: CalendarModel
    @State private var range: ClosedRange<Int> = 0...0
    @State private var ready = false

    private var days: [Int] {
        range.filter { day in day == model.todayNumber || !model.events(onDay: day).isEmpty }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Color.clear.frame(height: 1).onAppear { if ready { extend(back: true, proxy: proxy) } }
                    ForEach(days, id: \.self) { day in
                        Section {
                            ForEach(model.events(onDay: day), id: \.uid) { event in
                                ScheduleRow(model: model, event: event, day: day)
                            }
                            if model.events(onDay: day).isEmpty {
                                Text("Nada neste dia").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).padding(.leading, Theme.Space.m).padding(.vertical, 6)
                            }
                        } header: {
                            ScheduleHeader(model: model, day: day)
                        }
                        .id(day)
                    }
                    Color.clear.frame(height: 1).onAppear { if ready { extend(back: false, proxy: proxy) } }
                    if days.count <= 1 {
                        if model.isPending(day: model.anchorDay) {
                            VStack(spacing: 0) {
                                ForEach(0..<4, id: \.self) { _ in
                                    Skeleton(cornerRadius: Theme.Radius.nav)
                                        .frame(height: 38)
                                        .padding(.horizontal, Theme.Space.m)
                                        .padding(.vertical, 4)
                                }
                            }
                        } else if !model.loading {
                            TabMessage(text: "Nenhum evento neste período").frame(height: 120)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onAppear { reset(proxy: proxy) }
            .onChange(of: model.scheduleJump) { _, _ in reset(proxy: proxy) }
        }
    }

    private func reset(proxy: ScrollViewProxy) {
        let start = model.anchorDay
        range = (start - 3)...(start + 60)
        model.ensureLoaded(days: range)
        ready = false
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            let target = days.first { $0 >= start } ?? days.last
            if let target { proxy.scrollTo(target, anchor: .top) }
            try? await Task.sleep(for: .milliseconds(300))
            ready = true
        }
    }

    private func extend(back: Bool, proxy: ScrollViewProxy) {
        let anchor = days.first
        if back {
            range = (range.lowerBound - 45)...range.upperBound
            model.ensureLoaded(days: (range.lowerBound)...(range.lowerBound + 45))
            if let anchor { Task { proxy.scrollTo(anchor, anchor: .top) } }
        } else {
            range = range.lowerBound...(range.upperBound + 45)
            model.ensureLoaded(days: (range.upperBound - 45)...range.upperBound)
        }
    }
}

private struct ScheduleHeader: View {
    let model: CalendarModel
    let day: Int

    var body: some View {
        let date = model.index.date(forDayNumber: day)
        let today = day == model.todayNumber
        HStack(spacing: 6) {
            Text(date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).locale(Locale(identifier: "pt_BR"))).capitalized)
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(today ? Theme.accentText : Theme.textSecondary)
            if today { Text("hoje").font(Theme.Font.caption).foregroundStyle(Theme.accentText).padding(.horizontal, 6).background(Theme.accentFill, in: Capsule()) }
            Spacer()
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
    }
}

private struct ScheduleRow: View {
    let model: CalendarModel
    let event: CalEvent
    let day: Int

    var body: some View {
        let color = model.color(for: event)
        let selected = model.selection == event.uid
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .trailing, spacing: 1) {
                if event.allDay {
                    Text("dia todo").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    Text(TimeZoneKit.clock(event.start, in: model.zone)).font(Theme.Font.captionMono).foregroundStyle(Theme.textPrimary)
                    Text(TimeZoneKit.clock(event.end, in: model.zone)).font(Theme.Font.captionMono).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 48, alignment: .trailing)
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title.isEmpty ? "Sem título" : event.title)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(event.declined ? Theme.textTertiary : Theme.textPrimary)
                    .strikethrough(event.declined)
                    .lineLimit(1)
                Text([model.calendarInfo(event.calendarID)?.title, event.location.flatMap { MeetingLinks.links(in: $0).isEmpty ? $0 : nil }].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if MeetingLinks.detect(event) != nil {
                Button { model.join(event) } label: { Image(systemName: "video.fill") }
                    .buttonStyle(CircleButtonStyle(kind: .plain, size: Theme.Control.compactHeight))
                    .help("Entrar")
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(minHeight: 46)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous).fill(selected ? Theme.accentFill : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.select(event) }
    }
}
