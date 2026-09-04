import AppKit
import SessionKit
import SwiftUI

struct PanelView: View {

    let model: SessionModel

    @State private var now = Date()
    /// Measured height of the list. A ScrollView reports a flexible ideal
    /// height, so inside a size-to-fit VStack it starves down to a sliver —
    /// which is exactly what it did. We measure the content and give the
    /// scroll view a real height instead of only a ceiling.
    @State private var contentHeight: CGFloat = 0
    /// Keyboard focus. A list you can only reach with a mouse is a list half
    /// the people who use macOS cannot reach at all — and this one is how you
    /// choose what gets terminated.
    @FocusState private var focusedRow: Target.ID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Honoured for the footer bar. `.bar` is a translucent material, and
    /// Reduce Transparency is a legibility setting, not a taste one — the
    /// footer sits over scrolling text and is exactly the surface it exists
    /// for.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.openSettings) private var openSettings

    private var animation: Animation? { reduceMotion ? nil : Motion.standard }

    /// Animate on identity, not on the whole array. `residentBytes` drifts on
    /// every scan, so animating on `targets` re-ran the transition every few
    /// seconds for rows that hadn't meaningfully changed.
    private var identity: [Target.ID] { model.eligible.map(\.id) }

    private var listHeight: CGFloat {
        min(max(contentHeight, Metric.listMinHeight), Metric.listMaxHeight)
    }

    private var isScrollable: Bool { contentHeight > Metric.listMaxHeight }

    /// The list in the order it is drawn, which is the only order arrow keys
    /// are allowed to follow — moving down a grouped list must not jump
    /// between providers in dictionary order.
    private var orderedIDs: [Target.ID] { model.groups.flatMap { $0.targets.map(\.id) } }

    private func moveFocus(_ direction: MoveCommandDirection) {
        let ids = orderedIDs
        guard !ids.isEmpty else { return }
        guard let current = focusedRow, let index = ids.firstIndex(of: current) else {
            // Entering the list from nowhere lands at the end the user is
            // travelling towards, not always at the top.
            focusedRow = direction == .up ? ids.last : ids.first
            return
        }
        switch direction {
        case .up: focusedRow = ids[max(0, index - 1)]
        case .down: focusedRow = ids[min(ids.count - 1, index + 1)]
        default: break
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        .frame(width: Metric.panelWidth)
        .animation(animation, value: identity)
        .animation(animation, value: model.phase)
        .animation(animation, value: model.lifecycle)
        // The panel is sized by its content, so every row that appears or
        // leaves changes the window's height. Without this the window snaps to
        // the new size a frame before the rows finish moving into it, which
        // reads as the window flinching.
        .animation(animation, value: listHeight)
        // Scan only while the panel is on screen. A utility whose whole job is
        // reclaiming background resources has no business running a timer when
        // nobody is looking at it.
        .task {
            await model.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                await model.refresh()
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                now = Date()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Sundown")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.1)
                Text(model.headline)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            Spacer()

            Menu {
                // The three lifecycle moments live here rather than on a
                // segmented control. Teardown is the daily case and stays the
                // default; preflight and triage are deliberate choices.
                Picker(
                    "When",
                    selection: Binding(
                        get: { model.lifecycle },
                        set: { model.setLifecycle($0) }
                    )
                ) {
                    ForEach(SessionPolicy.Phase.allCases, id: \.self) { phase in
                        Text(phase.title).tag(phase)
                    }
                }
                .pickerStyle(.inline)

                Divider()
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                Button("Select All") { model.selectAll() }
                    .keyboardShortcut("a")
                    .disabled(model.eligible.isEmpty)
                Button("Deselect All") { model.selectNone() }
                    .disabled(model.selection.isEmpty)
                Divider()
                Button("Settings…") {
                    openSettings()
                    focusSettingsWindow()
                }
                .keyboardShortcut(",")
                Button("Quit Sundown") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .accessibilityLabel("More options")
        }
        .padding(.horizontal, Metric.contentInset)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.eligible.isEmpty {
            placeholder
        } else {
            ScrollViewReader { scroller in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Metric.sectionSpacing) {
                    ForEach(model.groups, id: \.provider) { group in
                        section(group.provider, group.targets)
                    }
                }
                .padding(.horizontal, Metric.inset)
                .padding(.bottom, 10)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ContentHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: listHeight)
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            .onMoveCommand(perform: moveFocus)
            // Focus that walks off the visible area is focus the user has
            // lost. Follow it.
            .onChange(of: focusedRow) { _, id in
                guard let id else { return }
                withAnimation(animation) { scroller.scrollTo(id, anchor: .center) }
            }
            // Only fade the edge when there is genuinely more below. Fading a
            // list that already fits just dims its last row for no reason.
            .mask {
                if isScrollable {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.9),
                            .init(color: .black.opacity(0), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                } else {
                    Rectangle()
                }
            }
            }
        }
    }

