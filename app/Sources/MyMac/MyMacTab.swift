import SwiftUI
import WispCore

struct MyMacTab: View {
    @State private var model = MyMacModel()

    private var gap: CGFloat { Theme.Layout.cardGap }

    var body: some View {
        ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: gap) {
            MachineHeader(machine: model.machine)
            HStack(spacing: gap) {
                CPUTile(snapshot: model.snapshot, history: model.cpuHistory)
                MemoryTile(snapshot: model.snapshot, history: model.memoryHistory)
                NetworkTile(snapshot: model.snapshot, down: model.downHistory, up: model.upHistory)
            }
            .frame(minHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: gap) {
                DiskTile(snapshot: model.snapshot)
                TemperatureTile(snapshot: model.snapshot)
                if model.snapshot == nil || model.snapshot?.battery != nil {
                    BatteryTile(battery: model.snapshot?.battery, celsius: model.snapshot?.temperature.battery)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: gap) {
                ProcessTile(title: "Mais CPU", icon: "flame.fill", rows: model.snapshot.map { ProcessTable.topByCPU($0.processes) }) {
                    SystemFormat.processCPU($0.cpu)
                }
                ProcessTile(title: "Mais memória", icon: "square.stack.3d.up.fill", rows: model.snapshot.map { ProcessTable.topByMemory($0.processes) }) {
                    SystemFormat.bytes($0.residentBytes, binary: true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, Theme.Space.m)
        }
        .scrollIndicators(.hidden)
        .task { await model.run() }
    }
}

// MARK: - Header

private struct MachineHeader: View {
    let machine: MachineInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let machine {
                Text(machine.name)
                    .font(Theme.Font.heading)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(subtitle(machine, now: context.date))
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Skeleton(cornerRadius: 6).frame(width: 260, height: 24)
                Skeleton(cornerRadius: 6).frame(width: 380, height: 14)
            }
        }
        .help(machine.map { "\($0.modelIdentifier) · \($0.hostName)" } ?? "")
    }

    private func subtitle(_ machine: MachineInfo, now: Date) -> String {
        var parts = [String]()
        if !machine.chip.isEmpty { parts.append(machine.chip) }
        parts.append(machine.osBuild.isEmpty ? "macOS \(machine.osVersion)" : "macOS \(machine.osVersion) (\(machine.osBuild))")
        parts.append("ligado há \(SystemFormat.duration(now.timeIntervalSince(machine.bootTime)))")
        parts.append(machine.hostName)
        return parts.joined(separator: " · ")
    }
}

// MARK: - Tile

private struct MacTile<Content: View>: View {
    let title: String
    let icon: String
    var trailing: String?
    var shortTrailing: String?
    var dot: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 16)
                Text(title)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: Theme.Space.s)
                if let trailing {
                    HStack(spacing: 5) {
                        if let dot {
                            Circle().fill(dot).frame(width: 6, height: 6)
                        }
                        ViewThatFits(in: .horizontal) {
                            caption(trailing)
                            if let shortTrailing { caption(shortTrailing) }
                        }
                    }
                }
            }
            .frame(height: 20)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

private struct Figure: View {
    let value: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(Theme.Font.heading)
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
            if let detail {
                Text(detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .lineLimit(1)
    }
}

private struct Detail: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textTertiary)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

private struct LoadingFigure: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Skeleton(cornerRadius: 6).frame(width: 90, height: 24)
            Skeleton(cornerRadius: 6).frame(height: 12)
        }
    }
}

private struct LiveSparkline: View {
    let series: [[Double]]
    var colors: [Color] = [Theme.accent]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(series.enumerated()), id: \.offset) { index, values in
                    let color = colors[index % colors.count]
                    if values.count > 1 {
                        area(values, in: geo.size)
                            .fill(LinearGradient(colors: [color.opacity(0.22), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                        line(values, in: geo.size)
                            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
    }

    private func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
        let slots = CGFloat(max(1, values.count - 1))
        return values.enumerated().map { index, value in
            CGPoint(
                x: size.width * CGFloat(index) / slots,
                y: 1 + (size.height - 2) * (1 - CGFloat(value))
            )
        }
    }

    private func line(_ values: [Double], in size: CGSize) -> Path {
        Path { path in path.addLines(points(values, in: size)) }
    }

    private func area(_ values: [Double], in size: CGSize) -> Path {
        let points = points(values, in: size)
        return Path { path in
            guard let first = points.first, let last = points.last else { return }
            path.move(to: CGPoint(x: first.x, y: size.height))
            path.addLines(points)
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.closeSubpath()
        }
    }
}

private struct UsageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(Theme.surfaceHi)
                .overlay(alignment: .leading) {
                    Capsule().fill(fraction >= 0.9 ? Theme.error : Theme.accent)
                        .frame(width: geo.size.width * min(1, max(0, fraction)))
                }
        }
        .frame(height: 4)
    }
}

