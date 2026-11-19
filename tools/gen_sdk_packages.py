#!/usr/bin/env python3
"""把 packages/<包名>/ 下的包定义翻译成 OpenWrt SDK 认识的 Makefile。

SPDX-License-Identifier: GPL-2.0-only

本仓库的包定义只有两样东西（都在 packages/<包名>/ 下）：

  control.in  opkg/apk 控制字段的模板（Version 与 Installed-Size 由构建系统填）
  layout      数据文件 → 包内路径 → 权限，打包布局的唯一来源

ipk 与 apk 两种格式分别由 OpenWrt 24.10 与 25.12 的 SDK 产出，而 SDK 只认
`package/<名>/Makefile`。所以这里把上面两样翻译成 Makefile，交给
scripts/sdk-build-data.sh 在 SDK 容器里编译——布局与字段仍然只写在 packages/
里，改一处不会只改到一边。

产物（都在 --dist 下，供 scripts/sdk-build-data.sh 在容器里读）：
  sdk-packages/<包名>/Makefile   SDK 包定义
  sdk-pkgs.list                  本次要编的包名清单（一行一个）

用法：
  tools/gen_sdk_packages.py --version 2026.11.18-r1 --only appdpi-cdn
  tools/gen_sdk_packages.py --version 2026.11.18-r1        # 全部五个包
"""

import argparse
import re
import sys
from pathlib import Path

# 版本号形如 2026.11.18-r1：OpenWrt 的 PKG_VERSION 与 PKG_RELEASE 两段。
_VERSION = re.compile(r"^(\d{4}\.\d{2}\.\d{2})-r(\d+)$")


def parse_control(path: Path) -> dict[str, str]:
    """解析 control.in。

    格式就是 Debian 控制文件：`Key: value`，续行以空格开头。这里只取生成
    Makefile 需要的几个字段，其余（Section/Priority/Architecture/Installed-Size）
    由 SDK 按包定义重新生成，不从这里抄。
    """
    fields: dict[str, str] = {}
    key = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        if raw and raw[0] in " \t":
            if key:
                fields[key] += "\n" + raw.strip()
            continue
        if not raw.strip() or ":" not in raw:
            key = None
            continue
        k, v = raw.split(":", 1)
        key = k.strip()
        fields[key] = v.strip()
    return fields


def parse_layout(path: Path) -> list[tuple[str, str, str]]:
    """解析 layout：每行 `<源文件>\t<包内绝对路径>\t<权限>`，`#` 开头是注释。"""
    rows: list[tuple[str, str, str]] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        # 注释行整行跳过：layout 的表头就是一行带制表符的说明文字
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            raise SystemExit(f"{path}: 这行不是 `源文件<TAB>包内路径[<TAB>权限]`：{raw!r}")
        src, dest = parts[0].strip(), parts[1].strip()
        mode = parts[2].strip() if len(parts) > 2 and parts[2].strip() else "644"
        if not dest.startswith("/"):
            raise SystemExit(f"{path}: 包内路径必须是绝对的：{dest!r}")
        rows.append((src, dest, mode))
    if not rows:
        raise SystemExit(f"{path}: layout 里没有任何数据文件")
    return rows


def _make_text(text: str) -> str:
    """把任意文本放进 Makefile 的 `define` 块：制表符换成空格、去掉反引号。

    文本里出现 `$(...)` 会被 make 当变量展开，用 `$$` 转义。
    """
    text = text.replace("\t", " ").replace("`", "'")
    return text.replace("$", "$$")


