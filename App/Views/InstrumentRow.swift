import SwiftUI

struct InstrumentRow: View {
    @Environment(\.mainContracts) private var contracts
    let instrument: FuturesInstrument

    private var movementColor: Color {
        instrument.isRising ? .red : .green
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(instrument.name + (contracts[instrument.id]?.month ?? ""))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(instrument.id) · \(instrument.exchange)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(instrument.lastPrice.formatted())
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(instrument.change >= 0 ? "+" : "")\(instrument.change.formatted())  \(instrument.changePercent, format: .number.precision(.fractionLength(2)))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(movementColor)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
