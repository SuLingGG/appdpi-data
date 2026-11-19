# appdpi-data

把 appdpi 依赖的五份数据（四个地理库 + CDN 库）打成 OpenWrt 数据包，由 GitHub
Actions 每天定时抓取、校验、打包并发布到 Releases。

每个包出两种格式，都由 OpenWrt 官方 SDK 现场编译：

| 目标系统 | 包管理器 | SDK | 产物 |
|---|---|---|---|
| OpenWrt 24.10 及更早 | opkg | `openwrt-24.10` | `appdpi-*.ipk` |
| OpenWrt 25.12 及更新 | apk-tools 3 | `openwrt-25.12` | `appdpi-*.apk` |

两种格式是**同一份包定义**（`packages/<包名>/control.in` + `layout`）生成的：
格式差异由 SDK 决定，不存在「ipk 改了、apk 忘了改」。数据本身来自上游，本仓库
只做「抓取 → 校验 → 打包 → 分发」。

本仓库只分发地理库与 CDN 库，不包含任何识别规则数据。

---

## 1. 安装

设备上已经装好 `appdpi` 本体。地理库四个包声明了 `Depends: appdpi`（数据只在引擎里有用）；
`appdpi-cdn` 不声明依赖——它是主包的依赖，反过来依赖主包就成环了。

```sh
# 24.10 及更早（opkg）
opkg install ./appdpi-geoip-qqwry.ipk

# 25.12 及更新（apk）
apk add --allow-untrusted ./appdpi-geoip-qqwry.apk
```

一次装五个：

```sh
# 24.10 及更早
opkg install ./appdpi-geoip-ip2region-v4.ipk ./appdpi-geoip-ip2region-v6.ipk \
             ./appdpi-geoip-qqwry.ipk ./appdpi-geoip-zxipv6wry.ipk ./appdpi-cdn.ipk

# 25.12 及更新
apk add --allow-untrusted ./appdpi-geoip-ip2region-v4.apk ./appdpi-geoip-ip2region-v6.apk \
             ./appdpi-geoip-qqwry.apk ./appdpi-geoip-zxipv6wry.apk ./appdpi-cdn.apk
```

`--allow-untrusted` 是必须的：包没有签名证书（本仓库不运营密钥），apk 默认拒绝
无签名来源。装之前可以先核对完整性：

```sh
apk verify ./appdpi-geoip-qqwry.apk     # 输出 "OK"
apk info -a ./appdpi-geoip-qqwry.apk    # 看包名/版本/依赖/安装到的路径
```

opkg 对文件名不敏感，改成 `qqwry.ipk` 也能装——包名在包内 `control` 里。
ipk 也可以先看内容：

```sh
tar -xzf appdpi-geoip-qqwry.ipk ./control.tar.gz
tar -xzOf control.tar.gz ./control      # Package/Version/Depends/Architecture
tar -xzf appdpi-geoip-qqwry.ipk ./data.tar.gz
tar -tzf data.tar.gz                     # 装到哪儿
```

**不装包、手动放文件也行**：把数据文件 `scp` 到表里那个路径，权限 `644`、
属主 `root:root`，然后重启 appdpi。效果与装包一样，只是包管理器不知道这份数据
是谁装的，之后 `opkg list-installed` / `apk list -I` 里没有它。

### 包名 ↔ 包内路径 ↔ 来源

| 包名（固定，不许改） | 包内路径 | 数据文件 | 大小（下载/解压后） | 来源（主 → 备） |
|---|---|---|---|---|
| `appdpi-geoip-ip2region-v4` | `/etc/appdpi/geoip/ip2region_v4.xdb` | ip2region_v4.xdb | 4.27MB / 11.1MB | jsDelivr → raw.githubusercontent |
| `appdpi-geoip-ip2region-v6` | `/etc/appdpi/geoip/ip2region_v6.xdb` | ip2region_v6.xdb | 7.26MB / 37.3MB | raw.githubusercontent → jsDelivr |
| `appdpi-geoip-qqwry` | `/etc/appdpi/geoip/qqwry.dat` | qqwry.dat | 13.0MB / 27.4MB | gh-proxy.com → ghfast.top → github.com |
| `appdpi-geoip-zxipv6wry` | `/etc/appdpi/geoip/zxipv6wry.db` | zxipv6wry.db（由 ip.7z 解出） | 0.57MB(7z) / 2.6MB | ip.zxinc.org/ip.7z（唯一源） |
| `appdpi-cdn` | `/etc/appdpi/cdn.txt` | cdn.txt（由 cdn.yml 转换） | 11KB | jsDelivr → raw.githubusercontent |

