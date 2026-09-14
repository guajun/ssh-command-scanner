#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$UserName,
    [string]$CommandTemplate,
    [ValidateRange(0, 255)]
    [int]$StartHost = 1,
    [ValidateRange(0, 255)]
    [int]$EndHost = 254,
    [ValidateRange(1, 60)]
    [int]$Timeout = 3,
    [ValidateRange(1, 128)]
    [int]$ThrottleLimit = 32,
    [string]$TextOutputPath,
    [switch]$NoColor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-ScanMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    if ($NoColor) {
        Write-Host $Message
    }
    else {
        Write-Host $Message -ForegroundColor $Color
    }
}

function Split-SshCommandLine {
    param([Parameter(Mandatory = $true)][string]$CommandLine)

    $tokens = New-Object 'System.Collections.Generic.List[string]'
    $buffer = New-Object System.Text.StringBuilder
    $quote = [char]0

    for ($index = 0; $index -lt $CommandLine.Length; $index++) {
        $character = $CommandLine[$index]

        if ($quote -ne [char]0) {
            if ($character -eq $quote) {
                $quote = [char]0
                continue
            }

            if ($quote -eq '"' -and $character -eq '\' -and ($index + 1) -lt $CommandLine.Length -and $CommandLine[$index + 1] -eq '"') {
                [void]$buffer.Append('"')
                $index++
                continue
            }

            [void]$buffer.Append($character)
            continue
        }

        if ($character -eq '"' -or $character -eq "'") {
            $quote = $character
            continue
        }

        if ([char]::IsWhiteSpace($character)) {
            if ($buffer.Length -gt 0) {
                $tokens.Add($buffer.ToString())
                [void]$buffer.Clear()
            }
            continue
        }

        [void]$buffer.Append($character)
    }

    if ($quote -ne [char]0) {
        throw 'SSH 命令模板包含未闭合的引号。'
    }

    if ($buffer.Length -gt 0) {
        $tokens.Add($buffer.ToString())
    }

    if ($tokens.Count -eq 0) {
        throw 'SSH 命令模板不能为空。'
    }

    $executableName = [System.IO.Path]::GetFileName($tokens[0]).ToLowerInvariant()
    if ($executableName -notin @('ssh', 'ssh.exe')) {
        throw '命令模板必须以 ssh 或 ssh.exe 开头。'
    }

    return $tokens.ToArray()
}

