<#
.SYNOPSIS
  EC 只读快照工具（BatteryGuard 研究配套）
.DESCRIPTION
  在不同充电状态下对 EC RAM 重点区域与 SMBus 充电器/电池寄存器做纯只读快照，
  用于对比寻找 EC 固件可能的充电控制状态位（关机限充路线的前置调查）。
  快照范围（全部只读，零写入）：
    - EC RAM 0x0090-0x009F  电池配置区（ACPI 零引用、含 BATM@0x96 等疑似字段，重点观察）
    - EC RAM 0x0460-0x047F  电池遥测区（ECWR/B1DC/B1VT/BCYC/BRSC...）
    - EC RAM 0x04B0-0x04BF  电池签名区（AEC4168126-4S1P，读取正确性校验）
    - EC RAM 0x0700-0x070F  14XA 充电寄存器区（本机已知全零，作为基线可信度对照）
    - EC RAM 0x00F0-0x00FF  低电量标志区（DCBL@0xFA 等）
    - 充电器(0x09): 0x14 电流 / 0x15 电压 / 0xFE 厂商ID / 0xFF 型号ID
    - 电池(0x0B):   0x08 温度 / 0x09 电压 / 0x0A 电流 / 0x14 充电请求 / 0x16 状态字
  SMBus 读取复用 BatteryGuard.ps1 硬件层（同一互斥锁，与运行中的守护进程安全共存）。
.USAGE
  .\ec-snapshot.ps1 -Label 插电停充      # 拍快照（自动 UAC 提权）
  .\ec-snapshot.ps1 -Diff f1.json f2.json # 对比两张快照
  建议在四种状态各拍一张：①插电充电中 ②停充维持 ③恢复充电瞬间 ④拔电电池模式
#>
param(
    [switch]$Diff,
    [Parameter(Position=0)][string]$File1,
    [Parameter(Position=1)][string]$File2,
    [string]$Label = ''
)

$ErrorActionPreference = 'Stop'
$Script:Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:MainScript = Join-Path $Script:Dir 'BatteryGuard.ps1'
$Script:DllPath = Join-Path $Script:Dir 'driver\inpoutx64.dll'
$Script:SnapDir = Join-Path $Script:Dir '.temp\ec-snapshots'

# ============ 差异对比模式（纯文件操作，无需管理员/驱动） ============
if ($Diff) {
    if (-not $File1 -or -not $File2) { Write-Host '用法: .\ec-snapshot.ps1 -Diff <快照1.json> <快照2.json>' -ForegroundColor Yellow; exit 1 }
    foreach ($f in @($File1, $File2)) {
        if (-not (Test-Path $f)) { if (Test-Path (Join-Path $Script:SnapDir $f)) { } else { Write-Host "文件不存在: $f" -ForegroundColor Red; exit 1 } }
    }
    $p1 = if (Test-Path $File1) { $File1 } else { Join-Path $Script:SnapDir $File1 }
    $p2 = if (Test-Path $File2) { $File2 } else { Join-Path $Script:SnapDir $File2 }
    $a = Get-Content $p1 -Raw -Encoding UTF8 | ConvertFrom-Json
    $b = Get-Content $p2 -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host ''
    Write-Host "═══ EC 快照对比 ═══" -ForegroundColor Cyan
    Write-Host ("A: {0}  [{1}]  {2}  SOC={3}%" -f (Split-Path $p1 -Leaf), $a.state.label, $a.meta.taken_at, $a.state.soc)
    Write-Host ("B: {0}  [{1}]  {2}  SOC={3}%" -f (Split-Path $p2 -Leaf), $b.state.label, $b.meta.taken_at, $b.state.soc)
    Write-Host ''

    $changes = 0
    # EC RAM 逐字节（区域名 '0x0090' 解析出起始地址，i 为相对偏移）
    foreach ($reg in $a.ec_ram.PSObject.Properties) {
        $nameA = $reg.Name
        $bytesA = $reg.Value
        $bytesB = $b.ec_ram.$nameA
        if ($null -eq $bytesB) { continue }
        $base = [Convert]::ToInt32($nameA.Substring(2), 16)
        for ($i = 0; $i -lt $bytesA.Count; $i++) {
            if ($bytesA[$i] -ne $bytesB[$i]) {
                Write-Host ("  EC 0x{0:X4}: 0x{1:X2} -> 0x{2:X2}" -f ($base + $i), $bytesA[$i], $bytesB[$i]) -ForegroundColor Yellow
                $changes++
            }
        }
    }
    # SMBus 寄存器
    $smA = $a.smbus.PSObject.Properties
    foreach ($r in $smA) {
        $vB = $b.smbus.($r.Name)
        if ($null -eq $vB) { continue }
        if ([int]$r.Value -ne [int]$vB) {
            Write-Host ("  SMBus {0}: 0x{1:X4} -> 0x{2:X4}" -f $r.Name, [int]$r.Value, [int]$vB) -ForegroundColor Green
            $changes++
        }
    }
    if ($changes -eq 0) { Write-Host '  （两张快照完全一致，无差异字节）' -ForegroundColor DarkGray }
    else { Write-Host ("  共 {0} 处差异" -f $changes) -ForegroundColor Cyan }
    exit 0
}