包名**不能改名**：设备上已有的安装、面板的依赖判断、用户脚本里的包名都指着它们。

抓取地址与主备顺序是实测出来的，没有另起一套：

- **v4 用 jsDelivr 主**、raw 兜底；**v6 反过来**——jsDelivr 对 GitHub 源有 20MB
  上限，37MB 的 v6 库会被回 403。
- **qqwry 先走能直接回源的镜像**：不少网络里 `github.com` TCP 超时，release
  资产还会再 302 到 `release-assets.githubusercontent.com`，一样不可达。
  直连留作最后兜底。这个文件是 GBK 二进制，脚本里绝不当文本处理。
- **zxipv6wry 上游只发 7z**，里面除了 `ipv6wry.db` 还塞了十几种语言的示例代码
  和另一个「只有国家」的库。CI runner 上有 7z，`7z e` 只取 `ipv6wry.db`。

---

## 2. 版本策略

`Version` 字段 = **数据日期 + 重出序号**：

```text
2026.11.18-r1     当天第一次出包
2026.11.18-r2     同一天重出（第二次）
```

opkg 与 apk 都认这个形式：`2026.11.18-r2 > 2026.11.18-r1`。日期用**北京日期**
（cron 也是按北京 02:00 定的），所以北京时间早上看到的就是当天。两种格式用同一个
版本号——同源于同一份数据，版本分开只会多一个对不上的维度。

**资产名固定，不带版本号**：

```text
appdpi-geoip-ip2region-v4.ipk  appdpi-geoip-ip2region-v4.apk
appdpi-geoip-ip2region-v6.ipk  appdpi-geoip-ip2region-v6.apk
appdpi-geoip-qqwry.ipk         appdpi-geoip-qqwry.apk
appdpi-geoip-zxipv6wry.ipk     appdpi-geoip-zxipv6wry.apk
appdpi-cdn.ipk                 appdpi-cdn.apk
```

这样 `https://github.com/<owner>/<repo>/releases/latest/download/appdpi-cdn.apk`
这种链接永远指向最新一份，README 和脚本里不用跟着版本号改。版本在包内元数据里，
`opkg list-installed` / `apk list -I` 能看到。

**只有数据真的变了才重打包**：五份文件抓下来先跟上一版 manifest 比 sha256，
没变的那份不打新包、版本号不动，Release 里沿用上一版的那个文件（见 §5）。

---

## 3. 升级会覆盖你手改过的数据文件

这五个包**不是** conffile（包里没有 `conffiles`），升级时包管理器直接用新文件
覆盖 `/etc/appdpi/…` 下的整份数据，**不会**问你、也不会留 `.opkg-new`。

原因很直接：这些是整份替换的数据集（IP 库、CDN 库），不是配置。逐行合并没有
意义，保留旧文件反而会让「升级了但数据还是旧的」这种最难查的问题出现。

所以：

- 不要手改这五个文件。要加自己的域名/CDN 条目，用 appdpi 自带的覆盖表
  （`/etc/appdpi/` 下独立文件），不要改包里那份。
- 真的要改，改完记得另存一份，下次升级会没。
- 关掉某份数据的自动升级：`opkg flag hold appdpi-geoip-qqwry`（opkg 支持
  hold，但面板升级时不一定尊重，最稳的办法是不装那个包）。

---

## 4. 回滚

Release 保留最近 **30 天**，tag 形如 `data-2026-11-18`，每个 tag 里是当天那十个
包（资产名不带版本号）。所以回滚就是装旧包里对应的那个文件：

```sh
# 1. 找到要回滚到哪一天
gh release list --repo <owner>/appdpi-data

# 2. 下载那天的包（资产名固定，从 tag 下载即可）
gh release download data-2026-11-10 --repo <owner>/appdpi-data \
   --pattern 'appdpi-geoip-qqwry.ipk'   # 25.12 上换成 .apk

# 3. 24.10 及更早：强制降级
opkg install --force-downgrade ./appdpi-geoip-qqwry.ipk

# 3. 25.12 及更新：apk 不接受自动降级，先卸再装旧的
apk del appdpi-geoip-qqwry
apk add --allow-untrusted ./appdpi-geoip-qqwry.apk

/etc/init.d/appdpi restart
```

没有 `gh` 的话，直接开
`https://github.com/<owner>/appdpi-data/releases/tag/data-2026-11-10` 下载。

