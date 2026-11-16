import SwiftUI
import WispCore

struct TimersView: View {
    @ObservedObject var timers: TimerService
    @State private var custom = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardGap) {
            Text("Timers")
                .font(Theme.Font.heading)
                .foregroundStyle(Theme.textPrimary)
            newTimer
            list
            if let notice = timers.notice {
                Text(notice)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.busy)
            }
        }
        .padding(.top, Theme.Space.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: New

    private var newTimer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                ForEach(TimerService.presets, id: \.self) { minutes in
                    Button("\(minutes) min") { timers.start(seconds: minutes * 60) }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                }
                Spacer(minLength: Theme.Space.m)
                TextField("mm:ss", text: $custom)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.bodyMedium.monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.m)
                    .frame(width: 84, height: 30)
                    .background(Theme.surfaceHi, in: Capsule())
                    .onSubmit(startCustom)
                    .onChange(of: custom) { _, _ in invalid = false }
                Button("Iniciar", action: startCustom)
                    .buttonStyle(CapsuleButtonStyle(kind: .accent))
                    .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if invalid {
                Text("Use mm:ss ou minutos, até 99:59.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.error)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func startCustom() {
        guard let seconds = TimerFormat.parse(custom) else {
            invalid = true
            return
        }
        timers.start(seconds: seconds)
        custom = ""
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        let items = timers.list.timers
        if items.isEmpty {
            Text("Nenhum timer rodando")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        } else {
            TimelineView(.periodic(from: .now, by: items.contains(where: \.isRunning) ? 1 : 3600)) { context in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(items) { timer in
                            TimerRow(timer: timer, now: context.date, timers: timers)
                        }
                    }
                    .padding(Theme.Space.s)
                }
                .scrollIndicators(.automatic)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .card()
        }
    }
}

private struct TimerRow: View {
    let timer: CountdownTimer
    let now: Date
    let timers: TimerService

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            TimerRing(
                fractionLeft: timer.fractionLeft(at: now),
                size: 30,
                lineWidth: 3,
                color: timer.isRunning ? Theme.accent : Theme.textSecondary
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(TimerFormat.clock(timer.remaining(at: now)))
                    .font(Theme.Font.title.monospacedDigit())
                    .foregroundStyle(timer.isRunning ? Theme.textPrimary : Theme.textSecondary)
                Text(timer.isRunning ? timer.label : "\(timer.label) · pausado")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: Theme.Space.s)
            Button {
                timer.isRunning ? timers.pause(timer.id) : timers.resume(timer.id)
            } label: {
                Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
            }
            .buttonStyle(CircleButtonStyle(size: 28))
            .help(timer.isRunning ? "Pausar" : "Continuar")
            Button {
                timers.cancel(timer.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(CircleButtonStyle(size: 28))
            .help("Cancelar")
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 48)
    }
}