// MARK: - CPU / Memória / Rede

private struct CPUTile: View {
    let snapshot: SystemSnapshot?
    let history: SampleHistory

    var body: some View {
        MacTile(title: "CPU", icon: "cpu", trailing: snapshot.map { SystemFormat.load($0.load) }) {
            if let cpu = snapshot?.cpu {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Figure(value: SystemFormat.percent(cpu.total), detail: "em uso")
                    if let efficiency = cpu.efficiency, let performance = cpu.performance {
                        Detail("P \(SystemFormat.percent(performance)) · E \(SystemFormat.percent(efficiency))")
                    } else {
                        Detail("carga 1 · 5 · 15 min")
                    }
                    Spacer(minLength: 0)
                    LiveSparkline(series: [history.normalized(floor: 1)])
                }
                .frame(maxHeight: .infinity)
            } else {
                LoadingFigure()
            }
        }
        .help("Carga média de 1, 5 e 15 minutos à direita")
    }
}

private struct MemoryTile: View {
    let snapshot: SystemSnapshot?
    let history: SampleHistory

    var body: some View {
        MacTile(
            title: "Memória",
            icon: "memorychip",
            trailing: snapshot?.pressure.map { "Pressão \($0.label.lowercased())" },
            shortTrailing: snapshot?.pressure?.label,
            dot: snapshot?.pressure == nil ? nil : (snapshot?.pressure == .normal ? Theme.ok : pressureColor)
        ) {
            if let memory = snapshot?.memory {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Figure(value: SystemFormat.bytes(memory.used, binary: true), detail: "de \(SystemFormat.bytes(memory.total, binary: true))")
                    Detail("Apps \(gb(memory.app)) · Fixa \(gb(memory.wired))")
                    Detail(swapLine(memory))
                    Spacer(minLength: 0)
                    LiveSparkline(series: [history.normalized(floor: 1)], colors: [pressureColor])
                }
                .frame(maxHeight: .infinity)
                .help(snapshot.map { "Swap \(gb($0.swapUsed)) usados de \(gb($0.swapTotal)) · cache de arquivos \(gb(memory.cached))" } ?? "")
            } else {
                LoadingFigure()
            }
        }
    }

    private func gb(_ bytes: UInt64) -> String { SystemFormat.bytes(bytes, binary: true) }

    private func swapLine(_ memory: MemoryBreakdown) -> String {
        let compressed = "Compr. \(gb(memory.compressed))"
        guard let snapshot, snapshot.swapTotal > 0 else { return compressed }
        return "\(compressed) · Swap \(gb(snapshot.swapUsed))"
    }

    private var pressureColor: Color {
        switch snapshot?.pressure {
        case .warning: Theme.busy
        case .critical: Theme.error
        default: Theme.accent
        }
    }
}

private struct NetworkTile: View {
    let snapshot: SystemSnapshot?
    let down: SampleHistory
    let up: SampleHistory

    private static let floor: Double = 50_000

    var body: some View {
        MacTile(title: "Rede", icon: "network", trailing: trailing) {
            if snapshot != nil, snapshot?.network == nil {
                TabMessage(text: "Sem conexão de rede")
            } else if let network = snapshot?.network, let rate = network.rate {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    rateLabel("arrow.down", SystemFormat.rate(rate.down), color: Theme.accent)
                    rateLabel("arrow.up", SystemFormat.rate(rate.up), color: Theme.accentTeal)
                    Detail(network.address.map { "IP \($0)" } ?? "Sem endereço IPv4")
                    let peak = max(Self.floor, (down.values + up.values).max() ?? 0)
                    Spacer(minLength: 0)
                    LiveSparkline(
                        series: [down.values.map { $0 / peak }, up.values.map { $0 / peak }],
                        colors: [Theme.accent, Theme.accentTeal]
                    )
                }
                .frame(maxHeight: .infinity)
            } else {
                LoadingFigure()
            }
        }
    }

    private var trailing: String? {
        guard let network = snapshot?.network else { return nil }
        return network.displayName.map { "\($0) · \(network.interface)" } ?? network.interface
    }

    private func rateLabel(_ icon: String, _ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
            Text(text)
                .font(Theme.Font.title)
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
        }
        .lineLimit(1)
    }
}

