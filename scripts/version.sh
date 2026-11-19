#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# 计算本次数据包的版本号，写成 dist/version.txt。
#
# 版本形如 2026.11.18-r1：前半是数据日期（北京日期，工作流里 TZ=Asia/Shanghai），
# 后半是 PKG_RELEASE——同一天重出时递增。opkg 与 apk 都认这个形式：
# 2026.11.18-r2 > 2026.11.18-r1，所以升级不会被「版本一样」挡住。
#
# ipk 与 apk 用的是同一个版本号：两种格式同源于同一份数据，版本分开只会多一个
# 对不上的维度。
#
# 用法：scripts/version.sh [YYYY.MM.DD]
# 环境变量：DIST（默认 <repo>/dist）、PREV_MANIFEST（默认 <dist>/manifest.prev.json）
#
# 输出：把版本号写进 <dist>/version.txt，并在 stdout 打一遍。

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIST=${DIST:-$ROOT/dist}
PREV_MANIFEST=${PREV_MANIFEST:-$DIST/manifest.prev.json}

if [ $# -ge 1 ]; then
	DATE=$1
else
	DATE=$(date +%Y.%m.%d)
fi

case $DATE in
[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]) ;;
*)
	printf 'E: 日期格式必须是 YYYY.MM.DD：%s\n' "$DATE" >&2
	exit 2
	;;
esac

mkdir -p "$DIST"

# 上一版用了同一天的版本号就 +1，否则从 1 起。读不到上一版（首次运行、或
# manifest 里没记版本）也按 1 算。
PREV_VERSION=""
if [ -f "$PREV_MANIFEST" ]; then
	PREV_VERSION=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8")).get("version",""))' "$PREV_MANIFEST" 2>/dev/null || true)
fi

case $PREV_VERSION in
"$DATE"-r*)
	last=${PREV_VERSION#"$DATE"-r}
	case $last in
	'' | *[!0-9]*) RELEASE=1 ;;
	*) RELEASE=$((last + 1)) ;;
	esac
	;;
*) RELEASE=1 ;;
esac

VERSION="$DATE-r$RELEASE"
printf '%s\n' "$VERSION" >"$DIST/version.txt"
printf '%s\n' "$VERSION"
