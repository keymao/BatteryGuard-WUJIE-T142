<#
.SYNOPSIS
  无界电池管家 GUI —— BatteryGuard v5 可视化控制面板
.DESCRIPTION
  实时显示：电量(EC直读)/充电状态/充电芯片电流寄存器/电池请求/守护心跳/最近事件
  控制：充电区间调节、立即停充/恢复、暂停/恢复保护、守护进程启停
  自动请求管理员权限（UAC），最小化到托盘。
.USAGE
  双击 启动电池管家.bat，或：powershell -STA -ExecutionPolicy Bypass -File BatteryGuardGui.ps1
#>
param()

# ================= STA / 管理员检查 =================
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File', "`"$PSCommandPath`"")
    exit
}
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File', "`"$PSCommandPath`"")
    exit
}

$ErrorActionPreference = 'Continue'
$Script:Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:MainScript = Join-Path $Script:Dir 'BatteryGuard.ps1'
$Script:CfgFile = Join-Path $Script:Dir 'batteryguard.config.json'
$Script:AgentDir = Join-Path $Script:Dir 'agent'
$Script:RuntimeFile = Join-Path $Script:AgentDir 'hw-runtime.json'
$Script:DllPath = Join-Path $Script:Dir 'driver\inpoutx64.dll'

# ================= 硬件层（从主脚本提取同一份 C#，保证协议一致） =================
try {
    $main = Get-Content $Script:MainScript -Raw -Encoding UTF8
    $m = [regex]::Match($main, "(?s)\$hwCs = @'(.*?)'@")
    if (-not $m.Success) { throw '主脚本中未找到硬件层 C# 源' }
    Add-Type -TypeDefinition $m.Groups[1].Value -Language CSharp
    if ([BatteryGuard.Hw.I2ec]::LoadLibrary($Script:DllPath) -eq [IntPtr]::Zero) { throw '无法加载 InpOut DLL（服务未安装？）' }
    Start-Sleep -Milliseconds 300
    if (-not [BatteryGuard.Hw.I2ec]::IsOpen()) { throw 'InpOut 驱动未运行（sc start inpoutx64）' }
    $Script:HwValid = $true
} catch {
    $Script:HwValid = $false
    $Script:HwError = $_.Exception.Message
}

Add-Type -Namespace Win32 -Name PS -MemberDefinition '[StructLayout(LayoutKind.Sequential)] public struct SPS { public byte AC; public byte Flag; public byte Pct; public byte R1; public int Life; public int Full; } [DllImport("kernel32.dll")] public static extern bool GetSystemPowerStatus(ref SPS s);'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ================= 辅助函数 =================

function Get-PowerStatus {
    $s = New-Object Win32.PS+SPS
    [void][Win32.PS]::GetSystemPowerStatus([ref]$s)
    [pscustomobject]@{ Percent = [int]$s.Pct; ACOnline = ($s.AC -eq 1) }
}

function Get-SafeConfig {
    $default = [ordered]@{
        MaxThreshold = 80; RecoverAt = 75; MinThreshold = 40; IntervalSec = 20
        HoldMs = 500; FullPlugHours = 2; RemindMinutes = 10
        EnableToast = $true; EnableSound = $true; LogCsv = $true
        DesignMWh = $null; HardwareMode = $true
    }
    if (Test-Path $Script:CfgFile) {
        try {
            $json = Get-Content $Script:CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($default.Keys)) {   # 键快照，规避 PS5.1 枚举修改异常
                if ($null -ne $json.$k) { $default[$k] = $json.$k }
            }
        } catch { }
    }
    return $default
}

function Save-SafeConfig([hashtable]$cfg) {
    if (-not (Test-Path $Script:AgentDir)) { New-Item -ItemType Directory -Path $Script:AgentDir -Force | Out-Null }
    $cfg | ConvertTo-Json | Set-Content -LiteralPath $Script:CfgFile -Encoding UTF8
}

