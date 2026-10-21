<#
.SYNOPSIS
  无界电池管家 BatteryGuard v5 —— 硬件级充电保护（SMBus 充电芯片直控）
.DESCRIPTION
  基于 EC 逆向 + xcdd/BatteryGuard-for-WUJIE-T142-STX 已验证协议的硬件限充：
  充电到上限 → 经 SMBus master E 向充电芯片(0x09)寄存器 0x14 写 0 停充；
  电量回落到恢复点 → 按电池请求值恢复充电。插电状态下电池稳定维持在区间内。
  安全防线：充电芯片/电池身份硬校验、写后回读、值域检查(64mA 步进)、
  固件重写压制、虚假 Critical 熔断、心跳看门狗、卸载/退出自动恢复。
  硬件不可用时自动回退软提醒模式。
.USAGE
  .\BatteryGuard.ps1 -Status          # 电池+充电控制面板
  .\BatteryGuard.ps1 -TestHardware    # 硬件通道自检（只读）
  .\BatteryGuard.ps1 -Watch           # 常驻守护（需管理员，硬件模式）
  .\BatteryGuard.ps1 -Watchdog        # 看门狗（检查心跳/恢复/重启守护）
  .\BatteryGuard.ps1 -Resume          # 手动恢复充电（应急）
  .\BatteryGuard.ps1 -Config -Max 80 -Recover 75
  .\BatteryGuard.ps1 -Install         # 注册计划任务（登录+看门狗）
  .\BatteryGuard.ps1 -Uninstall       # 恢复充电并移除任务
#>
[CmdletBinding(DefaultParameterSetName='Status')]
param(
    [Parameter(ParameterSetName='Status')][switch]$Status,
    [Parameter(ParameterSetName='Watch')][switch]$Watch,
    [Parameter(ParameterSetName='Watchdog')][switch]$Watchdog,
    [Parameter(ParameterSetName='TestHardware')][switch]$TestHardware,
    [Parameter(ParameterSetName='Resume')][switch]$Resume,
    [Parameter(ParameterSetName='Test')][switch]$TestToast,
    [Parameter(ParameterSetName='Config')][switch]$Config,
    [Parameter(ParameterSetName='Install')][switch]$Install,
    [Parameter(ParameterSetName='Uninstall')][switch]$Uninstall,
    [Parameter(ParameterSetName='ECInfo')][switch]$ECInfo,
    [Parameter(ParameterSetName='Config')][ValidateRange(50,100)][int]$Max = 80,
    [Parameter(ParameterSetName='Config')][ValidateRange(20,99)][int]$Recover = 0,
    [Parameter(ParameterSetName='Config')][ValidateRange(5,60)][int]$Min = 40,
    [Parameter(ParameterSetName='Config')][ValidateRange(10,600)][int]$IntervalSec = 20,
    [Parameter(ParameterSetName='Config')][ValidateRange(0,1440)][int]$FullPlugHours = 2
)

$ErrorActionPreference = 'Stop'
$Script:ToolName = '无界电池管家 BatteryGuard v5'
$Script:ScriptPath = $PSCommandPath
$Script:Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:CfgFile = Join-Path $Script:Dir 'batteryguard.config.json'
$Script:LogDir = Join-Path $Script:Dir 'logs'
$Script:TaskName = 'BatteryGuard'
$Script:TaskWdName = 'BatteryGuardWatchdog'
$Script:DllPath = Join-Path $Script:Dir 'driver\inpoutx64.dll'
$Script:AgentDir = Join-Path $Script:Dir 'agent'
$Script:RuntimeFile = Join-Path $Script:AgentDir 'hw-runtime.json'
$Script:BlockFile = Join-Path $Script:AgentDir 'hardware-block.json'

