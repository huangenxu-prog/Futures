#!/usr/bin/env python3
"""Read-only, bounded TqSdk memory probe; no orders or service changes."""
import os, sys, time, json, gc, ctypes, math, re, threading, weakref
def fields(path):
    out={}
    with open(path) as f:
        for line in f:
            k,_,v=line.partition(":")
            try: out[k]=int(v.split()[0])
            except (ValueError,IndexError): pass
    return out
def mem(): return fields("/proc/meminfo")
def status(): return fields("/proc/self/status")
def emit(stage, **extra):
    s=status(); m=mem()
    print(json.dumps(dict(stage=stage,rss_mib=round(s["VmRSS"]/1024,1),
        anon_mib=round(s.get("RssAnon",0)/1024,1),hwm_mib=round(s["VmHWM"]/1024,1),
        available_mib=round(m["MemAvailable"]/1024,1),threads=s["Threads"],
        fds=len(os.listdir("/proc/self/fd")),cpu_s=round(time.process_time(),2),**extra)),flush=True)
m=mem()
if m["MemAvailable"]<650*1024:
    print("ABORT: need at least 650 MiB available before starting",flush=True);sys.exit(3)
swap0=m.get("SwapTotal",0)-m.get("SwapFree",0)
try:
    with open("/proc/self/oom_score_adj","w") as f:f.write("1000")
except OSError:
    print("ABORT: cannot set OOM preference",flush=True);sys.exit(3)
os.nice(10)
def guard():
    while True:
        m=mem();s=status()
        if m["MemAvailable"]<350*1024 or s["VmRSS"]>300*1024 or m.get("SwapTotal",0)-m.get("SwapFree",0)-swap0>32*1024:
            emit("ABORT_MEMORY");os._exit(2)
        time.sleep(.25)
threading.Thread(target=guard,daemon=True).start()
emit("S0_python")
from tqsdk import TqApi,TqAuth
import tqsdk
emit("S0_import",version=getattr(tqsdk,"__version__","unknown"))
with open(os.environ.get("TQ_AUTH_FILE","/root/tq_test/auth.json")) as f: auth=json.load(f)
base="SHFE.rb SHFE.ag SHFE.au SHFE.cu CZCE.SR CZCE.RM CZCE.MA CZCE.CF CZCE.TA CZCE.SA DCE.m DCE.p DCE.jm DCE.c DCE.y GFEX.lc INE.sc".split()
ex=["SHFE","DCE","CZCE","CFFEX","INE","GFEX"]
api=None
quotes={}
def product(code):
    m=re.fullmatch(r"([A-Z]+\.[A-Za-z]+)[0-9]{3,4}",code or "")
    return m.group(1) if m else None
def wait(pred,seconds):
    end=time.time()+seconds
    while not pred() and time.time()<end:api.wait_update(deadline=min(end,time.time()+.5))
def subscribe(ids):
    for start in range(0,len(ids),12):
        chunk=ids[start:start+12]
        refs=api.get_quote_list(["KQ.m@"+p for p in chunk])
        wait(lambda:all(product(q.underlying_symbol)==p for p,q in zip(chunk,refs)),8)
        pairs=[(p,q.underlying_symbol) for p,q in zip(chunk,refs) if product(q.underlying_symbol)==p]
        if pairs:
            quotes.update(zip([p for p,c in pairs],api.get_quote_list([c for p,c in pairs])))
def priced(p):
    q=quotes.get(p)
    return q is not None and bool(q.datetime) and math.isfinite(q.last_price)
def coverage(ids):
    return dict(expected=len(ids),resolved=sum(p in quotes for p in ids),priced=sum(priced(p) for p in ids),missing=[p for p in ids if not priced(p)])
try:
    t=time.monotonic()
    api=TqApi(auth=TqAuth(auth["username"],auth["password"]),disable_print=True)
    ref=weakref.ref(api)
    emit("S1_init",seconds=round(time.monotonic()-t,2))
    subscribe(base);wait(lambda:all(priced(p) for p in base),15)
    emit("S2_17",**coverage(base))
    catalog=sorted({p for c in api.query_quotes(ins_class="FUTURE",exchange_id=ex,expired=False) if (p:=product(c)) and p.split(".")[0] in ex})
    if not catalog:raise RuntimeError("empty catalog")
    emit("S3_catalog",products=len(catalog))
    subscribe([p for p in catalog if p not in quotes]);wait(lambda:all(priced(p) for p in catalog),20)
    emit("S3_all",**coverage(catalog))
    end=time.time()+120
    while time.time()<end:
        interval=min(end,time.time()+30); start=time.monotonic();cpu=time.process_time();changes=0
        while time.time()<interval:
            if api.wait_update(deadline=min(interval,time.time()+.5)):
                changes+=sum(api.is_changing(q,"datetime") for q in quotes.values())
        emit("S4_steady",cpu_pct=round(100*(time.process_time()-cpu)/max(.001,time.monotonic()-start),1),quote_timestamp_changes=changes,**coverage(catalog))
    api.close();emit("S5_close")
    api=None;quotes.clear();emit("S6_del",api_alive=ref() is not None)
    gc.collect();emit("S7_gc",api_alive=ref() is not None)
    ctypes.CDLL("libc.so.6").malloc_trim(0);emit("S8_trim")
except Exception as exc:
    print("FAILED:",type(exc).__name__,flush=True);sys.exit(1)
finally:
    if api is not None:
        try:api.close()
        except Exception:pass