# ============ 拍快照模式（需要管理员：InpOut 驱动访问） ============
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$PSCommandPath`"")
    if ($Label) { $argList += @('-Label', "`"$Label`"") }
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit
}

# ============ 拍快照模式 ============

# 提取主脚本硬件层 C#（保证协议与守护同源）
$main = Get-Content $Script:MainScript -Raw -Encoding UTF8
$m = [regex]::Match($main, "(?s)\$hwCs = @'(.*?)'@")
if (-not $m.Success) { throw '主脚本中未找到硬件层 C# 源' }
Add-Type -TypeDefinition $m.Groups[1].Value -Language CSharp
if ([BatteryGuard.Hw.I2ec]::LoadLibrary($Script:DllPath) -eq [IntPtr]::Zero) { throw '无法加载 InpOut DLL' }
Start-Sleep -Milliseconds 300
if (-not [BatteryGuard.Hw.I2ec]::IsOpen()) { throw 'InpOut 驱动未运行' }

function Read-EcBlock([int]$start, [int]$count) {
    # 用 List[int] 而非 int[]：PS5.1 的 ConvertTo-Json 会把 int[] 序列化成 {value,Count} 对象，
    # List 才能正确输出为 JSON 数组（快照 diff 依赖）
    $bytes = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $count; $i++) {
        $bytes.Add([int][BatteryGuard.Hw.Charger]::ReadEcRamByte([uint16]($start + $i)))
    }
    return $bytes
}

function Read-Smb([byte]$addr, [byte]$cmd, [string]$name) {
    try { return [int][BatteryGuard.Hw.Charger]::ReadSmbusWord($addr, $cmd) }
    catch { return $null }   # 单寄存器读失败不中断整张快照（总线瞬态）
}

# ---- 采集 ----
$ecwr  = [int][BatteryGuard.Hw.Charger]::ReadEcRamByte(0x0460)
$soc   = [int][BatteryGuard.Hw.Charger]::ReadEcRamByte(0x047C)
$acOnline   = (($ecwr -band 1) -ne 0)
$charging   = (($ecwr -band 4) -ne 0)
$discharging= (($ecwr -band 8) -ne 0)

# 守护 runtime（判断"停充维持"状态）
$rtFile = Join-Path $Script:Dir 'agent\hw-runtime.json'
$stopped = $false
if (Test-Path $rtFile) { try { $r = Get-Content $rtFile -Raw -Encoding UTF8 | ConvertFrom-Json; $stopped = [bool]$r.stopped_by_us } catch { } }

$stateLabel = if (-not $acOnline) { '拔电-电池模式' }
             elseif ($stopped) { '插电-停充维持' }
             elseif ($charging) { '插电-充电中' }
             else { '插电-未充电' }
if ($Label) { $stateLabel = $Label }

$blocks = [ordered]@{
    '0x0090' = (Read-EcBlock 0x0090 16)   # 电池配置区（重点：SMCE/BATM/BTCF/BLEG/BTMF...）
    '0x0460' = (Read-EcBlock 0x0460 32)   # 电池遥测区
    '0x04B0' = (Read-EcBlock 0x04B0 16)   # 电池签名区
    '0x0700' = (Read-EcBlock 0x0700 16)   # 14XA 充电寄存器区（已知全零基线）
    '0x00F0' = (Read-EcBlock 0x00F0 16)   # 低电量标志区
}

