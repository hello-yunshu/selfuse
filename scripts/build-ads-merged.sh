#!/usr/bin/env bash
#
# 生成 dist/ads-merged.mrs
#
# 把多个广告/追踪域名集合求并集，转成 mihomo 的 mrs 二进制格式，供
# openwrt/yunshu.yaml 里的 rule-provider `ads-merged` 使用。
#
# 为什么要有这个脚本：
#   上游里有 yaml/hosts 纯文本源，mihomo 直接加载时瞬时内存占用是 mrs 的
#   数十倍；且各集合互相大量重叠。合并成一个 mrs 后内存与解析开销都最小。
#
# 收录标准（改动前先按这三条核）：
#   1. 最近 6 个月有更新；2. 与并集重叠低于 95%；3. 不能命中国内 CDN/登录/IP
#   关键域名（alicdn、gtimg、qpic、myqcloud、weixin、alipay 等）。
#   已否决：AdAway（2026-04 后停更）、StevenBlack（在其余并集之上增量为 0）、
#   1Hosts（2026-09 后未更新，且大量 DGA 垃圾域名）。
#
# 用法：
#   MIHOMO=/path/to/mihomo ./scripts/build-ads-merged.sh
#   OUT=/tmp/x.mrs MIHOMO=... ./scripts/build-ads-merged.sh
#
# 依赖：curl、python3、mihomo（需支持 convert-ruleset 子命令）
# 输出：dist/ads-merged.mrs 和 dist/build.json
#
# 失败即退出，不会产出残缺文件：任何上游下载失败、格式变化、条目数
# 低于健康下限，脚本都以非 0 退出，CI 因此不会发布新版本。
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/dist/ads-merged.mrs}"
META="${META:-$ROOT/dist/build.json}"
MIHOMO="${MIHOMO:-mihomo}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v "$MIHOMO" >/dev/null 2>&1 || { echo "找不到 mihomo，请设置 MIHOMO=/path/to/mihomo" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "需要 python3" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "需要 curl" >&2; exit 1; }

# name|kind|url|fallback_url
# kind: mrs = 上游已是 mihomo mrs；yaml = 上游是 clash yaml payload
# 主源用 raw.githubusercontent（CI 里最稳），备用 jsdelivr CDN
SRC=(
  "heidai|mrs|https://raw.githubusercontent.com/217heidai/adblockfilters/main/rules/adblockmihomo.mrs|https://cdn.jsdelivr.net/gh/217heidai/adblockfilters@main/rules/adblockmihomo.mrs"
  "anti-ad|mrs|https://raw.githubusercontent.com/privacy-protection-tools/anti-ad.github.io/master/docs/mihomo.mrs|https://cdn.jsdelivr.net/gh/privacy-protection-tools/anti-ad.github.io@master/docs/mihomo.mrs"
  "cats-team|mrs|https://raw.githubusercontent.com/Cats-Team/AdRules/main/adrules-mihomo.mrs|https://cdn.jsdelivr.net/gh/Cats-Team/AdRules@main/adrules-mihomo.mrs"
  "loyalsoldier|yaml|https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/reject.txt|https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/reject.txt"
  "neodevhost|yaml|https://raw.githubusercontent.com/neodevpro/neodevhost/master/clash|https://cdn.jsdelivr.net/gh/neodevpro/neodevhost@master/clash"
  "hagezi|text|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.txt|https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@main/wildcard/pro.txt"
  "oisd|text|https://raw.githubusercontent.com/sjhgvr/oisd/main/domainswild_big.txt|https://cdn.jsdelivr.net/gh/sjhgvr/oisd@main/domainswild_big.txt"
  "bm7|text|https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Advertising/Advertising_Domain.yaml|https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Advertising/Advertising_Domain.yaml"
)

fetch() {
  # $1 主地址  $2 备用地址（可为空）  $3 落地文件
  curl -fsSL --retry 3 --retry-all-errors --retry-delay 5 -m 240 -o "$3" "$1" && return 0
  [ -n "$2" ] || return 1
  echo "  主源失败，改用备用源" >&2
  curl -fsSL --retry 3 --retry-all-errors --retry-delay 5 -m 240 -o "$3" "$2"
}

for s in "${SRC[@]}"; do
  name="${s%%|*}"; rest="${s#*|}"
  kind="${rest%%|*}"; rest="${rest#*|}"
  url="${rest%%|*}"; alt="${rest#*|}"
  printf '下载 %-14s ... ' "$name"
  fetch "$url" "$alt" "$WORK/$name.raw"
  printf 'ok (%s bytes)\n' "$(wc -c < "$WORK/$name.raw" | tr -d ' ')"

  if [ "$kind" = "mrs" ]; then
    # mrs 源：解成每行一个 '+.domain' 的文本；格式不对会在这里转失败
    if ! "$MIHOMO" convert-ruleset domain mrs "$WORK/$name.raw" "$WORK/$name.list" 2>"$WORK/$name.err"; then
      echo "解析失败：$name（mrs）。上游可能改了格式：" >&2
      head -3 "$WORK/$name.err" >&2
      exit 1
    fi
  else
    # yaml / hosts / 纯域名等文本源，直接交给 python 归一化
    cp "$WORK/$name.raw" "$WORK/$name.list"
  fi
