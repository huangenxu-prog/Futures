"""Archive completed futures candles from existing atomic gateway snapshots.

No SDK session, no option data, no changes to the live gateway.
Run under a dedicated timer; SQLite keeps historical rows beyond JSON eviction.
"""
import argparse
import json
import math
import os
from pathlib import Path
import re
import sqlite3

ROOT = Path("/root/tq_test")
PERIODS = {60, 300, 900, 1800, 3600, 7200, 86400}
SYMBOL = re.compile(r"(CFFEX|SHFE|DCE|CZCE|INE|GFEX)\.[A-Za-z]+[0-9]{3,4}\Z")
FIELDS = ("open", "high", "low", "close", "volume")
SQL = """INSERT INTO candles VALUES (?,?,?,?,?,?,?,?,?,?,?)
ON CONFLICT(symbol,period,ts) DO UPDATE SET
o=excluded.o,h=excluded.h,l=excluded.l,c=excluded.c,v=excluded.v,
open_oi=excluded.open_oi,close_oi=excluded.close_oi,saved_at=excluded.saved_at
WHERE excluded.saved_at >= candles.saved_at"""

def archive(cache, db):
    os.umask(0o077)
    db.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(db, timeout=15) as conn:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("""CREATE TABLE IF NOT EXISTS candles(
            symbol TEXT NOT NULL, period INTEGER NOT NULL, ts INTEGER NOT NULL,
            o REAL NOT NULL,h REAL NOT NULL,l REAL NOT NULL,c REAL NOT NULL,
            v REAL NOT NULL,open_oi INTEGER,close_oi INTEGER,saved_at REAL NOT NULL,
            PRIMARY KEY(symbol,period,ts)) WITHOUT ROWID""")
        files = rows = skipped = 0
        for path in sorted(cache.glob("*.json")):
            try:
                data = json.loads(path.read_text())
                symbol, period = data["symbol"], data["period"]
                if not SYMBOL.fullmatch(symbol) or period not in PERIODS:
                    continue
                saved = float(data["saved_at"])
                if not math.isfinite(saved) or saved <= 0:
                    raise ValueError("invalid snapshot time")
                bars = sorted(data["bars"], key=lambda b: b["time"])
                # Conservatively omit the final candle: it may still be open.
                tail = bars[-1]["time"] if bars else 0
                batch = []
                for bar in bars:
                    ts = bar["time"]
                    if not isinstance(ts,int) or ts <= 0 or ts >= tail:
                        continue
                    values = [bar[k] for k in FIELDS]
                    if not all(isinstance(v,(int,float)) and math.isfinite(v) for v in values):
                        continue
                    oi = [bar.get(k) for k in ("openInterest","closeInterest")]
                    oi = [int(v) if isinstance(v,(int,float)) and math.isfinite(v) and v>=0 else None for v in oi]
                    batch.append((symbol,period,ts,*values,*oi,saved))
                conn.executemany(SQL,batch)
                files += 1
                rows += len(batch)
            except (OSError,ValueError,TypeError,KeyError,AttributeError):
                skipped += 1
        conn.commit()
        count, symbols = conn.execute("SELECT count(*),count(DISTINCT symbol) FROM candles").fetchone()
        print("FILES",files,"ROWS_PROCESSED",rows,"TOTAL_ROWS",count,"FUTURES",symbols,"SKIPPED",skipped,flush=True)
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--cache",type=Path,default=ROOT/"cache/klines")
    p.add_argument("--db",type=Path,default=ROOT/"data/futures_history.db")
    a=p.parse_args()
    archive(a.cache,a.db)
