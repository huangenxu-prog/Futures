#!/usr/bin/env bash
set -euo pipefail
APP="$1"
OUT="$2"
mkdir -p "$OUT"
test -d "$APP"
UDID="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; phones=[x for xs in d.values() for x in xs if x["isAvailable"] and x["name"].startswith("iPhone")]; print(next((x["udid"] for x in phones if x["name"]=="iPhone 16"),phones[0]["udid"]))')"
BUNDLE=com.huangenxu.futures
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState unplugged --batteryLevel 100 || true
xcrun simctl install "$UDID" "$APP"
for mode in hollow native; do
    xcrun simctl terminate "$UDID" "$BUNDLE" || true
    DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)"
    rm -f "$DATA/Documents/chart-replay.json"
    xcrun simctl io "$UDID" recordVideo --codec=h264 "$OUT/$mode.mp4" >"$OUT/$mode-record.log" 2>&1 &
    RECORD=$!
    sleep 1
    args=(-qihui-chart-replay)
    if [[ "$mode" == native ]]; then args+=(-qihui-native-candles); fi
    xcrun simctl launch "$UDID" "$BUNDLE" "${args[@]}"
    for i in $(seq 1 25); do
        [[ -s "$DATA/Documents/chart-replay.json" ]] && break
        sleep 1
    done
    xcrun simctl io "$UDID" screenshot "$OUT/$mode.png"
    kill -INT "$RECORD" || true
    wait "$RECORD" || true
    cp "$DATA/Documents/chart-replay.json" "$OUT/$mode.json"
    test -s "$OUT/$mode.mp4"
done
python3 - "$OUT" <<'PY'
import json, pathlib, statistics, sys
out=pathlib.Path(sys.argv[1])
summary={}
for mode in ("hollow","native"):
    rows=json.loads((out/f"{mode}.json").read_text())
    assert len(rows)==25, (mode, len(rows))
    assert [r["volume"] for r in rows]==list(range(500,525)), (mode, rows)
    assert len(set(r["close"] for r in rows[1:]))==2, mode
    times=[r["model_ms"] for r in rows[1:]]
    summary[mode]={"applied_ticks":len(times),"median_model_ms":statistics.median(times),"max_model_ms":max(times)}
(out/"summary.json").write_text(json.dumps(summary, indent=2))
print(json.dumps(summary,indent=2))
PY

# Validate the actual formula overlays and lower pane in the same offline replay.
xcrun simctl terminate "$UDID" "$BUNDLE" || true
rm -f "$DATA/Documents/chart-replay.json"
xcrun simctl launch "$UDID" "$BUNDLE" -qihui-chart-replay -qihui-formula-replay
for i in $(seq 1 30); do
    [[ -s "$DATA/Documents/chart-replay.json" ]] && break
    sleep 1
done
test -s "$DATA/Documents/chart-replay.json"
xcrun simctl io "$UDID" screenshot "$OUT/formula-platforms.png"
swift scripts/check-formula-screenshot.swift "$OUT/formula-platforms.png"
