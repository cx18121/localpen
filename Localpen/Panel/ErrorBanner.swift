import SwiftUI

struct ErrorBanner: View {
    let error: PanelError

    var body: some View {
        HStack(spacing: 12) {
            Text(error.displayMessage)
                .font(.system(size: 13))
                .foregroundStyle(Tokens.accentError)
                .lineLimit(2)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
