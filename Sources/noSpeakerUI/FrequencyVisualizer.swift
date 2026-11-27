import SwiftUI

struct FrequencyVisualizer: View {
    let voices: [(frequency: Double, amplitude: Double)]

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(voices.indices, id: \.self) { i in
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.6 + 0.4 * voices[i].amplitude))
                        .frame(width: max(2, geo.size.width / CGFloat(max(1, voices.count)) - 2),
                               height: geo.size.height * CGFloat(voices[i].amplitude))
                }
            }
        }
        .frame(height: 40)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
        .animation(.easeOut(duration: 0.05), value: voices.map { $0.frequency })
    }
}
