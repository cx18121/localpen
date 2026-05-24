import SwiftUI

struct PanelFooter: View {
    var body: some View {
        HStack(spacing: 14) {
            Text("↑↓ select")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textMute)
            Text("↩ apply")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textMute)
            Text("esc dismiss")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textMute)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.panelBG2)
    }
}