    private func section(_ provider: Provider, _ targets: [Target]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // The header acts on its whole group. "End everything Cursor left"
            // without a per-provider menu, and without teaching anyone a
            // modifier-click.
            Button {
                model.toggleProvider(provider)
            } label: {
                HStack(spacing: 4) {
                    Text(provider.name)
                    // Only when the whole group is taken. An empty circle on
                    // every header was decoration that read as a control.
                    if model.isFullySelected(provider) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 8))
                            .opacity(0.6)
                    }
                    Spacer()
                    Text("\(targets.count)").monospacedDigit()
                }
            }
            .buttonStyle(
                RowButtonStyle(
                    padding: EdgeInsets(
                        top: 1, leading: Metric.rowPaddingH,
                        bottom: 1, trailing: Metric.rowPaddingH
                    )
                )
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .help("Select or deselect everything from \(provider.name)")
            .padding(.bottom, 2)

            ForEach(targets) { target in
                TargetRow(
                    target: target,
                    isSelected: model.selection.contains(target.id),
                    endState: model.endState(target.id),
                    reason: model.reason(for: target),
                    now: now,
                    toggle: { model.toggle(target.id) }
                )
                .id(target.id)
                .focusable(!model.isBusy)
                .focused($focusedRow, equals: target.id)
                // Space toggles what the arrow keys landed on. Return is not
                // bound here: ⌘Return already commits the whole run, and a
                // bare Return on a row is one keystroke away from ending
                // things the user was only looking at.
                .onKeyPress(.space) {
                    model.toggle(target.id)
                    return .handled
                }
            }
        }
    }

    /// Three distinct nothing-to-show states. They must never contradict each
    /// other — a spinner in the header over a checkmark in the body reads as a
    /// bug, because it is one.
    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 8) {
            switch model.phase {
            case .scanning:
                ProgressView()
                    .controlSize(.small)
                Text("Checking what's still running")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

            default:
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.bounce, value: model.phase)
                Text(finishedSummary ?? model.headline)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Metric.placeholderHeight)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if !model.eligible.isEmpty || !failures.isEmpty {
            VStack(spacing: 8) {
                // Confirm the run whenever anything is left on screen.
                //
                // This was only ever shown in the empty-state placeholder,
                // which meant ending 3 of 7 rows produced no confirmation at
                // all: the list simply had four rows in it a moment later. A
                // destructive action that completes silently is the one place
                // a utility cannot afford to be quiet.
                if !model.eligible.isEmpty, let done = finishedSummary {
                    Label(done, systemImage: "checkmark.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }

                if let failures = failureSummary {
                    Label(failures, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !model.eligible.isEmpty {
                    Text(intent)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: { Task { await model.endSession() } }) {
                        HStack(spacing: 6) {
                            if model.isBusy {
                                ProgressView().controlSize(.small)
                            }
                            Text(model.isBusy ? "Ending…" : model.lifecycle.verb)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.selection.isEmpty || model.isBusy)
                }
            }
            .padding(.horizontal, Metric.contentInset)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(
                reduceTransparency
                    ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                    : AnyShapeStyle(.bar)
            )
        }
    }

    // MARK: - Copy

    /// States exactly what the button will do. No euphemism, no surprise.
    private var intent: String {
        // While a run is under way this line follows the work rather than
        // describing a selection that is already being spent.
        if let name = model.endingNow { return "Ending \(name)…" }

        let count = model.selection.count
        guard count > 0 else {
            // A disabled button with "Nothing selected" above it leaves the
            // user with no idea why, or what to do. Name the reason — and do
            // it whenever any row is in use, not only when every row is.
            let inUse = model.eligible.filter(\.hasLiveOwner).count
            return inUse > 0
                ? "\(inUse) in use by running sessions — tick any to override"
                : "Nothing selected"
        }

        let reclaim = model.reclaimableBytes
        let items = Format.items(count)
        return reclaim > 0
            ? "Ends \(items) · frees \(Format.bytes(reclaim))"
            : "Ends \(items)"
    }

    private var finishedSummary: String? {
        guard case .finished(let ended, let reclaimed, _) = model.phase, ended > 0 else {
            return nil
        }
        return reclaimed > 0
            ? "Ended \(Format.items(ended)) · \(Format.bytes(reclaimed)) reclaimed"
            : "Ended \(Format.items(ended))"
    }

    private var failures: [Outcome] {
        guard case .finished(_, _, let failures) = model.phase else { return [] }
        return failures
    }

    private var failureSummary: String? {
        guard let first = failures.first else { return nil }
        let reason: String =
            switch first.result {
            case .refused(let why): why
            case .failed(let why): why
            default: "Unknown"
            }
        return failures.count == 1
            ? "\(first.title): \(reason.lowercased())"
            : "\(failures.count) items could not be ended"
    }
}

/// Reports the intrinsic height of the list so the scroll view can be given a
/// real frame instead of a ceiling it never reaches.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
