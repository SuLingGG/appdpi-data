#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# 保证一次 Release 里某种格式的五个包资产齐全。
#
# 五个数据包各出两种格式（24.10 的 ipk、25.12 的 apk），所以要按格式各跑一次。
# 对每个包只有两种情况（本次编了哪些包由 <dist>/sdk-pkgs.list 说了算，
# 不能只看文件在不在：工作区重跑时上一轮留下的包还在，会被误当成这次新打的）：
#   1. 本次有变化 → 用 SDK 刚打出来的那个包（<dist>/<格式>/<包名>.<格式>）
#   2. 本次没变化 / 抓取失败 → 数据一样，包就一样，从上一个 Release 取回来沿用
#
# 取回时必须核对 sha256 与上一版 manifest 记录的一致；对不上、或者上一版
# 根本没有这个资产，就直接失败。宁可这天不出 Release，也不出一个资产不全、
# 或者混着来路不明包的 Release——「坏包绝不发布」在装配这一步同样成立。
#
# 用法：scripts/assemble.sh --format ipk|apk [--dist DIR] [--prev-tag TAG] [--repo OWNER/REPO]
# 输出：<dist>/assets-<格式>.tsv（package/format/asset/bytes/sha256/version/origin）

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DIST=${DIST:-$ROOT/dist}
PREV_TAG=${PREV_TAG:-}
REPO=${PACKAGE_REPO:-${GITHUB_REPOSITORY:-}}
PREV_MANIFEST=${PREV_MANIFEST:-$DIST/manifest.prev.json}
FORMAT=""

while [ $# -gt 0 ]; do
	case "$1" in
	--format)
		FORMAT=$2
		shift
		;;
	--dist)
		DIST=$2
		shift
		;;
	--prev-tag)
		PREV_TAG=$2
		shift
		;;
	--repo)
		REPO=$2
		shift
		;;
	-h | --help)
		sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
		exit 0
		;;
	*)
		printf 'E: 未知参数 %s\n' "$1" >&2
		exit 2
		;;
	esac
	shift
done

log() { printf '%s\n' "$*"; }
die() {
	printf 'E: %s\n' "$*" >&2
	exit 1
}

case $FORMAT in
ipk | apk) ;;
*) die "--format 只能是 ipk 或 apk（读到 '${FORMAT}'）" ;;
esac

[ -f "$DIST/fetch.tsv" ] || die "没有 $DIST/fetch.tsv（先跑 scripts/fetch.sh）"
[ -f "$DIST/version.txt" ] || die "没有 $DIST/version.txt（先跑 scripts/version.sh）"
[ -f "$DIST/sdk-pkgs.list" ] || die "没有 $DIST/sdk-pkgs.list（先跑 tools/gen_sdk_packages.py）"
VERSION=$(cat "$DIST/version.txt")
BUILT=$(tr '\n' ' ' <"$DIST/sdk-pkgs.list")
was_built() { # $1=包名 → 0 表示本次编过
	case " $BUILT " in
	*" $1 "*) return 0 ;;
	*) return 1 ;;
	esac
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/appdpi-assemble.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

# 上一版这个格式的资产与哈希（用于核对取回的东西）
: >"$tmp/prev-assets.tsv"
if [ -f "$PREV_MANIFEST" ]; then
	python3 - "$PREV_MANIFEST" "$FORMAT" >"$tmp/prev-assets.tsv" <<'PY' || die "解析上一版 manifest 失败"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
fmt = sys.argv[2]
for a in m.get("assets", []):
    if a.get("format") != fmt:
        continue
    print("\t".join([a.get("package", ""), a.get("asset", ""),
                     a.get("sha256", ""), a.get("version", ""),
                     str(a.get("bytes", ""))]))
PY
fi

prev_asset() { # $1=包名 → asset<TAB>sha256<TAB>version<TAB>bytes
	awk -F'\t' -v k="$1" '$1==k{print $2"\t"$3"\t"$4"\t"$5; exit}' "$tmp/prev-assets.tsv"
}

printf 'package\tformat\tasset\tbytes\tsha256\tversion\torigin\n' >"$DIST/assets-$FORMAT.tsv"
missing=""