# ================= C# 硬件层（移植自 STX T142Charger，本机实测验证） =================
$hwCs = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace BatteryGuard.Hw {
    public static class I2ec {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr LoadLibrary(string path);
        [DllImport("inpoutx64.dll", EntryPoint = "IsInpOutDriverOpen")]
        public static extern bool IsOpen();
        [DllImport("inpoutx64.dll", EntryPoint = "DlPortReadPortUchar")]
        static extern byte In(ushort port);
        [DllImport("inpoutx64.dll", EntryPoint = "DlPortWritePortUchar")]
        static extern void Out(ushort port, byte value);

        static byte RegisterRead(byte register) {
            Out(0x4E, 0x2E); Out(0x4F, register); Out(0x4E, 0x2F);
            return In(0x4F);
        }
        static void RegisterWrite(byte register, byte value) {
            Out(0x4E, 0x2E); Out(0x4F, register); Out(0x4E, 0x2F); Out(0x4F, value);
        }
        public static byte Read(ushort address) {
            byte low = RegisterRead(0x10), high = RegisterRead(0x11);
            try {
                RegisterWrite(0x10, (byte)address); RegisterWrite(0x11, (byte)(address >> 8));
                return RegisterRead(0x12);
            } finally {
                RegisterWrite(0x10, low); RegisterWrite(0x11, high);
            }
        }
        public static void Write(ushort address, byte value) {
            byte low = RegisterRead(0x10), high = RegisterRead(0x11);
            try {
                RegisterWrite(0x10, (byte)address); RegisterWrite(0x11, (byte)(address >> 8));
                RegisterWrite(0x12, value);
            } finally {
                RegisterWrite(0x10, low); RegisterWrite(0x11, high);
            }
        }
        public static int ReadWordEc(ushort address) {
            return Read(address) | (Read((ushort)(address + 1)) << 8);
        }
    }

    public static class Charger {
        static readonly Mutex Bus = new Mutex(false, "Global\\BatteryGuard-WUJIE-I2EC");

        static T Exclusive<T>(Func<T> operation) {
            bool acquired = false;
            try {
                try { acquired = Bus.WaitOne(2000); }
                catch (AbandonedMutexException) { acquired = true; }
                if (!acquired) throw new TimeoutException("I2EC is busy");
                return operation();
            } finally { if (acquired) Bus.ReleaseMutex(); }
        }

        static int Transfer(byte address, byte command, bool read, int value) {
            return Exclusive(delegate {
                const ushort routeRegister=0x1C99, masterE=0x1CA0, masterEData1=0x1CA6, masterEControl2=0x1CAA;
                byte savedRoute=I2ec.Read(routeRegister);
                byte savedStatus=I2ec.Read(masterE), savedControl=I2ec.Read((ushort)(masterE+1));
                byte savedCommand=I2ec.Read((ushort)(masterE+2)), savedAddress=I2ec.Read((ushort)(masterE+3));
                byte savedData0=I2ec.Read((ushort)(masterE+4)), savedData1=I2ec.Read(masterEData1);
                byte savedControl2=I2ec.Read(masterEControl2);
                if ((savedStatus&1)!=0 || (savedControl2&1)!=0)
                    throw new InvalidOperationException("SMBus master E is owned or busy");
                bool routeMayHaveChanged=false, transactionStarted=false;
                try {
                    routeMayHaveChanged=true;
                    I2ec.Write(routeRegister,(byte)((savedRoute&0xF8)|0x01));
                    I2ec.Write(masterEControl2,(byte)(savedControl2|0x01));
                    if ((I2ec.Read(masterEControl2)&1)==0) throw new InvalidOperationException("SMBus master E did not enable");

                    I2ec.Write(masterE,0xFE);
                    I2ec.Write((ushort)(masterE+2),command);
                    byte slave=(byte)((address<<1)|(read?1:0));
                    I2ec.Write((ushort)(masterE+3),slave);
                    I2ec.Write((ushort)(masterE+4),(byte)value);
                    I2ec.Write(masterEData1,(byte)(value>>8));
                    var busFree=System.Diagnostics.Stopwatch.StartNew();
                    while((I2ec.Read(0x1C00)&1)!=0 || (I2ec.Read(0x1C0A)&3)!=3){
                        if(busFree.ElapsedMilliseconds>250) throw new IOException("Firmware SMBus master A is still using the physical bus");
                        Thread.Sleep(1);
                    }
                    transactionStarted=true;
                    I2ec.Write((ushort)(masterE+1),0x4C);
                    var timeout=System.Diagnostics.Stopwatch.StartNew();
                    byte status;
                    do {
                        status=I2ec.Read(masterE);
                        if ((status&1)==0 && (status&0x7E)!=0) break;
                        Thread.Sleep(1);
                    } while(timeout.ElapsedMilliseconds<100);
                    if ((status&1)!=0) throw new TimeoutException("SMBus master E did not finish within 100 ms");
                    int result=I2ec.Read((ushort)(masterE+4))|(I2ec.Read(masterEData1)<<8);
                    if (I2ec.Read((ushort)(masterE+2))!=command || I2ec.Read((ushort)(masterE+3))!=slave)
                        throw new InvalidOperationException("SMBus master E response does not match its request");
                    if ((status&0x08)!=0 && (status&0x75)==0)
                        throw new IOException("ARBITRATION");
                    if ((status&0x7D)==0x24)
                        throw new IOException("NACK");
                    if ((status&0x7D)!=0 || (status&0x02)==0)
                        throw new InvalidOperationException("SMBus master E failed; HOSTA=0x"+status.ToString("X2"));
                    if (!read && result!=value)
                        throw new InvalidOperationException("SMBus write data did not match the request");
                    I2ec.Write(masterE,(byte)(status&0xFE));
                    if ((I2ec.Read(masterE)&0xFE)!=0) throw new InvalidOperationException("SMBus master E completion did not clear");
                    return result;
                } finally {
                    if (routeMayHaveChanged) {
                        if (transactionStarted && (I2ec.Read(masterE)&1)!=0) {
                            I2ec.Write((ushort)(masterE+1),(byte)(I2ec.Read((ushort)(masterE+1))|0x02));
                            Thread.Sleep(2);
                            I2ec.Write((ushort)(masterE+1),(byte)(I2ec.Read((ushort)(masterE+1))&0xFD));
                        }
                        if ((I2ec.Read(masterE)&1)==0) I2ec.Write(masterE,(byte)(I2ec.Read(masterE)&0xFE));
                        I2ec.Write(masterEControl2,savedControl2);
                        I2ec.Write((ushort)(masterE+1),savedControl);
                        I2ec.Write((ushort)(masterE+2),savedCommand);
                        I2ec.Write((ushort)(masterE+3),savedAddress);
                        I2ec.Write((ushort)(masterE+4),savedData0);
                        I2ec.Write(masterEData1,savedData1);
                        I2ec.Write(routeRegister,savedRoute);
                    }
                }
            });
        }

        static bool Retryable(IOException e) {
            string m = e.Message;
            return m == "ARBITRATION" || m == "NACK" ||
                   m.Contains("master A is still using") || m.Contains("did not finish");
        }
        static int ReadWord(byte address, byte command) {
            Exception last = null;
            for (int attempt = 0; attempt < 8; attempt++) {
                try { return Transfer(address, command, true, 0); }
                catch (IOException error) {
                    last = error;
                    if (!Retryable(error)) throw;
                    Thread.Sleep(5 + attempt * 5);
                }
            }
            throw new InvalidOperationException("EC SMBus read failed", last);
        }
        static int WriteWord(byte address, byte command, int value) {
            Exception last = null;
            for (int attempt = 0; attempt < 8; attempt++) {
                try {
                    Transfer(address, command, false, value);
                    if (ReadWord(address, command) != value)
                        throw new IOException("VERIFIED_MISMATCH");
                    return value;
                }
                catch (IOException error) {
                    last = error;
                    if (!Retryable(error) && error.Message != "VERIFIED_MISMATCH") throw;
                    Thread.Sleep(5 + attempt * 5);
                }
            }
            throw new InvalidOperationException("EC SMBus write failed", last);
        }

        public static int ReadChargerCurrent() {
            for (int attempt = 0; attempt < 4; attempt++) {
                int first = ReadWord(0x09, 0x14);
                int second = ReadWord(0x09, 0x14);
                if (first == second && first <= 0x0F00 && (first & 0x3F) == 0) return first;
                Thread.Sleep(5);
            }
            throw new IOException("Charger current register is inconsistent");
        }
        public static int ReadBatteryRequest() { return ReadWord(0x0B, 0x14); }
        public static int ReadBatteryStatus() { return ReadWord(0x0B, 0x16); }

        // 通用只读 SMBus word 读（快照/研究用）：仅允许已知从机地址，走与守护同一套
        // 交易/互斥/重试机制；不提供任何写入口（写入仍限定于已验证的充电电流寄存器）。
        public static int ReadSmbusWord(byte address, byte command) {
            if (address != 0x09 && address != 0x0B)
                throw new ArgumentOutOfRangeException("address", "Read-only probe supports charger 0x09 and battery 0x0B only");
            return ReadWord(address, command);
        }

        public static void SetChargeCurrent(int value) {
            if (value < 0 || value > 0x0F00 || (value & 0x3F) != 0)
                throw new ArgumentOutOfRangeException("value", "Current outside the verified original range");
            WriteWord(0x09, 0x14, value);
        }
        public static int EnforcePause() {
            int before = ReadChargerCurrent();
            if (before == 0) return 0;
            SetChargeCurrent(0);
            return before;
        }
        public static string ValidateIdentity() {
            int fe = ReadWord(0x09, 0xFE);
            int ff = ReadWord(0x09, 0xFF);
            if (fe != 0x4F32 || ff != 0x000A)
                throw new InvalidOperationException("Charger identity mismatch: 0x" + fe.ToString("X4") + "/0x" + ff.ToString("X4"));
            byte[] sig = new byte[15];
            for (int i = 0; i < 15; i++) sig[i] = I2ec.Read((ushort)(0x04B0 + i));
            string s = System.Text.Encoding.ASCII.GetString(sig);
            if (s != "AEC4168126-4S1P")
                throw new InvalidOperationException("Battery signature mismatch: " + s);
            return "charger 0x4F32/0x000A, battery AEC4168126-4S1P";
        }
        public static int ReadEcRamWord(ushort address) {
            return Exclusive(delegate { return I2ec.ReadWordEc(address); });
        }
        public static byte ReadEcRamByte(ushort address) {
            return Exclusive(delegate { return I2ec.Read(address); });
        }
    }
}
'@

