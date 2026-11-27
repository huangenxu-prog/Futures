"""Run with a compiled FormulaPublicSampleTest; optional second argument is an offline HTML directory."""
import hashlib
import html
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.request import urlopen

samples = []
for chapter in (2, 4, 6):
    filename = f"view7_{chapter}.html"
    if len(sys.argv) > 2:
        raw = (Path(sys.argv[2])/filename).read_bytes()
    else:
        with urlopen("https://www.wenhua.com.cn/guide/wh8/"+filename, timeout=30) as response:
            raw = response.read()
    print(filename, hashlib.sha256(raw).hexdigest())
    page = raw.decode("gb18030")
    # Preserve the example's statements together. Remove HTML markup, comments
    # and prose after the last semicolon. Do not translate unsupported functions.
    for cell in re.findall(r"<td\b[^>]*>(.*?)</td>", page, re.I | re.S):
        clean = html.unescape(re.sub(r"<[^>]+>", "\n", cell))
        blocks = re.split(r"(?:举例|例如|例)\s*\d*\s*[：:]", clean)[1:]
        for block in blocks:
            statements = []
            for line in block.splitlines():
                line = line.partition("//")[0].strip()
                if ";" in line and re.match(r"[a-zA-Z_(]",line):
                    statements.append(line[:line.rfind(";")+1])
            if statements:
                source = "\n".join(statements)
                digest = hashlib.sha256(source.encode()).hexdigest()[:16]
                if all(sample["id"] != digest for sample in samples):
                    samples.append(dict(id=digest,source=source))
results = json.loads(subprocess.run([sys.argv[1]],input=json.dumps(samples).encode(),
                                    stdout=subprocess.PIPE,check=True).stdout)
accepted = sum("error" not in result for result in results)
print(f"{len(samples)} unique worked example blocks: {accepted} evaluated; {len(samples)-accepted} rejected")
for result in results:
    print(result["id"],result.get("error","PASS"))
