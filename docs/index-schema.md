# WPM 官方源数据结构

本文档描述 `index.json`(WPM 官方包索引)的结构,以及 `wpm` 命令 `--json` 输出的契约。可用于构建基于 JSON 的 GUI / TUI 前端。

## 1. index.json 顶层

```jsonc
{
  "schema": 1,                    // 索引 schema 版本(当前为 1)
  "name": "official",             // 源名称
  "version": "official-2026.08.20", // 源版本(日期后缀)
  "updated": "2026-08-20",        // 索引更新日期
  "sources": [ Source ... ],      // 该索引对应的上游镜像源
  "packages": [ Package ... ]     // 包列表
}
```

### Source

```jsonc
{
  "name": "official-github-raw",  // 源标识
  "region": "global",             // 适用区域: global | cn ...
  "priority": 10,                 // 数字越小优先级越高
  "description": "...",
  "homepage": "https://...",
  "index_urls": [ "https://..." ] // 该源可用的索引下载地址
}
```

### Package

```jsonc
{
  "name": "ripgrep",              // 包名(唯一,小写)
  "version": "15.2.0",            // 版本
  "description": "Fast recursive search tool.",
  "kind": "external",             // external | builtin | index-only ...
  "category": "search",           // 见下方 category 列表
  "license": "MIT OR Unlicense",  // SPDX 表达式
  "commands": [ "rg" ],           // 安装后暴露到 PATH 的命令名
  "artifacts": {                  // 按平台分组的安装包
    "windows-x64": Artifact,
    "windows-arm64": Artifact     // 可选
  }
}
```

已知 `category` 取值:`archive, backup, cloud, data, developer, document, editor, filesystem, i18n, interactive, media, navigation, network, search, security, shell, system, terminal, text, viewer`。

### Artifact

```jsonc
{
  "type": "zip",                  // exe | zip
  "sha256": "71b2fe...",          // 构件 SHA-256(十六进制小写)
  "urls": [ "https://..." ],      // 下载地址(可多个,顺序尝试)
  "files": [                      // 从压缩包到安装目录的文件映射
    { "from": "rg.exe", "to": "rg.exe" }
  ],
  "size": 1789611,                // 构件字节数(可选,新增包均填充)
  "layout": "shim"                // 可选:flat(默认)| shim
}
```

`files[].from` 是压缩包内相对路径,`files[].to` 是安装后的目标文件名(可省略路径)。多文件包(如 `sysinternals-suite` 含 151 个 exe、`qpdf` 含 qpdf.exe + VC 运行库 DLL)在此完整枚举。

### layout 字段

- `flat`(默认):所有映射文件直接装入 `usr\bin\`,适用于单 exe 包。
- `shim`:载荷(exe + 私有 DLL)自包含安装到 `<root>\opt\<pkg>\`;`usr\bin\<cmd>.exe` 是 winuxcmd.exe 自身的硬链接,运行时由分发器转发到 `opt\<pkg>\<cmd>.exe`。DLL 与真 exe 同目录,天然解析、无跨包冲突;卸载即删目录。适用于带 DLL 或多文件的包(ncat/qpdf/gawk/curl/xz/bzip2/sysinternals-suite)。

## 2. wpm --json 输出契约

`--json` 输出为纯 JSON(机器可读),不混入人类可读文本。

### wpm list --json / wpm search <q> --json

```jsonc
{
  "all": false,          // 是否列出全部(含 index-only)
  "category": "",        // 按 category 过滤时的值
  "hidden": 2,           // 被隐藏(如 index-only)的包数量
  "matched": 104,        // 本次命中的包数量
  "packages": [ ... ]    // 摘要包列表,见下方「摘要包」
}
```

每项为「摘要包」:

```jsonc
{
  "name": "winuxcmd",
  "version": "0.16.6",
  "description": "WinuxCmd core command set",
  "kind": "external",
  "category": "i18n",
  "license": "MIT",
  "commands": [ "winuxcmd", "wpm" ],
  "installed": true,           // 本机是否已安装
  "install_state": "ready",    // ready | ...(安装相关状态)
  "state": "ready",            // 包状态
  "artifact": {                // 摘要构件信息(非完整 Artifact)
    "arch": "windows-x64",
    "type": "zip",
    "file_count": 1,
    "url_count": 1,
    "sha256_present": true,
    "size": 69357              // 仅当索引提供了 size 时存在
  }
}
```

### wpm info <pkg> --json

返回完整 Package,并附加 `wpm` 包装字段:

```jsonc
{
  // ...完整 Package 字段(name/version/description/kind/category/license/commands/artifacts)
  "wpm": {
    "name": "ripgrep",
    "version": "15.2.0",
    "description": "...",
    "kind": "external",
    "category": "search",
    "license": "MIT OR Unlicense",
    "commands": [ "rg" ],
    "installed": true,
    "install_state": "ready",
    "state": "ready",
    "artifact": {
      "arch": "windows-x64",
      "type": "zip",
      "file_count": 1,
      "url_count": 1,
      "sha256_present": true
    }
  }
}
```

## 3. 已知限制(供 TUI 前端参考)

- `wpm list --json` 与 `wpm search --json` 顶层返回 `matched`/`hidden` 计数 + `packages` 摘要列表;`wpm info --json` 返回完整包 + `wpm` 运行期状态。
- `wpm installed`、`wpm index status`、`wpm links list` 目前**不支持** `--json`(需在 winuxcmd 仓库侧补输出支持)。
- 摘要包里的 `artifact` 不含 `files`/`urls` 完整内容;需要下载细节时请用 `wpm info`。

## 4. 校验与生成脚本

| 脚本 | 用途 |
|---|---|
| `scripts/validate-index.ps1` | 校验 index.json 结构、SHA 摘要、包与命令引用一致性;输出 Packages / Installable / Index-only / Issues |
| `scripts/update-package.ps1` | 新增/更新单个包;自动计算 SHA256(下载)与 size(HEAD Content-Length);支持多文件映射 `-Files "from=to" ...` |
| `scripts/backfill-size.ps1` | 对缺失 `size` 的包通过 HEAD 请求回填字节数 |