function Get-ScanStatus {
    param(
        [int]$ExitCode,
        [string]$Detail
    )

    if ($ExitCode -eq 0) { return 'connected' }
    if ($Detail -match 'Permission denied') { return 'reachable_auth_failed' }
    if ($Detail -match 'Connection refused') { return 'refused' }
    if ($Detail -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed') { return 'host_key_failed' }
    if ($Detail -match 'timed out|No route to host|Network is unreachable|Connection closed') { return 'unreachable_or_timeout' }
    if ([string]::IsNullOrWhiteSpace($Detail)) { return 'indeterminate' }
    return 'other_error'
}

function ConvertTo-TableText {
    param(
        [AllowNull()]
        [string]$Value,
        [int]$MaximumLength = 54
    )

    if ($null -eq $Value) { return '' }

    $singleLine = ($Value -replace '[\r\n\t]+', ' ' -replace '\|', '/').Trim()
    if ($singleLine.Length -le $MaximumLength) { return $singleLine }
    return $singleLine.Substring(0, $MaximumLength - 3) + '...'
}

function Format-AsciiTable {
    param([Parameter(Mandatory = $true)][object[]]$Rows)

    $displayRows = @($Rows | ForEach-Object {
        [pscustomobject]@{
            IP = [string]$_.IP
            Status = [string]$_.Status
            ExitCode = [string]$_.ExitCode
            DurationMs = [string]$_.DurationMs
            Detail = ConvertTo-TableText -Value ([string]$_.Detail)
        }
    })

    $columns = @(
        [pscustomobject]@{ Key = 'IP'; Header = 'IP'; Width = 2 }
        [pscustomobject]@{ Key = 'Status'; Header = 'Status'; Width = 6 }
        [pscustomobject]@{ Key = 'ExitCode'; Header = 'Exit'; Width = 4 }
        [pscustomobject]@{ Key = 'DurationMs'; Header = 'Time(ms)'; Width = 8 }
        [pscustomobject]@{ Key = 'Detail'; Header = 'Detail'; Width = 6 }
    )

    foreach ($column in $columns) {
        $maximumCellWidth = ($displayRows | ForEach-Object { ([string]$_.($column.Key)).Length } | Measure-Object -Maximum).Maximum
        $column.Width = [Math]::Max($column.Header.Length, [int]$maximumCellWidth)
    }

    $border = '+' + (($columns | ForEach-Object { '-' * ($_.Width + 2) }) -join '+') + '+'
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add($border)
    $lines.Add('| ' + (($columns | ForEach-Object { $_.Header.PadRight($_.Width) }) -join ' | ') + ' |')
    $lines.Add($border)

    foreach ($row in $displayRows) {
        $lines.Add('| ' + (($columns | ForEach-Object { ([string]$row.($_.Key)).PadRight($_.Width) }) -join ' | ') + ' |')
    }

    $lines.Add($border)
    return $lines -join [Environment]::NewLine
}

if ([string]::IsNullOrWhiteSpace($UserName)) {
    $UserName = (Read-Host 'SSH 用户名').Trim()
}

if ($UserName -notmatch '^[A-Za-z0-9._-]+(?:\\[A-Za-z0-9._-]+)?$') {
    throw '用户名只能包含字母、数字、点、下划线、连字符，或 DOMAIN\user 形式。'
}

if ([string]::IsNullOrWhiteSpace($CommandTemplate)) {
    $CommandTemplate = (Read-Host 'SSH 命令模板 [ssh {user}@10.30.3.x]').Trim()
    if ([string]::IsNullOrWhiteSpace($CommandTemplate)) {
        $CommandTemplate = 'ssh {user}@10.30.3.x'
    }
}

if ($StartHost -gt $EndHost) {
    throw 'StartHost 不能大于 EndHost。'
}

$templateWithUser = [regex]::Replace(
    $CommandTemplate,
    '\{user\}',
    [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $UserName },
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)

$addressPattern = '(?<!\d)(?<a>\d{1,3})\.(?<b>\d{1,3})\.(?<c>\d{1,3})\.[xX](?![A-Za-z0-9])'
$addressMatches = [regex]::Matches($templateWithUser, $addressPattern)
if ($addressMatches.Count -ne 1) {
    throw 'SSH 命令模板必须且只能包含一个 IPv4 末段占位符，例如 10.30.3.x。'
}

$addressMatch = $addressMatches[0]
$networkParts = @(
    [int]$addressMatch.Groups['a'].Value,
    [int]$addressMatch.Groups['b'].Value,
    [int]$addressMatch.Groups['c'].Value
)
if (@($networkParts | Where-Object { $_ -gt 255 }).Count -gt 0) {
    throw 'SSH 命令模板中的 IPv4 网段无效。'
}

$prefix = $networkParts -join '.'
$tasks = New-Object 'System.Collections.Generic.List[object]'

foreach ($hostNumber in $StartHost..$EndHost) {
    $address = "$prefix.$hostNumber"
    $renderedCommand = $templateWithUser.Substring(0, $addressMatch.Index) + $address + $templateWithUser.Substring($addressMatch.Index + $addressMatch.Length)
    $commandTokens = @(Split-SshCommandLine -CommandLine $renderedCommand)
    $sshArguments = @(
        '-o', 'BatchMode=yes',
        '-o', "ConnectTimeout=$Timeout",
        '-o', 'ConnectionAttempts=1',
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'LogLevel=ERROR'
    ) + @($commandTokens | Select-Object -Skip 1) + @('exit')

    $tasks.Add([pscustomobject]@{
        IP = $address
        Executable = $commandTokens[0]
        Arguments = $sshArguments
    })
}

if (-not [string]::IsNullOrWhiteSpace($TextOutputPath)) {
    if ([string]::IsNullOrWhiteSpace([System.IO.Path]::GetExtension($TextOutputPath))) {
        $TextOutputPath += '.txt'
    }
    elseif ([System.IO.Path]::GetExtension($TextOutputPath) -ne '.txt') {
        throw 'TextOutputPath 必须使用 .txt 扩展名。'
    }

    $TextOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TextOutputPath)
    $outputDirectory = Split-Path -Parent $TextOutputPath
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        throw "输出目录不存在：$outputDirectory"
    }
}

