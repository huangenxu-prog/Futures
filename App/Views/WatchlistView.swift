import SwiftUI

struct WatchlistView: View {
    var body: some View {
        NavigationStack {
            List(FuturesInstrument.catalog) { instrument in
                NavigationLink {
                    InstrumentDetailView(instrument: instrument)
                } label: {
                    InstrumentRow(instrument: instrument)
                }
            }
            .navigationTitle("自选")
        }
    }
}
