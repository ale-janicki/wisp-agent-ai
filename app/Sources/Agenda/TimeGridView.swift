import SwiftUI
import WispCore

struct TimeGridView: View {
    @Bindable var model: CalendarModel
    private let hourH = CGFloat(CalendarModel.hourHeight)
    private static let gutterUnit: CGFloat = 42

    private var zones: [TimeZone] {
        model.prefs.secondaryZones.compactMap(TimeZone.init(identifier:))
    }

    private var gutterWidth: CGFloat { Self.gutterUnit * CGFloat(1 + zones.count) }

    var body: some View {
        GeometryReader { geo in
            let colW = max(48, (geo.size.width - gutterWidth) / CGFloat(model.visibleDays))
            VStack(spacing: 0) {
                header(colW: colW)
                Divider().overlay(Theme.stroke)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 0) {
                            gutter
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 0) {
                                    ForEach(model.dayBounds, id: \.self) { day in
                                        DayColumnView(model: model, day: day, width: colW)
                                            .frame(width: colW, height: hourH * 24)
                                    }
                                }
                                .scrollTargetLayout()
                            }
                            .scrollPosition(id: $model.leftDay, anchor: .leading)
                            .scrollTargetBehavior(.viewAligned)
                            .scrollIndicators(.hidden)
                            .frame(height: hourH * 24)
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onAppear {
                        let hour = max(0, Calendar.current.component(.hour, from: Date()) - 2)
                        proxy.scrollTo("hour\(hour)", anchor: .top)
                    }
                }
            }
        }
        .onChange(of: model.leftDay) { _, first in
            guard let first else { return }
            model.ensureLoaded(days: (first - 8)...(first + model.visibleDays + 8))
        }
        .onAppear {
            let first = model.leftDay ?? model.todayNumber
            model.ensureLoaded(days: (first - 8)...(first + model.visibleDays + 8))
        }
    }

    private func header(colW: CGFloat) -> some View {
        let rows = model.allDayRows
        let height = 38 + CGFloat(rows) * 19
        return HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(([TimeZone.current] + zones).enumerated()), id: \.offset) { _, zone in
                    Text(TimeZoneKit.offsetLabel(zone, at: Date()))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: Self.gutterUnit, height: 34)
                }
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(model.dayBounds, id: \.self) { day in
                        DayHeaderCell(model: model, day: day, width: colW, rows: rows)
                            .frame(width: colW, height: height, alignment: .top)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $model.leftDay, anchor: .leading)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .frame(height: height)
        }
        .frame(height: height)
    }

    private var gutter: some View {
        HStack(spacing: 0) {
            hourLabels(zone: nil)
            ForEach(zones, id: \.identifier) { zone in hourLabels(zone: zone) }
        }
        .frame(width: gutterWidth)
    }

    private func hourLabels(zone: TimeZone?) -> some View {
        let base = Calendar.current.startOfDay(for: Date())
        return VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                let moment = base.addingTimeInterval(Double(hour) * 3_600)
                Text(zone.map { TimeZoneKit.columnLabel(moment, primary: .current, secondary: $0) } ?? String(format: "%02d:00", hour))
                    .font(Theme.Font.captionMono)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: Self.gutterUnit, height: hourH, alignment: .topTrailing)
                    .padding(.trailing, 0)
                    .offset(y: hour == 0 ? 0 : -6)
                    .id(zone == nil ? "hour\(hour)" : "z\(zone?.identifier ?? "")\(hour)")
            }
        }
    }
}

struct DayHeaderCell: View {
    let model: CalendarModel
    let day: Int
    let width: CGFloat
    let rows: Int

    var body: some View {
        let date = model.index.date(forDayNumber: day)
        let today = day == model.todayNumber
        let allDay = model.events(onDay: day).filter(\.allDay)
        VStack(spacing: 2) {
            Button {
                model.focus(day: day, mode: .day)
            } label: {
                HStack(spacing: 5) {
                    Text(date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "pt_BR"))).replacingOccurrences(of: ".", with: "").uppercased())
                        .font(Theme.Font.caption)
                        .foregroundStyle(today ? Theme.accentText : Theme.textTertiary)
                    Text("\(Calendar.current.component(.day, from: date))")
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(today ? Theme.bg : Theme.textPrimary)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Circle().fill(today ? Theme.accent : .clear))
                }
                .frame(height: 34)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            ForEach(Array(allDay.prefix(rows >= 3 && allDay.count > 3 ? 2 : rows).enumerated()), id: \.offset) { _, event in
                AllDayChip(model: model, event: event, colW: width)
            }
            if rows >= 3, allDay.count > 3 {
                Text("+\(allDay.count - 2) mais")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(height: 17)
            }
        }
        .padding(.horizontal, 2)
        .frame(width: width, alignment: .top)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.stroke).frame(width: 1) }
    }
}

