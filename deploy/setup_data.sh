#!/usr/bin/env bash
# =============================================================================
# 数据获取：TC39x/TC3xx 手册 PDF + iLLD 源码 + iLLD API(CHM→MD)
# 用法:  ./setup_data.sh   （在工程根目录执行，需已运行 install.sh）
# 网络说明: Infineon 直连需浏览器 UA；GitHub 资源自动在多镜像间 fallback
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

PY=./.venv/bin/python
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36"
mkdir -p data/documents

dl() { # dl <输出> <url> — 带镜像 fallback
  local out="$1" url="$2" rc=1
  curl -sSL --max-time 600 -A "$UA" -H "Referer: https://documentation.infineon.com/" -o "$out" "$url" && rc=0
  if [ $rc -ne 0 ] || [ ! -s "$out" ]; then
    for p in https://ghproxy.net/ https://gh-proxy.com/ https://ghfast.top/; do
      curl -sSL --max-time 600 -o "$out" "$p$url" && [ -s "$out" ] && rc=0 && break
    done
  fi
  [ $rc -eq 0 ] && echo "  OK  $out ($(du -h "$out" | cut -f1))" || { echo "  FAIL $out"; return 1; }
}

# ---------------------------------------------------------------------------
# 1. Infineon 官方手册（公开直链，共 ~83MB / 7006 页）
# ---------------------------------------------------------------------------
echo "==> [1/4] 下载 AURIX 手册 PDF"
dl data/documents/tc39x-usermanual.pdf "https://www.infineon.com/assets/row/public/documents/10/44/infineon-aurix-tc39x-usermanual-en.pdf"
dl data/documents/tc3xx-part1.pdf       "https://www.infineon.com/assets/row/public/documents/10/44/infineon-aurix-tc3xx-part1-usermanual-en.pdf"
dl data/documents/tc3xx-part2.pdf       "https://www.infineon.com/assets/row/public/documents/10/44/infineon-aurix-tc3xx-part2-usermanual-en.pdf"
dl data/documents/tricore-arch-vol1.pdf "https://www.infineon.com/row/public/documents/10/44/infineon-aurix-architecture-vol1-usermanual-en.pdf"
# TC39x BD-step 勘误表（Errata Sheet v2.7 / 308 页）— 硅片已知偏差 + Workaround
dl data/documents/tc39x-bd-errata-sheet.pdf "https://www.infineon.com/assets/row/public/documents/10/52/infineon-aurix-tc39x-bd-step-errata-sheet-en.pdf"
# HSM 快速培训（公开版，11 页）— 硬件能力概览；完整 HSM TS 需 myICP 权限，见 deploy/README.md
dl data/documents/tc3xx-hsm-quick-training.pdf "https://www.infineon.com/assets/row/public/documents/10/56/infineon-aurix-tc3xx-hardware-security-module-quick-training-en.pdf"

# ---------------------------------------------------------------------------
# 2. iLLD 源码（sparse checkout 只取 src/BaseSw/iLLD/TC3xx，约 39MB）
# ---------------------------------------------------------------------------
echo "==> [2/4] 获取 iLLD 源码 (Infineon/illd_release_tc3x)"
if [ ! -d data/illd_tmp/src ]; then
  rm -rf data/illd_tmp
  for P in "" https://ghproxy.net/ https://gh-proxy.com/ https://ghfast.top/; do
    git clone --filter=blob:none --no-checkout --depth 1 \
      "${P}https://github.com/Infineon/illd_release_tc3x.git" data/illd_tmp && break
  done
  (cd data/illd_tmp && git sparse-checkout init --cone && git sparse-checkout set src/BaseSw/iLLD/TC3xx && git checkout main)
fi
rm -rf data/illd && mkdir -p data/illd
cp -r data/illd_tmp/src/BaseSw/iLLD/TC3xx data/illd/
rm -rf data/illd_tmp
echo "  iLLD 源码: $(find data/illd -name '*.c' | wc -l) 个 .c, $(find data/illd -name '*.h' | wc -l) 个 .h"

# ---------------------------------------------------------------------------
# 3. iLLD API 文档：CHM(70MB) → 解压 → 转 Markdown
# ---------------------------------------------------------------------------
echo "==> [3/4] 获取 iLLD API 文档 (CHM)"
CHM_URL="https://raw.githubusercontent.com/Infineon/illd_release_tc3x/main/doc/iLLD-UM-TC3xx.chm"
mkdir -p /tmp/illd_chm
if [ ! -s data/illd_api/.done ]; then
  dl /tmp/illd_chm/illd-um.chm "$CHM_URL"
  # 校验大小 ~70293275 字节，不完整则用 ghfast 断点续传
  SZ=$(stat -c%s /tmp/illd_chm/illd-um.chm 2>/dev/null || echo 0)
  while [ "$SZ" -lt 70293275 ]; do
    curl -sSL -C - --max-time 150 -o /tmp/illd_chm/illd-um.chm "https://ghfast.top/$CHM_URL" 2>/dev/null || true
    SZ=$(stat -c%s /tmp/illd_chm/illd-um.chm 2>/dev/null || echo 0)
    echo "  续传中: $SZ / 70293275"
  done
  rm -rf /tmp/illd_chm/out && mkdir -p /tmp/illd_chm/out
  7z x -y -o/tmp/illd_chm/out /tmp/illd_chm/illd-um.chm > /dev/null
  $PY - <<'EOF'
import re
from pathlib import Path
from bs4 import BeautifulSoup
src=Path('/tmp/illd_chm/out'); out=Path('data/illd_api'); out.mkdir(parents=True,exist_ok=True)
n=0
for f in src.glob('*.html'):
    if f.name.endswith('_source.html'): continue   # 源码页跳过（已有 .c/.h）
    s=BeautifulSoup(f.read_text('utf-8',errors='ignore'),'lxml')
    title=s.title.get_text(strip=True) if s.title else f.stem
    body=s.find('div',class_='contents') or s.body
    if not body: continue
    for t in body(['script','style','nav']): t.decompose()
    text=re.sub(r'\n{3,}','\n\n',body.get_text('\n',strip=True))
    if len(text)<80: continue
    (out/(re.sub(r'[^A-Za-z0-9_.-]','_',f.stem)[:100]+'.md')).write_text(f'# {title}\n\n{text}\n',encoding='utf-8')
    n+=1
print(f'  CHM→MD 转换: {n} 个文件')
EOF
  touch data/illd_api/.done
fi

# ---------------------------------------------------------------------------
# 4. 大 PDF 切片（300 页/片，规避 pdfplumber OOM）
# ---------------------------------------------------------------------------
echo "==> [4/4] 大 PDF 切片"
$PY - <<'EOF' 2>&1 | grep -v Warning
import fitz, os
for name in ['tc3xx-part1','tc3xx-part2','tc39x-bd-errata-sheet']:
    src=f'data/documents/{name}.pdf'
    if not os.path.exists(src): continue
    d0=fitz.open(src); n=d0.page_count; d0.close()
    step=300
    for i in range(0,n,step):
        end=min(i+step,n)
        out=f'data/documents/{name}-p{i+1:04d}-{end:04d}.pdf'
        if os.path.exists(out): continue
        s=fitz.open(src); d=fitz.open(); d.insert_pdf(s,from_page=i,to_page=end-1); d.save(out); d.close()
        print(' ', out)
    os.remove(src)   # 切片后删除原始大文件
EOF

echo "==> 数据就绪。下一步: ./deploy/rebuild_index.sh"
