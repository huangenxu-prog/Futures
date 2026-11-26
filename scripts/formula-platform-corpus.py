"""Independent bar-by-bar reference calculations for formula compatibility CI."""
import json
import operator
import statistics
import subprocess
import sys

bars = range(80)
c = [97+i%7-(3*i)%11 for i in bars]
o = [c[i]+i%3-1 for i in bars]
h = [max(o[i], c[i])+2 for i in bars]
l = [min(o[i], c[i])-2 for i in bars]
v = [11+i%9 for i in bars]
fixtures = []


def window(values, period, op, partial=False):
    return [op(values[max(0,i-period+1):i+1]) if partial or i+1 >= period else None for i in bars]


def ema(values, length, smooth=False, wenhua=False):
    series = []
    for i, value in enumerate(values):
        n = min(i+1, length) if wenhua else length
        weight = 1/n if smooth else 2/(1+n)
        series.append(value if i == 0 else value*weight + series[-1]*(1-weight))
    return series


def add(platform, label, source, *expected, params=""):
    fixtures.append(dict(label=label, source=source, platform=platform,
                         parameters=params, expected=expected))


# Product manual MACD editor, separately stored parameters.
dif = [a-b for a,b in zip(ema(c,12),ema(c,26))]
dea = ema(dif,9)
add("hexin","MACD","DIF:EMA(CLOSE,SHORT)-EMA(CLOSE,LONG),COLORFF8D1F;DEA:EMA(DIF,M),COLOR0CAEE6;MACD:(DIF-DEA)*2,COLORSTICK;",
    dif,dea,[2*(a-b) for a,b in zip(dif,dea)],params="SHORT=12 LONG=26 M=9")
# Public long/short colored candle example; opens/closes, wick endpoints and signal mask.
add("hexin","多空主图","DIF:=EMA(C,12)-EMA(C,26);DEA:=EMA(DIF,9);多头:=DIF>DEA;空头:=DIF<DEA;STICKLINE(多头,L,H,0,0),COLORGREEN;STICKLINE(多头,O,C,8,0),COLORGREEN;STICKLINE(空头,L,H,0,0),COLORRED;STICKLINE(空头,O,C,8,0),COLORRED;",
    *[[value[i] if cond(dif[i],dea[i]) else None for i in bars]
      for cond in (operator.gt,operator.lt) for value in (h,c)])

# Wenhua worked examples (WT8 guide chapters 6, 7.2, 7.4, 7.6).
wh = "wenhua"
mid = window(c,26,statistics.mean)
dev = window(c,26,statistics.stdev)
add(wh,"布林通道叠加均线","MID:MA(CLOSE,26);TMP2:=STD(CLOSE,26);TOP:MID+2*TMP2;BOTTOM:MID-2*TMP2;MA1:MA(CLOSE,5),LINETHICK1;MA2:MA(CLOSE,20),LINETHICK1;",mid,
    *[[a+sign*2*b if a is not None else None for a,b in zip(mid,dev)] for sign in (1,-1)],
    window(c,5,statistics.mean),window(c,20,statistics.mean))
hh = window(h,9,max,True)
ll = window(l,9,min,True)
rsv = [100*(x-b)/(a-b) for x,a,b in zip(c,hh,ll)]
k = ema(rsv,3,True,True)
d = ema(k,3,True,True)
add(wh,"KDJ","RSV:=(CLOSE-LLV(LOW,N))/(HHV(HIGH,N)-LLV(LOW,N))*100;K:SMA(RSV,M1,1);D:SMA(K,M2,1);J:3*K-2*D;",k,d,[3*a-2*b for a,b in zip(k,d)],params="N=9 M1=3 M2=3")
add(wh,"EMA","EMA10:EMA(C,10);",ema(c,10,wenhua=True))
add(wh,"成交量总和","SUM(VOL,25);",window(v,25,sum,True))
add(wh,"历史成交量","A:SUM(VOL,0);",[sum(v[:i+1]) for i in bars])
add(wh,"窗口新低文字","DRAWTEXT(L<=LLV(L,10),LOW,'新低');",[l[i] if l[i] == min(l[max(0,i-9):i+1]) else None for i in bars])
add(wh,"阴线实体","STICKLINE(OPEN-CLOSE>0,OPEN,CLOSE,COLORCYAN,0);",[x if x<y else None for x,y in zip(c,o)])
up = [int(x>y) for x,y in zip(c,o)]
add(wh,"连续阳线","BARSLASTCOUNT(CLOSE>OPEN);", [i-max([j for j in range(i+1) if not up[j]],default=-1) for i in bars])
add(wh,"首根阳线","BARSSINCE(CLOSE>OPEN);",[i-up.index(1) if any(up[:i+1]) else None for i in bars])
add(wh,"一直阳线","EVERY(CLOSE>OPEN,5);",[int(i>=4 and all(up[i-4:i+1])) for i in bars])
add(wh,"阳线计数","M:COUNT(ISUP,N);",window(up,8,sum,True),params="N=8")
add(wh,"条件显示","X:IFELSE(ISUP,H,L);",[h[i] if up[i] else l[i] for i in bars])

# TDX documented formula examples and conventional indicator definitions.
tdx = "tongdaxin"
add(tdx,"MA","MA(C,10);",window(c,10,statistics.mean))
add(tdx,"历史累计量","SUM(VOL,0);",[sum(v[:i+1]) for i in bars])
add(tdx,"IFN","X:IFN(CLOSE>OPEN,HIGH,LOW);",[l[i] if up[i] else h[i] for i in bars])
add(tdx,"标准差与方差","A:STD(C,5);B:STDP(C,5);D:VAR(C,5);E:VARP(C,5);",
    *[window(c,5,method) for method in (statistics.stdev,statistics.pstdev,statistics.variance,statistics.pvariance)])
add(tdx,"EXPMA","A:EXPMA(C,12);",ema(c,12))
add(tdx,"BIAS","BIAS:(C-MA(C,6))/MA(C,6)*100;",
    [(c[i]/statistics.mean(c[i-5:i+1])-1)*100 if i>=5 else None for i in bars])
add(tdx,"BBI","BBI:(MA(C,3)+MA(C,6)+MA(C,12)+MA(C,24))/4;",
    [statistics.mean(statistics.mean(c[i-n+1:i+1]) for n in (3,6,12,24)) if i>=23 else None for i in bars])
add(tdx,"MTM","MTM:CLOSE-REF(CLOSE,12);",[c[i]-c[i-12] if i>=12 else None for i in bars])
add(tdx,"ROC","ROC:(CLOSE/REF(CLOSE,12)-1)*100;",[(c[i]/c[i-12]-1)*100 if i>=12 else None for i in bars])
add(tdx,"WR","WR:100*(HHV(H,10)-C)/(HHV(H,10)-LLV(L,10));",
    [100*(max(h[i-9:i+1])-c[i])/(max(h[i-9:i+1])-min(l[i-9:i+1])) if i>=9 else None for i in bars])
add(tdx,"数学边界","A:INTPART(-3.5);B:CEILING(-3.5);D:FLOOR(-3.5);E:POW(SQRT(C),2);F:LOG(100);",
    [-3]*80,[-3]*80,[-4]*80,c,[2]*80)
subprocess.run([sys.argv[1],"--platform-corpus"],input=json.dumps(fixtures).encode(),check=True)
