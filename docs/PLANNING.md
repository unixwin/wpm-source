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
| `gawk` | 镜像 | CI 从 ezwinports(SourceForge)下载 `gawk-5.4.1-w32-bin.zip`(2026-07 更新,自带全部 DLL),校验后重新发布到 `wpm-artifacts` releases;生成 sha256+size 清单。**注意:w32 = 32 位构建,x64 经 WOW64 运行**,描述需注明 |
| `ncat` | 编译 | CI 用 MSYS2/MinGW 从 `github.com/nmap/nmap`(官方镜像,已验证可达)按 tag `nmap-<ver>` 构建 `ncat`,openssl 内置,打包 zip + sha256;发布到 releases |
| `make`(后续) | 镜像 | ezwinports `make-4.4.1-without-guile-w32-bin.zip`(392KB),捆绑 Dependencies 目录的 libintl-8.dll / libiconv-2.dll 后入库 |
| `socat`(后续) | 编译 | MinGW 静态构建,替代之前缺失 cygwin1.dll 的失败尝试 |

> 草案已落地:`D:\repo\wpm-artifacts`(README + mirror-gawk.yml + build-ncat.yml + repackage/check-dll-deps.sh / collect-dlls.sh),建仓后直接推送即可跑。

要点:
- 每个 release 附 `sha256.txt`(构件哈希)与 `size`(字节),供 `scripts/update-package.ps1` / 自动化流程直接消费。
- 二进制校验在 CI 与索引侧双重验证;入库前人工 review(等价于 index-only 槽位的"reviewed"门槛)。
- 仓库同时承载"重新打包脚本"(`repackage/`):从 msys2/ezwinports 提取 exe+DLL 并验证 DLL 依赖完备(用 `objdump -p` 遍历导入表),保证缺 DLL 的包不再出现。

## 二、SHIM 私享目录布局(DLL 隔离)

问题:多文件 / 带 DLL 的包平铺安装会污染全局 PATH 并导致跨包 DLL 版本冲突。