# ================= 基础设施 =================

function Get-Config {
    $default = [ordered]@{
        MaxThreshold   = 80      # 充电上限(%)：达到后停充
        RecoverAt      = 75      # 恢复充电点(%)：回落到此值以下恢复（浮充窗口）
        MinThreshold   = 40      # 放电下限提醒(%)
        IntervalSec    = 20      # 常规轮询间隔(秒)
        HoldMs         = 500     # 停充维持期间轮询间隔(毫秒)
        FullPlugHours  = 2
        RemindMinutes  = 10
        EnableToast    = $true
        EnableSound    = $true
        LogCsv         = $true
        DesignMWh      = $null
        HardwareMode   = $true   # 硬件限充总开关
    }
    if (Test-Path $Script:CfgFile) {
        try {
            $json = Get-Content $Script:CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($default.Keys)) {
                if ($null -ne $json.$k) { $default[$k] = $json.$k }
            }
        } catch { }
    }
    return $default
}

function Save-Config([hashtable]$cfg) {
    if (-not (Test-Path $Script:AgentDir)) { New-Item -ItemType Directory -Path $Script:AgentDir -Force | Out-Null }
    $cfg | ConvertTo-Json | Set-Content -LiteralPath $Script:CfgFile -Encoding UTF8
}

Add-Type -Namespace Win32 -Name PowerState -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct SYSTEM_POWER_STATUS {
    public byte ACLineStatus; public byte BatteryFlag; public byte BatteryLifePercent;
    public byte Reserved1; public int BatteryLifeTime; public int BatteryFullLifeTime;
}
[DllImport("kernel32.dll")] public static extern bool GetSystemPowerStatus(ref SYSTEM_POWER_STATUS sps);
'@

