import SwiftUI
import WispCore

/// The "detalhes" disclosure: each command the step ran with its exit code and output, then the live tail.
struct StepDetailsView: View {
    let row: SetupModel.StepRow
    @Binding var open: Bool

    private var details: [SetupDetail] { row.report?.details ?? [] }
    private var hasContent: Bool { !details.isEmpty || !row.liveLog.isEmpty || !row.command.isEmpty }

    var body: some View {
        if hasContent {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Button {
                    open.toggle()
                } label: {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 10)
                        Text("detalhes")
                            .font(Theme.Font.caption)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)

                if open {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        if !row.command.isEmpty {
                            Text("$ \(row.command)")
                                .foregroundStyle(Theme.textPrimary)
                        }
                        ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("$ \(detail.command)")
                                    .foregroundStyle(Theme.textPrimary)
                                Text("saída \(detail.exit)")
                                    .foregroundStyle(detail.exit == 0 ? Theme.textTertiary : Theme.error)
                                if !detail.output.isEmpty {
                                    Text(detail.output)
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(10)
                                }
                            }
                        }
                        if !row.liveLog.isEmpty {
                            Text(row.liveLog)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(8)
                        }
                    }
                    .font(Theme.Font.tool)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous))
                }
            }
        }
    }
}