Write-ScanMessage "`nSSH 网段扫描器" Cyan
Write-ScanMessage ("目标：{0}.{1}-{0}.{2}  用户：{3}  并发：{4}  超时：{5}s" -f $prefix, $StartHost, $EndHost, $UserName, $ThrottleLimit, $Timeout) DarkGray
Write-ScanMessage '认证：当前用户的 OpenSSH key、ssh-agent，或模板中通过 -i 指定的私钥。' DarkGray

$worker = {
    param($Executable, $ArgumentList, $Address)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $rawOutput = & $Executable @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE
    $stopwatch.Stop()
    $detail = (($rawOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()

    [pscustomobject]@{
        IP = $Address
        ExitCode = $exitCode
        DurationMs = $stopwatch.ElapsedMilliseconds
        Detail = $detail
    }
}

$pool = [runspacefactory]::CreateRunspacePool(1, $ThrottleLimit)
$jobs = New-Object 'System.Collections.Generic.List[object]'
$results = New-Object 'System.Collections.Generic.List[object]'

try {
    $pool.Open()

    foreach ($task in $tasks) {
        $powerShell = [powershell]::Create()
        $powerShell.RunspacePool = $pool
        [void]$powerShell.AddScript($worker).AddArgument($task.Executable).AddArgument($task.Arguments).AddArgument($task.IP)
        $jobs.Add([pscustomobject]@{
            IP = $task.IP
            PowerShell = $powerShell
            Handle = $powerShell.BeginInvoke()
        })
    }

    $completed = 0
    foreach ($job in $jobs) {
        try {
            $jobOutput = @($job.PowerShell.EndInvoke($job.Handle))
            if ($jobOutput.Count -eq 0) {
                throw 'SSH 工作线程没有返回结果。'
            }

            $item = $jobOutput[-1]
            $results.Add([pscustomobject]@{
                IP = [string]$item.IP
                Status = Get-ScanStatus -ExitCode ([int]$item.ExitCode) -Detail ([string]$item.Detail)
                ExitCode = [int]$item.ExitCode
                DurationMs = [long]$item.DurationMs
                Detail = [string]$item.Detail
            })
        }
        catch {
            $results.Add([pscustomobject]@{
                IP = $job.IP
                Status = 'other_error'
                ExitCode = 255
                DurationMs = 0
                Detail = $_.Exception.Message
            })
        }
        $completed++
        Write-Progress -Activity '正在扫描 SSH' -Status "$completed / $($jobs.Count)" -PercentComplete (($completed / $jobs.Count) * 100)
    }
}
finally {
    Write-Progress -Activity '正在扫描 SSH' -Completed
    foreach ($job in $jobs) {
        if ($null -ne $job.PowerShell) {
            $job.PowerShell.Dispose()
        }
    }
    $pool.Close()
    $pool.Dispose()
}

$sortedResults = @($results | Sort-Object { [int]($_.IP.Split('.')[-1]) })
$tableText = Format-AsciiTable -Rows $sortedResults
$summaryParts = @($sortedResults | Group-Object Status | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count })
$summaryText = 'Summary: ' + ($summaryParts -join '  ')

Write-ScanMessage "`n扫描结果 ($($sortedResults.Count))" Cyan
Write-Host $tableText
Write-ScanMessage $summaryText Cyan

if (-not [string]::IsNullOrWhiteSpace($TextOutputPath)) {
    $report = @(
        'SSH Command Scanner'
        'Generated: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')
        'Target: {0}.{1}-{0}.{2}' -f $prefix, $StartHost, $EndHost
        'User: {0}' -f $UserName
        ''
        $tableText
        ''
        $summaryText
    ) -join [Environment]::NewLine
    $report | Set-Content -LiteralPath $TextOutputPath -Encoding UTF8
    Write-ScanMessage "ASCII 表格：$TextOutputPath" Green
}
