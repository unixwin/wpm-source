# winuxsh: `&` 命令连接时 `--` 参数被错误解析

## 问题描述

在 winuxsh shell 中使用 `&` 连接多个命令时，如果命令中包含 `--` 参数，winuxsh 会错误地将 `--` 解析为自己的参数，导致报错：

```
winuxsh: unknown argument '--' (not a script file)
```

## 复现步骤

```bash
curl.exe -I https://github.com --connect-timeout 5 --max-time 10 2>&1 & curl.exe -x http://127.0.0.1:7890 https://github.com -I --connect-timeout 5 --max-time 10 2>&1
```

## 期望行为

`--` 应该作为子命令（curl.exe）的参数传递，而不是被 winuxsh 自身解析。

## 实际行为

winuxsh 拦截了 `--`，认为是传给自己的未知参数，导致命令执行失败。

## 环境

- OS: Windows (win32)
- Shell: winuxsh
- 复现频率: 100%
