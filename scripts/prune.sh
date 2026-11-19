#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# 删掉 30 天前的 Release（只删本仓库自己发的 data-* tag）。
#
# 为什么要删：每天最多一个 Release，一年 365 个，每个带十个资产、几十 MB。
# 留 30 天足够回滚，再往前翻没人看，还占配额。
#
# 只按 tag 前缀 data- 认自己的 Release——工作流以后要是发别的 Release（比如
# 手动打的标签），这里不会顺手删掉。
#
# 用法：scripts/prune.sh [--days N] [--repo OWNER/REPO] [--dry-run]
# 需要 GH_TOKEN（或已 gh auth login）。

set -uo pipefail

DAYS=30
REPO=${PACKAGE_REPO:-${GITHUB_REPOSITORY:-}}
DRY_RUN=0

while [ $# -gt 0 ]; do
	case "$1" in
	--days)
		DAYS=$2
		shift
		;;
	--repo)
		REPO=$2
		shift
		;;
	--dry-run) DRY_RUN=1 ;;
	-h | --help)
		sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
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

case $DAYS in
'' | *[!0-9]*) die "--days 必须是正整数：$DAYS" ;;
esac
command -v gh >/dev/null 2>&1 || die "没有 gh CLI"
[ -n "$REPO" ] || die "没有仓库名（--repo 或 GITHUB_REPOSITORY）"

# 一次取够：留 30 天时正常也就 30 来个 Release，取 200 足够翻过任何异常累积
list=$(gh release list --repo "$REPO" --limit 200 --json tagName,createdAt,publishedAt) ||
	die "读取 Release 列表失败"

# 日期算术交给 python3：date -d 的可用性与解析口径在各平台上不一致
victims=$(printf '%s' "$list" | python3 -c '
import json, sys
from datetime import datetime, timedelta, timezone

days = int(sys.argv[1])
cutoff = datetime.now(timezone.utc) - timedelta(days=days)
for r in json.load(sys.stdin):
    tag = r.get("tagName") or ""
    if not tag.startswith("data-"):
        continue
    stamp = r.get("publishedAt") or r.get("createdAt") or ""
    if not stamp:
        continue
    try:
        when = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        continue
    if when < cutoff:
        print(tag, when.strftime("%Y-%m-%d"))
' "$DAYS") || die "筛选过期 Release 失败"

if [ -z "$victims" ]; then
	log "没有超过 $DAYS 天的 Release，无需清理。"
	exit 0
fi

count=0
while read -r tag when; do
	[ -n "$tag" ] || continue
	if [ "$DRY_RUN" -eq 1 ]; then
		log "[dry-run] 将删除 $tag（发布于 $when）"
	else
		log "删除 $tag（发布于 $when）"
		gh release delete "$tag" --repo "$REPO" --yes --cleanup-tag ||
			die "删除 $tag 失败"
	fi
	count=$((count + 1))
done <<EOF
$victims
EOF

if [ "$DRY_RUN" -eq 1 ]; then
	log ""
	log "[dry-run] 共 $count 个会被删除（保留 $DAYS 天）"
else
	log ""
	log "清理完成：删除 $count 个 Release，保留最近 $DAYS 天。"
fi
