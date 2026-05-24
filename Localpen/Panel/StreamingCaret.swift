import SwiftUI

struct StreamingCaret: View {
    @State private var opacity: Double = 1.0

    var body: some View {
        Rectangle()
            .fill(Tokens.accent)
            .frame(width: 7, height: 16)
            .opacity(opacity)
            .padding(.leading, 2)
            .onAppear {
                withAnimation(Motion.caretBlink.repeatForever()) {
                    opacity = 0.35
                }
            }
    }
}
