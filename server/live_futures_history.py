"""Read-only TqSdk minute collector with bounded live subscriptions.
SQLite stores completed bars only. Restart periodically to rediscover main contracts.
"""
import argparse
import json
import math
import os
import sqlite3
import time
from pathlib import Path
from tqsdk import TqApi, TqAuth
from archive_futures_history import SQL, SYMBOL
from collect_futures_history import ROOT, DB, memory_ok

def rows_for(code, serial, observed, full):
    result = []
    source = serial if full else serial.tail(10)
    for r in source.itertuples(index=False):
        try:
            ts = int(r.datetime) // 1000000000
            values = [float(getattr(r,k)) for k in ("open","high","low","close","volume")]
            if ts <= 0 or ts > observed or not all(math.isfinite(v) for v in values):
                continue
            oi = []
            for k in ("open_oi","close_oi"):
                v = getattr(r,k,None)
                oi.append(int(v) if v is not None and math.isfinite(float(v)) and v>=0 else None)
            result.append((code,60,ts,*values,*oi,observed))
        except (ValueError, TypeError, OverflowError):
            continue
    tail = max((r[2] for r in result), default=0)
    return [r for r in result if r[2]<tail]

def run(limit, duration):
    os.umask(0o077)
    if not DB.is_file() or not memory_ok():
        raise RuntimeError("database missing or insufficient memory")
    auth=json.loads((ROOT/"auth.json").read_text())
    conn=sqlite3.connect(DB,timeout=15)
    api=None
    try:
        api=TqApi(auth=TqAuth(auth["username"],auth["password"]))
        codes=sorted(set(c for c in api.query_cont_quotes() if isinstance(c,str) and SYMBOL.fullmatch(c)))
        if not codes:
            raise RuntimeError("no main contracts")
        series={}
        for code in codes[:limit]:
            if not memory_ok():
                raise RuntimeError("memory guard during subscription")
            before=conn.execute("SELECT max(ts) FROM candles WHERE symbol=? AND period=60",(code,)).fetchone()[0]
            age=max(0,time.time()-before) if before else float("inf")
            length=1200 if age>=1170*60 else max(30,math.ceil(age/60)+15)
            try:
                series[code]=api.get_kline_serial(code,60,data_length=length)
            except Exception as exc:
                print("SUBSCRIBE_FAILED",code,type(exc).__name__,flush=True)
        if not series:
            raise RuntimeError("no subscriptions")
        print("SUBSCRIPTIONS",len(series),"DISCOVERED",len(codes),flush=True)
        initialized=set()
        signatures={}
        start=time.monotonic()
        next_scan=0
        next_report=0
        while not duration or time.monotonic()-start<duration:
            api.wait_update(deadline=time.time()+1)
            now=time.monotonic()
            if now<next_scan:
                continue
            next_scan=now+2
            if not memory_ok():
                raise RuntimeError("memory guard during collection")
            observed=time.time()
            batch=[]
            for code,serial in series.items():
                if not api.is_serial_ready(serial):
                    continue
                full=code not in initialized
                rows=rows_for(code,serial,observed,full)
                if not rows:
                    continue
                sig=tuple(r[:-1] for r in rows[-3:])
                if full or signatures.get(code)!=sig:
                    batch.extend(rows)
                    signatures[code]=sig
                    initialized.add(code)
            if batch:
                with conn:
                    conn.executemany(SQL,batch)
            if now>=next_report:
                print("READY",len(initialized),"OF",len(series),"ROWS_WRITTEN",len(batch),flush=True)
                next_report=now+30
        print("PILOT_DONE",len(initialized),"OF",len(series),flush=True)
    finally:
        try:
            if api is not None:
                api.close()
        finally:
            conn.close()

if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("--limit",type=int,choices=range(1,91),default=12)
    p.add_argument("--duration",type=int,default=90)
    a=p.parse_args()
    run(a.limit,a.duration)
