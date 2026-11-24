import Foundation

@main
struct OpenCandleQuoteSelfTest {
    static func main() {
        precondition(OpenCandleQuotePolicy.accepts(quoteTime: 1000, barTime: 1000, period: 300))
        precondition(OpenCandleQuotePolicy.accepts(quoteTime: 1299.9, barTime: 1000, period: 300))
        precondition(!OpenCandleQuotePolicy.accepts(quoteTime: 999, barTime: 1000, period: 300))
        precondition(!OpenCandleQuotePolicy.accepts(quoteTime: 1300, barTime: 1000, period: 300))
        precondition(!OpenCandleQuotePolicy.accepts(quoteTime: .nan, barTime: 1000, period: 300))
        print("Open candle real quote boundary checks: OK")
    }
}
