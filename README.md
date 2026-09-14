# SSH Command Scanner

一个面向 Windows OpenSSH 的交互式 IPv4 `/24` SSH 扫描器。输入用户名和 SSH 命令模板后，脚本对范围内每个地址发起一次非交互连接，并将完整结果写入 CSV。

## 一行运行

```powershell
iex ((irm 'https://guajun.github.io/ssh-command-scanner/scan.ps1').TrimStart([char]0xFEFF))
```

也可以在 [GitHub Pages](https://guajun.github.io/ssh-command-scanner/) 中填写参数，生成定制的一行命令。

## 命令模板

模板必须：

- 以 `ssh` 或 `ssh.exe` 开头；
- 包含一个 IPv4 末段占位符 `x`，例如 `10.30.3.x`；
- 可使用 `{user}` 作为用户名占位符；
- 可包含 OpenSSH 参数，例如 `-p`、`-i`、`-J` 和 `-F`。

示例：

```text
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
UserKnownHostsFile=NUL
LogLevel=ERROR
```

`BatchMode=yes` 会关闭密码交互。认证由当前 Windows 用户的默认 OpenSSH 私钥、`ssh-agent` 中的 key，或模板中 `-i` 指定的私钥完成。私钥不会离开本机。

## 参数

```powershell
.\scan.ps1 `
  -UserName young `
  -CommandTemplate 'ssh {user}@10.30.3.x' `
  -StartHost 1 `
  -EndHost 254 `
  -Timeout 3 `
  -ThrottleLimit 32 `
  -OutputPath .\result.csv
```

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

## 先审查再运行

```powershell
irm https://guajun.github.io/ssh-command-scanner/scan.ps1 -OutFile .\scan.ps1
Get-FileHash .\scan.ps1 -Algorithm SHA256
notepad .\scan.ps1
.\scan.ps1
```

每个 Release 附带 `checksums.txt`。仅扫描你有权访问的网络。

## License

[MIT](LICENSE)
