# Qihuiapp

A native iOS futures trading application.

## Project status

This repository has been initialized. The application implementation has not started yet.

## Product direction

- Native iOS application built with Swift and SwiftUI.
- Market quotes and futures contract watchlists.
- Candlestick charts and technical indicators.
- Account, positions, orders, and risk information.
- Trading connectivity isolated behind a server-side gateway; brokerage credentials must not be embedded in the app.

## Development principles

1. Separate market data, charting, account, and order-entry modules.
2. Keep the UI responsive and suitable for iPhone screens.
3. Make market-data and trading adapters replaceable.
4. Start with read-only UI and simulated trading; real-money order entry requires a separate review and explicit approval.
5. Never commit API keys, broker credentials, certificates, or personal account data.

## Planned milestones

1. Product structure and native UI foundation.
2. Watchlists, quote detail, and charting.
3. Technical indicators and chart interactions.
4. Market-data gateway integration.
5. Simulated trading, positions, and order management.
6. Security review and optional live-trading integration.

See [Architecture](docs/ARCHITECTURE.md) for the initial technical plan.
