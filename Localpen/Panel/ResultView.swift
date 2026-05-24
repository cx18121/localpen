import SwiftUI

// ResultView per DESIGN.md §3.4. Implementation lands in M2.
struct ResultView: View {
    @Binding var text: String
    let isStreaming: Bool
    var body: some View { EmptyView() }
}
