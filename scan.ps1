#requires -Version 5.1

[CmdletBinding()]
param(
    [Alias('User')]
    [string]$UserName,
    [string]$Target,
    [ValidateRange(1, 65535)]
    [int]$Port = 22,
    [string]$Identity,
    [string]$JumpHost,
    [string]$SshConfig,
    [ValidateRange(1, 60)]
    [int]$Timeout = 3,
    [ValidateRange(1, 128)]
    [int]$Concurrency = 32,
    [string]$TextOutputPath,
    [switch]$AllAddresses,
    [switch]$AllowLargeRange,
    [switch]$Interactive,
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

function Show-Usage {
    Write-Host @'
SSH Command Scanner

Required:
  -UserName USER              SSH login name
  -Target CIDR                IPv4 CIDR, for example 192.168.1.0/24

SSH options:
  -Port NUMBER                SSH port (default: 22)
  -Identity PATH              Private key passed to ssh -i
  -JumpHost HOST              Jump host passed to ssh -J
  -SshConfig PATH             Config file passed to ssh -F

Scan options:
  -Timeout SECONDS            Connection timeout (default: 3)
  -Concurrency NUMBER         Concurrent SSH processes (default: 32)
  -TextOutputPath PATH.txt    Save the ASCII table to a UTF-8 text file
  -AllAddresses               Include IPv4 network and broadcast addresses
  -AllowLargeRange            Allow 1025-65536 target addresses
  -Interactive                Prompt for missing required values

By default, network and broadcast addresses are skipped for prefixes /0-/30.
Both addresses in /31 and the single address in /32 are always scanned.
'@
}

function ConvertFrom-IPv4Number {
    param([Parameter(Mandatory = $true)][uint64]$Value)

    return '{0}.{1}.{2}.{3}' -f (
        ($Value -shr 24) -band 255
    ), (
        ($Value -shr 16) -band 255
    ), (
        ($Value -shr 8) -band 255
    ), (
        $Value -band 255
    )
}

function Resolve-IPv4Cidr {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Cidr,
        [switch]$IncludeAllAddresses
    )

    $match = [regex]::Match(
        $Cidr.Trim(),
        '^(?<a>\d{1,3})\.(?<b>\d{1,3})\.(?<c>\d{1,3})\.(?<d>\d{1,3})/(?<prefix>\d|[12]\d|3[0-2])$'
    )
    if (-not $match.Success) {
        throw 'Target 必须是 IPv4 CIDR，例如 192.168.1.0/24。'
    }

    $octets = @(
        [int]$match.Groups['a'].Value,
        [int]$match.Groups['b'].Value,
        [int]$match.Groups['c'].Value,
        [int]$match.Groups['d'].Value
    )
    if (@($octets | Where-Object { $_ -gt 255 }).Count -gt 0) {
        throw 'Target 中包含无效的 IPv4 地址。'
    }

    $prefixLength = [int]$match.Groups['prefix'].Value
    $addressValue = ([uint64]$octets[0] -shl 24) -bor
                    ([uint64]$octets[1] -shl 16) -bor
                    ([uint64]$octets[2] -shl 8) -bor
                    [uint64]$octets[3]
    $hostBits = 32 - $prefixLength
    $blockSize = [uint64][Math]::Pow(2, $hostBits)
    $networkValue = $addressValue - ($addressValue % $blockSize)
    $broadcastValue = $networkValue + $blockSize - 1

    if (-not $IncludeAllAddresses -and $prefixLength -le 30) {
        $firstValue = $networkValue + 1
        $lastValue = $broadcastValue - 1
    }
    else {
        $firstValue = $networkValue
        $lastValue = $broadcastValue
    }

    return [pscustomobject]@{
        Canonical = '{0}/{1}' -f (ConvertFrom-IPv4Number -Value $networkValue), $prefixLength
        PrefixLength = $prefixLength
        FirstValue = [uint64]$firstValue
        LastValue = [uint64]$lastValue
        Count = [uint64]($lastValue - $firstValue + 1)
    }
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

if ($Interactive) {
    if ([string]::IsNullOrWhiteSpace($UserName)) {
        $UserName = (Read-Host 'SSH 用户名').Trim()
    }
    if ([string]::IsNullOrWhiteSpace($Target)) {
        $Target = (Read-Host '目标 CIDR').Trim()
    }
}

if ([string]::IsNullOrWhiteSpace($UserName) -or [string]::IsNullOrWhiteSpace($Target)) {
    Show-Usage
    throw '必须提供 -UserName 和 -Target；需要交互输入时请添加 -Interactive。'
}
if ($UserName -notmatch '^[^\s\x00-\x1F\x7F]+$') {
    throw 'UserName 不能包含空白或控制字符。'
}
if (-not [string]::IsNullOrWhiteSpace($JumpHost) -and $JumpHost -notmatch '^[^\s\x00-\x1F\x7F]+$') {
    throw 'JumpHost 不能包含空白或控制字符。'
}
foreach ($pathValue in @($Identity, $SshConfig, $TextOutputPath)) {
    if (-not [string]::IsNullOrWhiteSpace($pathValue) -and $pathValue -match '[\x00-\x1F\x7F]') {
        throw '路径参数不能包含控制字符。'
    }
}

$resolvedTarget = Resolve-IPv4Cidr -Cidr $Target -IncludeAllAddresses:$AllAddresses
$defaultHostLimit = [uint64]1024
$absoluteHostLimit = [uint64]65536
if ($resolvedTarget.Count -gt $absoluteHostLimit) {
    throw "目标包含 $($resolvedTarget.Count) 个地址，超过绝对上限 $absoluteHostLimit。"
}
if ($resolvedTarget.Count -gt $defaultHostLimit -and -not $AllowLargeRange) {
    throw "目标包含 $($resolvedTarget.Count) 个地址，默认上限为 $defaultHostLimit；确认授权范围后可添加 -AllowLargeRange。"
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

$sshApplication = Get-Command ssh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $sshApplication) {
    throw 'PATH 中没有找到 OpenSSH 客户端 ssh。'
}
$sshExecutable = $sshApplication.Source
$knownHostsSink = if ($env:OS -eq 'Windows_NT') { 'NUL' } else { '/dev/null' }

$commonArguments = @(
    '-o', 'BatchMode=yes',
    '-o', "ConnectTimeout=$Timeout",
    '-o', 'ConnectionAttempts=1',
    '-o', 'StrictHostKeyChecking=no',
    '-o', "UserKnownHostsFile=$knownHostsSink",
    '-o', 'LogLevel=ERROR',
    '-p', [string]$Port
)
if (-not [string]::IsNullOrWhiteSpace($Identity)) {
    $commonArguments += @('-i', $Identity)
}
if (-not [string]::IsNullOrWhiteSpace($JumpHost)) {
    $commonArguments += @('-J', $JumpHost)
}
if (-not [string]::IsNullOrWhiteSpace($SshConfig)) {
    $commonArguments += @('-F', $SshConfig)
}

Write-ScanMessage "`nSSH 网段扫描器" Cyan
Write-ScanMessage ("目标：{0}  地址：{1}  用户：{2}  端口：{3}  并发：{4}  超时：{5}s" -f $resolvedTarget.Canonical, $resolvedTarget.Count, $UserName, $Port, $Concurrency, $Timeout) DarkGray
Write-ScanMessage '认证：当前用户的 OpenSSH key、ssh-agent，或通过 -Identity 指定的私钥。' DarkGray

$worker = {
    param($Executable, $ArgumentList, $Address, $NumericAddress)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $rawOutput = & $Executable @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE
    $stopwatch.Stop()
    $detail = (($rawOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()

    [pscustomobject]@{
        IP = $Address
        NumericIP = [uint64]$NumericAddress
        ExitCode = $exitCode
        DurationMs = $stopwatch.ElapsedMilliseconds
        Detail = $detail
    }
}

$pool = [runspacefactory]::CreateRunspacePool(1, $Concurrency)
$activeJobs = New-Object 'System.Collections.Generic.List[object]'
$results = New-Object 'System.Collections.Generic.List[object]'
$nextAddressValue = [uint64]$resolvedTarget.FirstValue
$completedCount = 0

try {
    $pool.Open()

    while ($nextAddressValue -le $resolvedTarget.LastValue -or $activeJobs.Count -gt 0) {
        while ($nextAddressValue -le $resolvedTarget.LastValue -and $activeJobs.Count -lt $Concurrency) {
            $address = ConvertFrom-IPv4Number -Value $nextAddressValue
            $sshArguments = @($commonArguments) + @('-l', $UserName, $address, 'exit')
            $powerShell = [powershell]::Create()
            $powerShell.RunspacePool = $pool
            [void]$powerShell.AddScript($worker).AddArgument($sshExecutable).AddArgument($sshArguments).AddArgument($address).AddArgument($nextAddressValue)
            $activeJobs.Add([pscustomobject]@{
                IP = $address
                NumericIP = $nextAddressValue
                PowerShell = $powerShell
                Handle = $powerShell.BeginInvoke()
            })
            $nextAddressValue++
        }

        $finishedJobs = @($activeJobs | Where-Object { $_.Handle.IsCompleted })
        if ($finishedJobs.Count -eq 0) {
            Start-Sleep -Milliseconds 25
            continue
        }

        foreach ($job in $finishedJobs) {
            try {
                $jobOutput = @($job.PowerShell.EndInvoke($job.Handle))
                if ($jobOutput.Count -eq 0) {
                    throw 'SSH 工作线程没有返回结果。'
                }

                $item = $jobOutput[-1]
                $results.Add([pscustomobject]@{
                    IP = [string]$item.IP
                    NumericIP = [uint64]$item.NumericIP
                    Status = Get-ScanStatus -ExitCode ([int]$item.ExitCode) -Detail ([string]$item.Detail)
                    ExitCode = [int]$item.ExitCode
                    DurationMs = [long]$item.DurationMs
                    Detail = [string]$item.Detail
                })
            }
            catch {
                $results.Add([pscustomobject]@{
                    IP = $job.IP
                    NumericIP = [uint64]$job.NumericIP
                    Status = 'other_error'
                    ExitCode = 255
                    DurationMs = 0
                    Detail = $_.Exception.Message
                })
            }
            finally {
                $job.PowerShell.Dispose()
                [void]$activeJobs.Remove($job)
            }

            $completedCount++
            Write-Progress -Activity '正在扫描 SSH' -Status "$completedCount / $($resolvedTarget.Count)" -PercentComplete (($completedCount / $resolvedTarget.Count) * 100)
        }
    }
}
finally {
    Write-Progress -Activity '正在扫描 SSH' -Completed
    foreach ($job in $activeJobs) {
        $job.PowerShell.Dispose()
    }
    $pool.Close()
    $pool.Dispose()
}

$sortedResults = @($results | Sort-Object NumericIP)
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
        'Target: {0}' -f $resolvedTarget.Canonical
        'Addresses: {0}' -f $resolvedTarget.Count
        'User: {0}' -f $UserName
        'Port: {0}' -f $Port
        ''
        $tableText
        ''
        $summaryText
    ) -join [Environment]::NewLine
    $report | Set-Content -LiteralPath $TextOutputPath -Encoding UTF8
    Write-ScanMessage "ASCII 表格：$TextOutputPath" Green
}
