"""Bounded pilot: append completed 1-minute bars for current futures main contracts.
No quote subscriptions for options; no changes to gateway or trade services.
Run manually under the shared prefetch lock before scheduling.
"""
import argparse
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import time

from tqsdk import TqApi, TqAuth
from archive_futures_history import SQL, SYMBOL

ROOT = Path("/root/tq_test")
DB = ROOT / "data/futures_history.db"
PERIOD = 60

def memory_ok():
    try:
        return next(int(s.split()[1]) for s in Path("/proc/meminfo").read_text().splitlines()
                    if s.startswith("MemAvailable:")) >= 1572864
    except (OSError, ValueError, StopIteration):
        return False

def collect(limit):
    if not memory_ok():
        print("SKIP: available memory below 1.5 GiB", flush=True)
        return
    os.umask(0o077)
    auth = json.loads((ROOT / "auth.json").read_text())
    if not DB.is_file():
        raise RuntimeError("Run archive_futures_history.py first")
    with sqlite3.connect(DB, timeout=15) as conn:
        conn.execute("""CREATE TABLE IF NOT EXISTS collector_attempts (
            symbol TEXT PRIMARY KEY, attempted REAL NOT NULL, result TEXT NOT NULL)""")
        conn.commit()
        previous = dict(conn.execute("SELECT symbol,attempted FROM collector_attempts"))
        api = TqApi(auth=TqAuth(auth["username"], auth["password"]))
        try:
            codes = sorted(set(c for c in api.query_cont_quotes()
                               if isinstance(c, str) and SYMBOL.fullmatch(c)))
            if not codes:
                raise RuntimeError("No valid main contracts")
            jobs = sorted(codes, key=lambda c: (previous.get(c, 0), c))[:limit]
            print("MAIN_CONTRACTS", len(codes), "PILOT_JOBS", len(jobs), flush=True)
            for code in jobs:
                if not memory_ok():
                    print("STOP: memory guard", flush=True)
                    break
                before = conn.execute("SELECT max(ts) FROM candles WHERE symbol=? AND period=?", (code, PERIOD)).fetchone()[0]
                result = "no_data"
                rows = []
                try:
                    serial = api.get_kline_serial(code, PERIOD, data_length=1200)
                    deadline = time.monotonic() + 12
                    while not api.is_serial_ready(serial) and time.monotonic() < deadline:
                        api.wait_update(deadline=min(time.time()+1, time.time()+max(0,deadline-time.monotonic())))
                    if api.is_serial_ready(serial):
                        observed = time.time()
                        valid = []
                        for r in serial.itertuples(index=False):
                            ts = int(r.datetime) // 1000000000
                            values = [float(getattr(r,k)) for k in ("open","high","low","close","volume")]
                            if ts <= 0 or not all(math.isfinite(v) for v in values):
                                continue
                            oi = []
                            for k in ("open_oi","close_oi"):
                                v = getattr(r,k,None)
                                oi.append(int(v) if v is not None and math.isfinite(float(v)) and v >= 0 else None)
                            valid.append((code,PERIOD,ts,*values,*oi,observed))
                        tail = max((r[2] for r in valid), default=0)
                        rows = [r for r in valid if r[2] < tail]
                    if rows:
                        result = "ok"
                except Exception as exc:
                    result = type(exc).__name__
                with conn:
                    if rows:
                        conn.executemany(SQL, rows)
                    conn.execute("INSERT INTO collector_attempts VALUES (?,?,?) ON CONFLICT(symbol) DO UPDATE SET attempted=excluded.attempted,result=excluded.result", (code,time.time(),result))
                after = conn.execute("SELECT max(ts) FROM candles WHERE symbol=? AND period=?", (code,PERIOD)).fetchone()[0]
                print(code,result,"ROWS",len(rows),"BEFORE",before,"AFTER",after,flush=True)
        finally:
            api.close()

if __name__ == "__main__":
    p=argparse.ArgumentParser()
    p.add_argument("--limit",type=int,default=6,choices=range(1,7))
    collect(p.parse_args().limit)
