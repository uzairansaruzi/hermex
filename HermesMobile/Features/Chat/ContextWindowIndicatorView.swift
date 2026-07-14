import SwiftUI

struct ContextWindowIndicatorPresentation: Equatable {
    let percentage: Double?

    init(snapshot: ContextWindowSnapshot?) {
        percentage = snapshot?.percentage
    }

    var percentageLabel: String {
        guard let percentage else { return "–" }
        return "\(Int(percentage * 100))"
    }

    var isInteractive: Bool {
        percentage != nil
    }
}

struct ContextWindowIndicatorView: View {
    let snapshot: ContextWindowSnapshot?

    @Environment(\.colorScheme) private var colorScheme
    @State private var showPopover = false
    private let ringSize: CGFloat = 30
    private let tapTargetSize: CGFloat = 44

    var body: some View {
        Button(action: showContextDetails) {
            ZStack {
                Circle()
                    .stroke(trackColor, lineWidth: 3)
                    .frame(width: ringSize, height: ringSize)

                if let percentage = presentation.percentage {
                    Circle()
                        .trim(from: 0, to: CGFloat(min(percentage, 1.0)))
                        .stroke(
                            progressColor,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: ringSize, height: ringSize)
                        .rotationEffect(.degrees(-90))
                }

                Text(presentation.percentageLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(presentation.isInteractive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .frame(width: ringSize, height: ringSize)
            .adaptiveGlass(
                .regular,
                isInteractive: presentation.isInteractive,
                fallbackMaterial: .ultraThinMaterial,
                in: Circle()
            )
            .frame(width: tapTargetSize, height: tapTargetSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!presentation.isInteractive)
        .accessibilityLabel(presentation.isInteractive ? "Context usage" : "Context usage loading")
        .accessibilityValue(presentation.isInteractive ? "\(presentation.percentageLabel) percent" : "")
        .popover(isPresented: $showPopover) {
            if let snapshot {
                ContextWindowPopover(snapshot: snapshot)
                    .presentationCompactAdaptation(.none)
                    .presentationBackground(.clear)
            }
        }
    }

    private var presentation: ContextWindowIndicatorPresentation {
        ContextWindowIndicatorPresentation(snapshot: snapshot)
    }

    private func showContextDetails() {
        guard presentation.isInteractive else { return }
        showPopover = true
    }

    private var trackColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.12)
    }

    private var progressColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.82)
    }
}

private struct ContextWindowPopover: View {
    let snapshot: ContextWindowSnapshot
    private let popoverCornerRadius: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ContextWindowFormatter.tokensLabel(from: snapshot))
                .font(.subheadline)
                .fontWeight(.semibold)

            Divider()

            ContextWindowInfoRow(
                label: String(localized: "Input"),
                value: ContextWindowFormatter.inputTokensLabel(from: snapshot)
            )
            ContextWindowInfoRow(
                label: String(localized: "Output"),
                value: ContextWindowFormatter.outputTokensLabel(from: snapshot)
            )
            ContextWindowInfoRow(
                label: String(localized: "Threshold"),
                value: ContextWindowFormatter.thresholdLabel(from: snapshot)
            )
            ContextWindowInfoRow(
                label: String(localized: "Cost"),
                value: ContextWindowFormatter.costLabel(from: snapshot)
            )
        }
        .padding()
        .frame(width: 220)
        .adaptiveGlass(
            .regular,
            fallbackMaterial: .regularMaterial,
            in: RoundedRectangle(cornerRadius: popoverCornerRadius, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: popoverCornerRadius, style: .continuous))
    }
}

private struct ContextWindowInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}
