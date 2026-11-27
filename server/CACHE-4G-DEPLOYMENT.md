# 4 GiB gateway deployment archive (2026-11-28 CST)

Incremental archive on top of main; not a byte-for-byte snapshot of the older production gateway. Do not overwrite production blindly. No credentials, live cache data or trade gateway configuration included.

## Verified on production
- K-line memory soft limit 64, disk limit 3000, live series 8, history length 1200.
- Main history periods: 900, 300, 1800, 3600, 7200, 60, 86400 seconds. Favorite warm periods: 900, 1800, 3600, 7200, 86400.
- History prefetch memory floor 1 GiB; two empty results within 6 hours trigger a per-contract/per-period 6-hour cooldown. Explicit exceptions do not increment this counter. Runtime cooldown behavior not yet verified.
- Option directory TTL 1800 seconds; real quote and exact quote validation unchanged except expired filtering for chains.
- Full option metadata prefetch: 25938 rows, 422 underlyings, 411 directory writes, 18.82 s on first successful run. Separate pressure test peak RSS 690.29 MiB. Metadata file 5.6 MiB, directory 1.7 MiB. Metadata snapshot is not read by the gateway; only compatible directory files are consumed.
- Gateway health after deployment: RSS 461472 KiB, 64 ready cache entries, 2.3 GiB available system memory, zero swap usage. No proof of actual client latency improvement.
- Both prefetch timers enabled, shared nonblocking flock configured. Runtime contention behavior not yet verified; skipped invocations can make directory TTL lapse.
- Existing disk cache 678 JSON files, 94 MiB; no additional cleanup scheduled.

## systemd configuration
Production files are archived in systemd-cache-4g/. Before installation compare existing units, preserve local settings, ensure /root/tq_test/cache/options exists with mode 0700 and /usr/bin/flock is present. Existing auth.json is required; never commit it. History timer excerpt uses the observed schedule, not a byte-identical copy of its original file.

Validate Python with py_compile and unit files with systemd-analyze verify. Back up production first. Install only reviewed changes; daemon-reload and enable timers when safe. Do not restart the trade gateway. Gateway code updates require a separately planned gateway restart. No iOS change is required. 

## Rollback
Production backups: market_gateway.py.bak-4g, market_gateway.py.bak-options, prefetch_main_history.py.bak-4g, prefetch_main_history.py.bak-cooldown, and both service .bak files. Select the appropriate baseline; do not blindly restore an older gateway over later fixes. Disable the option timer if necessary. No automatic deletion of cache data.
