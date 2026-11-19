#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# 抓取五份数据源 → dist/<包名>/<文件>，算 sha256，与上一版 manifest 比对，
# 把结果写成 dist/fetch.tsv 供后面的 validate / 打包读取。
#
# 抓取地址与主备顺序沿用项目里已经踩过一遍的那一套（见 README §1）：这里不另起
# 一套源，也不改优先级，否则两边的失败模式对不上。
#
# 用法：
#   scripts/fetch.sh [--allow-partial] [--prev FILE]
# 环境变量：
#   DIST             产物目录，默认 <repo>/dist
#   PREV_MANIFEST    上一版 manifest.json；不存在则视为「全部变化」
#
# 退出码：0 = 五份都拿到（或 --allow-partial 下的部分失败）；1 = 有源抓不到且
# 不允许部分成功。单份源的失败照样写进 fetch.tsv，不留空。

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DIST=${DIST:-$ROOT/dist}
PREV_MANIFEST=${PREV_MANIFEST:-$DIST/manifest.prev.json}
ALLOW_PARTIAL=0

while [ $# -gt 0 ]; do
	case "$1" in
	--allow-partial) ALLOW_PARTIAL=1 ;;
	--prev)
		PREV_MANIFEST=$2
		shift
		;;
	-h | --help)
		sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
		exit 0
		;;
	*)
		printf 'E: 未知参数 %s\n' "$1" >&2
		exit 2
		;;
	esac
	shift
done

# 进度信息一律走 stderr：stdout 是 dist/fetch.tsv 的通道，混进去就多几行记录
log() { printf '%s\n' "$*" >&2; }
warn() { printf 'W: %s\n' "$*" >&2; }
die() {
	printf 'E: %s\n' "$*" >&2
	exit 1
}

mkdir -p "$DIST"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/appdpi-fetch.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

# ---------------------------------------------------------------- 源清单
# 每行：包名 <TAB> 文件名 <TAB> 后处理 <TAB> url1;url2;...
# 后处理：none = 直接落盘；zx7z = 从 7z 里取 ipv6wry.db；cdn = cdn.yml 转文本。
emit() {
	local pkg=$1 file=$2 post=$3
	shift 3
	local urls
	urls=$(printf '%s;' "$@")
	printf '%s\t%s\t%s\t%s\n' "$pkg" "$file" "$post" "${urls%;}"
}

list_sources() {
	# v4：jsDelivr 主、raw 兜底（实测 jsDelivr 在国内更快）
	emit appdpi-geoip-ip2region-v4 ip2region_v4.xdb none \
		"https://cdn.jsdelivr.net/gh/lionsoul2014/ip2region/data/ip2region_v4.xdb" \
		"https://raw.githubusercontent.com/lionsoul2014/ip2region/master/data/ip2region_v4.xdb"
	# v6：反过来。jsDelivr 对 GitHub 源有 20MB 上限，37MB 的 v6 库会被回 403。
	emit appdpi-geoip-ip2region-v6 ip2region_v6.xdb none \
		"https://raw.githubusercontent.com/lionsoul2014/ip2region/master/data/ip2region_v6.xdb" \
		"https://cdn.jsdelivr.net/gh/lionsoul2014/ip2region/data/ip2region_v6.xdb"
	# qqwry：先走能直接回源的镜像（github.com 在不少网络里 TCP 超时，release
	# 资产还会 302 到 release-assets.githubusercontent.com），直连留作兜底。
	emit appdpi-geoip-qqwry qqwry.dat none \
		"https://gh-proxy.com/https://github.com/metowolf/qqwry.dat/releases/latest/download/qqwry.dat" \
		"https://ghfast.top/https://github.com/metowolf/qqwry.dat/releases/latest/download/qqwry.dat" \
		"https://github.com/metowolf/qqwry.dat/releases/latest/download/qqwry.dat"
	# zxipv6wry：上游只发 7z，解出 ipv6wry.db；2022-03 之后冻结，没变就不出包。
	emit appdpi-geoip-zxipv6wry zxipv6wry.db zx7z \
		"https://ip.zxinc.org/ip.7z"
	# cdn：nali 那份 cdn.yml，用 tools/cdn_convert.py 转成 s/r 行文本。
	emit appdpi-cdn cdn.txt cdn \
		"https://cdn.jsdelivr.net/gh/4ft35t/cdn/src/cdn.yml" \
		"https://raw.githubusercontent.com/4ft35t/cdn/master/src/cdn.yml"
}

