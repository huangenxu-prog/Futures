# Vendored TradingChart 0.1.3

Upstream: https://github.com/pavellunev/trading_chart (tag 0.1.3; commit 141ad493c6fb2c5951d4d14b2ff736ad9da531c7).

MIT license: see LICENSE and App/Resources/ThirdPartyNotices.txt.

Local modifications: chart theme supports hollow rising bodies, solid falling bodies and a custom doji colour. MainChartPane draws these bodies using the chart's current visible range and autoscaled Y-domain. The rest of the original indicator, paging, zoom, crosshair and drawing machinery is retained.

Tests were omitted from the local Swift package manifest to avoid bundling the upstream test suite in the iOS application; upstream runtime Sources and string catalog are retained.