struct AllDayChip: View {
    let model: CalendarModel
    let event: CalEvent
    let colW: CGFloat
    @State private var offset: CGFloat = 0

    var body: some View {
        let color = model.color(for: event)
        Text(event.title)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, minHeight: 17, maxHeight: 17, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.opacity(event.declined ? 0.1 : 0.3)))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3) }
            .overlay {
                if model.selection == event.uid { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5) }
            }
            .offset(x: offset)
            .onTapGesture { model.select(event) }
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        guard event.writable else { return }
                        offset = CGFloat(GridMath.dayDelta(forTranslation: Double(value.translation.width), columnWidth: Double(colW))) * colW
                    }
                    .onEnded { value in
                        offset = 0
                        guard event.writable else { return }
                        model.moveAllDay(event, deltaDays: GridMath.dayDelta(forTranslation: Double(value.translation.width), columnWidth: Double(colW)))
                    }
            )
            .help(event.title)
    }
}

struct DayColumnView: View {
    let model: CalendarModel
    let day: Int
    let width: CGFloat
    private let hourH = CGFloat(CalendarModel.hourHeight)

    var body: some View {
        let date = model.index.date(forDayNumber: day)
        let timed = model.events(onDay: day).filter { !$0.allDay }
        let byUID = Dictionary(timed.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        let placements = EventLayout.layout(timed, on: date, calendar: model.calendar)
        let stroke = Theme.stroke
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                for hour in 0..<24 {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: CGFloat(hour) * hourH))
                    line.addLine(to: CGPoint(x: size.width, y: CGFloat(hour) * hourH))
                    context.stroke(line, with: .color(stroke), lineWidth: 1)
                }
                var edge = Path()
                edge.move(to: .zero)
                edge.addLine(to: CGPoint(x: 0, y: size.height))
                context.stroke(edge, with: .color(stroke), lineWidth: 1)
            }
            .allowsHitTesting(false)

            if model.isPending(day: day) {
                ForEach(Array(SkeletonPattern.spans(seed: day).enumerated()), id: \.offset) { _, span in
                    Skeleton(cornerRadius: 6)
                        .frame(width: width - 6, height: CGFloat(span.length) * hourH)
                        .offset(x: 2, y: CGFloat(span.start) * hourH)
                        .allowsHitTesting(false)
                }
            }

            ForEach(slots(on: date), id: \.start) { slot in
                slotView(slot, on: date)
            }

            ForEach(placements, id: \.id) { placement in
                if let event = byUID[placement.id] {
                    EventBlock(model: model, event: event, placement: placement, colW: width)
                }
            }

            if let ghost = model.creating, ghost.day == day {
                let range = GridMath.createRange(fromY: ghost.startY, toY: ghost.endY, hourHeight: Double(hourH))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.accent.opacity(0.25))
                    .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1) }
                    .frame(width: width - 6, height: CGFloat(range.end - range.start) / 60 * hourH)
                    .offset(x: 2, y: CGFloat(range.start) / 60 * hourH)
                    .allowsHitTesting(false)
            }

            if day == model.todayNumber {
                TimelineView(.everyMinute) { context in
                    let minutes = context.date.timeIntervalSince(model.calendar.startOfDay(for: context.date)) / 60
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.error).frame(height: 1.5)
                        Circle().fill(Theme.error).frame(width: 8, height: 8).offset(x: -4)
                    }
                    .frame(width: width)
                    .offset(y: CGFloat(minutes) / 60 * hourH - 1)
                }
                .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: hourH * 24, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture(count: 2).onEnded { tap in
                let range = GridMath.createRange(fromY: Double(tap.location.y), toY: Double(tap.location.y), hourHeight: Double(hourH))
                commit(range)
            }
        )
        .simultaneousGesture(TapGesture().onEnded { model.closeDetail() })
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    model.creating = (day, Double(value.startLocation.y), Double(value.location.y))
                }
                .onEnded { value in
                    model.creating = nil
                    commit(GridMath.createRange(fromY: Double(value.startLocation.y), toY: Double(value.location.y), hourHeight: Double(hourH)))
                }
        )
    }

    private func commit(_ range: (start: Int, end: Int)) {
        if model.availabilityOn {
            model.addAvailabilitySlot(day: day, startMinute: range.start, endMinute: range.end)
        } else {
            model.newDraft(day: day, startMinute: range.start, endMinute: range.end)
        }
    }

    private func slots(on date: Date) -> [DateInterval] {
        guard model.availabilityOn else { return [] }
        let start = model.calendar.startOfDay(for: date)
        let end = model.calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return model.availabilitySlots.filter { $0.start < end && $0.end > start }
    }

    private func slotView(_ slot: DateInterval, on date: Date) -> some View {
        let dayStart = model.calendar.startOfDay(for: date)
        let from = max(slot.start, dayStart).timeIntervalSince(dayStart) / 60
        let to = min(slot.end, dayStart.addingTimeInterval(86_400)).timeIntervalSince(dayStart) / 60
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Theme.ok.opacity(0.22))
            .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.ok.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
            .frame(width: width - 6, height: max(8, CGFloat(to - from) / 60 * hourH))
            .offset(x: 2, y: CGFloat(from) / 60 * hourH)
            .onTapGesture { model.removeAvailabilitySlot(slot) }
            .help("Clique para remover este horário")
    }
}

