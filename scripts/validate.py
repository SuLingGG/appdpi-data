#!/usr/bin/env python3
"""五份数据文件的结构校验。坏包绝不发布。

SPDX-License-Identifier: GPL-2.0-only

校验分两层：
  1. 格式本身能不能用 —— 按各库自己的头部约定判断（xdb 看 2 字节版本号、
     qqwry 看索引区偏移、zxipv6wry 看魔数、cdn 看行格式与正则可编译性）。
  2. 这份数据像不像「完整的一份」 —— 与上一版比体积，防截断、防换源。

每项检查打一行 `OK/FAIL <文件>: <原因>`。任何一行 FAIL，退出码就是 1，
后面的打包与发布步骤不会被执行。

用法：scripts/validate.py [--dist DIR] [--prev-manifest FILE] [--tsv FILE]
"""

import argparse
import json
import re
import struct
import subprocess
import sys
import time
from pathlib import Path

# xdb 的最小体量：v4 库实测 11.1MB、v6 37.3MB。给一个远低于真实值的下限，
# 只为挡住「下载被截断」这种明显损坏。
XDB_MIN_BYTES = 524544
XDB_VERSIONS = {2, 3}

CDN_MIN_ROWS = 300
CDN_ROW = re.compile(r"^[sr]\t.+\t.+$")

# 体积突变阈值：单份数据相对上一版涨跌超过这个比例就报错
SIZE_SWING = 0.40


class Report:
    """逐条收集 OK/FAIL，顺便把结果写成 dist/validate.json。"""

    def __init__(self) -> None:
        self.checks: list[dict] = []

    def ok(self, file: str, reason: str) -> None:
        self._emit("OK", file, reason, True)

    def fail(self, file: str, reason: str) -> None:
        self._emit("FAIL", file, reason, False)

    def skip(self, file: str, reason: str) -> None:
        print(f"SKIP {file}: {reason}")

    def _emit(self, tag: str, file: str, reason: str, good: bool) -> None:
        print(f"{tag} {file}: {reason}")
        self.checks.append({"file": file, "ok": good, "reason": reason})

    @property
    def failed(self) -> int:
        return sum(1 for c in self.checks if not c["ok"])

    @property
    def passed(self) -> int:
        return sum(1 for c in self.checks if c["ok"])


def le32(buf: bytes, off: int) -> int:
    return struct.unpack_from("<I", buf, off)[0]


def size_label(n: int) -> str:
    return f"{n} 字节（{n / 1048576:.1f} MiB）"


# ------------------------------------------------------------------ 格式判据


def check_xdb(path: Path, rep: Report) -> None:
    name = path.name
    size = path.stat().st_size
    with path.open("rb") as f:
        head = f.read(2)

    if len(head) < 2:
        rep.fail(name, "文件短于 2 字节，读不出 xdb 版本号")
        return
    ver = int.from_bytes(head, "little")
    if ver in XDB_VERSIONS:
        rep.ok(name, f"xdb 头部版本 {ver}（合法值 2/3）")
    else:
        rep.fail(name, f"xdb 头部版本 {ver}，不在 {{2, 3}} 内（前 2 字节 LE）")

    if size >= XDB_MIN_BYTES:
        rep.ok(name, f"体量 {size_label(size)} ≥ 下限 {XDB_MIN_BYTES}")
    else:
        rep.fail(name, f"体量只有 {size} 字节，低于下限 {XDB_MIN_BYTES}（疑似截断）")


def check_qqwry(path: Path, rep: Report) -> None:
    """按纯真库自己的索引结构判断：头 8 字节是两个小端偏移 start/end。

    合法库必须 start < end、end+7 落在文件内、索引区长度是 7 的整数倍
    （每条索引 7 字节）。纯真库是 GBK 二进制，只能按字节读，绝不能按
    UTF-8 解码。
    """
    name = path.name
    size = path.stat().st_size
    with path.open("rb") as f:
        hdr = f.read(8)
    if len(hdr) < 8:
        rep.fail(name, "文件短于 8 字节，读不出索引区偏移")
        return

    start = le32(hdr, 0)
    end = le32(hdr, 4)

    if start < end:
        rep.ok(name, f"索引区偏移递增（start={start}, end={end}）")
    else:
        rep.fail(name, f"索引区偏移不递增（start={start}, end={end}）")
        return

    if end + 7 <= size:
        rep.ok(name, f"末条索引落在文件内（{end}+7 ≤ {size}）")
    else:
        rep.fail(name, f"末条索引越界（{end}+7 > {size}）")

    if (end - start) % 7 == 0:
        segs = (end - start) // 7 + 1
        rep.ok(name, f"索引区长度是 7 的整数倍（{segs} 条记录）")
    else:
        rep.fail(name, f"索引区长度 {(end - start)} 不是 7 的倍数")


def check_zxipv6wry(path: Path, rep: Report, member: str) -> None:
    name = path.name
    with path.open("rb") as f:
        magic = f.read(4)

    if magic == b"IPDB":
        rep.ok(name, "魔数 IPDB 正确")
    else:
        rep.fail(name, f"魔数不是 IPDB（读到 {magic!r}）")

    if member == "ipv6wry.db":
        rep.ok(name, "7z 内取出的成员名是 ipv6wry.db")
    elif member:
        rep.fail(name, f"7z 内取出的成员名是 {member!r}，必须是 ipv6wry.db")
    else:
        rep.fail(name, "没有记录 7z 成员名（应为 ipv6wry.db），无法确认取的是哪个库")