function Get-RuntimeSafe {
    if (-not (Test-Path $Script:RuntimeFile)) { return $null }
    try { return (Get-Content $Script:RuntimeFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Save-RuntimeField([string]$name, $value) {
    # 供 GUI 与守护协调：读-改-写 runtime（守护每轮会整体覆写，字段语义一致即可）
    $rt = Get-RuntimeSafe
    if ($null -eq $rt) {
        $obj = [ordered]@{}
        $obj[$name] = $value
        $obj.heartbeat = (Get-Date -Format o)
        if (-not (Test-Path $Script:AgentDir)) { New-Item -ItemType Directory -Path $Script:AgentDir -Force | Out-Null }
        $obj | ConvertTo-Json | Set-Content -LiteralPath $Script:RuntimeFile -Encoding UTF8
        return
    }
    $rt | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
    if (-not $rt.PSObject.Properties['heartbeat']) { $rt | Add-Member -NotePropertyName heartbeat -NotePropertyValue (Get-Date -Format o) -Force }
    $rt | ConvertTo-Json | Set-Content -LiteralPath $Script:RuntimeFile -Encoding UTF8
}

function Get-EcBatteryFast {
    if (-not $Script:HwValid) { return $null }
    try {
        $ecwr = [int][BatteryGuard.Hw.Charger]::ReadEcRamByte(0x0460)
        return [pscustomobject]@{
            ACOnline = (($ecwr -band 1) -ne 0)
            Charging = (($ecwr -band 4) -ne 0)
            Discharging = (($ecwr -band 8) -ne 0)
            SoC = [int][BatteryGuard.Hw.Charger]::ReadEcRamByte(0x047C)
            VoltageMV = [BatteryGuard.Hw.Charger]::ReadEcRamWord(0x0470)
            Rate = [BatteryGuard.Hw.Charger]::ReadEcRamWord(0x046C)
        }
    } catch { return $null }
}

function Find-WatchProcess {
    $w = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like ('*"' + $Script:MainScript + '"*') -and $_.CommandLine -match '-Watch' }
    return $w
}

function Add-Log([string]$text) {
    $stamp = Get-Date -Format 'HH:mm:ss'
    [void]$script:listLog.Items.Add("$stamp  $text")
    $script:listLog.TopIndex = [math]::Max(0, $script:listLog.Items.Count - 1)
}

# ================= 手动硬件操作 =================

function Invoke-ManualStop {
    if (-not $Script:HwValid) { [System.Windows.Forms.MessageBox]::Show("硬件层不可用：$($Script:HwError)", '错误'); return }
    try {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
        $before = [BatteryGuard.Hw.Charger]::EnforcePause()
        if ($before -gt 0) { Save-RuntimeField 'restore_current' $before }
        Save-RuntimeField 'stopped_by_us' $true
        Save-RuntimeField 'last_event' 'GUI 手动停充'
        Save-RuntimeField 'last_event_at' (Get-Date -Format o)
        if ($before -gt 0) { Add-Log ("手动停充完成：电流 0x{0:X4}→0（守护将按策略维持）" -f $before) }
        else { Add-Log '充电电流本已为 0（未充电或已停充）' }
    } catch { Add-Log "停充失败：$($_.Exception.Message)" }
    finally { [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default }
}

function Invoke-ManualResume {
    if (-not $Script:HwValid) { [System.Windows.Forms.MessageBox]::Show("硬件层不可用：$($Script:HwError)", '错误'); return }
    try {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
        $request = [BatteryGuard.Hw.Charger]::ReadBatteryRequest()
        $status = [BatteryGuard.Hw.Charger]::ReadBatteryStatus()
        if ($request -le 0 -or (($status -band 0xD000) -ne 0)) {
            Add-Log '电池未请求充电（已满/温度保护/故障告警），无需恢复'
            return
        }
        $value = $request -band 0x3FC0
        $rt = Get-RuntimeSafe
        if ($rt -and [int]$rt.restore_current -gt 0) { $value = [math]::Min([int]$rt.restore_current, $value) }
        if ($value -le 0) { Add-Log '有效恢复电流为 0，取消'; return }
        [BatteryGuard.Hw.Charger]::SetChargeCurrent($value)
        # 同时暂停保护，避免守护 20 秒内再次压制（用户意图=想充电）
        $cfg = Get-SafeConfig
        if ([bool]$cfg.HardwareMode) {
            $cfg.HardwareMode = $false
            Save-SafeConfig $cfg
            Add-Log ("已恢复充电（0x{0:X4}）并自动暂停保护；充满后请点[恢复保护]" -f $value)
        } else {
            Add-Log ("已恢复充电（0x{0:X4}），保护处于暂停状态" -f $value)
        }
        Save-RuntimeField 'stopped_by_us' $false
        Save-RuntimeField 'last_event' 'GUI 恢复充电（暂停保护）'
        Save-RuntimeField 'last_event_at' (Get-Date -Format o)
    } catch { Add-Log "恢复失败：$($_.Exception.Message)" }
    finally { [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default }
}

function Invoke-ToggleProtection {
    $cfg = Get-SafeConfig
    $newVal = -not [bool]$cfg.HardwareMode
    $cfg.HardwareMode = $newVal
    Save-SafeConfig $cfg
    if ($newVal) {
        Add-Log '保护已恢复：守护将在下轮按区间接管'
        $rt = Get-RuntimeSafe
        if ($rt -and [bool]$rt.stopped_by_us) {
            Add-Log '（注意：当前处于停充状态，守护 20 秒内会重新评估）'
        }
    } else {
        # 立即恢复充电（不等守护下轮）
        if ($Script:HwValid) {
            try {
                $request = [BatteryGuard.Hw.Charger]::ReadBatteryRequest()
                $status = [BatteryGuard.Hw.Charger]::ReadBatteryStatus()
                if ($request -gt 0 -and (($status -band 0xD000) -eq 0)) {
                    $value = $request -band 0x3FC0
                    $rt = Get-RuntimeSafe
                    if ($rt -and [int]$rt.restore_current -gt 0) { $value = [math]::Min([int]$rt.restore_current, $value) }
                    if ($value -gt 0) { [BatteryGuard.Hw.Charger]::SetChargeCurrent($value); Add-Log ("保护已暂停并恢复充电（0x{0:X4}）" -f $value) }
                } else { Add-Log '保护已暂停（电池当前未请求充电）' }
            } catch { Add-Log "保护已暂停（恢复充电失败：$($_.Exception.Message)）" }
        } else { Add-Log '保护已暂停' }
        Save-RuntimeField 'stopped_by_us' $false
        Save-RuntimeField 'last_event' 'GUI 暂停保护'
        Save-RuntimeField 'last_event_at' (Get-Date -Format o)
    }
}

function Invoke-StopDaemon {
    $watch = Find-WatchProcess
    if (-not $watch) { Add-Log '守护未在运行'; return }
    $rt = Get-RuntimeSafe
    if ($rt -and [bool]$rt.stopped_by_us) {
        Add-Log '守护停充中，先恢复充电...'
        if ($Script:HwValid) {
            try {
                $request = [BatteryGuard.Hw.Charger]::ReadBatteryRequest()
                $status = [BatteryGuard.Hw.Charger]::ReadBatteryStatus()
                if ($request -gt 0 -and (($status -band 0xD000) -eq 0)) {
                    $value = $request -band 0x3FC0
                    if ([int]$rt.restore_current -gt 0) { $value = [math]::Min([int]$rt.restore_current, $value) }
                    if ($value -gt 0) { [BatteryGuard.Hw.Charger]::SetChargeCurrent($value); Add-Log '充电已恢复' }
                } else { Add-Log '电池未请求充电，无需恢复' }
            } catch { Add-Log "恢复充电失败：$($_.Exception.Message)（插拔充电器可恢复）" }
        }
        Save-RuntimeField 'stopped_by_us' $false
    }
    # 禁用看门狗，防止守护被自动拉起
    try { Disable-ScheduledTask -TaskName 'BatteryGuardWatchdog' -ErrorAction SilentlyContinue | Out-Null } catch { }
    foreach ($p in $watch) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Add-Log '守护进程已停止（看门狗已禁用）'
}

function Invoke-StartDaemon {
    try { Enable-ScheduledTask -TaskName 'BatteryGuardWatchdog' -ErrorAction SilentlyContinue | Out-Null } catch { }
    $existing = Find-WatchProcess
    if ($existing) { Add-Log '守护已在运行'; return }
    Start-Process powershell -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File', "`"$($Script:MainScript)`"", '-Watch')
    Add-Log '守护进程已启动（看门狗已启用）'
}

# ================= UI 构建 =================

$font = 'Microsoft YaHei UI'
$fontB = New-Object System.Drawing.Font($font, 12, [System.Drawing.FontStyle]::Bold)
$fontN = New-Object System.Drawing.Font($font, 9.5)
$fontBig = New-Object System.Drawing.Font($font, 40, [System.Drawing.FontStyle]::Bold)
$fontSmall = New-Object System.Drawing.Font($font, 8.5)

$form = New-Object System.Windows.Forms.Form
$form.Text = '无界电池管家 v5'
$form.Size = New-Object System.Drawing.Size(600, 720)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = $fontN
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 250)
try { $form.Icon = [System.Drawing.SystemIcons]::Shield } catch { }

# ---- 顶部：大字电量 + 状态 ----
$grpTop = New-Object System.Windows.Forms.GroupBox
$grpTop.Text = ' 电池状态（EC 实时直读） '
$grpTop.SetBounds(12, 10, 566, 150)
$grpTop.Font = $fontN

$script:lblSoC = New-Object System.Windows.Forms.Label
$script:lblSoC.Text = '--%'
$script:lblSoC.Font = $fontBig
$script:lblSoC.ForeColor = [System.Drawing.Color]::FromArgb(46, 108, 230)
$script:lblSoC.SetBounds(20, 30, 150, 70)
$script:lblSoC.TextAlign = 'MiddleCenter'
$grpTop.Controls.Add($script:lblSoC)

$script:lblState = New-Object System.Windows.Forms.Label
$script:lblState.Text = '初始化...'
$script:lblState.Font = $fontB
$script:lblState.ForeColor = [System.Drawing.Color]::DimGray
$script:lblState.SetBounds(185, 30, 370, 30)
$grpTop.Controls.Add($script:lblState)

$script:lblDetail = New-Object System.Windows.Forms.Label
$script:lblDetail.Text = ''
$script:lblDetail.Font = $fontSmall
$script:lblDetail.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
$script:lblDetail.SetBounds(185, 64, 370, 76)
$grpTop.Controls.Add($script:lblDetail)
$form.Controls.Add($grpTop)

# ---- 守护状态 ----
$grpDaemon = New-Object System.Windows.Forms.GroupBox
$grpDaemon.Text = ' 守护进程 '
$grpDaemon.SetBounds(12, 168, 566, 92)
$grpDaemon.Font = $fontN

$script:lblDaemon = New-Object System.Windows.Forms.Label
$script:lblDaemon.Text = '检测中...'
$script:lblDaemon.Font = $fontN
$script:lblDaemon.SetBounds(16, 24, 380, 56)
$script:lblDaemon.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
$grpDaemon.Controls.Add($script:lblDaemon)

$script:btnDaemonStart = New-Object System.Windows.Forms.Button
$script:btnDaemonStart.Text = '启动'
$script:btnDaemonStart.SetBounds(404, 22, 70, 28)
$script:btnDaemonStart.Add_Click({ Invoke-StartDaemon; Update-All })
$grpDaemon.Controls.Add($script:btnDaemonStart)

$script:btnDaemonStop = New-Object System.Windows.Forms.Button
$script:btnDaemonStop.Text = '停止'
$script:btnDaemonStop.SetBounds(482, 22, 70, 28)
$script:btnDaemonStop.Add_Click({ Invoke-StopDaemon; Update-All })
$grpDaemon.Controls.Add($script:btnDaemonStop)

$script:btnDaemonRestart = New-Object System.Windows.Forms.Button
$script:btnDaemonRestart.Text = '重启'
$script:btnDaemonRestart.SetBounds(404, 54, 148, 28)
$script:btnDaemonRestart.Add_Click({ Invoke-StopDaemon; Start-Sleep -Milliseconds 800; Invoke-StartDaemon; Update-All })
$grpDaemon.Controls.Add($script:btnDaemonRestart)
$form.Controls.Add($grpDaemon)

# ---- 区间配置 ----
$grpCfg = New-Object System.Windows.Forms.GroupBox
$grpCfg.Text = ' 充电区间（守护 20 秒内自动生效） '
$grpCfg.SetBounds(12, 268, 566, 100)
$grpCfg.Font = $fontN

$lbl1 = New-Object System.Windows.Forms.Label
$lbl1.Text = '停充上限 %'
$lbl1.SetBounds(20, 30, 80, 20)
$grpCfg.Controls.Add($lbl1)
$script:numMax = New-Object System.Windows.Forms.NumericUpDown
$script:numMax.Minimum = 50; $script:numMax.Maximum = 100; $script:numMax.Value = 80
$script:numMax.SetBounds(100, 27, 60, 26)
$grpCfg.Controls.Add($script:numMax)

$lbl2 = New-Object System.Windows.Forms.Label
$lbl2.Text = '恢复点 %'
$lbl2.SetBounds(180, 30, 70, 20)
$grpCfg.Controls.Add($lbl2)
$script:numRecover = New-Object System.Windows.Forms.NumericUpDown
$script:numRecover.Minimum = 20; $script:numRecover.Maximum = 99; $script:numRecover.Value = 75
$script:numRecover.SetBounds(250, 27, 60, 26)
$grpCfg.Controls.Add($script:numRecover)

$lbl3 = New-Object System.Windows.Forms.Label
$lbl3.Text = '下限提醒 %'
$lbl3.SetBounds(330, 30, 80, 20)
$grpCfg.Controls.Add($lbl3)
$script:numMin = New-Object System.Windows.Forms.NumericUpDown
$script:numMin.Minimum = 5; $script:numMin.Maximum = 60; $script:numMin.Value = 40
$script:numMin.SetBounds(412, 27, 60, 26)
$grpCfg.Controls.Add($script:numMin)

$script:btnApply = New-Object System.Windows.Forms.Button
$script:btnApply.Text = '应用配置'
$script:btnApply.SetBounds(180, 58, 150, 30)
$script:btnApply.Add_Click({
    $cfg = Get-SafeConfig
    $cfg.MaxThreshold = [int]$script:numMax.Value
    $cfg.RecoverAt = [int]$script:numRecover.Value
    $cfg.MinThreshold = [int]$script:numMin.Value
    Save-SafeConfig $cfg
    Add-Log ("配置已保存：$($cfg.RecoverAt)%~$($cfg.MaxThreshold)% 停充窗口，$($cfg.MinThreshold)% 下限提醒")
})
$grpCfg.Controls.Add($script:btnApply)
$form.Controls.Add($grpCfg)

# ---- 手动控制 ----
$grpCtrl = New-Object System.Windows.Forms.GroupBox
$grpCtrl.Text = ' 手动控制 '
$grpCtrl.SetBounds(12, 376, 566, 76)
$grpCtrl.Font = $fontN

$script:btnStopNow = New-Object System.Windows.Forms.Button
$script:btnStopNow.Text = '🛡 立即停充'
$script:btnStopNow.SetBounds(20, 26, 160, 36)
$script:btnStopNow.Add_Click({ Invoke-ManualStop; Update-All })
$grpCtrl.Controls.Add($script:btnStopNow)

$script:btnResumeNow = New-Object System.Windows.Forms.Button
$script:btnResumeNow.Text = '🔌 恢复充电'
$script:btnResumeNow.SetBounds(196, 26, 160, 36)
$script:btnResumeNow.Add_Click({ Invoke-ManualResume; Update-All })
$grpCtrl.Controls.Add($script:btnResumeNow)

$script:btnPause = New-Object System.Windows.Forms.Button
$script:btnPause.Text = '⏸ 暂停保护'
$script:btnPause.SetBounds(372, 26, 174, 36)
$script:btnPause.Add_Click({ Invoke-ToggleProtection; Update-All })
$grpCtrl.Controls.Add($script:btnPause)
$form.Controls.Add($grpCtrl)

# ---- 事件日志 ----
$grpLog = New-Object System.Windows.Forms.GroupBox
$grpLog.Text = ' 事件日志 '
$grpLog.SetBounds(12, 460, 566, 190)
$grpLog.Font = $fontN

$script:listLog = New-Object System.Windows.Forms.ListBox
$script:listLog.SetBounds(14, 24, 538, 156)
$script:listLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:listLog.HorizontalScrollbar = $true
$grpLog.Controls.Add($script:listLog)
$form.Controls.Add($grpLog)

$script:lblFoot = New-Object System.Windows.Forms.Label
$script:lblFoot.Text = '关闭窗口=最小化到托盘；托盘右键可退出。关机插电不受保护（会充满）。'
$script:lblFoot.Font = $fontSmall
$script:lblFoot.ForeColor = [System.Drawing.Color]::Gray
$script:lblFoot.SetBounds(14, 654, 560, 20)
$form.Controls.Add($script:lblFoot)

# ---- 托盘 ----
$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Text = '无界电池管家 v5'
try { $script:tray.Icon = [System.Drawing.SystemIcons]::Shield } catch { }
$script:tray.Visible = $true
$script:tray.ContextMenu = New-Object System.Windows.Forms.ContextMenu
[void]$script:tray.ContextMenu.MenuItems.Add('显示面板', { $script:form.Show(); $script:form.WindowState = 'Normal'; $script:form.Activate() })
[void]$script:tray.ContextMenu.MenuItems.Add('立即停充', { Invoke-ManualStop; Update-All })
[void]$script:tray.ContextMenu.MenuItems.Add('恢复充电', { Invoke-ManualResume; Update-All })
[void]$script:tray.ContextMenu.MenuItems.Add('-')
[void]$script:tray.ContextMenu.MenuItems.Add('退出', {
    $script:tray.Visible = $false
    $script:form.Close()
    [System.Windows.Forms.Application]::Exit()
})
$script:tray.Add_DoubleClick({ $script:form.Show(); $script:form.WindowState = 'Normal'; $script:form.Activate() })

# ---- 最小化到托盘 ----
$form.Add_FormClosing({
    param($s, $e)
    if ($s.Tag -eq 'realExit') { $script:tray.Visible = $false; return }
    $e.Cancel = $true
    $s.Hide()
    try { $script:tray.ShowBalloonTip(2000, '无界电池管家', '已最小化到托盘，双击图标恢复。', 'Info') } catch { }
})

# ================= 状态刷新 =================

$script:lastPhase = ''
$script:lastStopped = $null
$script:lastEventAt = ''

function Update-All {
    $ec = Get-EcBatteryFast
    $win = Get-PowerStatus
    $rt = Get-RuntimeSafe
    $cfg = Get-SafeConfig

    $soc = if ($ec) { $ec.SoC } else { $win.Percent }
    $acOnline = if ($ec) { $ec.ACOnline } else { $win.ACOnline }
    $charging = if ($ec) { $ec.Charging } else { $false }

    # 停充态判定：runtime stopped_by_us 优先，否则看 EC
    $stopped = if ($rt -and $rt.PSObject.Properties['stopped_by_us']) { [bool]$rt.stopped_by_us } else { $false }
    $paused = -not [bool]$cfg.HardwareMode

    # 大字与状态
    $script:lblSoC.Text = "$soc%"
    if (-not $acOnline) {
        $script:lblSoC.ForeColor = [System.Drawing.Color]::FromArgb(230, 126, 34)
        $stateTxt = '🔋 电池供电'
    } elseif ($stopped) {
        $script:lblSoC.ForeColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
        $stateTxt = '🛡 已停充（硬件）'
    } elseif ($charging) {
        $script:lblSoC.ForeColor = [System.Drawing.Color]::FromArgb(46, 150, 80)
        $stateTxt = '⚡ 充电中'
    } else {
        $script:lblSoC.ForeColor = [System.Drawing.Color]::FromArgb(46, 108, 230)
        $stateTxt = '🔌 已插电（未充电）'
    }
    if ($paused) { $stateTxt += ' [保护已暂停]' }
    $script:lblState.Text = $stateTxt

    # 详情行
    $lines = @()
    if ($ec) { $lines += ("电压 {0:N2} V" -f ($ec.VoltageMV / 1000)) } else { $lines += '电压 --（硬件层不可用）' }
    if ($rt -and $rt.PSObject.Properties['last_charger_current']) {
        $cur = [int]$rt.last_charger_current
        $lines += ("充电芯片电流寄存器 0x{0:X4}（{1} mA）" -f $cur, ($cur * 64))
    } else { $lines += '充电芯片电流寄存器 --' }
    if ($rt -and $rt.PSObject.Properties['heartbeat']) {
        $age = [int]((Get-Date) - [datetime]$rt.heartbeat).TotalSeconds
        $hbState = if ($age -lt 45) { '● 正常' } elseif ($age -lt 120) { '● 迟滞' } else { '● 异常' }
        $lines += ("守护心跳 {0}s 前 {1}   phase={2}" -f $age, $hbState, $rt.phase)
    } else { $lines += '守护心跳 --（守护未运行）' }
    if ($rt -and $rt.PSObject.Properties['last_event'] -and $rt.last_event) {
        $when = ''
        if ($rt.PSObject.Properties['last_event_at'] -and $rt.last_event_at) {
            try { $when = (Get-Date -Date $rt.last_event_at -Format 'HH:mm') } catch { }
        }
        $lines += "最近事件 [$when] $($rt.last_event)"
    }
    if ($rt -and $rt.error) { $lines += "守护错误：$($rt.error)" }
    $script:lblDetail.Text = ($lines -join "`n")

    # 守护块
    $watch = Find-WatchProcess
    $watchAlive = ($null -ne $watch -and @($watch).Count -gt 0)
    $rtHw = if ($rt -and $rt.PSObject.Properties['hw_available']) { [bool]$rt.hw_available } else { $false }
    if ($watchAlive) {
        $mode = if ($rtHw) { '硬件限充' } else { '软提醒' }
        if ($paused) { $mode += '（已暂停）' }
        $script:lblDaemon.Text = "● 守护运行中（$mode）`n区间 $($cfg.RecoverAt)% ~ $($cfg.MaxThreshold)% 停充 / $($cfg.MinThreshold)% 下限提醒"
    } else {
        $script:lblDaemon.Text = "○ 守护未运行（电池不受限充保护）`n区间 $($cfg.RecoverAt)% ~ $($cfg.MaxThreshold)% 停充 / $($cfg.MinThreshold)% 下限提醒"
    }

    # 暂停按钮文字
    $script:btnPause.Text = if ($paused) { '▶ 恢复保护' } else { '⏸ 暂停保护' }

    # 事件变化 → 日志
    if ($rt) {
        $curPhase = [string]$rt.phase
        $curStopped = if ($rt.PSObject.Properties['stopped_by_us']) { [bool]$rt.stopped_by_us } else { $null }
        $curEventAt = if ($rt.PSObject.Properties['last_event_at']) { [string]$rt.last_event_at } else { '' }
        if ($curEventAt -and $curEventAt -ne $script:lastEventAt) {
            $script:lastEventAt = $curEventAt
            if ($rt.last_event) { Add-Log $rt.last_event }
        }
        if ($curPhase -ne $script:lastPhase -and $curPhase) {
            $script:lastPhase = $curPhase
        }
        if ($null -ne $curStopped -and $null -ne $script:lastStopped -and $curStopped -ne $script:lastStopped) {
            Add-Log ("充电控制状态切换：{0}" -f $(if ($curStopped) { '停充' } else { '允许充电' }))
        }
        $script:lastStopped = $curStopped
    }

    # 托盘文字
    $script:tray.Text = "无界电池管家 {0}% {1}" -f $soc, $(if ($stopped) { '已停充' } elseif ($charging) { '充电中' } elseif (-not $acOnline) { '电池' } else { '插电' })
}

# ================= 初始化 =================

# 载入当前配置到控件
$cfgNow = Get-SafeConfig
$script:numMax.Value = [int]$cfgNow.MaxThreshold
$script:numRecover.Value = [int]$cfgNow.RecoverAt
$script:numMin.Value = [int]$cfgNow.MinThreshold

Add-Log "GUI 启动（硬件层：$(if ($Script:HwValid) { '就绪' } else { "不可用 - $($Script:HwError)" })）"
if (-not $Script:HwValid) {
    Add-Log '提示：硬件层不可用时仅能查看守护状态与调整配置'
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Update-All })
$timer.Start()

Update-All

[void]$form.ShowDialog()
$timer.Stop()
$script:tray.Visible = $false
