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
- `shim`:载荷(exe + 私有 DLL)自包含安装到 `<root>\opt\<pkg>\`;`usr\bin\<cmd>.exe` 是
  `winuxcmd-shim.exe`(轻量转发器)的硬链接,运行时读 `.wpm\shims.map` 把命令转发到
  `opt\<pkg>\` 下的载荷 exe 并透传退出码;`bin\<cmd>.exe` 则直接硬链接载荷本体。
  DLL 与真 exe 同目录,天然解析、无跨包冲突;卸载即删目录。适用于带 DLL 或多文件的包
  (ncat/qpdf/gawk/curl/xz/bzip2/sysinternals-suite)。

### shim 载荷解析与 runtime-tree 规则(issue #72)

载荷 exe 启动后,Windows 按它**自己所在目录**解析私有 DLL;RUNTIME_PREFIX 类构建
(git-for-windows 的 git.exe、rustc.exe 等)还按 exe 所在目录推算 exec-path、模板目录、
sysroot。因此 **shim 转发到哪个位置,哪个位置就必须是 exe 在其运行时树中的原位**:

1. **载荷解析**。wpm 为命令 `c` 注册 `shims.map` 时取 `opt\<pkg>\c.exe`;该位置不存在时,
   回退扫描 `files` 里**非目录**映射,取 `to` 文件名(不区分大小写)等于 `c.exe` 的目的路径。
   目录映射(如 `{ "from": "go/", "to": "./" }`)把整棵树铺进载荷根,exe 落在载荷根本身就
   等于原位,同样成立。
2. **禁止把 exe 从映射树里吊到包根**。`{ "from": "mingw64/bin/git.exe", "to": "git.exe" }`
   配合 `{ "from": "mingw64/", ... }` 是已被证伪的形态:吊出的副本脱离同级 DLL 与前缀树,
   干净环境直接 `0xC0000135`(DLL 缺失),DLL 恰好经 PATH 可见时也退化为错误前缀
   (`git init` 报模板缺失、exec-path 漂移)。`validate-index.ps1` 对该形态告警
   (`rust` 条目的 `bin/rustc.exe -> rustc.exe` 即现网实例,吊出后 `rustc` 同样
   `0xC0000135`,cargo 因静态链接幸存)。
3. **改用构件自带的入口 launcher**。上游发行物若自带 relocation-capable 入口,映射它而不是
   真 exe。MinGit 的 `cmd/git.exe`(43KB 静态 launcher,真 exe 仍在 `mingw64/bin/git.exe`)
   即为此物;launcher 自身按「自身目录剥一层」定位包根,所以映射目的必须**恰好在包根下
   一层、且不在任何目录映射的子树内**,例如 `{ "from": "cmd/git.exe", "to": "payload/git.exe" }`。
   已验证完整闭环(见 PR):`git --version` / `git init`(模板齐全)/ `git clone https://...`
   全部成功,且 PATH 无任何私有 DLL。
4. **文件映射不得落入目录映射的子树**(无论先后):文件映射在前会预创建目的目录,目录映射
   随后要求 `--force`;目录映射在前则 wpm 会先 unlink 再链接同一路径
   (materialize_file 的 self-collision),安装失败且破坏载荷。`validate-index.ps1` 对此报错。
5. **没有 relocation-capable 入口的构件**必须自带静态 launcher(niu-git 的
   `scripts/entry/launch-git.c` 模式:/MT、钉 GIT_EXEC_PATH/GIT_TEMPLATE_DIR、PATH 前插
   真 exe 目录、透传退出码)或改走 `flat` + 自定位单 exe(niugit 形态);两者都没有的
   RUNTIME_PREFIX/DLL 绑定载荷不具备 shim 条目资格。

## 2. wpm --json 输出契约

`--json` 输出为纯 JSON(机器可读),不混入人类可读文本。

**版本化**:每个 `--json` 载荷顶层带 `"schema": 1`(整数)。字段只增不改;语义不兼容时递增,前端应校验该字段。

### wpm list --json / wpm search <q> --json

```jsonc
{
  "schema": 1,           // 契约版本
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
    "layout": "flat",          // flat(默认)| shim(shim 包载荷在 opt\<pkg>\)
    "file_count": 1,
    "url_count": 1,
    "sha256_present": true,
    "size": 69357              // 仅当索引提供了 size 时存在
  }
}
```

### wpm installed --json

```jsonc
{
  "schema": 1,
  "matched": 12,         // 本 root 已安装的包数量
  "packages": [ ... ]    // 摘要包列表,结构同上(installed 恒为 true)
}
```

### wpm index status --json

```jsonc
{
  "schema": 1,
  "root": "C:\\winuxcmd",                     // WinuxCmd 根目录
  "local_index": "C:\\winuxcmd\\.wpm\\...",   // 本地索引文件路径
  "fallback": "builtin",                      // 索引缺失时的回退来源
  "version": "official-2026.08.20",           // 当前索引版本
  "updated": "2026-08-20",                    // 索引更新日期
  "packages": 123                             // 索引内包数量
}
```

### wpm links list --json

```jsonc
{
  "schema": 1,
  "bin": "C:\\winuxcmd\\usr\\bin",  // 命令入口目录(PATH 暴露点)
  "count": 2,
  "commands": [ "wpm", "winuxcmd" ] // 入口命令名(含 shim 转发器)
}
```

### wpm info <pkg> --json

返回完整 Package,并附加 `wpm` 包装字段:

```jsonc
{
  "schema": 1,
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

## 3. 已知限制(供 TUI / GUI 前端参考)

- `wpm list --json`、`wpm search --json`、`wpm installed --json` 顶层返回 `schema`/`matched` 计数 + `packages` 摘要列表;`wpm info --json` 返回完整包 + `wpm` 运行期状态;`wpm index status --json` 与 `wpm links list --json` 覆盖索引与入口状态。
- 摘要包里的 `artifact` 不含 `files`/`urls` 完整内容;需要下载细节时请用 `wpm info`。
- 变更类子命令(`install`/`uninstall`/`update`)暂无 `--json`;前端应以退出码为准,进度文本仅作展示。

## 4. 校验与生成脚本

| 脚本 | 用途 |
|---|---|
| `scripts/validate-index.ps1` | 校验 index.json 结构、SHA 摘要、包与命令引用一致性;输出 Packages / Installable / Index-only / Issues |
| `scripts/update-package.ps1` | 新增/更新单个包;自动计算 SHA256(下载)与 size(HEAD Content-Length);支持多文件映射 `-Files "from=to" ...` |
| `scripts/backfill-size.ps1` | 对缺失 `size` 的包通过 HEAD 请求回填字节数 |