不想走包管理器的话，`tar -xzf appdpi-geoip-qqwry.ipk ./data.tar.gz` 之后
`tar -xzf data.tar.gz -C /`（apk 用 `apk extract --destination /`），然后重启
appdpi——效果一样，只是包管理器的状态没跟着回退。

超过 30 天的旧包会被工作流删掉（`scripts/prune.sh`），要更长的保留期就把
`--days 30` 改大。

---

## 5. 每天跑，但只在有变化时出包

`on.schedule` 是 `0 18 * * *`（UTC）——**cron 只认 UTC**，18:00 UTC 才是北京时间
次日 02:00。写成 `0 2 * * *` 会变成北京时间上午 10 点。

为什么要天天跑却大多不出包，看实测的更新节奏：

| 数据 | 实测更新频率 | 说明 |
|---|---|---|
| `qqwry.dat` | **每周** | 上游几乎每周一个 release |
| `ip2region_v4/v6.xdb` | **1–3 周** | 上游按需更新，v6 更慢 |
| `cdn.txt` | **季度级** | cdn.yml 长期不动 |
| `zxipv6wry.db` | **2022-03 之后冻结** | 上游不再更新，正常情况永远 `changed=false` |

所以每天抓一遍、按 sha256 判断「变了没有」，变了才打包发布。否则每天发一个
「内容一样、版本号不同」的包，用户每次升级都在重写同一份几十 MB 的数据，还没法
从版本号看出到底有没有真更新。

判断依据是上一版 Release 里的 `manifest.json`：每份数据记着 sha256、字节数、
上游版本号与日期。没有上一版（首次运行）就当五份全变。

### 十个资产怎么保证齐全

某一份抓取失败、或者某一份没有变化时，那份数据**不重新打包**，而是把上一版
Release 里的同一个文件取回来（同一格式、核对 sha256 与上一版 manifest 一致才算
数），和本次新打的包一起发布。这样：

- 每次 Release 都恰好五个 ipk + 五个 apk，`releases/latest/download/xxx.apk`
  永远可用；
- 抓取失败只会让那一份停在上一个版本，不会连带把其它四份也挡住；
- 失败的项写在 Release 说明和 Workflow Summary 里，不会静默消失。

装配规则在 `scripts/assemble.sh`，按格式各跑一次；取回来的文件哈希对不上、或者
上一版根本没有那个资产，直接失败——宁可这天不发，也不发一个资产不全或混着来路
不明包的 Release。

### 校验不过就不发

`scripts/validate.py` 对五份文件做结构校验（每项打 `OK/FAIL <文件>: <原因>`），
任何一项 FAIL，job 就红、不打包、不发布：

| 数据 | 判据 |
|---|---|
| `*.xdb` | 前 2 字节 LE ∈ {2,3}；大小 ≥ 524544 |
| `qqwry.dat` | 头部两个 LE 偏移递增、`end+7 ≤ size`、`(end-start) % 7 == 0` |
| `zxipv6wry.db` | 4 字节魔数 `IPDB`；7z 里取的成员名必须是 `ipv6wry.db` |
| `cdn.txt` | 数据行 ≥ 300，每行 `^[sr]\t.+\t.+$`，`r` 行的正则能被 `grep -E` 编译 |
| 全部 | 单文件大小相对上一版变化超过 ±40% 报错（防截断、防换源） |

### 包是怎么编出来的

包定义只写在 `packages/<包名>/` 下（`control.in` 控制字段、`layout` 布局），
`tools/gen_sdk_packages.py` 把它们翻译成 SDK 认识的 Makefile，交给
`scripts/sdk-build-data.sh` 在官方 SDK 容器里编译。工作流里是两步 docker run：
24.10 的镜像出 ipk，25.12 的镜像出 apk，同一个脚本、同一份定义。

---

## 6. 在 GitHub 上要做三件事

仓库已经建好（`SuLingGG/appdpi-data`，public），推上去之后还有三步要在页面上做：

1. **确认仓库是 public**（`Settings → General → Danger Zone`）。
   私有的也能跑，但 Release 资产需要登录才能下载，设备上直接下 URL 用不了，
   匿名用户也看不到 `releases/latest/download/...` 这种固定链接。

2. **打开写权限**：`Settings → Actions → General → Workflow permissions` 选
   **Read and write permissions**。工作流要创建 Release、删 30 天前的旧 Release，
   只有 `contents: write` 才够；组织默认的 read-only 会让发布步骤报 403。

