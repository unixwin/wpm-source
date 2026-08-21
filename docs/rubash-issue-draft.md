# [bug] winuxsh 参数预处理吞掉通配符与特殊字符,破坏传给原生程序/pwsh 的参数

在 winuxsh(winuxcmd 自带 shell)下通过 `pwsh -Command "..."` 或直接调用原生 exe 时,参数中的通配符和特殊字符会被替换成 `%RUBASH_*%` 占位符或被拦截,导致命令静默失败。以下均为本会话实际踩到的复现案例。

## 复现案例

### 1. `*` 被替换为 `%RUBASH_STAR%`(即使位于引号内)

```sh
pwsh -NoProfile -Command "Copy-Item full\bin\* smoke -Force"
# 报错: Cannot find path '...\full\bin\%RUBASH_STAR%' because it does not exist.
```

预期:引号内的 `*` 应原样传给 pwsh;即使做 glob 展开,也不应把字面 `%RUBASH_STAR%` 写进目标程序的参数。

### 2. `?` 被替换为 `%RUBASH_QMARK%`(URL 被破坏)

```sh
gh api repos/nmap/nmap/contents/configure.ac?ref=v7.991
# 实际请求: .../configure.ac%RUBASH_QMARK%ref=v7.991 → parse error / 404
```

### 3. 相邻带引号字符串被拼接成一个参数

```sh
script.ps1 -Files "a=b","c=d","e=f"
# PowerShell 收到的是单个字符串: a=b,c=d,e=f(数组绑定失效)
```

bash/POSIX 行为:`"a","b"` 是三个 argv 片段拼接语义有歧义,但至少 `"a" "b"` 必须是两个独立参数。

### 4. 数组参数后的多个值被错误重绑

```sh
pwsh -File update-package.ps1 -Files "a=b" "c=d" "e=f" -Sha256 xxx
# 报错: Cannot validate argument on parameter 'Platform'. The argument "e=f" does not
# belong to the set "windows-x64,windows-arm64"
```

`-Files` 后的多个值未完整绑定给 `-Files`,部分值被路由给了后面的命名参数。

### 5. 原生 exe 的 `--` 长选项被 winuxsh 拦截

```sh
./ncat.exe --send-only 127.0.0.1 59999
# winuxsh: unknown argument '--' (not a script file)
```

winuxsh 把传给子进程的 `--xxx` 当成了自己的参数校验。

### 6. `bash -n` 等自身 flag 不支持

```sh
bash -n script.sh
# winuxsh: unknown argument '-n' (not a script file)
```

无法做 shell 语法检查;同理其他 bash 自身 flag 也应透传。

### 7. 以 `/` 开头的参数被路径转换

```sh
openssl req -new -subj "/CN=test" ...
# /CN=test 被当作 POSIX 路径转换成 Windows 路径,导致 subject 解析失败
```

## 影响

- 一切"shell 里嵌 pwsh 单行脚本"的自动化(如 CI 本地脚本、opencode/agent 工具调用)都会踩中;
- 通配符替换发生在**引号内**,用户无法用常规 quoting 规避,只能绕开(`Get-ChildItem | Copy-Item`、`-f ref=` 等 workaround);
- 与 MSYS2/Git Bash 的 MSYS_ARG_CONV_EXCL 问题类似,但 rubash 的替换是**无条件的**(连引号内都替换),更难规避。

## 建议

1. 引号内的 `*` `?` 不做任何替换(优先修复 1、2);
2. `%RUBASH_*%` 替换只应在**未加引号**且确需 glob 展开时发生,且展开失败时应保留原样而不是注入占位符;
3. 透传 `--` 开头参数给子进程;支持 bash 自身 flag(-n 等);
4. 相邻引号串按 POSIX 规则处理("a""b" 拼接、"a" "b" 分立),数组多值参数不被重绑。

环境:Windows Server,x64,winuxcmd 0.16.6 自带 winuxsh。