# ---------------------------------------------------------------- 下载
# 主备回退：逐个 URL 试，第一个成功的算数。-f 让 4xx/5xx 直接失败，
# --retry 只重试网络层错误与 5xx（配合 --retry-all-errors 更宽），
# 不使用 -C - 断点续传：服务端忽略 Range 时会拼出半个文件，本地看不出来。
# 输出：$DL_URL（最终 URL，跟过跳转）、$DL_HDR（响应头文件）。
download() {
	local urls=$1 out=$2
	local -a hdrs=(-H 'Accept-Encoding: identity')
	local url eff hdr
	rm -f "$out"
	DL_URL=""
	DL_TRIED=""
	DL_ERR=""
	hdr=$tmp/headers.txt
	for url in $(printf '%s\n' "$urls" | tr ';' '\n'); do
		[ -n "$url" ] || continue
		DL_TRIED=${DL_TRIED:+$DL_TRIED;}$url
		log "  → $url"
		: >"$hdr"
		if eff=$(curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors \
			--connect-timeout 20 --max-time 1800 \
			"${hdrs[@]}" -D "$hdr" -o "$out" -w '%{url_effective}' "$url" 2>"$tmp/curl.err"); then
			if [ -s "$out" ]; then
				DL_URL=$eff
				return 0
			fi
			DL_ERR="响应为空"
		else
			DL_ERR=$(tail -1 "$tmp/curl.err" 2>/dev/null)
		fi
		warn "  失败：${DL_ERR:-未知错误}"
	done
	return 1
}

# 响应头取值：重定向会留下多段头，取最后一段（= 最终响应）
hdr_value() {
	grep -i "^$1:" "$tmp/headers.txt" 2>/dev/null | tail -1 |
		sed -e 's/^[^:]*:[[:space:]]*//' -e 's/\r$//'
}

# 响应头里的 Last-Modified → ISO 8601（UTC）。拿不到就留空，不猜。
last_modified() {
	local raw
	raw=$(hdr_value last-modified)
	[ -n "$raw" ] || return 0
	date -u -d "$raw" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true
}

# release 资产地址里带 tag（…/releases/download/<tag>/x）→ 当作上游版本号
tag_from_url() {
	case $1 in
	*/releases/download/*/*)
		printf '%s' "$1" | sed -n 's#.*/releases/download/\([^/]*\)/.*#\1#p'
		;;
	esac
}

# ---------------------------------------------------------------- 上一版
# 从上一版 manifest 抽出 包名→sha256/字节数/上游版本，供「变了没有」比对。
prev_lookup() {
	awk -F'\t' -v k="$1" '$1==k{print $2"\t"$3"\t"$4; exit}' "$tmp/prev.tsv" 2>/dev/null
}

: >"$tmp/prev.tsv"
if [ -f "$PREV_MANIFEST" ]; then
	python3 - "$PREV_MANIFEST" >"$tmp/prev.tsv" <<'PY' || die "解析上一版 manifest 失败：$PREV_MANIFEST"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
for f in m.get("files", []):
    print("\t".join([
        f.get("package", ""), f.get("sha256") or "", str(f.get("bytes") or ""),
        f.get("upstream_version") or "",
    ]))
PY
	log "上一版 manifest：$PREV_MANIFEST（$(wc -l <"$tmp/prev.tsv" | tr -d ' ') 份记录）"
else
	log "没有上一版 manifest（$PREV_MANIFEST）：本次视为全部变化"
fi

