#!/usr/bin/env python3
"""从 devkit 源码提取含 CJK 的字符串字面量 → 生成/合并 Localizable.xcstrings。
- 跳过 MCPToolCatalog（AI 专用描述保持中文）与 #if DEBUG 自检文件
- 词法级剥离注释（行注释/块注释），仅取真实字符串字面量
- zh-Hans 值 = key；en 已有翻译保留，缺省置空待填
"""
import json, re, os, glob

SKIP_FILES = {"MCPToolCatalog.swift", "DebugSelfCheck.swift", "DebugSnapshot.swift", "SheetProbe.swift"}
CATALOG = "Localizable.xcstrings"
CJK = re.compile(r'[\u4e00-\u9fff]')

def extract_string_literals(code):
    """词法扫描：跳过注释，返回字符串字面量内容（处理转义与插值原样保留）。"""
    out, i, n = [], 0, len(code)
    NORMAL, LINE_COMMENT, BLOCK_COMMENT, STRING, ML_STRING = range(5)
    state = NORMAL
    while i < n:
        c = code[i]
        if state == NORMAL:
            if code.startswith("//", i):
                state = LINE_COMMENT; i += 2
            elif code.startswith("/*", i):
                state = BLOCK_COMMENT; i += 2
            elif code.startswith('"""', i):
                state = ML_STRING; i += 3
            elif c == '"':
                state = STRING; buf = []; i += 1; continue
            else:
                i += 1
        elif state == LINE_COMMENT:
            if c == "\n": state = NORMAL
            i += 1
        elif state == BLOCK_COMMENT:
            if code.startswith("*/", i): state = NORMAL; i += 2
            else: i += 1
        elif state == ML_STRING:
            if code.startswith('"""', i): state = NORMAL; i += 3
            else: i += 1
        elif state == STRING:
            if c == "\\":
                buf.append(code[i:i+2]); i += 2
            elif c == '"':
                out.append("".join(buf)); state = NORMAL; i += 1
            else:
                buf.append(c); i += 1
    return out

def unescape(s):
    # 提取 key 用：仅处理常见转义（\\(\"ntr）——插值 \(…) 保留原样（转换后源码已无插值形式的 key）
    out, i, n = [], 0, len(s)
    while i < n:
        if s[i] == "\\" and i + 1 < n:
            e = s[i+1]
            if e == '"': out.append('"')
            elif e == "\\": out.append("\\")
            elif e == "n": out.append("\n")
            elif e == "t": out.append("\t")
            elif e == "r": out.append("\r")
            else: out.append(s[i:i+2])
            i += 2
        else:
            out.append(s[i]); i += 1
    return "".join(out)

keys = set()
for f in sorted(glob.glob("**/*.swift", recursive=True)):
    if os.path.basename(f) in SKIP_FILES or "build/" in f:
        continue
    code = open(f).read()
    if f.endswith(("GitBannerMenu.swift",)) and False:
        continue
    for lit in extract_string_literals(code):
        val = unescape(lit)
        if CJK.search(val):
            keys.add(val)

# 读现有 catalog，保留已填 en
try:
    cat = json.load(open(CATALOG))
except Exception:
    cat = {"sourceLanguage": "zh-Hans", "strings": {}, "version": "1.0"}

strings = cat["strings"]
for k in sorted(keys):
    if k not in strings:
        strings[k] = {"localizations": {}}
    loc = strings[k].setdefault("localizations", {})
    loc.setdefault("zh-Hans", {"stringUnit": {"state": "translated", "value": k}})
    if "en" not in loc:
        loc["en"] = {"stringUnit": {"state": "translated", "value": ""}}

# 丢弃源码中已不存在的 key（保持 catalog 干净）
for k in list(strings.keys()):
    if k not in keys:
        del strings[k]

json.dump(cat, open(CATALOG, "w"), ensure_ascii=False, indent=2, sort_keys=True)
empty = sum(1 for k in keys if strings[k]["localizations"]["en"]["stringUnit"]["value"] == "")
print(f"total keys: {len(keys)}, en 待翻译: {empty}")