done

python3 - "$WORK" > "$WORK/merged.yaml" <<'PY'
import os
import re
import sys

work = sys.argv[1]

# 健康下限：低于它就说明上游改格式或返回了空壳，直接失败
FLOOR = {
    "heidai": 150000,
    "anti-ad": 60000,
    "cats-team": 130000,
    "loyalsoldier": 120000,
    "neodevhost": 120000,
    "hagezi": 150000,
    "oisd": 150000,
    "bm7": 200000,
}
TOTAL_MIN, TOTAL_MAX = 450000, 900000

IPLIKE = re.compile(r"^[\d.]+$")


def norm(line):
    t = line.strip()
    if not t or t.startswith("#") or t.startswith("payload"):
        return None
    if t.startswith("||"):
        t = t[2:]
        if "^" in t:
            t = t.split("^")[0]
    if t.startswith("- "):
        t = t[2:].strip()
    elif t == "-":
        return None
    if len(t) >= 2 and t[0] == t[-1] and t[0] in "'\"":
        t = t[1:-1].strip()
    while True:
        if t.startswith("+.") or t.startswith("*."):
            t = t[2:]
        elif t.startswith("."):
            t = t[1:]
        else:
            break
    t = t.strip().strip("'\"").lower().rstrip(".")
    if not t or " " in t or "/" in t or "." not in t:
        return None
    # 过滤 IP 和内嵌主机头，这些不是域名
    if IPLIKE.match(t):
        return None
    return t


domains = set()
for name, floor in FLOOR.items():
    path = os.path.join(work, name + ".list")
    local = set()
    with open(path, "r", errors="replace") as f:
        for line in f:
            d = norm(line)
            if d:
                local.add(d)
    sys.stderr.write("  %-14s 条目 %d（下限 %d）\n" % (name, len(local), floor))
    if len(local) < floor:
        sys.stderr.write("异常：%s 只有 %d 条，低于下限 %d，拒绝产出\n" % (name, len(local), floor))
        sys.exit(1)
    domains |= local

n = len(domains)
sys.stderr.write("并集去重后 %d 条\n" % n)
if not (TOTAL_MIN <= n <= TOTAL_MAX):
    sys.stderr.write("并集 %d 条超出合理区间 [%d, %d]，拒绝产出\n" % (n, TOTAL_MIN, TOTAL_MAX))
    sys.exit(1)

sys.stdout.write("payload:\n")
for d in sorted(domains):
    sys.stdout.write("  - '+.%s'\n" % d)
PY

mkdir -p "$(dirname "$OUT")"

# yaml -> mrs（convert-ruleset 的第二个参数是源格式）
"$MIHOMO" convert-ruleset domain yaml "$WORK/merged.yaml" "$WORK/ads-merged.mrs"

# 回读校验：把生成的 mrs 再解出来，与源集合逐条比对，防止转换丢条目或改写
"$MIHOMO" convert-ruleset domain mrs "$WORK/ads-merged.mrs" "$WORK/verify.list"
N="$(python3 - "$WORK/merged.yaml" "$WORK/verify.list" <<'PY'
import sys


def load_yaml(path):
    out = set()
    with open(path, "r", errors="replace") as f:
        for line in f:
            t = line.strip()
            if not t.startswith("- "):
                continue
            t = t[2:].strip().strip("'\"")
            if t.startswith("+."):
                t = t[2:]
            out.add(t)
    return out


def load_list(path):
    out = set()
    with open(path, "r", errors="replace") as f:
        for line in f:
            t = line.strip()
            if not t:
                continue
            if t.startswith("+."):
                t = t[2:]
            out.add(t)
    return out


src = load_yaml(sys.argv[1])
back = load_list(sys.argv[2])
if src != back:
    sys.stderr.write(
        "校验失败：mrs 回读与源集合不一致（源多 %d 条，回读多 %d 条）\n"
        % (len(src - back), len(back - src))
    )
    sys.exit(1)
sys.stdout.write("%d\n" % len(src))
PY
)"
echo "集合校验通过：$N 条完全一致"

cp "$WORK/ads-merged.mrs" "$OUT"

if command -v sha256sum >/dev/null 2>&1; then
  SHA="$(sha256sum "$OUT" | awk '{print $1}')"
else
  SHA="$(shasum -a 256 "$OUT" | awk '{print $1}')"
fi
BYTES="$(wc -c < "$OUT" | tr -d ' ')"
mkdir -p "$(dirname "$META")"

# 把来源清单一起写进 build.json，供 manifest 追溯
sources_json=""
for s in "${SRC[@]}"; do
  n="${s%%|*}"; r="${s#*|}"
  r="${r#*|}"; u="${r%%|*}"
  sources_json="$sources_json{\"name\":\"$n\",\"url\":\"$u\"},"
done
sources_json="[${sources_json%,}]"

cat > "$META" <<EOF
{
  "entries": $N,
  "bytes": $BYTES,
  "sha256": "$SHA",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "sources": $sources_json
}
EOF

printf '完成 %s（%s 字节，%s 条，sha256 %s）\n' "$OUT" "$BYTES" "$N" "$SHA"