function Get-PowerStatus {
    $s = New-Object Win32.PowerState+SYSTEM_POWER_STATUS
    [void][Win32.PowerState]::GetSystemPowerStatus([ref]$s)
    [pscustomobject]@{ Percent = [int]$s.BatteryLifePercent; ACOnline = ($s.ACLineStatus -eq 1) }
}

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-Hardware {
    if (Test-Path $Script:BlockFile) { return $false }
    if (-not (Test-Path $Script:DllPath)) { return $false }
    try {
        if (-not ('BatteryGuard.Hw.I2ec' -as [type])) { Add-Type -TypeDefinition $hwCs -Language CSharp }
        if ([BatteryGuard.Hw.I2ec]::LoadLibrary($Script:DllPath) -eq [IntPtr]::Zero) { return $false }
        Start-Sleep -Milliseconds 300
        if (-not [BatteryGuard.Hw.I2ec]::IsOpen()) { return $false }
        [void][BatteryGuard.Hw.Charger]::ValidateIdentity()
        return $true
    } catch { return $false }
}

# EC RAM 电池快照（零 SMBus 交易）
function Get-EcBattery {
    try {
        $ecwr = [int][BatteryGuard.Hw.Charger]::ReadEcRamByte(0x0460)
        $pawt = [int][BatteryGuard.Hw.Charger]::ReadEcRamByte(0x0461)
        $soc  = [int][BatteryGuard.Hw.Charger]::ReadEcRamByte(0x047C)
        $rate = [BatteryGuard.Hw.Charger]::ReadEcRamWord(0x046C)
        $remain = [BatteryGuard.Hw.Charger]::ReadEcRamWord(0x046E)
        $volt = [BatteryGuard.Hw.Charger]::ReadEcRamWord(0x0470)
        return [pscustomobject]@{
            ACOnline = (($ecwr -band 1) -ne 0); BatteryPresent = (($ecwr -band 2) -ne 0)
            Charging = (($ecwr -band 4) -ne 0); Discharging = (($ecwr -band 8) -ne 0)
            CriticalFlag = (($ecwr -band 0x10) -ne 0)
            SoC = $soc; ChargeRate = $rate; Remaining = $remain; VoltageMV = $volt
            AdapterCode = $pawt; Raw = $ecwr
        }
    } catch { return $null }
}

# ================= 运行时状态 =================

function Get-Runtime {
    $state = [ordered]@{
        phase = 'idle'; hw_available = $false; stopped_by_us = $false
        restore_current = 0; last_charger_current = 0
        heartbeat = ''; last_action = ''; error = ''
        last_event = ''; last_event_at = ''
    }
    if (Test-Path $Script:RuntimeFile) {
        try {
            $saved = Get-Content $Script:RuntimeFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $saved.psobject.Properties) {
                if ($state.Contains($p.Name)) { $state[$p.Name] = $p.Value }
            }
        } catch { }
    }
    return $state
}

function Save-Runtime([hashtable]$rt) {
    if (-not (Test-Path $Script:AgentDir)) { New-Item -ItemType Directory -Path $Script:AgentDir -Force | Out-Null }
    $rt.heartbeat = (Get-Date -Format o)
    $rt | ConvertTo-Json | Set-Content -LiteralPath $Script:RuntimeFile -Encoding UTF8
}

# ================= 通知 =================

$Script:AppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

