#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 本次：只读。把 184 仓库里的 docx 转成 md，并把内嵌图片导出到同名 .assets/ 目录。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

{
    echo "### server: $SERVER"
    echo "### host:   $(hostname)"
    echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "### repo:   $ROOT"
    echo
    set -x

    # ---- 命令开始 ----
    echo "== 0. 找 docx =="
    DOCS=$(find "$ROOT" -path "$ROOT/.git" -prune -o \
        -type f -iname '*.docx' -print 2>/dev/null)
    printf '%s\n' "$DOCS"
    LEGACY=$(find "$ROOT" -path "$ROOT/.git" -prune -o \
        -type f -iname '*.doc' -print 2>/dev/null)

    echo "== 1. 转换（含图片） =="
    command -v pandoc || echo "pandoc: 不可用，用 python 解析"
    command -v python3 || echo "python3: 不可用"

    i=0
    printf '%s\n' "$DOCS" | while IFS= read -r f; do
        [ -n "$f" ] || continue
        i=$((i + 1))
        base=$(basename "$f" .docx)
        md="$DIR/tmp/$TS.$i.$base.md"
        assets="$DIR/tmp/$TS.$i.$base.assets"
        echo "--- $f"
        echo "    -> $md"
        echo "    -> $assets/"

        if command -v pandoc >/dev/null 2>&1; then
            pandoc -f docx -t gfm --wrap=none --extract-media="$assets" "$f" -o "$md" \
                && echo "pandoc ok"
        else
            python3 - "$f" "$md" "$assets" <<'PY'
import sys, zipfile, re, os
from xml.etree import ElementTree as ET

src, mdpath, assets_dir = sys.argv[1], sys.argv[2], sys.argv[3]

W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
A = 'http://schemas.openxmlformats.org/drawingml/2006/main'
V = 'urn:schemas-microsoft-com:vml'

def q(ns, t): return '{%s}%s' % (ns, t)

def text_of(el):
    parts = []
    for node in el.iter():
        if node.tag == q(W, 't'):
            parts.append(node.text or '')
        elif node.tag == q(W, 'tab'):
            parts.append(' ')
        elif node.tag in (q(W, 'br'), q(W, 'cr')):
            parts.append('\n')
    return ''.join(parts)

def style_of(p):
    ps = p.find(q(W, 'pPr'))
    if ps is None:
        return ''
    st = ps.find(q(W, 'pStyle'))
    return '' if st is None else (st.get(q(W, 'val')) or '')

z = zipfile.ZipFile(src)
rels = {}
if 'word/_rels/document.xml.rels' in z.namelist():
    rt = ET.fromstring(z.read('word/_rels/document.xml.rels'))
    for rel in rt:
        rels[rel.get('Id')] = (rel.get('Target'), rel.get('TargetMode'))

os.makedirs(assets_dir, exist_ok=True)
img_cache = {}
extracted = []

def resolve(rid):
    if rid in img_cache:
        return img_cache[rid]
    target, mode = rels.get(rid, (None, None))
    if not target or mode == 'External':
        return None
    path = os.path.normpath(os.path.join('word', target)).replace(os.sep, '/')
    if path not in z.namelist():
        return None
    name = os.path.basename(path)
    with open(os.path.join(assets_dir, name), 'wb') as fh:
        fh.write(z.read(path))
    extracted.append(name)
    ref = os.path.basename(assets_dir) + '/' + name
    img_cache[rid] = ref
    return ref

root = ET.fromstring(z.read('word/document.xml'))
body = root.find(q(W, 'body'))
out = []

def image_refs(el):
    refs = []
    for blip in el.iter(q(A, 'blip')):
        rid = blip.get(q(R, 'embed')) or blip.get(q(R, 'link'))
        ref = resolve(rid) if rid else None
        refs.append('![](%s)' % ref if ref else '[图片]')
    if not refs:
        for im in el.iter(q(V, 'imagedata')):
            rid = im.get(q(R, 'id'))
            ref = resolve(rid) if rid else None
            refs.append('![](%s)' % ref if ref else '[图片]')
    return refs

def emit_para(p):
    txt = text_of(p).strip('\n')
    st = style_of(p)
    refs = image_refs(p)
    m = re.match(r'Heading\s*([1-6])', st, re.I)
    if m:
        out.append('#' * int(m.group(1)) + ' ' + txt.replace('\n', ' '))
        out.append('')
    elif txt.strip():
        if 'List' in st or 'list' in st:
            out.append('- ' + txt.replace('\n', ' '))
        else:
            out.append(txt)
            out.append('')
    if refs:
        out.extend(refs)
        out.append('')

def emit_table(tbl):
    rows = []
    for tr in tbl.findall(q(W, 'tr')):
        cells = []
        for tc in tr.findall(q(W, 'tc')):
            refs = image_refs(tc)
            cells.append(' '.join(text_of(tc).split()) or (' '.join(refs) if refs else ''))
        rows.append(cells)
    if not rows:
        return
    width = max(len(r) for r in rows)
    rows = [r + [''] * (width - len(r)) for r in rows]
    out.append('| ' + ' | '.join(rows[0]) + ' |')
    out.append('|' + '---|' * width)
    for r in rows[1:]:
        out.append('| ' + ' | '.join(r) + ' |')
    out.append('')

for el in list(body):
    if el.tag == q(W, 'p'):
        emit_para(el)
    elif el.tag == q(W, 'tbl'):
        emit_table(el)

text = re.sub(r'\n{3,}', '\n\n', '\n'.join(out)).strip() + '\n'
with open(mdpath, 'w', encoding='utf-8') as fh:
    fh.write(text)
print('python ok, chars=%d images=%d' % (len(text), len(extracted)))
for name in extracted:
    size = os.path.getsize(os.path.join(assets_dir, name))
    print('  %s  %d bytes' % (name, size))
PY
        fi

        echo "--- 预览（前 40 行）"
        sed -n '1,40p' "$md"
        echo "--- 图片文件"
        ls -l "$assets" 2>/dev/null || echo "（没有导出图片）"
    done

    if [ -n "$LEGACY" ]; then
        echo "注意：存在旧版 .doc（非 zip 格式），python 转换不支持。"
    fi
    if [ -z "$DOCS$LEGACY" ]; then
        echo "仓库里没找到 doc/docx 文件。"
    fi

    echo "== 2. 下一步 =="
    echo "把 184/tmp/ 下新生成的 .md 和 .assets/ 一起 add/commit/push，图片才会一起过来。"
    echo "如果图片是 .emf/.wmf 矢量格式，浏览器里可能不显示，需要先转 PNG。"
    # ---- 命令结束 ----

    set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