def check_cdn(path: Path, rep: Report) -> None:
    name = path.name
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as e:
        rep.fail(name, f"不是合法 UTF-8：{e}")
        return

    rows = [l for l in text.splitlines() if l.strip() and not l.startswith("#")]
    if len(rows) >= CDN_MIN_ROWS:
        rep.ok(name, f"数据行 {len(rows)} 行 ≥ {CDN_MIN_ROWS}")
    else:
        rep.fail(name, f"数据行只有 {len(rows)} 行，少于 {CDN_MIN_ROWS}")

    bad = [l for l in rows if not CDN_ROW.match(l)]
    if bad:
        rep.fail(name, f"{len(bad)} 行不是 `[sr]<TAB>厂商<TAB>键`格式，例：{bad[0]!r}")
    else:
        rep.ok(name, f"{len(rows)} 行全部符合 `[sr]<TAB>厂商<TAB>键`")

    # 引擎用 POSIX 正则匹配 r 行，所以这里的编译判据也必须是 grep -E
    # （不是 Python 的 re：两者语法不完全一样）。
    bad_re = []
    for row in rows:
        if not row.startswith("r\t"):
            continue
        pattern = row.split("\t", 2)[2]
        # 退出码 2 = 正则语法错；0/1 = 能编译（命中/没命中都算通过）
        rc = subprocess.run(
            ["grep", "-E", "-e", pattern, "/dev/null"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode
        if rc not in (0, 1):
            bad_re.append(pattern)
    n_re = sum(1 for r in rows if r.startswith("r\t"))
    if bad_re:
        rep.fail(name, f"{len(bad_re)} 条 r 行正则过不了 grep -E，例：{bad_re[0]!r}")
    else:
        rep.ok(name, f"{n_re} 条 r 行正则都能被 grep -E 编译")


# ------------------------------------------------------------------ 主流程


def load_entries(tsv: Path) -> list[dict]:
    rows = tsv.read_text(encoding="utf-8").splitlines()
    if not rows:
        raise SystemExit(f"{tsv} 是空的：先跑 scripts/fetch.sh")
    head = rows[0].split("\t")
    out = []
    for line in rows[1:]:
        if not line.strip():
            continue
        out.append(dict(zip(head, line.split("\t"))))
    return out


def load_prev(path: Path) -> dict[str, dict]:
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    return {f.get("package", ""): f for f in data.get("files", [])}


def main() -> int:
    ap = argparse.ArgumentParser(description="五份数据文件的结构校验")
    ap.add_argument("--dist", type=Path, default=Path("dist"), help="产物目录")
    ap.add_argument(
        "--prev-manifest", type=Path, default=None, help="上一版 manifest.json"
    )
    ap.add_argument(
        "--tsv", type=Path, default=None, help="fetch.tsv（默认 <dist>/fetch.tsv）"
    )
    args = ap.parse_args()

    dist: Path = args.dist
    tsv: Path = args.tsv or dist / "fetch.tsv"
    prev_path: Path = args.prev_manifest or dist / "manifest.prev.json"

    entries = load_entries(tsv)
    prev = load_prev(prev_path)
    if prev:
        print(f"# 上一版 manifest：{prev_path}（{len(prev)} 份记录）")
    else:
        print(f"# 没有上一版 manifest（{prev_path}）：体积与版本对比项跳过")

    rep = Report()
    for e in entries:
        pkg = e.get("package", "")
        fname = e.get("file", "")
        path = dist / pkg / fname
        status = e.get("status", "")

        if status != "ok":
            rep.skip(fname, f"本次抓取失败，不校验（{e.get('error') or '原因未知'}）")
            continue
        if not path.is_file() or path.stat().st_size == 0:
            rep.fail(fname, f"文件不存在或为空：{path}")
            continue

        prev_e = prev.get(pkg, {})
        if pkg == "appdpi-geoip-ip2region-v4" or pkg == "appdpi-geoip-ip2region-v6":
            check_xdb(path, rep)
        elif pkg == "appdpi-geoip-qqwry":
            check_qqwry(path, rep)
        elif pkg == "appdpi-geoip-zxipv6wry":
            check_zxipv6wry(path, rep, e.get("archive_member", ""))
        elif pkg == "appdpi-cdn":
            check_cdn(path, rep)
        else:
            rep.fail(fname, f"没有为包 {pkg!r} 定义校验规则")
            continue

        # 体积突变保护：−40% 以上多半是被截断，+40% 以上多半是换了个源
        size = path.stat().st_size
        prev_bytes = prev_e.get("bytes") or 0
        if not prev_bytes:
            rep.skip(fname, "体积突变保护：上一版没有记录，本次跳过")
        else:
            delta = (size - prev_bytes) / prev_bytes
            if abs(delta) > SIZE_SWING:
                rep.fail(
                    fname,
                    f"体积相对上一版变化 {delta * 100:+.1f}%（{prev_bytes} → {size}），"
                    f"超过 ±{SIZE_SWING * 100:.0f}% 阈值",
                )
            else:
                rep.ok(
                    fname,
                    f"体积相对上一版变化 {delta * 100:+.1f}%（{prev_bytes} → {size}），在阈值内",
                )

    out = {
        "ok": rep.failed == 0,
        "validated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "checks": rep.checks,
    }
    (dist / "validate.json").write_text(
        json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    print()
    print(f"校验完成：{rep.passed} 项通过，{rep.failed} 项失败")
    if rep.failed:
        print("有 FAIL 项：不发布任何包。", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