function Send-Alert([string]$title, [string]$msg, [bool]$sound) {
    # Toast 在非交互会话（计划任务/嵌套后台进程）中同步调用可能永久挂起，
    # 改为 fire-and-forget 后台 runspace：卡死只影响后台线程，不阻塞守护主循环
    $inner = {
        param($t, $m, $appId)
        try {
            [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
            [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
            $xmlText = "<toast scenario=`"reminder`"><visual><binding template=`"ToastGeneric`"><text>" + [System.Security.SecurityElement]::Escape($t) + "</text><text>" + [System.Security.SecurityElement]::Escape($m) + "</text></binding></visual><audio silent=`"true`"/></toast>"
            $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
            $xml.LoadXml($xmlText)
            $toast = New-Object Windows.UI.Notifications.ToastNotification($xml)
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        } catch { }
    }
    try {
        $ps2 = [powershell]::Create()
        [void]$ps2.AddScript($inner.ToString()).AddArgument($title).AddArgument($msg).AddArgument($Script:AppId)
        [void]$ps2.BeginInvoke()
    } catch {
        Write-Host "[$(Get-Date -Format HH:mm:ss)] $title - $msg"
    }
    if ($sound) { try { [System.Media.SystemSounds]::Exclamation.Play() } catch { } }
}

# ================= 日志 =================

function Write-HistoryLog([pscustomobject]$bat, [string]$phase) {
    if (-not (Test-Path $Script:LogDir)) { New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null }
    $file = Join-Path $Script:LogDir ("battery-{0}.csv" -f (Get-Date -Format 'yyyy-MM'))
    if (-not (Test-Path $file)) {
        "time,percent,state,voltage_mV,charge_rate,phase" | Set-Content -LiteralPath $file -Encoding UTF8
    }
    Add-Content -LiteralPath $file -Value ('{0},{1},{2},{3},{4},{5}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $bat.SoC, $bat.Raw, $bat.VoltageMV, $bat.ChargeRate, $phase) -Encoding UTF8
}

# ================= 硬件操作 =================

function Invoke-HwStop([hashtable]$rt) {
    $before = [BatteryGuard.Hw.Charger]::EnforcePause()
    if ($before -gt 0) { $rt.restore_current = $before }
    $rt.stopped_by_us = $true
    $rt.phase = 'stopped'
    $rt.last_action = (Get-Date -Format o)
    return $true
}

function Invoke-HwResume([hashtable]$rt) {
    # 恢复值优先取电池实时请求（电池说需要多少就充多少），这是 SBS 正确语义
    $request = [BatteryGuard.Hw.Charger]::ReadBatteryRequest()
    $status = [BatteryGuard.Hw.Charger]::ReadBatteryStatus()
    if ($request -le 0 -or (($status -band 0xD000) -ne 0)) {
        $rt.phase = 'waiting_for_battery'
        return $false
    }
    $value = $request -band 0x3FC0
    if ($rt.restore_current -gt 0) { $value = [math]::Min([int]$rt.restore_current, $value) }
    if ($value -le 0) { $rt.phase = 'waiting_for_battery'; return $false }
    [BatteryGuard.Hw.Charger]::SetChargeCurrent($value)
    $rt.stopped_by_us = $false
    $rt.restore_current = 0
    $rt.phase = 'charging_allowed'
    $rt.last_action = (Get-Date -Format o)
    return $true
}

function Suspend-Hardware([string]$reason) {
    if (-not (Test-Path $Script:AgentDir)) { New-Item -ItemType Directory -Path $Script:AgentDir -Force | Out-Null }
    @{ active = $true; reason = $reason; created_at = (Get-Date -Format o) } | ConvertTo-Json | Set-Content -LiteralPath $Script:BlockFile -Encoding UTF8
}

# ================= 守护主循环 =================

function Start-Watch {
    $cfg = Get-Config
    $admin = Test-Admin
    $hwReady = $false
    if ($admin -and [bool]$cfg.HardwareMode) {
        $hwReady = Initialize-Hardware
    }

    $rt = Get-Runtime
    $rt.hw_available = $hwReady
    Save-Runtime $rt

    $mode = if ($hwReady) { '硬件限充' } else { '软提醒' + $(if (-not $admin) { '（非管理员）' } elseif (-not $cfg.HardwareMode) { '（配置关闭）' } else { '（硬件初始化失败）' }) }
    Write-Host "[$(Get-Date -Format HH:mm:ss)] $Script:ToolName 守护启动：$mode，区间 $($cfg.RecoverAt)%~$($cfg.MaxThreshold)%。" -ForegroundColor Cyan
    Send-Alert -Title $Script:ToolName -Msg "守护已启动（$mode，区间 $($cfg.RecoverAt)%~$($cfg.MaxThreshold)%）" -Sound $false

    $lastLow = [datetime]::MinValue
    $lastFull = [datetime]::MinValue
    $fullSince = $null
    $logMinute = -1
    $notifiedStop = $false
    $notifiedResume = $false

    while ($true) {
        try {
            $cfg = Get-Config
            # v5.1: HardwareMode 热切换——关闭时先恢复充电再停止干预
            $hwActive = $hwReady -and [bool]$cfg.HardwareMode
            if ($hwReady -and -not [bool]$cfg.HardwareMode -and $rt.stopped_by_us) {
                try { [void](Invoke-HwResume $rt) } catch { }
                $rt.phase = 'protection_paused'
                $rt.last_event = '保护已暂停，充电已恢复'
                $rt.last_event_at = (Get-Date -Format o)
                Save-Runtime $rt
            }
            $ec = $null
            if ($hwReady) { $ec = Get-EcBattery }
            $win = Get-PowerStatus
            $soc = if ($ec) { $ec.SoC } else { $win.Percent }
            $acOnline = if ($ec) { $ec.ACOnline } else { $win.ACOnline }
            $now = Get-Date
            $cooldown = [timespan]::FromMinutes([int]$cfg.RemindMinutes)

            # 虚假 Critical 熔断：EC 报临界但 Windows 电量充足 → 停止硬件访问
            if ($ec -and $ec.CriticalFlag -and $win.Percent -gt 20) {
                Suspend-Hardware 'EC reports Critical battery while Windows remaining capacity exceeds 20%'
                Send-Alert -Title '⚠ 硬件守护熔断' -Msg 'EC 与 Windows 电池状态矛盾，已停止一切硬件访问。请人工检查（运行 -Status 查看详情）。' -Sound $true
                $hwReady = $false
                $rt.phase = 'hardware_suspended'
                Save-Runtime $rt
            }

            if ($hwActive -and $acOnline) {
                # ---- 硬件限充逻辑 ----
                $needStop = ($soc -ge $cfg.MaxThreshold) -or ($rt.stopped_by_us -and $soc -gt $cfg.RecoverAt)
                $needResume = ($rt.stopped_by_us -and $soc -le $cfg.RecoverAt)

                if ($needStop -and -not $rt.stopped_by_us) {
                    [void](Invoke-HwStop $rt)
                    $rt.last_event = "硬件停充 @ SoC=$soc%（上限 $($cfg.MaxThreshold)%）"
                    $rt.last_event_at = (Get-Date -Format o)
                    Save-Runtime $rt
                    if (-not $notifiedStop) {
                        Send-Alert -Title '🛡 硬件停充已生效' -Msg "电量 $soc% ≥ 上限 $($cfg.MaxThreshold)%，充电电流已归零。电池将维持在区间内。" -Sound ([bool]$cfg.EnableSound)
                        $notifiedStop = $true; $notifiedResume = $false
                    }
                }
                elseif ($rt.stopped_by_us) {
                    # 停充维持：固件可能周期性重写充电电流，检测到非零立即压制
                    $cur = [BatteryGuard.Hw.Charger]::ReadChargerCurrent()
                    $rt.last_charger_current = $cur
                    if ($cur -gt 0 -and $needStop) {
                        [void](Invoke-HwStop $rt)
                    }
                    elseif ($needResume) {
                        if (Invoke-HwResume $rt) {
                            $rt.last_event = "恢复充电 @ SoC=$soc%（恢复点 $($cfg.RecoverAt)%）"
                            $rt.last_event_at = (Get-Date -Format o)
                            Save-Runtime $rt
                            if (-not $notifiedResume) {
                                Send-Alert -Title '🔌 充电已恢复' -Msg "电量回落至 $soc% ≤ 恢复点 $($cfg.RecoverAt)%，已按电池请求恢复充电。" -Sound $false
                                $notifiedResume = $true; $notifiedStop = $false
                            }
                        }
                    }
                    Save-Runtime $rt
                }
                elseif (-not $rt.stopped_by_us -and $soc -lt $cfg.MaxThreshold) {
                    $rt.phase = 'charging_allowed'
                    # v5.1: 正常充电时也读充电电流，供 GUI 显示
                    try { $rt.last_charger_current = [BatteryGuard.Hw.Charger]::ReadChargerCurrent() } catch { }
                }
            }
            elseif ($hwActive -and -not $acOnline -and $rt.stopped_by_us) {
                # 拔电：充电寄存器无意义，保持状态等待重新插电
                $rt.phase = 'battery'
                Save-Runtime $rt
            }

            # ---- 软提醒（硬件/软件模式共用）----
            if (-not $acOnline -and $soc -le $cfg.MinThreshold -and (($now - $lastLow) -ge $cooldown)) {
                Send-Alert -Title '🔋 电量下限提醒' -Msg "电量仅剩 $soc%（下限 $($cfg.MinThreshold)%）。请插上电源适配器。" -Sound ([bool]$cfg.EnableSound)
                $lastLow = $now
            }
            if ($acOnline -and $soc -ge 95) {
                if (-not $fullSince) { $fullSince = $now }
                if ((($now - $fullSince).TotalHours -ge [int]$cfg.FullPlugHours) -and (($now - $lastFull) -ge [timespan]::FromMinutes(30))) {
                    Send-Alert -Title '⚠ 长期满充' -Msg "电池已在 ≥95% 状态持续充电超过 $([int](($now - $fullSince).TotalHours)) 小时。建议拔电使用。" -Sound ([bool]$cfg.EnableSound)
                    $lastFull = $now
                }
            } else { $fullSince = $null }

            # ---- 日志 ----
            if ([bool]$cfg.LogCsv -and $now.Minute -ne $logMinute -and ($now.Minute % 5) -eq 0) {
                $logMinute = $now.Minute
                $snap = [pscustomobject]@{ SoC = $soc; Raw = $(if ($ec) { $ec.Raw } else { 0 }); VoltageMV = $(if ($ec) { $ec.VoltageMV } else { 0 }); ChargeRate = $(if ($ec) { $ec.ChargeRate } else { 0 }) }
                Write-HistoryLog $snap $rt.phase
            }

            $rt.heartbeat = (Get-Date -Format o)
            $rt.error = ''   # 本轮完整成功：清除上一轮可能残留的瞬态错误（如 SMBus 总线冲突超时）
            Save-Runtime $rt
        } catch {
            # 瞬态错误（SMBus 超时/NACK/仲裁）在共享总线上属预期现象，记录但不致命；
            # 下一轮成功后会自动清除。连续失败由心跳/看门狗夶底。
            $rt.error = $_.Exception.Message
            $rt.heartbeat = (Get-Date -Format o)
            Save-Runtime $rt
        }
        if ($hwReady -and $rt.stopped_by_us) {
            # 停充维持期间快速轮询（毫秒级，防固件重写窗口充电）
            Start-Sleep -Milliseconds ([int]$cfg.HoldMs)
        } else {
            Start-Sleep -Seconds ([int]$cfg.IntervalSec)
        }
    }
}

# ================= 看门狗 =================

function Invoke-Watchdog {
    $rt = Get-Runtime
    $watchProc = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like ('*"' + $Script:ScriptPath + '"*') -and $_.CommandLine -match '-Watch' }
    $alive = ($null -ne $watchProc)
    "watchdog: 守护进程存活=$alive, phase=$($rt.phase), stopped_by_us=$($rt.stopped_by_us)"
    if (-not $alive) {
        if ($rt.stopped_by_us) {
            "守护已退出但充电仍被停 → 尝试恢复充电"
            try {
                if (Initialize-Hardware) {
                    [void](Invoke-HwResume $rt)
                    Save-Runtime $rt
                    "✔ 充电已恢复（phase=$($rt.phase)）"
                    Send-Alert -Title 'BatteryGuard 看门狗' -Msg '守护进程退出后已自动恢复充电。' -Sound $false
                } else { "✘ 硬件不可用，无法自动恢复；请插拔充电器或运行 .\BatteryGuard.ps1 -Resume" }
            } catch { "✘ 恢复失败: $($_.Exception.Message)" }
        }
        "重启守护进程..."
        Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File', "`"$($Script:ScriptPath)`"", '-Watch') -ErrorAction SilentlyContinue
    }
}

# ================= 面板与自检 =================

function Show-StatusPanel {
    $cfg = Get-Config
    $win = Get-PowerStatus
    $rt = Get-Runtime
    $hwOk = $false; $hwNote = ''
    if (Test-Admin) {
        $hwOk = Initialize-Hardware
        if (-not $hwOk -and (Test-Path $Script:BlockFile)) { $hwNote = '硬件访问已被熔断' }
    } else { $hwNote = '（需管理员读取硬件状态）' }

    Write-Host ''
    Write-Host "  ═══════════ $Script:ToolName ═══════════" -ForegroundColor Cyan
    Write-Host ''
    $ec = $null
    if ($hwOk) { $ec = Get-EcBattery }
    $soc = if ($ec) { $ec.SoC } else { $win.Percent }
    $acOnline = if ($ec) { $ec.ACOnline } else { $win.ACOnline }
    $state = if ($ec -and $ec.Charging) { '⚡ 充电中' } elseif ($acOnline) { if ($rt.stopped_by_us) { '🛡 已停充(硬件)' } else { '🔌 已插电' } } else { '🔋 电池供电' }
    Write-Host ("  状态      : {0}    电量: {1}%" -f $state, $soc) -ForegroundColor Green
    if ($ec) {
        Write-Host ("  EC 遥测   : 电压 {0:N2}V  充电速率 {1}  ECWR=0x{2:X2}  适配器代码={3}" -f ($ec.VoltageMV/1000), $ec.ChargeRate, $ec.Raw, $ec.AdapterCode)
        try {
            $cur = [BatteryGuard.Hw.Charger]::ReadChargerCurrent()
            $req = [BatteryGuard.Hw.Charger]::ReadBatteryRequest()
            Write-Host ("  充电芯片  : 电流寄存器 0x{0:X4} ({1}mA)  电池请求 0x{2:X4} ({3}mA)" -f $cur, ($cur*64), $req, ($req*64))
        } catch { Write-Host "  充电芯片  : 读取失败（总线忙）" }
    }
    Write-Host ("  守护模式  : {0}  {1}" -f $(if ($rt.hw_available) { '硬件限充' } else { '软提醒' }), $hwNote)
    Write-Host ("  区间      : {0}% 停充 / {1}% 恢复（浮充窗口）  下限提醒 {2}%" -f $cfg.MaxThreshold, $cfg.RecoverAt, $cfg.MinThreshold) -ForegroundColor DarkCyan
    if ($rt.error) { Write-Host ("  最近错误 : {0}" -f $rt.error) -ForegroundColor Yellow }
    Write-Host ''
}

function Invoke-TestHardware {
    if (-not (Test-Admin)) { Write-Host '需要管理员权限。' -ForegroundColor Yellow; return }
    Write-Host ''
    Write-Host '  ─── 硬件通道自检（只读） ───' -ForegroundColor Cyan
    $ok = Initialize-Hardware
    if (-not $ok) {
        Write-Host '  ✘ 硬件初始化失败（驱动未运行/身份不符/被熔断）' -ForegroundColor Red
        if (Test-Path $Script:BlockFile) { Get-Content $Script:BlockFile -Encoding UTF8 }
        return
    }
    Write-Host '  ✔ InpOut 驱动 + I2EC 通道就绪' -ForegroundColor Green
    try {
        $id = [BatteryGuard.Hw.Charger]::ValidateIdentity()
        Write-Host ("  ✔ 身份校验: {0}" -f $id) -ForegroundColor Green
    } catch { Write-Host "  ✘ $($_.Exception.Message)"; return }
    $ec = Get-EcBattery
    Write-Host ("  EC 电池快照: SoC={0}% AC={1} 充电={2} 放电={3} 电压={4}mV" -f $ec.SoC, $ec.ACOnline, $ec.Charging, $ec.Discharging, $ec.VoltageMV)
    try {
        $cur = [BatteryGuard.Hw.Charger]::ReadChargerCurrent()
        Write-Host ("  ✔ 充电器电流寄存器: 0x{0:X4} ({1} mA)" -f $cur, ($cur * 64))
    } catch { Write-Host "  ✘ 电流寄存器读取失败: $($_.Exception.Message)" -ForegroundColor Yellow }
    try {
        $req = [BatteryGuard.Hw.Charger]::ReadBatteryRequest()
        Write-Host ("  ✔ 电池充电请求: 0x{0:X4} ({1} mA)" -f $req, ($req * 64))
    } catch { Write-Host "  ✘ 电池请求读取失败: $($_.Exception.Message)" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '  说明：写路径（停充/恢复）在守护模式中按需使用；本自检不写任何寄存器。' -ForegroundColor DarkCyan
    Write-Host ''
}

# ================= 计划任务 =================

function Install-Autostart {
    if (-not (Test-Admin)) { Write-Host '安装需要管理员权限（右键管理员运行 PowerShell）。' -ForegroundColor Yellow; return }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($Script:ScriptPath)`" -Watch")
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $Script:TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description '无界电池管家：硬件级充电区间守护' -Force | Out-Null
    Start-ScheduledTask -TaskName $Script:TaskName
    $wdAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($Script:ScriptPath)`" -Watchdog")
    $wdTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(10) -RepetitionInterval (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $Script:TaskWdName -Action $wdAction -Trigger $wdTrigger -Settings $settings -Principal $principal -Description '无界电池管家：看门狗（守护死亡时恢复充电）' -Force | Out-Null
    Write-Host "✔ 已注册守护任务 [$Script:TaskName]（登录自启，管理员权限）与看门狗 [$Script:TaskWdName]（每10分钟）。" -ForegroundColor Green
}

function Uninstall-Autostart {
    try {
        $rt = Get-Runtime
        if ($rt.stopped_by_us -and (Test-Admin)) {
            if (Initialize-Hardware) {
                [void](Invoke-HwResume $rt)
                Save-Runtime $rt
                Write-Host '✔ 已先恢复充电。' -ForegroundColor Green
            } else { Write-Host '⚠ 无法确认恢复充电，请插拔一次充电器或运行 -Resume。' -ForegroundColor Yellow }
        }
    } catch { }
    Unregister-ScheduledTask -TaskName $Script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $Script:TaskWdName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "✔ 已移除计划任务。InpOut 驱动保留（sc stop/delete inpoutx64 可手动卸载）。" -ForegroundColor Green
}

# ================= 主入口 =================

switch ($PSCmdlet.ParameterSetName) {
    'Watch'        { Start-Watch }
    'Watchdog'     { Invoke-Watchdog }
    'TestHardware' { Invoke-TestHardware }
    'Resume'       {
        if (-not (Test-Admin)) { Write-Host '需要管理员权限。' -ForegroundColor Yellow; break }
        $rt = Get-Runtime
        if (Initialize-Hardware) {
            if (Invoke-HwResume $rt) { Save-Runtime $rt; Write-Host "✔ 充电已恢复（phase=$($rt.phase)）。" -ForegroundColor Green }
            else { Save-Runtime $rt; Write-Host "电池未请求充电（可能已满/温度保护），无需恢复。" -ForegroundColor Yellow }
        } else { Write-Host '硬件不可用。' -ForegroundColor Red }
    }
    'Test'         {
        Send-Alert -Title $Script:ToolName -Msg '通知测试成功！' -Sound $true
        Write-Host '✔ 已发送测试通知。'
    }
    'Config'       {
        $cfg = Get-Config
        if ($PSBoundParameters.ContainsKey('Max'))     { $cfg.MaxThreshold = $Max }
        if ($PSBoundParameters.ContainsKey('Recover')) { if ($Recover -gt 0) { $cfg.RecoverAt = $Recover } }
        if ($Recover -eq 0 -and $PSBoundParameters.ContainsKey('Max')) { $cfg.RecoverAt = [math]::Max(20, $Max - 5) }
        if ($PSBoundParameters.ContainsKey('Min'))     { $cfg.MinThreshold = $Min }
        if ($PSBoundParameters.ContainsKey('IntervalSec')) { $cfg.IntervalSec = $IntervalSec }
        if ($PSBoundParameters.ContainsKey('FullPlugHours')){ $cfg.FullPlugHours = $FullPlugHours }
        Save-Config $cfg
        Write-Host ("✔ 配置已保存：{0}% 停充 / {1}% 恢复 / {2}% 下限提醒（守护进程下轮自动生效）。" -f $cfg.MaxThreshold, $cfg.RecoverAt, $cfg.MinThreshold) -ForegroundColor Green
    }
    'Install'      { Install-Autostart }
    'Uninstall'    { Uninstall-Autostart }
    'ECInfo'       {
        if (Test-Admin) {
            $inst = Get-CimInstance -Namespace root\wmi -ClassName MICommonInterface -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($inst) {
                function Invoke-MI([byte[]]$cmd) {
                    $r = Invoke-CimMethod -InputObject $inst -MethodName MiInterface -Arguments @{ InData = $cmd }
                    if ($null -eq $r -or $null -eq $r.OutData) { return $null }
                    return ,@($r.OutData)
                }
                Write-Host "`n  ─── EC 实时读取（MI/WMI 协议） ───" -ForegroundColor Cyan
                foreach ($c in @(@('性能模式',0x0800),@('风扇转速',0x0D00),@('键盘背光档',0x1200),@('Fn 功能锁',0x0B00),@('触控板状态',0x0C00))) {
                    $b = New-Object byte[] 32; $b[0]=0x00; $b[1]=0xFA; $b[2] = [int]$c[1] -band 0xFF; $b[3] = [int]$c[1] -shr 8
                    $out = $null; try { $out = Invoke-MI $b } catch { }
                    if ($null -eq $out) { Write-Host ("  {0,-8}: 无响应" -f $c[0]); continue }
                    $info = switch ([int]$c[1]) {
                        0x0800 { "ITSM=$($out[4])" }
                        0x0D00 { $f2 = ([int]$out[5] -shl 8) -bor $out[4]; $f1 = ([int]$out[7] -shl 8) -bor $out[6]; "Fan1≈$f1 Fan2≈$f2 RPM" }
                        0x1200 { "KBNL=$($out[4])" }
                        0x0B00 { if ($out[4]) {'Fn锁开'} else {'Fn锁关'} }
                        0x0C00 { if ($out[4]) {'触控板禁用'} else {'触控板启用'} }
                    }
                    Write-Host ("  {0,-8}: {1}" -f $c[0], $info)
                }
                Write-Host ''
            }
        } else { Write-Host 'ECInfo 需要管理员权限。' -ForegroundColor Yellow }
    }
    default        { Show-StatusPanel }
}
