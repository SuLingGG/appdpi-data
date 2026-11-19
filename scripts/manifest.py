#!/usr/bin/env python3
"""把本次管线的中间结果合成对外发布的 manifest.json 与 Release 说明。

SPDX-License-Identifier: GPL-2.0-only

输入（都在 dist/ 下，由前几步分别写出）：
  fetch.tsv       抓取结果：每份源的 sha256/字节数/上游版本与日期/是否变化
  validate.json   校验结果：哪些检查已通过（有失败时根本走不到这一步）
  assets-ipk.tsv  本次发布的 ipk：谁是新打的（built）、谁是从上一版取回的（carried）
  assets-apk.tsv  同上，apk（24.10 与 25.12 两个 SDK 各出一半）
  version.txt     本次版本号（YYYY.MM.DD-rN）

输出：
  manifest.json     下一轮构建拿它当「上一版」比对；用户也能直接读
  release-notes.md  Release 正文，同时灌进 Workflow Summary

为什么单独一步：抓取、校验、打包各自不该改写别人的产物。谁产生的事实谁记录，
到这一步才合并，出问题时中间结果原样留在 dist/ 里可以逐个复看。
"""

import argparse
import json
import sys
import time
from pathlib import Path

FORMATS = ("ipk", "apk")


def read_tsv(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines:
        return []
    head = lines[0].split("\t")
    return [dict(zip(head, l.split("\t"))) for l in lines[1:] if l.strip()]


def layout_path(root: Path, pkg: str) -> str:
    """包内安装路径从 packages/<pkg>/layout 读，避免在这儿再写一份映射。"""
    layout = root / "packages" / pkg / "layout"
    if not layout.is_file():
        return ""
    for line in layout.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 2:
            return parts[1]
    return ""


def human(n: int) -> str:
    return f"{n / 1048576:.2f} MiB" if n >= 1048576 else f"{n / 1024:.1f} KiB"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--root", type=Path, default=None, help="仓库根（默认本脚本的上一级）"
    )
    ap.add_argument(
        "--dist", type=Path, default=None, help="产物目录（默认 <root>/dist）"
    )
    ap.add_argument("--tag", default="", help="Release tag，如 data-2026-11-18")
    ap.add_argument("--version", default="", help="本次版本号，默认读 dist/version.txt")
    ap.add_argument("--out", type=Path, default=None, help="manifest 路径")
    ap.add_argument(
        "--allow-incomplete",
        action="store_true",
        help="允许不齐（没有变化、没有发布 Release 的那天用；只写说明，不发布）",
    )
    args = ap.parse_args()

    root = args.root or Path(__file__).resolve().parent.parent
    dist = args.dist or root / "dist"

    version = args.version
    if not version:
        vf = dist / "version.txt"
        if vf.is_file():
            version = vf.read_text(encoding="utf-8").strip()
    if not version:
        print(
            "没有版本号：dist/version.txt 不存在，请先跑 scripts/version.sh",
            file=sys.stderr,
        )
        return 2

    fetch = read_tsv(dist / "fetch.tsv")
    if not fetch:
        print(f"{dist / 'fetch.tsv'} 是空的：先跑 scripts/fetch.sh", file=sys.stderr)
        return 2

    assets: list[dict] = []
    for fmt in FORMATS:
        for row in read_tsv(dist / f"assets-{fmt}.tsv"):
            row["package"] = row.get("package", "")
            row["format"] = fmt
            row["bytes"] = int(row["bytes"]) if row.get("bytes", "").isdigit() else 0
            assets.append(row)
    by_key = {(a["package"], a["format"]): a for a in assets if a.get("asset")}

    validate = {}
    vpath = dist / "validate.json"
    if vpath.is_file():
        validate = json.loads(vpath.read_text(encoding="utf-8"))

    files = []
    for row in fetch:
        files.append(
            {
                "package": row["package"],
                "file": row["file"],
                "path": layout_path(root, row["package"]),
                "status": row["status"],
                "changed": row["changed"] == "true",
                "bytes": int(row["bytes"]) if row["bytes"].isdigit() else 0,
                "sha256": row["sha256"],
                "source": row["source"],
                "sources_tried": [
                    u for u in row.get("sources_tried", "").split(";") if u
                ],
                "upstream_version": row.get("upstream_version", ""),
                "upstream_date": row.get("upstream_date", ""),
                "archive_member": row.get("archive_member", ""),
                "error": row.get("error", ""),
            }
        )

    # 每个包两种格式都必须有资产；缺一个就说明这次发布是残的
    missing = [
        f"{f['package']}.{fmt}"
        for f in files
        for fmt in FORMATS
        if (f["package"], fmt) not in by_key
    ]
    failed = [f for f in files if f["status"] != "ok"]
    changed = any(f["changed"] for f in files)

    manifest = {
        "schema": 2,
        "tag": args.tag,
        "version": version,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "changed": changed,
        "validated": bool(validate.get("ok")),
        "validated_at": validate.get("validated_at", ""),
        "files": files,
        "assets": [
            {
                "asset": a["asset"],
                "package": a["package"],
                "format": a["format"],
                "version": a.get("version", ""),
                "bytes": a["bytes"],
                "sha256": a.get("sha256", ""),
                "origin": a.get("origin", ""),
            }
            for a in assets
            if a.get("asset")
        ],
    }

    out = args.out or dist / "manifest.json"
    out.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    # ------------------------------------------------------------ Release 说明
    lines = [
        (
            f"数据版本 `{version}`：五个数据包，每个都出两种格式——"
            "OpenWrt 24.10 及更早的 `ipk`（opkg）与 25.12 及更新的 `apk`（apk-tools 3）。"
        ),
        "",
    ]
    if not changed:
        lines += ["**本次五份数据都没有变化，没有发布新的 Release。**", ""]
    lines += [
        "| 包 | 文件（包内路径） | 本次变化 | 数据大小 | 上游版本/日期 | 包 |",
        "|---|---|---|---|---|---|",
    ]
    up_names = {
        "appdpi-geoip-ip2region-v4": "ip2region v4",
        "appdpi-geoip-ip2region-v6": "ip2region v6",
        "appdpi-geoip-qqwry": "纯真 qqwry",
        "appdpi-geoip-zxipv6wry": "ZX IPv6",
        "appdpi-cdn": "CDN 厂商库",
    }
    for f in files:
        mark = "有变化" if f["changed"] else "无变化"
        up = f["upstream_version"] or "-"
        if f["upstream_date"]:
            up += f" / {f['upstream_date']}"
        pkg_cell = []
        if not by_key and args.allow_incomplete:
            # 没变化的那天根本不打包，别说成「缺」
            pkg_cell = ["无变化，未打包"]
        else:
            for fmt in FORMATS:
                a = by_key.get((f["package"], fmt))
                if not a:
                    pkg_cell.append(f"{fmt} 缺")
                    continue
                tag = "新打包" if a.get("origin") == "built" else "沿用"
                pkg_cell.append(f"{fmt} `{a.get('version') or '-'}`（{tag}）")
        if f["status"] != "ok":
            pkg_cell = ["抓取失败，沿用上一版"]
        lines.append(
            f"| `{f['package']}`（{up_names.get(f['package'], '-')}） | `{f['file']}` → `{f['path']}` "
            f"| {mark} | {human(f['bytes'])} | {up} | {'；'.join(pkg_cell)} |"
        )
    lines += [
        "",
        (
            f"版本号 `{version}` 是「数据日期 + 重出序号」：同一天重出时序号递增，"
            "opkg 与 apk 都认这个形式，升级不会被「版本一样」挡住。"
        ),
        "",
        "```sh",
        "# 24.10 及更早（opkg）",
        "opkg install ./appdpi-geoip-qqwry.ipk",
        "",
        "# 25.12 及更新（apk）",
        "apk add --allow-untrusted ./appdpi-geoip-qqwry.apk",
        "```",
        "",
        (
            "包没有签名证书，apk 需要 `--allow-untrusted` 才会装；装之前用 "
            "`apk verify ./appdpi-geoip-qqwry.apk` 核对内容完整。"
        ),
        "",
        (
            "`manifest.json` 记录了每份数据的 sha256、大小与上游版本，"
            "下一轮构建拿它当「上一版」比对，判断哪份数据真的变了。"
        ),
    ]
    if failed:
        lines += ["", "### 本次抓取失败", ""]
        for f in failed:
            lines.append(f"- `{f['package']}`：{f['error'] or '原因未知'}")
        lines += [
            "",
            (
                "失败项没有新数据，两种格式的资产都沿用上一版；其余数据照常发布。"
                "校验（格式/体积突变）没有失败的项，失败的是下载环节。"
            ),
        ]
    # 不发布的那天（--allow-incomplete）本来就没有资产清单，别把它说成缺资产
    if missing and not args.allow_incomplete:
        lines += ["", "### 缺少资产（不该出现）", ""]
        for name in missing:
            lines.append(f"- `{name}`：没有产物，发布不完整")

    notes = dist / "release-notes.md"
    notes.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"manifest：{out}（{len(files)} 份数据，{len(manifest['assets'])} 个资产）")
    print(f"Release 说明：{notes}")

    if args.allow_incomplete:
        return 0
    if missing:
        print(f"有包没有资产：{', '.join(missing)}——不发布", file=sys.stderr)
        return 1
    if len(files) != 5:
        print(f"数据文件不是 5 份（{len(files)} 份），不发布", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
