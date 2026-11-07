#!/usr/bin/env python3
"""把含 CJK 与插值的 Swift 字符串字面量改写为 String(format: L("…%@…"), String(expr)…)。
仅处理插值表达式为「简单标识符 / 点链 / 下标 / 无嵌套调用」的情形，其余打印 MANUAL。"""
import re, sys, glob, os

SKIP_FILES = {"MCPToolCatalog.swift", "DebugSelfCheck.swift", "DebugSnapshot.swift", "SheetProbe.swift",
              "Localizable.xcstrings"}
CJK = re.compile(r'[\u4e00-\u9fff]')
IDENT = re.compile(r'^[A-Za-z_][A-Za-z0-9_.\[\]]*$')  # a.b、arr[0]、x.count（不含空格/运算符/问号）

def find_literals(line):
    """返回行内字符串字面量的 (start, end) 列表，处理转义与插值中的嵌套字符串。"""
    out, i, n = [], 0, len(line)
    while i < n:
        if line[i] == '"':
            j, start = i + 1, i
            while j < n:
                c = line[j]
                if c == '\\':
                    j += 2
                    continue
                if c == '"':
                    out.append((start, j + 1))
                    i = j + 1
                    break
                j += 1
            else:
                break
        else:
            i += 1
    return out

def split_interp(content):
    """把字面量内容拆成 [(is_expr, text), …]；插值表达式用括号深度扫描。"""
    parts, buf, i, n = [], [], 0, len(content)
    while i < n:
        if content.startswith('\\(', i):
            if buf: parts.append((False, ''.join(buf))); buf = []
            depth, j = 1, i + 2
            while j < n and depth:
                c = content[j]
                if c == '\\':
                    j += 2; continue
                if c == '(':
                    depth += 1
                elif c == ')':
                    depth -= 1
                    if depth == 0: break
                j += 1
            parts.append((True, content[i + 2:j]))
            i = j + 1
        else:
            buf.append(content[i]); i += 1
    if buf: parts.append((False, ''.join(buf)))
    return parts

def unescape(s):
    return s.replace('\\"', '"').replace('\\\\', '\\').replace('\\n', '\n').replace('\\t', '\t').replace('\\r', '\r')

def transform_literal(lit):
    """返回 (new_code, ok)。"""
    content = lit[1:-1]
    if not CJK.search(content) or '\\(' not in content:
        return None, True
    parts = split_interp(content)
    key, args, simple = [], [], True
    for is_expr, text in parts:
        if is_expr:
            expr = text.strip()
            if not IDENT.match(expr) or ' ' in expr or '?' in expr:
                simple = False
                break
            key.append('%@')
            args.append(f'String({expr})')
        else:
            key.append(text)
    if not simple or not args:
        return None, False
    keystr = ''.join(key).replace('"', '\\"')
    call = f'String(format: L("{keystr}")'
    if len(args) == 1:
        call += f', {args[0]})'
    else:
        call += ', ' + ', '.join(args) + ')'
    return call, True

def process(path):
    lines = open(path).readlines()
    changed, manual = [], []
    for ln, line in enumerate(lines):
        stripped = line.lstrip()
        if stripped.startswith('//') or stripped.startswith('*') or stripped.startswith('/*'):
            continue
        if '"' not in line or not CJK.search(line) or '\\(' not in line:
            continue
        new_line, offset, touched, bad = line, 0, False, False
        for s, e in find_literals(line):
            rep, ok = transform_literal(line[s:e])
            if rep is None and ok:
                continue
            if not ok:
                bad = True
                continue
            new_line = new_line[:s + offset] + rep + new_line[e + offset:]
            offset += len(rep) - (e - s)
            touched = True
        if touched:
            lines[ln] = new_line
            changed.append((ln + 1, new_line.rstrip()))
        if bad:
            manual.append((ln + 1, line.rstrip()))
    if changed:
        open(path, 'w').writelines(lines)
    return changed, manual

all_manual = []
for f in sorted(glob.glob('**/*.swift', recursive=True)):
    if os.path.basename(f) in SKIP_FILES or 'build/' in f:
        continue
    changed, manual = process(f)
    for ln, nl in changed:
        print(f"FIX {f}:{ln}: {nl.strip()[:120]}")
    for ln, ol in manual:
        all_manual.append((f, ln, ol))

print(f"\n=== MANUAL ({len(all_manual)}) ===")
for f, ln, ol in all_manual:
    print(f"{f}:{ln}: {ol.strip()[:150]}")