log "装配五个 $FORMAT 资产（版本 $VERSION，上一版：${PREV_TAG:-无}）"
log ""

while IFS=$'\t' read -r pkg _file _status _rest; do
	[ "$pkg" = package ] && continue
	[ -n "$pkg" ] || continue

	built=$DIST/$FORMAT/$pkg.$FORMAT
	if was_built "$pkg"; then
		[ -s "$built" ] || {
			printf '  %-30s 缺：本次编了这个包，却没有产物 %s\n' "$pkg" "$built" >&2
			missing="$missing $pkg"
			continue
		}
		bytes=$(wc -c <"$built" | tr -d ' ')
		sha=$(sha256sum "$built" | cut -d' ' -f1)
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$pkg" "$FORMAT" "$pkg.$FORMAT" "$bytes" "$sha" "$VERSION" built \
			>>"$DIST/assets-$FORMAT.tsv"
		printf '  %-30s %-12s 新打包 %s\n' "$pkg" "$FORMAT" "$VERSION" >&2
		continue
	fi

	prev=$(prev_asset "$pkg")
	prev_name=$(printf '%s' "$prev" | cut -f1)
	prev_sha=$(printf '%s' "$prev" | cut -f2)
	prev_ver=$(printf '%s' "$prev" | cut -f3)

	if [ -z "$prev_name" ] || [ -z "$prev_sha" ]; then
		printf '  %-30s 缺：上一版没有这个资产，没法沿用\n' "$pkg" >&2
		missing="$missing $pkg"
		continue
	fi

	# 1) 本地已经有同名包（同一次工作区重跑），哈希对得上就直接用
	dist_pkg=$DIST/$FORMAT/$prev_name
	if [ -f "$dist_pkg" ] && [ "$(sha256sum "$dist_pkg" | cut -d' ' -f1)" = "$prev_sha" ]; then
		printf '  %-30s %-12s 沿用（本地副本） %s\n' "$pkg" "$prev_name" "$prev_ver" >&2
	# 2) 从上一版 Release 取回
	elif [ -n "$PREV_TAG" ] && [ -n "$REPO" ] && command -v gh >/dev/null 2>&1; then
		rm -rf "$tmp/dl"
		mkdir -p "$tmp/dl"
		if ! gh release download "$PREV_TAG" --repo "$REPO" \
			--pattern "$prev_name" --dir "$tmp/dl" --clobber >/dev/null 2>&1; then
			printf '  %-30s 缺：从 %s 取 %s 失败\n' "$pkg" "$PREV_TAG" "$prev_name" >&2
			missing="$missing $pkg"
			continue
		fi
		got_sha=$(sha256sum "$tmp/dl/$prev_name" | cut -d' ' -f1)
		if [ "$got_sha" != "$prev_sha" ]; then
			printf '  %-30s 缺：取回的 %s sha256 与上一版 manifest 不符\n' "$pkg" "$prev_name" >&2
			missing="$missing $pkg"
			continue
		fi
		mkdir -p "$DIST/$FORMAT"
		mv -f "$tmp/dl/$prev_name" "$dist_pkg"
		printf '  %-30s %-12s 沿用（取自 %s） %s\n' "$pkg" "$prev_name" "$PREV_TAG" "$prev_ver" >&2
	else
		printf '  %-30s 缺：没有上一版 tag/repo，无法取回 %s\n' "$pkg" "$prev_name" >&2
		missing="$missing $pkg"
		continue
	fi

	bytes=$(wc -c <"$dist_pkg" | tr -d ' ')
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$pkg" "$FORMAT" "$prev_name" "$bytes" "$prev_sha" "$prev_ver" carried \
		>>"$DIST/assets-$FORMAT.tsv"
done <"$DIST/fetch.tsv"

log ""
n=$(($(wc -l <"$DIST/assets-$FORMAT.tsv") - 1))
if [ -n "$missing" ]; then
	die "资产不齐，缺：$missing（这天不发 Release）"
fi
if [ "$n" -ne 5 ]; then
	die "资产只有 $n 个，应为 5 个"
fi
log "资产齐全：$n 个 $FORMAT"
log "清单：$DIST/assets-$FORMAT.tsv"