$smbus = [ordered]@{
    'charger_0x14_current'  = (Read-Smb 0x09 0x14)
    'charger_0x15_voltage'  = (Read-Smb 0x09 0x15)
    'charger_0xFE_mfgid'    = (Read-Smb 0x09 0xFE)
    'charger_0xFF_devid'    = (Read-Smb 0x09 0xFF)
    'battery_0x08_temp'     = (Read-Smb 0x0B 0x08)
    'battery_0x09_voltage'  = (Read-Smb 0x0B 0x09)
    'battery_0x0A_current'  = (Read-Smb 0x0B 0x0A)
    'battery_0x14_request'  = (Read-Smb 0x0B 0x14)
    'battery_0x16_status'   = (Read-Smb 0x0B 0x16)
}

# 电池签名（校验读取正确性）
$sig = ''
try {
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt 15; $i++) { [void]$sb.Append([char][BatteryGuard.Hw.Charger]::ReadEcRamByte(0x04B0 + $i)) }
    $sig = $sb.ToString()
} catch { }

$snap = [ordered]@{
    meta = [ordered]@{
        taken_at = (Get-Date -Format o)
        tool = 'ec-snapshot.ps1 v1（纯只读）'
    }
    state = [ordered]@{
        label = $stateLabel
        ac_online = $acOnline
        charging = $charging
        discharging = $discharging
        stopped_by_us = $stopped
        soc = $soc
        ecwr = $ecwr
    }
    ec_ram = $blocks
    smbus = $smbus
    battery_signature = $sig
}

# ---- 落盘 ----
if (-not (Test-Path $Script:SnapDir)) { New-Item -ItemType Directory -Path $Script:SnapDir -Force | Out-Null }
$file = Join-Path $Script:SnapDir ("snap-{0}-{1}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ($stateLabel -replace '[\\/:*?"<>| ]', '_'))
$snap | ConvertTo-Json | Set-Content -LiteralPath $file -Encoding UTF8

# ---- 人读摘要 ----
Write-Host ''
Write-Host "═══ EC 只读快照 ═══" -ForegroundColor Cyan
Write-Host ("  状态      : {0}（AC={1} 充电={2} 放电={3} 守护停充={4}）" -f $stateLabel, $acOnline, $charging, $discharging, $stopped)
Write-Host ("  电量      : {0}%   ECWR=0x{1:X2}" -f $soc, $ecwr)
Write-Host ("  电池签名  : {0}（校验读取正确性）" -f $(if ($sig -eq 'AEC4168126-4S1P') { "$sig ✔" } else { "$sig ⚠" }))
Write-Host ''
Write-Host '  ── EC RAM 0x0090-0x009F（重点观察区）──' -ForegroundColor Magenta
for ($row = 0; $row -lt 16; $row += 8) {
    $line = ($blocks['0x0090'][$row..($row+7)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    Write-Host ("  {0:X4}: {1}" -f (0x0090 + $row), $line)
}
$batm = $blocks['0x0090'][6]
Write-Host ("  BATM@0x96 = 0x{0:X2}（命名疑似 BATtery Mode，零引用，待多状态对比）" -f $batm) -ForegroundColor Yellow
Write-Host ''
Write-Host '  ── EC RAM 0x0460-0x047F（电池遥测）──' -ForegroundColor Magenta
for ($row = 0; $row -lt 32; $row += 8) {
    $line = ($blocks['0x0460'][$row..($row+7)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    Write-Host ("  {0:X4}: {1}" -f (0x0460 + $row), $line)
}
Write-Host ''
Write-Host '  ── 0x0700-0x070F（14XA 充电区基线，应为全零）──' -ForegroundColor Magenta
$line7 = ($blocks['0x0700'] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
Write-Host ("  0x0700: {0}" -f $line7)
Write-Host ''
Write-Host '  ── SMBus 寄存器 ──' -ForegroundColor Magenta
foreach ($k in @('charger_0x14_current','charger_0x15_voltage','charger_0xFE_mfgid','charger_0xFF_devid',
                 'battery_0x08_temp','battery_0x09_voltage','battery_0x0A_current','battery_0x14_request','battery_0x16_status')) {
    $v = $smbus[$k]
    if ($null -eq $v) { Write-Host ("  {0,-26}: 读取失败（总线瞬态）" -f $k) -ForegroundColor DarkYellow }
    else { Write-Host ("  {0,-26}: 0x{1:X4} ({1})" -f $k, $v) }
}
Write-Host ''
Write-Host ("  快照已保存: {0}" -f $file) -ForegroundColor Green
Write-Host '  下一步：在其他充电状态各拍一张，然后用 -Diff 对比。' -ForegroundColor DarkCyan
