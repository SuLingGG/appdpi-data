#!/usr/bin/env python3
"""把 nali 的 cdn.yml 转成引擎读的纯文本。

SPDX-License-Identifier: GPL-2.0-only

输入：cdn.yml（4ft35t/cdn，nali 用的那份），结构是
    <域名后缀或正则>:
      name: 厂商名
      link: 官网
输出：每行 `s<TAB>厂商名<TAB>后缀` 或 `r<TAB>厂商名<TAB>正则`。

输入取 4ft35t/cdn 的 cdn.yml，产出本仓库 appdpi-cdn 包里的 cdn.txt。
转换逻辑要跟引擎读 cdn.txt 的判据对齐（r 行按正则、s 行按后缀），改动
两边要一起改。

为什么用自定义格式而不是留 YAML：引擎是 C，不想为 325 条数据拖一个 YAML
解析器；转换放在构建侧（脚本 + 转换产物入库），运行时只读定长行。
"""

import argparse
import re
import sys
from pathlib import Path

# YAML 里可能出现的正则元字符；与 nali 的 MaybeRegexp 判据保持一致：
# 出现这些字符就当正则处理，否则按后缀精确匹配。
_REGEX_HINT = re.compile(r"[\\()*+?\[\]|^$]")


def parse_yaml(text: str) -> list[tuple[str, str]]:
    """只解析 cdn.yml 用到的那一小撮结构，不引入 PyYAML。"""
    out: list[tuple[str, str]] = []
    key: str | None = None
    for raw in text.splitlines():
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[0].isspace():
            if not line.rstrip().endswith(":"):
                continue
            key = line.rstrip()[:-1].strip().strip("\"'")
            continue
        stripped = line.strip()
        if key and stripped.startswith("name:"):
            name = stripped[len("name:") :].strip().strip("\"'")
            if name:
                out.append((key, name))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("yaml", type=Path, help="cdn.yml 路径")
    ap.add_argument("-o", "--output", type=Path, help="输出文件（缺省写 stdout）")
    args = ap.parse_args()

    entries = parse_yaml(args.yaml.read_text(encoding="utf-8"))
    if not entries:
        print("没有解析到条目，cdn.yml 格式可能变了", file=sys.stderr)
        return 1

    lines = [
        "# appdpi CDN 厂商库",
        "# 由 tools/cdn_convert.py 从 nali 的 cdn.yml（4ft35t/cdn）转换而来，勿手改。",
        "# 格式：s<TAB>厂商<TAB>域名后缀 / r<TAB>厂商<TAB>正则",
    ]
    seen: set[str] = set()
    for key, name in entries:
        name = name.replace("\t", " ")
        kind = "r" if _REGEX_HINT.search(key) else "s"
        row = f"{kind}\t{name}\t{key.lower()}"
        if row in seen:
            continue
        seen.add(row)
        lines.append(row)

    text = "\n".join(lines) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
        print(f"写入 {args.output}：{len(entries)} 条", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
