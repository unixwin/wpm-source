# WPM 仓库规划草案(待发 ISSUE)

> 状态:草案。目标仓库见文末;发布前需按 `gh` 认证情况落地。

## 背景

- 当前官方索引 `index.json`:123 包,121 可安装,2 个 index-only(`gawk`、`ncat`),校验 0 问题。
- 痛点:
  1. `gawk` 有 ezwinports 可移植构建,但上游在 SourceForge(本环境直链 403);`ncat` 上游无独立 Windows 构建,需自行编译。
  2. GNU/MSYS2 工具捆绑 DLL(libintl-8.dll、libiconv-2.dll、libgmp、libmpfr、libssl …),平铺进 `usr\bin` 会污染全局 PATH 并产生跨包 DLL 冲突(此前 `make`/`socat` 因此无法入库)。
  3. TUI/GUI 前端依赖稳定 JSON 契约,`wpm` 部分子命令仍无 `--json`。

## 一、自托管构件:新仓库 `unixwin/wpm-artifacts`

目标:为"上游不稳定 / 被墙 / 无官方构建"的包提供带 SHA-256 的可移植二进制,统一托管在 GitHub Releases。

模式(每个包一个 GitHub Actions workflow):

| 包 | 策略 | 说明 |
|---|---|---|
| `gawk` | 镜像 | CI 从 ezwinports(SourceForge)下载 `gawk-5.4.x-windows-binaries.zip`(自带 gmp/mpfr/iconv/intl DLL),校验后重新发布到 `wpm-artifacts` releases;生成 sha256+size 清单 |
| `ncat` | 编译 | CI 用 MSYS2/MinGW 从 nmap 源码构建 `ncat`,openssl 静态或内置,打包 zip + sha256;发布到 releases |
| `make`(后续) | 镜像 | ezwinports 构建,捆绑 libintl-8.dll / libiconv-2.dll 后入库 |
| `socat`(后续) | 编译 | MinGW 静态构建,替代之前缺失 cygwin1.dll 的失败尝试 |

要点:
- 每个 release 附 `sha256.txt`(构件哈希)与 `size`(字节),供 `scripts/update-package.ps1` / 自动化流程直接消费。
- 二进制校验在 CI 与索引侧双重验证;入库前人工 review(等价于 index-only 槽位的"reviewed"门槛)。
- 仓库同时承载"重新打包脚本"(`repackage/`):从 msys2/ezwinports 提取 exe+DLL 并验证 DLL 依赖完备(用 `objdump -p` 遍历导入表),保证缺 DLL 的包不再出现。

## 二、SHIM 私享目录布局(DLL 隔离)

问题:多文件 / 带 DLL 的包平铺安装会污染全局 PATH 并导致跨包 DLL 版本冲突。

方案(scoop 式 shim):
- 安装布局:`usr\bin\<pkg>\`(exe + 全部 DLL 的私有目录)。
- `usr\bin\<cmd>.exe` 为转发器 shim(原生 exe,数 KB):启动 `usr\bin\<pkg>\<cmd>.exe`,继承环境变量与退出码。
- 真正 exe 与 DLL 同目录,DLL 解析零成本、无需 PATH 注入;全局 PATH 只多一个 shim 文件名。
- `wpm links list` / `commands` 仍暴露 `<cmd>`;卸载 = 删私有目录 + 删 shim。

索引契约:
- `artifacts.<platform>.layout`:可选,`flat`(默认)| `shim`;或由 wpm 自动判定(文件列表含 `.dll` 即走 shim)。
- 建议显式 `layout` 字段,便于 TUI 展示与安装逻辑明确。
- 依赖 DLL 的包因此全部可入库:`gawk`(gmp/mpfr/iconv/intl)、`make`(intl/iconv)、`socat` 等。

边界:
- exe 只找自身目录 DLL → 天然满足;仅自身 PATH 解析的子进程场景无需处理。
- 兄弟工具互调(如 `xz`→`xzdec`):兄弟命令同样生成 shim,依赖方通过 PATH 找到 shim,行为一致。

## 三、TUI / GUI 路线

架构:单一 `index.json` 为唯一事实源;CLI(`wpm`)、TUI、GUI 全部消费同一数据,JSON 契约见 `docs/index-schema.md`。

- **winuxcmd(WinuxCmd 仓库)补 JSON 契约**:为 `wpm installed`、`wpm index status`、`wpm links list` 增加 `--json`;稳定输出字段(与 list/search/info 对齐)。
- **TUI:新仓库 `unixwin/wpm-tui`**(Rust + ratatui 或 Go + bubbletea):浏览/搜索/安装/卸载/更新,分类筛选、详情面板、links 管理。数据经 `wpm --json` 读取,变更经调用 `wpm` 执行。
- **GUI:新仓库 `unixwin/wpm-gui`**(Rust + egui / Tauri,或本地 Web 面板):置于 TUI 之后,依赖 schema 与 TUI 成熟度。

## 里程碑

- M1(本 issue 可执行部分):wpm-artifacts 落地(gawk 镜像 + ncat 编译)→ 填回两个 index-only 槽位;winuxcmd 落地 shim 布局;索引加 `layout` 字段;`make` 随 shim 一起入库。
- M2:winuxcmd 补齐 `--json` 契约 → wpm-tui 首版。
- M3:wpm-gui。

## 涉及仓库一览

| 仓库 | 职责 | 变更 |
|---|---|---|
| `unixwin/wpm-source`(本仓库) | 索引 + 脚本 + 文档 | `layout` 字段;gawk/ncat 构件落地;`docs/index-schema.md` 补 shim 说明 |
| `unixwin/wpm-artifacts`(新) | 自托管二进制 + CI 构建/镜像 + sha256 清单 | gawk / ncat / make(后续) |
| `unixwin/WinuxCmd` | wpm 本体 | shim 转发器与安装布局;`--json` 补全 |
| `unixwin/wpm-tui`(新) | TUI 客户端 | M2 |
| `unixwin/wpm-gui`(新) | GUI 客户端 | M3 |

## 待确认

1. issue 发到哪个仓库(`unixwin/wpm-source` 还是新建规划仓库)。
2. shim 用原生转发器(winuxcmd 自带)还是 `.cmd` 兜底。
3. `layout` 用显式字段还是自动判定。