struct EventBlock: View {
    let model: CalendarModel
    let event: CalEvent
    let placement: EventPlacement
    let colW: CGFloat
    private let hourH = CGFloat(CalendarModel.hourHeight)
    @State private var shift = CGSize.zero
    @State private var growTop: CGFloat = 0
    @State private var growBottom: CGFloat = 0

    var body: some View {
        let color = model.color(for: event)
        let inner = colW - 6
        let width = max(24, inner * CGFloat(placement.widthFraction) - 2)
        let x = 2 + inner * CGFloat(placement.leadingFraction)
        let top = CGFloat(placement.startMinute) / 60 * hourH
        let height = max(16, CGFloat(placement.endMinute - placement.startMinute) / 60 * hourH - 1)
        let selected = model.selection == event.uid
        VStack(alignment: .leading, spacing: 1) {
            Text(event.title.isEmpty ? "Sem título" : event.title)
                .font(Theme.Font.caption)
                .fontWeight(.semibold)
                .foregroundStyle(event.declined ? Theme.textTertiary : Theme.textPrimary)
                .strikethrough(event.declined)
                .lineLimit(height > 40 && width >= 90 ? 2 : 1)
                .truncationMode(.tail)
                .allowsTightening(true)
                .minimumScaleFactor(0.9)
            if height > 34 {
                Text(timeLabel)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(width: width, height: height + growBottom - growTop, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(event.declined ? 0.1 : 0.28)))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3).padding(.vertical, 1) }
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5) }
        }
        .overlay(alignment: .topTrailing) {
            if MeetingLinks.detect(event) != nil, height > 22 {
                Image(systemName: "video.fill").font(.system(size: 9)).foregroundStyle(Theme.textSecondary).padding(4)
            }
        }
        .overlay(alignment: .top) { if event.writable { handle(.top) } }
        .overlay(alignment: .bottom) { if event.writable { handle(.bottom) } }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: shift == .zero ? .clear : .black.opacity(0.35), radius: 6, y: 3)
        .offset(x: x + shift.width, y: top + shift.height + growTop)
        .zIndex(shift == .zero ? 0 : 5)
        .onTapGesture { model.select(event) }
        .gesture(moveGesture)
        .help("\(event.title)\n\(timeLabel)")
    }

    private var timeLabel: String {
        let zone = model.zone
        return "\(TimeZoneKit.clock(event.start, in: zone))–\(TimeZoneKit.clock(event.end, in: zone))"
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard event.writable else { return }
                let moved = preview(value.translation)
                shift = CGSize(width: CGFloat(moved.days) * colW, height: CGFloat(moved.minutes) / 60 * hourH)
            }
            .onEnded { value in
                guard event.writable else { return }
                let dm = Double(value.translation.height) / Double(hourH) * 60
                let dd = GridMath.dayDelta(forTranslation: Double(value.translation.width), columnWidth: Double(colW))
                shift = .zero
                model.move(event, deltaMinutes: dm, deltaDays: dd)
            }
    }

    private func preview(_ translation: CGSize) -> (days: Int, minutes: Double) {
        let dm = Double(translation.height) / Double(hourH) * 60
        let dd = GridMath.dayDelta(forTranslation: Double(translation.width), columnWidth: Double(colW))
        let span = GridMath.move(TimeSpan(start: event.start, end: event.end), deltaMinutes: dm, deltaDays: 0, calendar: model.calendar)
        return (dd, span.start.timeIntervalSince(event.start) / 60)
    }

    private func handle(_ edge: Edge.Set) -> some View {
        Color.clear
            .frame(height: 7)
            .contentShape(Rectangle())
            .pointerStyle(.rowResize)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let snapped = GridMath.snap(Double(value.translation.height) / Double(hourH) * 60)
                        let pixels = CGFloat(snapped) / 60 * hourH
                        if edge == .top { growTop = pixels } else { growBottom = pixels }
                    }
                    .onEnded { value in
                        growTop = 0
                        growBottom = 0
                        model.resize(event, edge: edge, deltaMinutes: Double(value.translation.height) / Double(hourH) * 60)
                    }
            )
    }
}
