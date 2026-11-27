import os,json,time,hashlib,tempfile,subprocess
from pathlib import Path
from collections import defaultdict
from tqsdk import TqApi,TqAuth
from market_gateway import option_underlying_code
ROOT=Path("/root/tq_test")
CACHE=ROOT/"cache/options"
def allowed():
    mem=next(int(x.split()[1]) for x in Path("/proc/meminfo").read_text().splitlines() if x.startswith("MemAvailable:"))
    busy=subprocess.run(["systemctl","is-active","--quiet","qihui-main-history-prefetch.service"]).returncode==0
    return mem>=1572864 and not busy
def save(path,data):
    with tempfile.NamedTemporaryFile(mode="w",dir=path.parent,delete=False) as f:
        tmp=Path(f.name)
        try:
            json.dump(data,f,allow_nan=False,separators=(",",":"))
            f.flush()
            os.replace(tmp,path)
        finally:
            tmp.unlink(missing_ok=True)
def run():
    if not allowed():
        print("SKIP: memory or history prefetch",flush=True)
        return
    os.umask(0o077)
    CACHE.mkdir(parents=True,exist_ok=True)
    started=time.time()
    auth=json.loads((ROOT/"auth.json").read_text())
    api=TqApi(auth=TqAuth(auth["username"],auth["password"]))
    rows=[]
    fields=["instrument_id","underlying_symbol","strike_price","option_class","expire_datetime","last_exercise_datetime","price_tick","volume_multiple"]
    try:
        codes=list(api.query_quotes(ins_class="OPTION",exchange_id=["SHFE","DCE","CZCE","INE","GFEX","CFFEX"],expired=False))
        print("TOTAL_OPTIONS",len(codes),flush=True)
        for i in range(0,len(codes),500):
            if not allowed():
                print("ABORT: resource guard",flush=True)
                return
            df=api.query_symbol_info(codes[i:i+500])
            rows.extend(json.loads(df[fields].to_json(orient="records",double_precision=15)))
            if i%5000==0:
                print("PROGRESS",len(rows),"/",len(codes),flush=True)
        if not codes or len(rows)!=len(codes) or set(r["instrument_id"] for r in rows)!=set(codes):
            raise RuntimeError("Incomplete option metadata")
    finally:
        api.close()
    groups=defaultdict(list)
    for r in rows:
        groups[r["underlying_symbol"]].append(r["instrument_id"])
    now=time.time()
    save(ROOT/"cache/option-metadata.json",dict(saved=now,rows=rows))
    written=0
    for u,cs in groups.items():
        if not isinstance(u,str) or not all(option_underlying_code(c)==u for c in cs):
            continue
        path=CACHE/(hashlib.sha256(u.encode()).hexdigest()+".json")
        try:
            if json.loads(path.read_text())["saved"]>started:
                continue
        except (OSError,ValueError,KeyError,TypeError):
            pass
        save(path,dict(underlying=u,saved=now,codes=sorted(cs)))
        written+=1
    print("OPTIONS",len(rows),"UNDERLYINGS",len(groups),"CACHE_WRITTEN",written,"SECONDS",round(time.time()-started,2),flush=True)
if __name__=="__main__":
    run()
