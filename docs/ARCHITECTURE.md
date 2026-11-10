# Initial Architecture

## 1. Client

- Language: Swift
- UI: SwiftUI
- Minimum iOS version: to be decided after checking the target devices and required APIs.
- App layers:
  - Presentation: screens, navigation, reusable components.
  - Domain: instruments, quotes, bars, indicators, orders, positions.
  - Data: repositories and transport clients.
  - Infrastructure: WebSocket client, persistence, logging, configuration.

## 2. Suggested feature modules

- AppShell: launch, navigation, theme, settings.
- Market: futures watchlist, quote snapshots, contract search.
- Chart: candlesticks, volume, crosshair, zoom, indicators.
- Account: account summary and risk metrics.
- Trading: simulated orders, order status, positions, fills.
- Settings: connection status and user preferences.

## 3. Backend boundary

The iOS app should communicate with a separately deployed gateway over authenticated HTTPS and WebSocket connections.

The gateway is responsible for:
- Connecting to the selected market-data or brokerage interface.
- Normalizing exchange and broker-specific messages.
- Managing sessions and credentials securely.
- Enforcing account-level authorization and order validation.
- Providing audit logs and reconnect handling.

Do not place CTP/broker credentials or private certificates in the iOS bundle. Do not expose a broker's native trading interface directly to an untrusted mobile client.

## 4. Data contracts

Define transport-independent domain models before selecting a live data provider:

- Instrument
- Quote
- Candle
- DepthSnapshot
- AccountSnapshot
- Position
- Order
- TradeFill

Use explicit timestamps, exchange identifiers, contract multipliers, tick sizes, price precision, and trading status. Do not assume all futures contracts share the same trading sessions or units.

## 5. Charting

The chart module should be independently replaceable. Evaluate an existing SwiftUI candlestick library before adopting it. Verify license compatibility, iOS deployment target, performance, interaction behavior, and maintenance status.

Initial chart requirements:
- Candlesticks and volume.
- Timeframe selection.
- Pan and zoom.
- Crosshair with OHLC details.
- EMA overlays, initially EMA20 and EMA50.
- Indicator calculations separated from rendering.

## 6. Safety and release gates

- First milestone: UI prototype using mock data.
- Second milestone: read-only live market data.
- Third milestone: simulated order lifecycle.
- Live trading must remain disabled until protocol behavior, authorization, risk checks, failure recovery, and user confirmation flows have been reviewed.
