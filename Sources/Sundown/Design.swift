import SessionKit
import SwiftUI

/// Every spacing, size, and timing value in the app, in one place, with a
/// reason. Nothing here is arbitrary; if a number can't be defended it
/// shouldn't be a constant.
enum Metric {
    /// Wide enough for a scoped package name at 12pt without truncation,
    /// narrow enough that the panel reads as a utility, not a window.
    static let panelWidth: CGFloat = 340

    /// Roughly ten rows plus their headers. Past that the list scrolls rather
    /// than growing — a menu bar panel that reaches the Dock has lost the plot.
    static let listMaxHeight: CGFloat = 380
    /// One row. The floor exists so a single result still reads as a list
    /// rather than a squeezed strip.
    static let listMinHeight: CGFloat = 44
    /// Empty and scanning states. Fixed, so the panel doesn't resize when it
    /// flips between "checking" and "clean".
    static let placeholderHeight: CGFloat = 96

    static let inset: CGFloat = 10
    static let rowPaddingH: CGFloat = 8
    static let rowPaddingV: CGFloat = 5
    static let rowRadius: CGFloat = 6
    static let sectionSpacing: CGFloat = 14

    /// Header and footer text align with row text, not with the row's
    /// background. Rows are inset by `inset` and padded again inside.
    static let contentInset: CGFloat = inset + rowPaddingH
}

enum Motion {
    /// Critically damped. No overshoot on anything the user didn't throw.
    ///
    /// Nothing in this panel is dragged, flicked or thrown, so nothing in it
    /// has earned a bounce. Overshoot is how motion says "you gave this
    /// momentum"; on a list that just re-sorted itself, it says something
    /// untrue. (A `settle` spring with `extraBounce` lived here and was never
    /// used — the checkmark's `symbolEffect(.bounce)` already marks the one
    /// moment that wanted it.)
    static let standard: Animation = .smooth(duration: 0.28)

    /// Press feedback. Short enough to read as instant, long enough not to
    /// strobe on a fast double-click.
    static let press: Animation = .easeOut(duration: 0.08)

    /// Hover. Slower than press on purpose: hover is ambient, press is an
    /// answer to something the user just did.
    static let hover: Animation = .easeOut(duration: 0.12)
}

// MARK: - Controls

/// A row that answers on mouse-down.
///
/// `.buttonStyle(.plain)` draws no chrome, and on macOS that includes no
/// pressed state — so the rows in this panel, which end processes, gave no
/// sign they had been hit until the next scan came back. Feedback that waits
/// for the action to finish is not feedback; the directness is gone by then.
///
/// The fill sits *above* the row's hover fill rather than replacing it, so
/// press reads as one step darker than hover instead of as a state swap.
struct RowButtonStyle: ButtonStyle {

    /// Rows carry their own padding; headers pass theirs in so the highlight
    /// isn't drawn tight against the text.
    var padding: EdgeInsets = EdgeInsets()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(padding)
            .contentShape(.rect)
            .background {
                RoundedRectangle(cornerRadius: Metric.rowRadius, style: .continuous)
                    .fill(.quaternary.opacity(configuration.isPressed ? 1 : 0))
            }
            // Reduced motion still gets the state change — it just arrives
            // without the fade. Removing the feedback entirely would punish
            // the setting.
            .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
    }
}

// MARK: - Kind presentation

extension Kind {
    // Sections are grouped by provider, not by kind, so the kind only ever
    // appears as this glyph. A `title` existed here until nothing used it.
    var symbol: String {
        switch self {
        case .mcpServer: "cable.connector"
        case .agent: "terminal"
        case .container: "shippingbox"
        case .listener: "point.3.connected.trianglepath.dotted"
        }
    }
}

// MARK: - Formatting

enum Format {

    /// `820 MB`. Memory style, because that's what Activity Monitor shows and
    /// disagreeing with the system tool would be its own small betrayal.
    static func bytes(_ value: UInt64) -> String {
        guard value > 0 else { return "—" }
        return Int64(clamping: value)
            .formatted(.byteCount(style: .memory, allowedUnits: [.mb, .gb]))
    }

    /// `2h 14m`, `42m`, `18s`. Compact, never zero-padded, never "0h".
    static func duration(since start: Date?, now: Date = .now) -> String {
        guard let start else { return "" }
        let seconds = Int(max(0, now.timeIntervalSince(start)))

        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours >= 24 {
            let days = hours / 24
            return "\(days)d \(hours % 24)h"
        }
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    /// `7 items` / `1 item`. Small thing; getting it wrong is loud.
    static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }
}