方案(自硬链接 shim,FHS 化布局,已实现于 WinuxCmd PR #169):

安装布局(依据 Windows DLL 搜索顺序:exe 目录 → System32 → … → PATH,故真身自包含即可零配置解析):

```
winuxcmd\
├── usr\bin\          仅命令入口:单 exe 包平铺;shim 包的 <cmd>.exe 是 winuxcmd.exe 自身的硬链接
└── opt\<pkg>\        自包含载荷(exe + 私有 DLL),如 opt\ncat\{ncat.exe, libssl-3.dll, ...}
```

- **无独立 shim 二进制**:分发保持单文件 winuxcmd.exe;分发器(main)对非内置命令名转发到 `opt\<pkg>\<cmd>.exe`(先查同名目录,再扫描 opt/ 一层),继承参数/退出码。
- usr\bin 每个条目都硬链接唯一规范文件(winuxcmd.exe),与既有 links 体系完全同构;升级随主程序自动同步。
- 真 exe 与 DLL 同目录,DLL 解析零成本、无需 PATH 注入;全局 PATH 只多一个硬链接名。
- 不采用"DLL 放 usr\lib + 加 PATH":System32 先于 PATH 被搜索,同名系统 DLL 会静默遮蔽;且重新污染全局 PATH。
- 文档/man 不装到 usr\share,保留在 `opt\<pkg>\` 内:卸载 = 删目录 + 删链接,一删全清。

索引契约:
- `artifacts.<platform>.layout`:显式字段,`flat`(默认)| `shim`;`wpm list/info --json` 的 artifact 摘要已暴露该字段。
- 已标记 shim:ncat / qpdf / gawk / curl / xz / bzip2 / sysinternals-suite。
- 依赖 DLL 的包因此全部可入库:`make`(intl/iconv)、`socat` 等后续可加。

### 迁移(存量用户)

无需脚本,分三步自然完成:

1. **升级 winuxcmd.exe**:新分发器向后兼容 —— 转发只对"非内置名且 opt 载荷存在"生效,老安装零影响。
2. **索引自动更新**:layout 字段随 official index 下发;旧版 wpm 忽略未知字段仍按 flat 安装(优雅降级),新版 wpm 正确落 opt。
3. **按需迁移单个包**:`wpm install --force <pkg>` 一步完成 —— 载荷进 `opt\<pkg>\`、创建自硬链接 shim、清理 usr\bin 中字节一致的旧 flat 残留(内容不一致的文件属于其他包,绝不误删)。

兼容性说明:winuxsh 无需任何同步(shim 就是 usr\bin 普通文件);PATH 契约不变(opt 不进 PATH);`wpm links rebuild/remove` 只操作内置名单,不触碰包 shim。

边界:
- exe 只找自身目录 DLL → 天然满足;仅自身 PATH 解析的子进程场景无需处理。
- 兄弟工具互调(如 `xz`→`xzdec`):兄弟命令同样生成 shim,依赖方通过 PATH 找到 shim,行为一致。

## 三、TUI / GUI 路线

架构:单一 `index.json` 为唯一事实源;CLI(`wpm`)、TUI、GUI 全部消费同一数据,JSON 契约见 `docs/index-schema.md`。

- **winuxcmd(WinuxCmd 仓库)补 JSON 契约**:为 `wpm installed`、`wpm index status`、`wpm links list` 增加 `--json`;稳定输出字段(与 list/search/info 对齐)。
- **TUI:新仓库 `unixwin/wpm-tui`**(Rust + ratatui 或 Go + bubbletea):浏览/搜索/安装/卸载/更新,分类筛选、详情面板、links 管理。数据经 `wpm --json` 读取,变更经调用 `wpm` 执行。
- **GUI:新仓库 `unixwin/wpm-gui`**(Rust + egui / Tauri,或本地 Web 面板):置于 TUI 之后,依赖 schema 与 TUI 成熟度。

## 四、Toolchain 层与生态化评估(已决策,2026-08-21)

将范围从"纯 shell 工具"扩展为两层:**shell 工具(flat)+ 可重定位工具链(shim)**。

### 准入标准(toolchain 层,全部满足才收)
1. 自包含可移植压缩包(**排除** rustup-init 式运行时下载器)
2. 可重定位:在 `opt\<pkg>\` 内即可运行,无需机器级全局设置
3. 官方 release 或 wpm-artifacts CI 构建,SHA-256 固定
4. 许可证允许再分发

**仍排除**:GUI、MSI/MSIX、服务/驱动、conda/vcpkg 等不可重定位环境、MSVC/Windows SDK(不可再分发)、winget/scoop/choco 类"装软件的软件"。

### 为什么 shim 架构是关键
工具链的历史痛点(DLL 地狱、PATH 污染、多版本冲突)恰好被 `opt\<pkg>\` 私享目录 + 自硬链接转发解决;sha256 钉死则给出 scoop/winget 都没有的**可复现安装**。

### 首批试点(已入库)
| 包 | 形态 | 说明 |
|---|---|---|
| uv 0.12.5 | 单静态 exe | Python 项目管理,替代 pip/venv 全家桶 |
| deno 2.9.5 | 单静态 exe | TS/JS 运行时一体化 |
| bun 1.4.0 | 单静态 exe | JS 运行时+打包+测试+包管理 |

后续候选(按迁移成本):go(官方 zip 直接可用)、python(python-build-standalone)、node(官方 zip)、temurin-jdk(zip)、llvm+mingw-w64(NSIS 解包或 CI 构建,~1GB)。

### 生态定位
与 winget(包装安装器、无钉版)/scoop(弱校验、全局 shim)的差异点:**可复现 + 私享隔离 + unix 工具集一体 + 国内镜像友好**。多版本共存(`pkg@version`)作为二期。

## 里程碑

- M1(已完成):wpm-artifacts 落地(gawk/ncat);shim 布局进 WinuxCmd 0.17.0;`layout` 字段与迁移逻辑;toolchain 层开闸(uv/deno/bun 试点)。
- M2(进行中):winuxcmd `--json` 契约已齐;env-sync 插件已合并;下一步 wpm-tui 首版。
- M3:wpm-gui;工具链多版本共存(`pkg@version`)。

## 涉及仓库一览

| 仓库 | 职责 | 变更 |
|---|---|---|
| `unixwin/wpm-source`(本仓库) | 索引 + 脚本 + 文档 | `layout` 字段;gawk/ncat 构件落地;`docs/index-schema.md` 补 shim 说明 |
| `unixwin/wpm-artifacts`(新) | 自托管二进制 + CI 构建/镜像 + sha256 清单 | gawk / ncat / make(后续) |
| `unixwin/WinuxCmd` | wpm 本体 | shim 转发器与安装布局;`--json` 补全 |
| `unixwin/wpm-tui`(新) | TUI 客户端 | M2 |
| `unixwin/wpm-gui`(新) | GUI 客户端 | M3 |

## 决议与进展

1. issue 发到 `unixwin/wpm-source`(本文档即正文)。
2. shim 采用**原生转发器 exe**(随 winuxcmd 分发),`.cmd` 仅作兜底方案。
3. `layout` 采用**显式字段**(`flat` 默认 | `shim`),便于 TUI 展示与安装逻辑明确。
4. `unixwin/wpm-artifacts` 已建仓并推送骨架;gawk 5.4.1 镜像 workflow 已触发。