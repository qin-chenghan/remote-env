#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 本次：只读。找 184 仓库里的 docx，诊断为什么推不上去，转成 md 写到 184/tmp/。
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
    find "$ROOT" -path "$ROOT/.git" -prune -o \
        -type f \( -iname '*.docx' -o -iname '*.doc' \) -print 2>/dev/null

    DOCS=$(find "$ROOT" -path "$ROOT/.git" -prune -o \
        -type f -iname '*.docx' -print 2>/dev/null)
    LEGACY=$(find "$ROOT" -path "$ROOT/.git" -prune -o \
        -type f -iname '*.doc' -print 2>/dev/null)

    echo "== 1. 文件信息 =="
    { printf '%s\n' "$DOCS"; printf '%s\n' "$LEGACY"; } | while IFS= read -r f; do
        [ -n "$f" ] || continue
        echo "--- $f"
        ls -l "$f"
        file "$f" 2>/dev/null || true
        echo "size_bytes=$(stat -c %s "$f" 2>/dev/null)"
    done

    echo "== 2. Git 状态 / 为什么没推上去 =="
    cd "$ROOT" || exit 1
    git remote -v
    git status -sb
    echo "--- 本地领先 origin 的提交"
    git log --oneline origin/main..HEAD 2>/dev/null
    echo "--- 已被 git 跟踪的 doc/docx"
    git ls-files | grep -iE '\.docx?$' || echo "（没有）"
    echo "--- 每条 docx 的 ignore 判定"
    { printf '%s\n' "$DOCS"; printf '%s\n' "$LEGACY"; } | while IFS= read -r f; do
        [ -n "$f" ] || continue
        rel=${f#"$ROOT"/}
        git check-ignore -v "$f" 2>/dev/null || echo "$rel: 未被 ignore"
    done
    echo "--- hooks / 推送配置"
    ls -l .git/hooks/pre-push .git/hooks/pre-commit .git/hooks/pre-receive 2>/dev/null || echo "（无相关 hook）"
    echo "hooksPath=$(git config --get core.hooksPath || true)"
    echo "push.default=$(git config --get push.default || true)"
    echo "--- 仓库大小 / 大文件"
    git count-objects -vH
    echo "--- 最近一次提交"
    git log -1 --stat --oneline

    echo "== 3. 转 md =="
    command -v pandoc || echo "pandoc: 不可用"
    command -v python3 || echo "python3: 不可用"

    i=0
    printf '%s\n' "$DOCS" | while IFS= read -r f; do
        [ -n "$f" ] || continue
        i=$((i + 1))
        base=$(basename "$f" .docx)
        md="$DIR/tmp/$TS.$i.$base.md"
        echo "--- 转换 $f -> $md"
        if command -v pandoc >/dev/null 2>&1; then
            pandoc -f docx -t gfm --wrap=none "$f" -o "$md" && echo "pandoc ok"
        else
            python3 - "$f" "$md" <<'PY'
import sys, zipfile, re
from xml.etree import ElementTree as ET

src, dst = sys.argv[1], sys.argv[2]
W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
def q(t): return '{%s}%s' % (W, t)

def text_of(el):
    parts = []
    for node in el.iter():
        if node.tag == q('t'):
            parts.append(node.text or '')
        elif node.tag == q('tab'):
            parts.append(' ')
        elif node.tag in (q('br'), q('cr')):
            parts.append('\n')
    return ''.join(parts)

def style_of(p):
    ps = p.find(q('pPr'))
    if ps is None:
        return ''
    st = ps.find(q('pStyle'))
    return '' if st is None else (st.get(q('val')) or '')

try:
    z = zipfile.ZipFile(src)
    xml = z.read('word/document.xml')
except Exception as e:
    print('ERROR: %s' % e, file=sys.stderr)
    sys.exit(2)

root = ET.fromstring(xml)
body = root.find(q('body'))
out = []

def emit_para(p):
    txt = text_of(p).strip('\n')
    st = style_of(p)
    m = re.match(r'Heading\s*([1-6])', st, re.I)
    if m:
        out.append('#' * int(m.group(1)) + ' ' + txt.replace('\n', ' '))
        out.append('')
        return
    if p.find('.//' + q('drawing')) is not None and not txt.strip():
        out.append('[图片]')
        out.append('')
        return
    if not txt.strip():
        if out and out[-1] != '':
            out.append('')
        return
    if 'List' in st or 'list' in st:
        out.append('- ' + txt.replace('\n', ' '))
    else:
        out.append(txt)
        out.append('')

def emit_table(tbl):
    rows = []
    for tr in tbl.findall(q('tr')):
        cells = []
        for tc in tr.findall(q('tc')):
            cells.append(' '.join(text_of(tc).split()))
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
    if el.tag == q('p'):
        emit_para(el)
    elif el.tag == q('tbl'):
        emit_table(el)

text = '\n'.join(out)
text = re.sub(r'\n{3,}', '\n\n', text).strip() + '\n'
with open(dst, 'w', encoding='utf-8') as fh:
    fh.write(text)
print('python ok, chars=%d' % len(text))
PY
        fi
        echo "--- 预览（前 60 行）"
        sed -n '1,60p' "$md"
    done

    if [ -n "$LEGACY" ]; then
        echo "注意：存在旧版 .doc（非 zip 格式），上面的 python 转换不支持，需要另想办法。"
    fi
    if [ -z "$DOCS$LEGACY" ]; then
        echo "仓库里没找到 doc/docx 文件。"
    fi

    echo "== 4. 结论提示 =="
    echo "如果第 2 节显示 184/docs/ 命中 .gitignore：文件不是被远端拦截，是根本没进 commit。"
    echo "要上库有两个办法：1) 把 md 放到 184/tmp/（不被忽略）；2) 确需 docx 就 git add -f，但二进制不建议入库。"
    echo "GitHub 单文件硬上限 100 MiB；超过会在 push 时被远端拒绝。"
    # ---- 命令结束 ----

    set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
