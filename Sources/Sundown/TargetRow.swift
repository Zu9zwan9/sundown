import SessionKit
import SwiftUI

struct TargetRow: View {

    let target: Target
    let isSelected: Bool
    /// Where this row sits in a run happening right now.
    let endState: SessionModel.EndState
    /// Why the policy did or didn't check this. Shown on hover, above the
    /// technical evidence — the user's question is "why is this here", not
    /// "what regex matched".
    let reason: String
    let now: Date
    let toggle: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Sustained CPU worth surfacing. Matches `SessionPolicy`'s runaway
    /// threshold — the row and the policy must never disagree about what
    /// counts as busy.
    private var isBusy: Bool { target.cpuPercent >= 50 }

    var body: some View {
        // The whole row is one control. The checkbox is a picture of the
        // state, not a second tap target — two hit regions doing the same
        // thing is how you get a double-toggle on the edge of the box.
        Button(action: toggle) {
            HStack(spacing: 8) {
                leading

                Image(systemName: target.kind.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(target.title)
                        .font(.system(size: 12, weight: .medium))
                        // Selection is legible from the title alone, so a long
                        // list reads at a glance without a second badge column.
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    subtitle
                        .font(.system(size: 10))
                        .lineLimit(1)
                        // Tail, not middle. Middle truncation was eating the
                        // centre of "pid 3739 · 2 children · 8h 15m" and
                        // leaving "pid 3739 ·…children", which is worse than
                        // simply stopping.
                        .truncationMode(.tail)
                }

                Spacer(minLength: 6)

                Text(Format.bytes(target.residentBytes))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        // A row already in the reaper's hands is not a control any more.
        .disabled(endState != .untouched)
        // Queued rows step back so the one in flight is the only thing with
        // full presence. Ended rows stay legible — they are the receipt.
        .opacity(endState == .queued ? 0.5 : 1)
        .animation(reduceMotion ? nil : Motion.standard, value: endState)
        .buttonStyle(
            RowButtonStyle(
                padding: EdgeInsets(
                    top: Metric.rowPaddingV, leading: Metric.rowPaddingH,
                    bottom: Metric.rowPaddingV, trailing: Metric.rowPaddingH
                )
            )
        )
        .background {
            RoundedRectangle(cornerRadius: Metric.rowRadius, style: .continuous)
                .fill(.quaternary.opacity(isHovering ? 1 : 0))
        }
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : Motion.hover) {
                isHovering = hovering
            }
        }
        // Why this row is here, then how we know. A tool that ends processes
        // owes its reasoning.
        .help("\(reason)\n\(target.evidence)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(target.title)
        .accessibilityValue(accessibilityState)
        .accessibilityHint(reason)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var accessibilityState: String {
        switch endState {
        case .untouched: isSelected ? "Selected" : "Not selected"
        case .queued: "Waiting to be ended"
        case .inFlight: "Ending now"
        case .ended: "Ended"
        }
    }

    /// The state of the row, in the one place the eye already checks.
    ///
    /// The checkbox slot carries the run as well as the selection, rather than
    /// a second column appearing beside it. A control that becomes a status
    /// indicator in place reads as the same object changing; a status
    /// indicator that slides in beside it reads as the row growing a new part
    /// mid-operation.
    @ViewBuilder
    private var leading: some View {
        ZStack {
            switch endState {
            case .untouched, .queued:
                Toggle("", isOn: .constant(isSelected))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .allowsHitTesting(false)

            case .inFlight:
                ProgressView()
                    .controlSize(.mini)

            case .ended:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        // Fixed, so swapping a checkbox for a spinner for a checkmark never
        // shifts the title one pixel sideways. 16 to match the icon column
        // beside it and to leave the focus ring somewhere to be drawn.
        .frame(width: 16, height: 16)
    }

    /// `node · pid 4821 · 2h 14m · 98% CPU · orphaned`
    private var subtitle: Text {
        var line = Text(target.subtitle)

        let uptime = Format.duration(since: target.startedAt, now: now)
        if !uptime.isEmpty {
            line = line + Text(" · ") + Text(uptime).monospacedDigit()
        }

        var text = line.foregroundStyle(.tertiary)

        // Both of these earn one step more contrast than the rest of the line,
        // because both are the reason someone would act on this row.
        if isBusy {
            text =
                text
                + Text(" · ")
                + Text("\(Int(target.cpuPercent))% CPU").monospacedDigit()
                .foregroundStyle(.secondary)
        }
        if target.isSuperseded {
            text = text + Text(" · superseded").foregroundStyle(.secondary)
        } else if target.isOrphaned {
            text = text + Text(" · orphaned").foregroundStyle(.secondary)
        }
        return text
    }
}
