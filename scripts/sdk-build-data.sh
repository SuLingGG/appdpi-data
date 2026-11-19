#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# 在 OpenWrt SDK 容器里把五个数据包编成该 SDK 的包格式：
#   24.10 分支用 opkg，产物是 .ipk；25.12 分支用 apk，产物是 .apk。
#
# **这个脚本只在 SDK 容器内运行**，由 .github/workflows/daily.yml 调用；本地
# 想复现就照工作流那行 docker run 原样跑。包定义由 tools/gen_sdk_packages.py
# 从 packages/<包名>/ 生成，这里只负责挂上去、选包、编译、收产物。
#
# 用法：sdk-build-data.sh <工作区> <产物目录> <格式>
#   工作区    仓库检出目录（容器里路径与宿主一致，dist/ 在它下面）
#   产物目录  收集目录，产物统一改名成 appdpi-xxx.<格式>（不带版本号）
#   格式      ipk 或 apk，只用来校验产物扩展名与改名的后缀
#
# 退出原因都写在 stderr：容器里的失败在 Actions 日志里只剩这一句，不写清楚
# 就只能靠重跑猜。
set -eu

SRC="${1:?用法: $0 <工作区> <产物目录> <ipk|apk>}"
OUT="${2:?用法: $0 <工作区> <产物目录> <ipk|apk>}"
FMT="${3:?用法: $0 <工作区> <产物目录> <ipk|apk>}"

case "$FMT" in
ipk | apk) ;;
*)
	echo "格式只能是 ipk 或 apk：$FMT" >&2
	exit 1
	;;
esac

[ -f ./scripts/feeds ] || {
	echo "当前目录不是 SDK 根（找不到 ./scripts/feeds）" >&2
	exit 1
}
[ -d "$SRC/dist/sdk-packages" ] || {
	echo "没有 $SRC/dist/sdk-packages：先跑 tools/gen_sdk_packages.py" >&2
	exit 1
}
[ -f "$SRC/dist/sdk-pkgs.list" ] || {
	echo "没有 $SRC/dist/sdk-pkgs.list：先跑 tools/gen_sdk_packages.py" >&2
	exit 1
}
[ -d "$SRC/dist" ] || {
	echo "没有数据目录 $SRC/dist：先跑 scripts/fetch.sh" >&2
	exit 1
}

# SDK 的 host 工具在 staging_dir/host/bin 下，不一定在 PATH 里；优先用 SDK 自带
# 的 tar（与 24.10 的 ipk 格式是同一套实现），没有就退回系统的。
if [ -x ./staging_dir/host/bin/tar ]; then
	TAR=$PWD/staging_dir/host/bin/tar
else
	TAR=tar
fi
APK=$PWD/staging_dir/host/bin/apk

echo "==> 挂载包定义"
# 整块目录挂成 package/appdpi-data：改名而不是逐个链 Makefile，新增包时
# 这里不用跟着改。符号指到工作区里，容器退出后定义仍可复看。
rm -rf package/appdpi-data
ln -sfn "$SRC/dist/sdk-packages" package/appdpi-data

echo "==> 选包"
# 五个数据包都没有编译步骤，只需要 SDK 的包元数据；不装任何 feed。
# appdpi 不在这个 SDK 里（DEPENDS 只写进控制字段），defconfig 会打一条
# 「依赖不存在」的警告，属正常。
make defconfig >/dev/null

# 编译完把包拆开对一遍：包里每个文件都要落在 layout 写的位置，内容与校验过的
# 数据逐字节一致。SDK 自己不会替我们做这件事——路径写错时照样能出一个「成功」
# 的空包，装到设备上才发现引擎读不到。
verify_pkg() {
	pkg=$1
	pkgfile=$2
	work=$OUT/.verify-$pkg
	rm -rf "$work"
	mkdir -p "$work"
	if [ "$FMT" = ipk ]; then
		"$TAR" -xzOf "$pkgfile" ./data.tar.gz | "$TAR" -xzf - -C "$work" || {
			echo "$pkg：解不出 data.tar.gz" >&2
			exit 1
		}
	else
		"$APK" --allow-untrusted extract --destination "$work" "$pkgfile" >/dev/null || {
			echo "$pkg：apk 解包失败" >&2
			exit 1
		}
	fi
	while IFS=$(printf '\t') read -r src dest _mode; do
		case $src in '' | '#'*) continue ;; esac
		want=$SRC/dist/$pkg/$src
		got=$work$dest
		[ -f "$got" ] || {
			echo "$pkg：包里没有 $dest（layout 写了，实际没装进去）" >&2
			exit 1
		}
		[ "$(sha256sum "$got" | cut -d' ' -f1)" = "$(sha256sum "$want" | cut -d' ' -f1)" ] || {
			echo "$pkg：$dest 的内容与 $want 不一致" >&2
			exit 1
		}
	done <"$SRC/packages/$pkg/layout"
	rm -rf "$work"
	printf '    %-8s 包内容核对通过（%s）\n' "" "$pkg"
}

echo "==> 编译"
mkdir -p "$OUT"
n=0
while read -r pkg; do
	[ -n "$pkg" ] || continue
	echo "    $pkg"
	make "package/appdpi-data/$pkg/compile" -j"$(nproc)" \
		APPDI_DATA_DIR="$SRC/dist" || exit 1

	# 产物名由 SDK 决定（appdpi-cdn_<版本>_all.ipk / appdpi-cdn-<版本>.apk），
	# 发布资产要固定别名，所以这里按包名找回来再改名。
	found=$(find bin/packages -type f \
		\( -name "$pkg[_-]*.$FMT" \) 2>/dev/null | head -n 1)
	[ -n "$found" ] || {
		echo "$pkg：没有产出 .$FMT 包，检查这个 SDK 的包格式" >&2
		exit 1
	}
	cp -f "$found" "$OUT/$pkg.$FMT"
	printf '    %-8s %s\n' "$(du -h "$OUT/$pkg.$FMT" | cut -f1)" "$(basename "$found")"
	verify_pkg "$pkg" "$OUT/$pkg.$FMT"
	n=$((n + 1))
done <"$SRC/dist/sdk-pkgs.list"

[ "$n" -gt 0 ] || {
	echo "一个包都没编出来" >&2
	exit 1
}
echo "==> 完成：$n 个 .$FMT 包"