3. **手动跑一次**：`Actions → 每日数据包 → Run workflow`。
   定时任务在 fork/新建仓库上不保证立刻生效，先手动跑一次能确认整条链路通、
   也顺便把第一版 Release 建出来（首次没有上一版 manifest，五份都算变化）。

不需要配任何 secret：工作流用的是自动注入的 `GITHUB_TOKEN`。

---

## 7. 本地跑一遍（不打 Release）

需要 docker（或一个解好的 OpenWrt SDK）与网络。抓取要访问 jsDelivr /
raw.githubusercontent / gh-proxy / ip.zxinc.org，任一网络不通时会自动走备用源。

```sh
git clone <你的仓库> appdpi-data && cd appdpi-data

# 1) 抓五份数据（约 80MB 下载），算 sha256，与上一版比对
./scripts/fetch.sh

# 2) 校验（任何 FAIL 退出码非 0）
python3 scripts/validate.py --dist dist

# 3) 算版本号、生成 SDK 包定义
./scripts/version.sh "$(date +%Y.%m.%d)"
python3 tools/gen_sdk_packages.py --dist dist --version "$(cat dist/version.txt)"

# 4) 用两个 SDK 镜像各编一遍（磁盘上先放好 dist/ipk、dist/apk）
mkdir -p dist/ipk dist/apk && chmod 777 dist/ipk dist/apk
for sdk in 24.10 25.12; do
  fmt=ipk; [ "$sdk" = 25.12 ] && fmt=apk
  docker run --rm -e APPDI_DATA_DIR="$PWD/dist" -v "$PWD:$PWD" -w /builder \
    "ghcr.io/openwrt/sdk:x86_64-openwrt-$sdk" \
    /bin/sh -c "bash setup.sh && exec /bin/sh '$PWD/scripts/sdk-build-data.sh' '$PWD' '$PWD/dist/$fmt' $fmt"
  sudo chown -R "$(id -u):$(id -g)" dist
done

# 5) 核对产物（没有上一版 Release 时 assemble 会要求全部新打）
ls -l dist/ipk dist/apk
apk verify dist/apk/appdpi-geoip-qqwry.apk      # 需要 apk-tools 3，SDK 里有
tar -xzOf dist/ipk/appdpi-geoip-qqwry.ipk ./control.tar.gz | tar -xzO ./control
```

只编某几个包时，`gen_sdk_packages.py` 加 `--only 包名1,包名2`；编完注意
`dist/sdk-pkgs.list` 会跟着变成这一次要编的清单，`assemble.sh` 用它区分
「这次新打的」和「沿用的」。

`dist/` 不入库（`.gitignore` 已排除）：下载加上产物接近 100MB。

---

## 8. 目录结构

```text
.github/workflows/daily.yml       每天 02:00（北京）抓取/校验/打包/发布
packages/<包名>/control.in        包控制字段模板
packages/<包名>/layout            数据文件 → 包内路径 → 权限（打包布局的唯一来源）
tools/gen_sdk_packages.py         packages/ → SDK 包定义（ipk 与 apk 共用）
tools/cdn_convert.py              cdn.yml → cdn.txt
scripts/fetch.sh                  抓五份源（主备回退）、算 sha256、与上一版比对
scripts/validate.py               五种格式的结构校验 + 体积突变保护
scripts/version.sh                算本次版本号（YYYY.MM.DD-rN）
scripts/sdk-build-data.sh         在 SDK 容器里编出该 SDK 的包格式
scripts/assemble.sh               保证某种格式的五个资产齐全（没变的/失败的从上一版取回）
scripts/manifest.py               合成 manifest.json 与 Release 说明
scripts/prune.sh                  删 30 天前的 data-* Release
```

管线各步只写自己的中间产物（`fetch.tsv` / `validate.json` / `sdk-pkgs.list` /
`assets-ipk.tsv` / `assets-apk.tsv`），最后由 `manifest.py` 合成
`dist/manifest.json`。出问题时中间结果原样留在 `dist/` 里，可以一步一步复看，
不用去猜是哪一步写坏的。

## 9. 许可

脚本与打包定义：GPL-2.0-only（见 `COPYING` 与 `LICENSES/GPL-2.0`）。
五份数据文件各自沿用上游许可（Apache-2.0 / Free / GPL-2.0-only），逐项列在
`COPYING` 里。本仓库不重新分发数据：抓取地址与校验口径都在脚本里，包由 CI
现场生成。