# ---------------------------------------------------------------- 主循环
TSV=$DIST/fetch.tsv
{
	printf 'package\tfile\tstatus\tchanged\tbytes\tsha256\tsource\tsources_tried\tupstream_version\tupstream_date\tarchive_member\terror\n'

	list_sources | while IFS=$'\t' read -r pkg file post urls; do
		[ -n "$pkg" ] || continue
		dir=$DIST/$pkg
		out=$dir/$file
		mkdir -p "$dir"
		rm -f "$out" "$dir/$file.part"

		printf '\n[%s] %s ← %s\n' "$pkg" "$file" "$post" >&2

		status=ok
		err=""
		url_final=""
		tried=""
		upstream_version=""
		upstream_date=""
		member=""
		work=$tmp/$pkg
		mkdir -p "$work"

		case $post in
		none)
			if download "$urls" "$work/download.bin"; then
				mv -f "$work/download.bin" "$out"
				url_final=$DL_URL
				tried=$DL_TRIED
				upstream_date=$(last_modified)
				upstream_version=$(tag_from_url "$DL_URL")
				# 源不提供 Last-Modified 时（jsDelivr / raw 都不给），
				# 能记的只有 jsDelivr 解析出来的版本号；拿不到就留空，不编。
				# 分支名（HEAD/master）不算版本号，只收数字开头的。
				[ -n "$upstream_version" ] ||
					upstream_version=$(hdr_value x-jsd-version | grep -E '^[0-9]' || true)
			else
				status=failed
				err=${DL_ERR:-所有源都失败}
				tried=$DL_TRIED
			fi
			;;
		zx7z)
			# 只发 7z：下载后在 runner 上解出 ipv6wry.db 再算哈希。
			# 上游 2022-03 后冻结，因此「哈希没变 → 不出包」是常态。
			if download "$urls" "$work/ip.7z"; then
				tried=$DL_TRIED
				upstream_date=$(last_modified)
				sevenzip=""
				for c in 7z 7za 7zr; do
					command -v "$c" >/dev/null 2>&1 && {
						sevenzip=$c
						break
					}
				done
				if [ -z "$sevenzip" ]; then
					status=failed
					err="没有 7z/7za/7zr，无法解 ip.7z"
				elif ! "$sevenzip" e -y -o"$work" "$work/ip.7z" ipv6wry.db >/dev/null 2>&1; then
					status=failed
					err="从 ip.7z 里取 ipv6wry.db 失败"
				elif [ ! -s "$work/ipv6wry.db" ]; then
					status=failed
					err="解出来的 ipv6wry.db 是空的"
				else
					mv -f "$work/ipv6wry.db" "$out"
					member=ipv6wry.db
					url_final=$DL_URL
				fi
			else
				status=failed
				err=${DL_ERR:-所有源都失败}
				tried=$DL_TRIED
			fi
			;;
		cdn)
			if download "$urls" "$work/cdn.yml"; then
				tried=$DL_TRIED
				url_final=$DL_URL
				upstream_date=$(last_modified)
				upstream_version=$(hdr_value x-jsd-version | grep -E '^[0-9]' || true)
				if ! python3 "$ROOT/tools/cdn_convert.py" "$work/cdn.yml" -o "$out" 2>"$work/cdn.err"; then
					status=failed
					err="cdn_convert.py 失败：$(tail -1 "$work/cdn.err")"
				fi
			else
				status=failed
				err=${DL_ERR:-所有源都失败}
				tried=$DL_TRIED
			fi
			;;
		*)
			status=failed
			err="未知后处理 $post"
			;;
		esac

		bytes=""
		sha=""
		changed=""
		if [ "$status" = ok ] && [ -s "$out" ]; then
			bytes=$(wc -c <"$out" | tr -d ' ')
			sha=$(sha256sum "$out" | cut -d' ' -f1)
			prev=$(prev_lookup "$pkg")
			prev_sha=$(printf '%s' "$prev" | cut -f1)
			if [ -z "$prev_sha" ]; then
				changed=true
			elif [ "$prev_sha" = "$sha" ]; then
				changed=false
			else
				changed=true
			fi
		elif [ "$status" = ok ]; then
			status=failed
			err="落盘的文件是空的"
		fi

		# 记录是 TSV：任何字段里混进制表符或换行都会让整行错位
		err=$(printf '%s' "$err" | tr '\t\n' '  ')
		url_final=$(printf '%s' "$url_final" | tr '\t\n' '  ')
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$pkg" "$file" "$status" "$changed" "$bytes" "$sha" \
			"$url_final" "$tried" "$upstream_version" "$upstream_date" "$member" "$err"

		if [ "$status" = ok ]; then
			printf '  %s  %s bytes  %s  changed=%s\n' "$sha" "$bytes" "${upstream_date:-无日期}" "$changed" >&2
		else
			printf '  FAIL %s\n' "$err" >&2
		fi
	done
} >"$TSV"

# ---------------------------------------------------------------- 汇总
total=0
n_ok=0
n_changed=0
n_failed=0
while IFS=$'\t' read -r pkg file status changed bytes rest; do
	[ "$pkg" = package ] && continue
	[ -n "$pkg" ] || continue
	total=$((total + 1))
	if [ "$status" = ok ]; then
		n_ok=$((n_ok + 1))
		[ "$changed" = true ] && n_changed=$((n_changed + 1))
	else
		n_failed=$((n_failed + 1))
	fi
done <"$TSV"

if [ "$n_changed" -gt 0 ]; then
	printf 'changed=true\n' >"$DIST/fetch.changed"
else
	printf 'changed=false\n' >"$DIST/fetch.changed"
fi

log ""
sum_bytes=$(awk -F'\t' 'NR>1 && $5!=""{s+=$5} END{print s+0}' "$TSV")
log "抓取完成：$n_ok/$total 成功，$n_changed 份有变化，$n_failed 份失败，合计 $sum_bytes 字节"
log "结果：$TSV"

if [ "$n_ok" -eq 0 ]; then
	die "一份数据都没抓到，不做发布"
fi
if [ "$n_failed" -gt 0 ] && [ "$ALLOW_PARTIAL" -eq 0 ]; then
	die "$n_failed 份数据抓取失败（未加 --allow-partial）"
fi
exit 0
