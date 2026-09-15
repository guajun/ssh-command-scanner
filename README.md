# SSH Command Scanner

一个支持 PowerShell 与 Bash 的交互式 IPv4 `/24` SSH 扫描器。输入用户名以及网段目标或 SSH 命令后，脚本对范围内每个地址发起一次非交互连接，并在终端输出完整 ASCII 表格。

## 一行运行

```powershell
iex ([Text.Encoding]::UTF8.GetString((iwr -UseBasicParsing 'https://guajun.github.io/ssh-command-scanner/scan.ps1').Content).TrimStart([char]0xFEFF))
```

```bash
bash <(curl -fsSL 'https://guajun.github.io/ssh-command-scanner/scan.sh')
```

也可以在 [GitHub Pages](https://guajun.github.io/ssh-command-scanner/) 中填写参数，生成定制的一行命令。

## 目标与命令

输入支持三种形式：

- 裸网段：`10.30.3.x`，使用单独输入的用户名；
- 用户目标：`admin@10.30.3.x`；
- 完整命令：以 `ssh` 或 `ssh.exe` 开头，可包含 `-p`、`-i`、`-J` 和 `-F`。

所有形式必须包含且只能包含一个 IPv4 末段占位符 `x`。完整命令可使用 `{user}` 作为用户名占位符。

示例：

```text
10.30.3.x
admin@10.30.3.x
ssh {user}@10.30.3.x
ssh -p 2222 -i "C:\Users\me\.ssh\id_ed25519" {user}@10.30.3.x
ssh -J jump-host {user}@10.30.3.x
```

扫描器强制使用以下连接参数：

```text
BatchMode=yes
ConnectionAttempts=1
ConnectTimeout=<超时秒数>
StrictHostKeyChecking=no
UserKnownHostsFile=NUL 或 /dev/null
LogLevel=ERROR
```

`BatchMode=yes` 会关闭密码交互。认证由当前用户的默认 OpenSSH 私钥、`ssh-agent` 中的 key，或模板中 `-i` 指定的私钥完成。私钥不会离开本机。

## 参数

```powershell
.\scan.ps1 `
  -UserName admin `
  -CommandTemplate 'ssh {user}@10.30.3.x' `
  -StartHost 1 `
  -EndHost 254 `
  -Timeout 3 `
  -ThrottleLimit 32 `
  -TextOutputPath .\result.txt
```

```bash
./scan.sh \
  --user admin \
  --command-template 'ssh {user}@10.30.3.x' \
  --start-host 1 \
  --end-host 254 \
  --timeout 3 \
  --throttle-limit 32 \
  --text-output-path ./result.txt
```

默认不会创建文件。仅在提供 `-TextOutputPath` 时，才会把终端中的同一张 ASCII 表格写入 UTF-8 `.txt` 文件；省略扩展名时会自动补充 `.txt`。

状态含义：

| 状态 | 含义 |
| --- | --- |
| `connected` | 已使用 key/agent 完成 SSH 登录 |
| `reachable_auth_failed` | SSH 服务可达，但密钥认证失败 |
| `refused` | 目标拒绝 TCP 22 或模板指定端口的连接 |
| `unreachable_or_timeout` | 超时、无路由或网络不可达 |
| `host_key_failed` | 主机指纹校验失败 |
| `indeterminate` | SSH 返回 255，但没有诊断文本 |
| `other_error` | 其他 SSH 或本地执行错误 |

## 终端输出

```text
+------------+-----------------------+------+----------+-------------------+
| IP         | Status                | Exit | Time(ms) | Detail            |
+------------+-----------------------+------+----------+-------------------+
| 10.30.3.94 | reachable_auth_failed | 255  | 108      | Permission denied |
| 10.30.3.155 | connected             | 0    | 76       |                   |
+------------+-----------------------+------+----------+-------------------+
```

## 先审查再运行

```powershell
irm https://guajun.github.io/ssh-command-scanner/scan.ps1 -OutFile .\scan.ps1
Get-FileHash .\scan.ps1 -Algorithm SHA256
notepad .\scan.ps1
.\scan.ps1
```

每个 Release 附带 `checksums.txt`。仅扫描你有权访问的网络。

Bash 脚本可以这样下载检查：

```bash
curl -fSLo scan.sh https://guajun.github.io/ssh-command-scanner/scan.sh
sha256sum scan.sh
less scan.sh
bash scan.sh
```

## License

[MIT](LICENSE)
