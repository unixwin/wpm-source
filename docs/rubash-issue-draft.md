# [bug] winuxsh 参数预处理问题(0.17.1 复测版)

> 2026-08-21 在更新后的 winuxsh(winuxcmd 0.17.1 自带)下逐条复测。
> 原始 7 个问题:**4 个已修复、2 个确认为非 bug(撤回)、1 个仍未修复**,另发现 1 个新的转换问题。

## 复测结论总览

| # | 原始问题 | 状态 | 证据 |
|---|---|---|---|
| 1 | 引号内 `*` → `%RUBASH_STAR%` | ✅ 已修复 | `echo "*.zip"` → `*.zip`;无匹配的裸 `*.ext` 也原样保留 |
| 2 | `?` → `%RUBASH_QMARK%` | ✅ 已修复 | `http://x/y?ref=v1` 完好 |
| 3 | 相邻带引号串被拼接(`"a=b","c=d","e=f"`) | ⚠️ 撤回,非 bug | 与原生 CreateProcess 行为**完全一致**(见下方基线) |
| 4 | 数组参数多值被重绑到后续命名参数 | ⚠️ 撤回,非 bug | 同上;不再误报 `-Platform` 校验错误 |
| 5 | 原生 exe 的 `--xxx` 长选项被拦截 | ✅ 已修复 | `wpm source list --json` 经管道正常输出 JSON |
| 6 | `bash -n script.sh` 报 unknown argument | ❌ **仍未修复** | `winuxsh: unknown argument '-n' (not a script file)` |
| 7 | `/` 开头参数被路径转换(`/CN=test`) | ✅ 已修复 | `openssl req -subj "/CN=test"` → `subject=CN=test` |

### #3/#4 撤回依据(python 直接 CreateProcess 基线)

```
pwsh -File t.ps1 -Files "a=b","c=d","e=f"
  → count=1, item: a=b,c=d,e=f        ← winuxsh 与原生结果一致
pwsh -File t.ps1 -Files "a=b" "c=d" -Sha xxx
  → count=1, item: a=b, sha=xxx       ← 原生同样丢弃 c=d,-File 模式本就不支持空格续参
```

逗号在 Windows 命令行里不是 argv 分隔符,这是原生语义;原草稿预期有误。

## 🆕 新发现:未加引号的 `\` 被改写为 `//`

自编 argvdump(gcc 原生 exe)直调实测:

```
$ argvdump.exe C:\Windows\System32 'C:\Windows\System32' "C:\Windows\System32"
1:[C://Windows//System32]     ← 未加引号:反斜杠全部变成双正斜杠
2:[C:\Windows\System32]       ← 单引号:完好
3:[C:\Windows\System32]      ← 双引号:完好
```

实际踩坑案例:

```sh
where.exe /R C:\Windows\System32 notepad.exe
# ERROR: Invalid directory specified   ← 收到的是 C://Windows//System32(where 对目录校验严格)
icacls <file> /grant "Administrators:(F)"
# 巧合成功:Win32 API 容忍 C://Users//... 形式,但输出显示路径已被改写
cmd //c "..."    # 双斜杠形式失效(cmd 收到字面 //c);单斜杠 cmd /c 正常
```

**建议**:与旧 #1/#2 同一修法——未加引号的 `\` 不做任何替换;若要做 POSIX 风格转换,只应作用于"看起来像 POSIX 绝对路径且目标程序是 MSYS 类工具"的场景,且失败时保留原样。

**workaround**:给含 `\` 或以 `/` 开头的参数加引号即可。

## 仍未修复清单(按优先级)

1. 未加引号 `\` → `//` 改写(新,影响面最大:所有内嵌 Windows 路径的命令)
2. `bash -n` 等 bash 自身 flag 不支持(原 #6)

环境:Windows Server 2022 x64,winuxcmd 0.17.1 自带 winuxsh;复测方法为 gcc 编译 argvdump.exe 直调 + python subprocess CreateProcess 双基线对照。