// MARK: - Disco / Temperatura / Bateria

private struct DiskTile: View {
    let snapshot: SystemSnapshot?

    var body: some View {
        let volumes = snapshot?.volumes ?? []
        let boot = volumes.first { $0.isBoot } ?? volumes.first
        MacTile(title: "Disco", icon: "internaldrive.fill", trailing: boot?.name) {
            if let boot {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Figure(value: SystemFormat.bytes(boot.available), detail: "livres de \(SystemFormat.bytes(boot.total))")
                    UsageBar(fraction: boot.usedFraction)
                        .padding(.vertical, 2)
                    Detail("\(SystemFormat.bytes(boot.availableRaw)) sem o purgável")
                    ForEach(volumes.filter { $0.id != boot.id }) { volume in
                        Detail("\(volume.name) · \(SystemFormat.bytes(volume.available)) livres de \(SystemFormat.bytes(volume.total))")
                    }
                }
                .help("Livre como o Finder mostra (inclui espaço purgável que o macOS libera quando precisa)")
            } else if snapshot != nil {
                TabMessage(text: "Não consegui ler o disco")
            } else {
                LoadingFigure()
            }
        }
    }
}

private struct TemperatureTile: View {
    let snapshot: SystemSnapshot?

    var body: some View {
        MacTile(title: "Temperatura", icon: "thermometer.medium") {
            if let snapshot {
                let temperature = snapshot.temperature
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    if let average = temperature.socAverage {
                        Figure(value: SystemFormat.celsius(average), detail: "chip, média")
                        Detail(others(temperature))
                        Detail("Estado térmico \(snapshot.thermal.label.lowercased())")
                    } else {
                        Figure(value: snapshot.thermal.label, detail: "estado térmico")
                        Detail("Sensores de temperatura indisponíveis")
                    }
                }
                .help("Sensores do chip (média dos sensores de die; a Apple não publica quais são da CPU ou da GPU)")
            } else {
                LoadingFigure()
            }
        }
    }

    private func others(_ temperature: TemperatureSummary) -> String {
        var parts = [String]()
        if let max = temperature.socMax { parts.append("máx \(SystemFormat.celsius(max))") }
        if let ssd = temperature.ssd { parts.append("SSD \(SystemFormat.celsius(ssd))") }
        return parts.joined(separator: " · ")
    }

}

private struct BatteryTile: View {
    let battery: BatteryStatus?
    let celsius: Double?

    var body: some View {
        MacTile(title: "Bateria", icon: icon, trailing: battery?.stateLabel) {
            if let battery {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Figure(value: "\(battery.percent)%", detail: battery.timeLabel ?? battery.stateLabel.lowercased())
                    Detail(health(battery))
                    if let celsius {
                        Detail("Temperatura \(SystemFormat.celsius(celsius))")
                    }
                }
            } else {
                LoadingFigure()
            }
        }
    }

    private var icon: String {
        guard let battery else { return "battery.100" }
        if battery.state == .charging { return "battery.100.bolt" }
        switch battery.percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    private func health(_ battery: BatteryStatus) -> String {
        var parts = [String]()
        if let cycles = battery.cycleCount { parts.append("\(cycles) ciclos") }
        if let health = battery.health { parts.append("capacidade \(health)%") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Processos

private struct ProcessTile: View {
    let title: String
    let icon: String
    let rows: [ProcessSample]?
    let value: (ProcessSample) -> String

    var body: some View {
        MacTile(title: title, icon: icon) {
            if let rows, !rows.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { process in
                        HStack(spacing: Theme.Space.s) {
                            Text(process.name)
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: Theme.Space.s)
                            Text(value(process))
                                .font(Theme.Font.captionMono)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .help("\(process.name) · PID \(process.pid)")
                    }
                }
            } else if rows != nil {
                TabMessage(text: "Não consegui listar os processos")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<5, id: \.self) { _ in Skeleton(cornerRadius: 4).frame(height: 13) }
                }
            }
        }
    }
}
