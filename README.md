# SSH Command Scanner

一个支持 PowerShell 与 Bash 的结构化 IPv4 CIDR SSH 扫描器。它使用当前用户的 OpenSSH key 或 ssh-agent，对目标地址各连接一次，并在终端输出 ASCII 表格。

## 网页生成器

在 [GitHub Pages](https://guajun.github.io/ssh-command-scanner/) 中填写用户名、CIDR 和 SSH 参数，即可生成适用于 PowerShell 或 Bash 的一行命令。

## CLI

PowerShell：

```powershell
& ([scriptblock]::Create([Text.Encoding]::UTF8.GetString((iwr -UseBasicParsing 'https://guajun.github.io/ssh-command-scanner/scan.ps1').Content).TrimStart([char]0xFEFF))) `
  -UserName admin `
  -Target '192.168.1.0/24'
```

Bash：

```bash
bash <(curl -fsSL 'https://guajun.github.io/ssh-command-scanner/scan.sh') \
  --user admin \
  --target '192.168.1.0/24'
```

用户名和目标是必填参数。无参数执行不会隐式询问；需要交互模式时应显式添加 `-Interactive` 或 `--interactive`。

## CIDR 目标

目标使用标准 IPv4 CIDR：

```text
192.168.1.0/24
10.30.0.0/22
192.168.1.25/32
```

传入 `192.168.1.42/24` 时会规范化为 `192.168.1.0/24`。

默认行为：

- `/0` 至 `/30` 跳过网络地址和广播地址；
- `/31` 扫描两个地址；
- `/32` 扫描单个地址；
- 默认最多 1024 个目标；
- `-AllAddresses` / `--all-addresses` 包含边界地址；
- `-AllowLargeRange` / `--allow-large-range` 将上限放宽至 65536。

## SSH 参数

| 用途 | PowerShell | Bash |
| --- | --- | --- |
| 用户名 | `-UserName` | `--user` |
| CIDR | `-Target` | `--target` |
| SSH 端口 | `-Port` | `--port` |
| 私钥 | `-Identity` | `--identity` |
| 跳板机 | `-JumpHost` | `--jump-host` |
| SSH config | `-SshConfig` | `--ssh-config` |
| 超时 | `-Timeout` | `--timeout` |
| 并发数 | `-Concurrency` | `--concurrency` |
| TXT 输出 | `-TextOutputPath` | `--text-output` |
| 包含边界 | `-AllAddresses` | `--all-addresses` |
| 大型网段 | `-AllowLargeRange` | `--allow-large-range` |
| 交互模式 | `-Interactive` | `--interactive` |

完整示例：

```powershell
.\scan.ps1 `
  -UserName admin `
  -Target '192.168.1.0/24' `
  -Port 2222 `
  -Identity "$env:USERPROFILE\.ssh\id_ed25519" `
  -JumpHost 'ops@bastion.example' `
  -Timeout 3 `
  -Concurrency 32 `
  -TextOutputPath '.\result.txt'
```

```bash
./scan.sh \
  --user admin \
  --target '192.168.1.0/24' \
  --port 2222 \
  --identity "$HOME/.ssh/id_ed25519" \
  --jump-host 'ops@bastion.example' \
  --timeout 3 \
  --concurrency 32 \
  --text-output './result.txt'
```

脚本固定添加 `BatchMode=yes`、单次连接、主机超时和非交互主机指纹参数。密码交互被关闭；私钥始终保留在本机。

## 输出

默认不会创建文件，全部结果直接显示为 ASCII 表格：

```text
+---------------+-----------------------+------+----------+-------------------+
| IP            | Status                | Exit | Time(ms) | Detail            |
+---------------+-----------------------+------+----------+-------------------+
| 192.168.1.10  | reachable_auth_failed | 255  | 108      | Permission denied |
| 192.168.1.155 | connected             | 0    | 76       |                   |
+---------------+-----------------------+------+----------+-------------------+
```

仅当提供 TXT 输出参数时，才会把相同表格保存为 UTF-8 `.txt` 文件。

状态含义：

| 状态 | 含义 |
| --- | --- |
| `connected` | 已使用 key/agent 完成 SSH 登录 |
| `reachable_auth_failed` | SSH 服务可达，但密钥认证失败 |
| `refused` | 目标拒绝 SSH 连接 |
| `unreachable_or_timeout` | 超时、无路由或网络不可达 |
| `host_key_failed` | 主机指纹校验失败 |
| `indeterminate` | SSH 返回 255，但没有诊断文本 |
| `other_error` | 其他 SSH 或本地执行错误 |

## 先审查再运行

PowerShell：

```powershell
iwr -UseBasicParsing https://guajun.github.io/ssh-command-scanner/scan.ps1 -OutFile .\scan.ps1
Get-FileHash .\scan.ps1 -Algorithm SHA256
notepad .\scan.ps1
.\scan.ps1 -UserName admin -Target '192.168.1.0/24'
```

Bash：

```bash
curl -fSLo scan.sh https://guajun.github.io/ssh-command-scanner/scan.sh
sha256sum scan.sh
less scan.sh
bash scan.sh --user admin --target '192.168.1.0/24'
```

每个 Release 附带 `checksums.txt`。仅扫描你有权访问的网络。

## License

[MIT](LICENSE)
