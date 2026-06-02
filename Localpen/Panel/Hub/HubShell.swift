import SwiftUI

/// The `.hub` phase chrome (ADR 0016): a mode strip on top, the active mode's body
/// below, a keyboard-hint footer. Only the body changes per mode; the strip + footer
/// are stable chrome. Rendered inside PanelView's existing notch envelope.
struct HubShell: View {
    @Bindable var controller: PanelController

    var body: some View {
        VStack(spacing: 0) {
            HubModeStrip(controller: controller)
            Hairline()
            modeBody
            Hairline()
            footer
        }
    }

    @ViewBuilder private var modeBody: some View {
        switch controller.hub.mode {
        case .today:   TodayModeView(controller: controller)
        case .ask:     AskInput(controller: controller)        // existing view, reused verbatim
        case .kb:      KBModeView(controller: controller)
        case .people:  PeopleModeView(controller: controller)
        case .capture: CaptureModeView(controller: controller)
        case .now:     NowModeView(controller: controller)
        case .suggestions: SuggestionsModeView(controller: controller)
        }
    }

    private var footer: some View {
        HStack(spacing: Spacing.s5) {
            KbdHint("⇥", "switch mode")
            KbdHint("esc", "close")
            Spacer()
        }
        .panelFooterChrome()
    }
}

/// The mode tiles. Active tile = `accentTint` fill + `accent` icon + label; the rest
/// are icon-only in `textSoft` (icon-only keeps them all within the fixed 400pt width;
/// the active label is the "where am I" cue). The single place the hub body shows accent.
private struct HubModeStrip: View {
    @Bindable var controller: PanelController

    var body: some View {
        HStack(spacing: Spacing.s2) {
            ForEach(HubMode.allCases) { tile($0) }
            Spacer(minLength: 0)
            expandToggle
        }
        .padding(.horizontal, Spacing.s5)
        .padding(.vertical, Spacing.s3)
    }

    /// Toggle the focus ("expanded") size — wider hub + taller reading surfaces. Lives in the
    /// strip's empty trailing slot, the one consistent spot across hub modes.
    private var expandToggle: some View {
        Button { controller.togglePanelExpanded() } label: {
            Image(systemName: controller.panelExpanded
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                // Match the mode tiles' icon spec (13pt, weight tracks active state) so
                // the strip's icons read as one row of controls.
                .font(.system(size: 13, weight: controller.panelExpanded ? .medium : .regular))
                .foregroundStyle(controller.panelExpanded ? Tokens.accent : Tokens.textSoft)
                .padding(Spacing.s2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(controller.panelExpanded ? "Collapse" : "Expand")
    }

    @ViewBuilder private func tile(_ mode: HubMode) -> some View {
        let active = controller.hub.mode == mode
        Button { controller.hub.setMode(mode) } label: {
            HStack(spacing: Spacing.s2) {
                Image(systemName: mode.icon)
                    .font(.system(size: 13, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? Tokens.accent : Tokens.textSoft)
                if active {
                    Text(mode.title)
                        .font(Typography.menuRowFocused)
                        .foregroundStyle(Tokens.text)
                }
            }
            .padding(.horizontal, active ? Spacing.s4 : Spacing.s3)
            .padding(.vertical, Spacing.s2)
            .background(
                RoundedRectangle(cornerRadius: Spacing.innerRadius, style: .continuous)
                    .fill(active ? Tokens.accentTint : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode.title)
    }
}