def makefile(pkg: str, ctrl: dict[str, str], layout: list[tuple[str, str, str]],
             version: str, release: str) -> str:
    desc_lines = [l.strip() for l in ctrl.get("Description", "").splitlines()]
    title = desc_lines[0] if desc_lines else pkg
    body = desc_lines[1:] if len(desc_lines) > 1 else desc_lines
    url = ctrl.get("Source", "") or ctrl.get("URL", "")
    license_ = ctrl.get("License", "GPL-2.0-only")
    maintainer = ctrl.get("Maintainer", "SuLingGG")
    # 依赖以 control.in 的 Depends 为准：地理库声明 appdpi，appdpi-cdn 不声明
    # ——它是主包的依赖，反过来再依赖主包就成环了。Makefile 里每个依赖要带
    # `+` 前缀，逗号分隔改成空格分隔。
    depends = " ".join(
        "+" + d.strip() for d in ctrl.get("Depends", "").split(",") if d.strip()
    )

    prepare: list[str] = []
    install: list[str] = []
    for src, dest, mode in layout:
        base = Path(src).name
        prepare.append(f"\t$(CP) $(APPDI_DATA_DIR)/{pkg}/{src} $(PKG_BUILD_DIR)/{base}")
        install.append(f"\t$(INSTALL_DIR) $(1){Path(dest).parent!s}")
        if mode == "755":
            install.append(f"\t$(INSTALL_BIN) $(PKG_BUILD_DIR)/{base} $(1){dest}")
        elif mode == "644":
            install.append(f"\t$(INSTALL_DATA) $(PKG_BUILD_DIR)/{base} $(1){dest}")
        else:
            install.append(f"\t$(INSTALL_DATA) $(PKG_BUILD_DIR)/{base} $(1){dest}")
            install.append(f"\tchmod {mode} $(1){dest}")

    first_src = Path(layout[0][0]).name
    desc_text = "\n".join(" " + l for l in body) if body else " " + title

    return f"""\
# 由 tools/gen_sdk_packages.py 从 packages/{pkg}/ 下的 control.in 与 layout 生成，勿手改。
# 改字段或布局请改那两个文件；这行以上的内容由构建时的 --version 决定。
include $(TOPDIR)/rules.mk

PKG_NAME:={pkg}
PKG_VERSION:={version}
PKG_RELEASE:={release}
PKG_LICENSE:={license_}
PKG_MAINTAINER:={maintainer}

include $(INCLUDE_DIR)/package.mk

# 数据文件由 scripts/fetch.sh 抓取、scripts/validate.py 校验，落在宿主机的
# dist/<包名>/ 下。容器里由 make 命令行的 APPDI_DATA_DIR 指过来。
APPDI_DATA_DIR?=$(TOPDIR)/dist

define Package/{pkg}
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Traffic Control
  TITLE:={_make_text(title)}
  URL:={url}
  DEPENDS:={depends}
  PKGARCH:=all
endef

define Package/{pkg}/description
{_make_text(desc_text)}
endef

define Build/Prepare
\tmkdir -p $(PKG_BUILD_DIR)
{chr(10).join(prepare)}
\t[ -s $(PKG_BUILD_DIR)/{first_src} ] || {{ echo "数据文件不存在或为空：$(APPDI_DATA_DIR)/{pkg}/{layout[0][0]}" >&2; exit 1; }}
endef

define Build/Compile
endef

define Package/{pkg}/install
{chr(10).join(install)}
endef

$(eval $(call BuildPackage,{pkg}))
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=None, help="仓库根（默认脚本上一级）")
    ap.add_argument(
        "--dist", type=Path, default=None, help="产物目录（默认 <root>/dist）"
    )
    ap.add_argument("--version", required=True, help="版本号，形如 2026.11.18-r1")
    ap.add_argument(
        "--only",
        default="",
        help="只生成这些包（逗号分隔）；缺省生成 packages/ 下的全部包",
    )
    args = ap.parse_args()

    root = args.root or Path(__file__).resolve().parent.parent
    dist = args.dist or root / "dist"
    out_dir = dist / "sdk-packages"
    list_path = dist / "sdk-pkgs.list"
    m = _VERSION.match(args.version)
    if not m:
        print(f"版本号必须是 YYYY.MM.DD-rN：{args.version}", file=sys.stderr)
        return 2
    version, release = m.group(1), m.group(2)

    pkg_root = root / "packages"
    available = sorted(p.name for p in pkg_root.iterdir() if (p / "control.in").is_file())
    if not available:
        print(f"{pkg_root} 下没有包定义", file=sys.stderr)
        return 2

    wanted = [p.strip() for p in args.only.split(",") if p.strip()] or available
    unknown = [p for p in wanted if p not in available]
    if unknown:
        print(f"没有这些包：{', '.join(unknown)}；可选 {', '.join(available)}", file=sys.stderr)
        return 2

    out_dir.mkdir(parents=True, exist_ok=True)
    for pkg in wanted:
        ctrl = parse_control(pkg_root / pkg / "control.in")
        if ctrl.get("Package", "") != pkg:
            print(
                f"{pkg}/control.in 里的 Package 是 {ctrl.get('Package')!r}，与目录名不一致",
                file=sys.stderr,
            )
            return 2
        layout = parse_layout(pkg_root / pkg / "layout")
        target = out_dir / pkg
        target.mkdir(parents=True, exist_ok=True)
        (target / "Makefile").write_text(
            makefile(pkg, ctrl, layout, version, release), encoding="utf-8"
        )
        print(f"{pkg} → {target / 'Makefile'}（{len(layout)} 个文件）")

    list_path.write_text("\n".join(wanted) + "\n", encoding="utf-8")
    print(f"包名清单：{list_path}（{len(wanted)} 个）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
