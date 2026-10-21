using System;
using System.Diagnostics;
using System.IO;
using System.Media;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace WJB
{
    public class EcBat
    {
        public bool AcOnline, Charging, Discharging, Critical, BatteryPresent;
        public int SoC, Rate, Remaining, VoltageMV, AdapterCode, Raw;
    }

    public static class DaemonOps
    {
        public static EcBat ReadEc()
        {
            try
            {
                int ecwr = Charger.ReadEcRamByte(0x0460);
                int pawt = Charger.ReadEcRamByte(0x0461);
                EcBat b = new EcBat();
                b.Raw = ecwr;
                b.AcOnline = (ecwr & 1) != 0;
                b.BatteryPresent = (ecwr & 2) != 0;
                b.Charging = (ecwr & 4) != 0;
                b.Discharging = (ecwr & 8) != 0;
                b.Critical = (ecwr & 0x10) != 0;
                b.AdapterCode = pawt;
                b.SoC = Charger.ReadEcRamByte(0x047C);
                b.Rate = Charger.ReadEcRamWord(0x046C);
                b.Remaining = Charger.ReadEcRamWord(0x046E);
                b.VoltageMV = Charger.ReadEcRamWord(0x0470);
                return b;
            }
            catch { return null; }
        }

        public static void HwStop(Rt rt)
        {
            int before = Charger.EnforcePause();
            if (before > 0) rt.restore_current = before;
            rt.stopped_by_us = true;
            rt.phase = "stopped";
            rt.last_action = DateTime.Now.ToString("o");
        }

        public static bool HwResume(Rt rt)
        {
            int request = Charger.ReadBatteryRequest();
            int status = Charger.ReadBatteryStatus();
            if (request <= 0 || (status & 0xD000) != 0) { rt.phase = "waiting_for_battery"; return false; }
            int value = request & 0x3FC0;
            if (rt.restore_current > 0) value = Math.Min(rt.restore_current, value);
            if (value <= 0) { rt.phase = "waiting_for_battery"; return false; }
            Charger.SetChargeCurrent(value);
            rt.stopped_by_us = false;
            rt.restore_current = 0;
            rt.phase = "charging_allowed";
            rt.last_action = DateTime.Now.ToString("o");
            return true;
        }

        public static void Suspend(string reason)
        {
            try
            {
                Directory.CreateDirectory(App.AgentDir);
                string safe = reason.Replace("\"", "'");
                File.WriteAllText(App.BlockFile,
                    string.Format("{{\"active\":true,\"reason\":\"{0}\",\"created_at\":\"{1}\"}}", safe, DateTime.Now.ToString("o")));
            }
            catch { }
        }
    }

    // Toast 通知：守护进程不再占用托盘图标（修复托盘双图标），
    // 视觉通知经 PowerShell 子进程发送（AUMID 与脚本版一致，已验证可用）；
    // 参数通过环境变量传递，避免引号/XML 双重转义问题。fire-and-forget，失败静默。
    public static class Notifier
    {
        const string Script = @"
$ErrorActionPreference = 'SilentlyContinue'
$t = [Environment]::GetEnvironmentVariable('WJB_TOAST_TITLE')
$m = [Environment]::GetEnvironmentVariable('WJB_TOAST_MSG')
try {
  [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
  [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
  $xmlText = '<toast scenario=""reminder""><visual><binding template=""ToastGeneric""><text>' + [System.Security.SecurityElement]::Escape($t) + '</text><text>' + [System.Security.SecurityElement]::Escape($m) + '</text></binding></visual><audio silent=""true""/></toast>'
  $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
  $xml.LoadXml($xmlText)
  $toast = New-Object Windows.UI.Notifications.ToastNotification($xml)
  [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show($toast)
} catch { }
";

        public static void Toast(string title, string msg, bool sound)
        {
            try
            {
                string ps = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
                if (File.Exists(ps))
                {
                    ProcessStartInfo psi = new ProcessStartInfo();
                    psi.FileName = ps;
                    psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " +
                        Convert.ToBase64String(Encoding.Unicode.GetBytes(Script));
                    psi.UseShellExecute = false;
                    psi.CreateNoWindow = true;
                    psi.EnvironmentVariables["WJB_TOAST_TITLE"] = title == null ? "" : title;
                    psi.EnvironmentVariables["WJB_TOAST_MSG"] = msg == null ? "" : msg;
                    Process.Start(psi);
                }
            }
            catch { }
            if (sound) { try { SystemSounds.Exclamation.Play(); } catch { } }
        }
    }

    public static class Daemon
    {
        public static void Run()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new DaemonCtx());
        }

        public static void WatchdogRun()
        {
            try
            {
                Rt rt = Rt.Load();
                bool alive = Util.HasDaemonProcess();
                if (!alive)
                {
                    if (rt.stopped_by_us)
                    {
                        string err;
                        if (Charger.Ensure(out err))
                        {
                            try { DaemonOps.HwResume(rt); rt.Save(); }
                            catch { }
                        }
                    }
                    try
                    {
                        ProcessStartInfo psi = new ProcessStartInfo();
                        psi.FileName = App.ExePath;
                        psi.Arguments = "-daemon";
                        psi.UseShellExecute = false;
                        psi.CreateNoWindow = true;
                        Process.Start(psi);
                    }
                    catch { }
                }
            }
            catch { }
        }
    }

    class DaemonCtx : ApplicationContext
    {
        Timer timer;
        bool hwOk = false;
        Rt rt = new Rt();
        DateTime next = DateTime.Now;
        PowerWindow pwnd;
        int preSleepSoc = -1;   // 睡前电量，用于唤醒后判断睡眠期间是否被充过电

        bool notifiedStop = false, notifiedResume = false;
        bool lastAcPowerReq = false;   // 电源请求当前状态（避免重复 Set/Clear 计数漂移）
        DateTime lastLow = DateTime.MinValue, lastFull = DateTime.MinValue;
        DateTime fullSince = DateTime.MinValue;
        bool fullActive = false;
        int logMinute = -1;

        public DaemonCtx()
        {
            string err;
            hwOk = Charger.Ensure(out err);
            rt = Rt.Load();
            rt.hw_available = hwOk;
            rt.phase = hwOk ? "starting" : "no_hardware";
            rt.Save();

            // 隐藏消息窗口：接收系统电源广播（WM_POWERBROADCAST），
            // 用于睡眠前最后一次压制充电、唤醒后立即重新接管
            pwnd = new PowerWindow();
            pwnd.OnPowerMsg = OnPowerMsg;

            timer = new Timer();
            timer.Interval = 400;
            timer.Tick += new EventHandler(OnTick);
            timer.Start();
        }

        void OnPowerMsg(int wParam)
        {
            const int PBT_APMSUSPEND = 0x0004;
            const int PBT_APMRESUMEAUTOMATIC = 0x0012;
            if (wParam == PBT_APMSUSPEND) OnSleeping();
            else if (wParam == PBT_APMRESUMEAUTOMATIC) OnResumed();
        }

        // 睡眠前：进程即将被系统冻结，睡眠期间无法压制 EC 固件的充电电流重写（reassertion），
        // 充电会恢复直至充满 —— 这是软件守护的物理边界（EC 无原生限充位可用，见 EC逆向报告）。
        // 此处尽力而为：睡前最后一次把充电电流压成 0，并记录睡前电量供唤醒后对比提示。
        void OnSleeping()
        {
            try
            {
                if (!hwOk) return;
                rt = Rt.Load();
                preSleepSoc = -1;
                try { EcBat ec = DaemonOps.ReadEc(); if (ec != null) preSleepSoc = ec.SoC; } catch { }
                if (rt.stopped_by_us) { DaemonOps.HwStop(rt); rt.Save(); }
            }
            catch { }
        }

        void OnResumed()
        {
            try
            {
                if (!hwOk) return;
                rt = Rt.Load();
                int soc = -1;
                try { EcBat ec = DaemonOps.ReadEc(); if (ec != null) soc = ec.SoC; } catch { }
                if (rt.stopped_by_us)
                {
                    // 唤醒后固件往往已重写充电电流 → 立即重新压制（不等下一轮 Timer）
                    int cur = 0;
                    try { cur = Charger.ReadChargerCurrent(); } catch { }
                    if (cur > 0) { DaemonOps.HwStop(rt); rt.Save(); }
                    if (preSleepSoc >= 0 && soc > preSleepSoc + 1)
                    {
                        rt.last_event = string.Format("睡眠期间充电未受保护：{0}% → {1}%，已重新停充", preSleepSoc, soc);
                        rt.last_event_at = DateTime.Now.ToString("o");
                        rt.Save();
                        Notifier.Toast("🛡 已重新停充",
                            string.Format("睡眠期间充电不受保护，电量 {0}% → {1}%。", preSleepSoc, soc), false);
                    }
                }
            }
            catch { }
            preSleepSoc = -1;
            next = DateTime.MinValue;   // 下一个 Tick 立即做完整评估
        }

        void OnTick(object sender, EventArgs e)
        {
            DateTime now = DateTime.Now;
            if (now < next) return;
            try { DoWork(now); }
            catch (Exception ex) { rt.error = ex.Message; }
            Cfg c = Cfg.Load();
            int delay = (hwOk && rt.stopped_by_us) ? c.HoldMs : c.IntervalSec * 1000;
            if (delay < 200) delay = 200;
            next = DateTime.Now.AddMilliseconds(delay);
        }

        void DoWork(DateTime now)
        {
            Cfg cfg = Cfg.Load();
            bool hwActive = hwOk && cfg.HardwareMode;

            if (hwOk && !cfg.HardwareMode && rt.stopped_by_us)
            {
                try { DaemonOps.HwResume(rt); }
                catch { }
                rt.phase = "protection_paused";
                rt.last_event = "保护已暂停，充电已恢复";
                rt.last_event_at = now.ToString("o");
            }

            EcBat ec = hwOk ? DaemonOps.ReadEc() : null;
            NativeMethods.POWER_STATUS ps = Util.Power();
            int soc = ec != null ? ec.SoC : (int)ps.BatteryLifePercent;
            bool ac = ec != null ? ec.AcOnline : ps.ACLineStatus == 1;
            int winSoc = ps.BatteryLifePercent;

            // 电源请求：插电且保护启用期间阻止系统“超时自动睡眠”（睡眠会冻结守护 → EC 固件恢复充电直至充满）。
            // 拔电/保护暂停/熔断时立即释放，避免用电池时被拦住不睡。仅拦截超时自动睡眠，
            // 手动点“睡眠”、合盖动作不受影响（属于用户主动选择，睡后充电同样不受保护）。
            bool needBlock = ac && hwActive;
            if (needBlock != lastAcPowerReq)
            {
                PowerReq.SetSystemRequired(needBlock);
                lastAcPowerReq = needBlock;
            }

            // 虚假 Critical 熔断
            if (ec != null && ec.Critical && winSoc > 20 && winSoc <= 100)
            {
                DaemonOps.Suspend("EC reports Critical battery while Windows remaining capacity exceeds 20%");
                Balloon("⚠ 硬件守护熔断", "EC 与 Windows 电池状态矛盾，已停止一切硬件访问。", true);
                hwOk = false;
                PowerReq.SetSystemRequired(false);   // 守护已失效，不再阻止自动睡眠
                lastAcPowerReq = false;
                rt.phase = "hardware_suspended";
                rt.Save();
                return;
            }

            if (hwActive && ac)
            {
                bool needStop = soc >= cfg.MaxThreshold || (rt.stopped_by_us && soc > cfg.RecoverAt);
                bool needResume = rt.stopped_by_us && soc <= cfg.RecoverAt;

                int cur = rt.last_charger_current;
                try { cur = Charger.ReadChargerCurrent(); rt.error = ""; }
                catch { }
                rt.last_charger_current = cur;

                if (needStop && !rt.stopped_by_us)
                {
                    DaemonOps.HwStop(rt);
                    rt.last_event = string.Format("硬件停充 @ SoC={0}%（上限 {1}%）", soc, cfg.MaxThreshold);
                    rt.last_event_at = now.ToString("o");
                    if (!notifiedStop)
                    {
                        Balloon("🛡 硬件停充已生效", string.Format("电量 {0}% ≥ 上限 {1}%，充电电流已归零。", soc, cfg.MaxThreshold), cfg.EnableSound);
                        notifiedStop = true; notifiedResume = false;
                    }
                }
                else if (rt.stopped_by_us)
                {
                    if (cur > 0 && needStop)
                    {
                        DaemonOps.HwStop(rt);
                    }
                    else if (needResume && DaemonOps.HwResume(rt))
                    {
                        rt.last_event = string.Format("恢复充电 @ SoC={0}%（恢复点 {1}%）", soc, cfg.RecoverAt);
                        rt.last_event_at = now.ToString("o");
                        if (!notifiedResume)
                        {
                            Balloon("🔌 充电已恢复", string.Format("电量回落至 {0}%，已按电池请求恢复充电。", soc), false);
                            notifiedResume = true; notifiedStop = false;
                        }
                    }
                }
                else
                {
                    rt.phase = "charging_allowed";
                }
            }
            else if (hwActive && !ac && rt.stopped_by_us)
            {
                rt.phase = "battery";
            }

            // 软提醒
            if (!ac && soc <= cfg.MinThreshold && (now - lastLow).TotalMinutes >= cfg.RemindMinutes)
            {
                Balloon("🔋 电量下限提醒", string.Format("电量仅剩 {0}%。请插上电源适配器。", soc), cfg.EnableSound);
                lastLow = now;
            }
            if (ac && soc >= 95)
            {
                if (!fullActive) { fullSince = now; fullActive = true; }
                if ((now - fullSince).TotalHours >= cfg.FullPlugHours && (now - lastFull).TotalMinutes >= 30)
                {
                    Balloon("⚠ 长期满充", string.Format("电池已在 ≥95% 状态持续充电超过 {0} 小时。", (int)(now - fullSince).TotalHours), cfg.EnableSound);
                    lastFull = now;
                }
            }
            else fullActive = false;

            // CSV 日志
            if (cfg.LogCsv && now.Minute != logMinute && now.Minute % 5 == 0)
            {
                logMinute = now.Minute;
                CsvLog.Append(soc, ec != null ? ec.Raw : 0, ec != null ? ec.VoltageMV : 0, ec != null ? ec.Rate : 0, rt.phase);
            }

            rt.heartbeat = now.ToString("o");
            rt.hw_available = hwOk;
            rt.error = "";   // 本轮完整成功：清除上一轮可能残留的瞬态错误（SMBus 总线冲突超时等）
            rt.Save();
        }

        void Balloon(string title, string msg, bool sound)
        {
            Notifier.Toast(title, msg, sound);
        }
    }

    // 隐藏的顶层消息窗口：系统睡眠/唤醒广播（WM_POWERBROADCAST）会送达所有顶层窗口，
    // 守护进程不再有托盘图标（NotifyIcon 自带隐藏窗口），因此自建一个接收广播。
    class PowerWindow : NativeWindow
    {
        public delegate void PowerMsgHandler(int wParam);
        public PowerMsgHandler OnPowerMsg;

        public PowerWindow()
        {
            CreateParams cp = new CreateParams();
            cp.Caption = "WJB.PowerBroadcast";
            cp.Style = unchecked((int)0x80000000);  // WS_POPUP，无 WS_VISIBLE → 隐藏
            CreateHandle(cp);
        }

        protected override void WndProc(ref Message m)
        {
            const int WM_POWERBROADCAST = 0x0218;
            if (m.Msg == WM_POWERBROADCAST && OnPowerMsg != null)
            {
                try { OnPowerMsg(m.WParam.ToInt32()); } catch { }
            }
            base.WndProc(ref m);
        }
    }

    // 电源请求（PowerRequestSystemRequired）：插电保护期间阻止系统“超时自动睡眠”。
    // 进程退出时句柄自动关闭、请求自动释放，不会遗留“睡不下去”的状态。
    static class PowerReq
    {
        // 注意：Flags 必须为 1（POWER_REQUEST_CONTEXT_SIMPLE_STRING）。实测 Flags=0 时
        // PowerCreateRequest 返回 INVALID_PARAMETER（87）导致请求静默失败（防睡眠不生效）。
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct REASON_CONTEXT
        {
            public uint Version;
            public uint Flags;               // 1 = SIMPLE_STRING 模式
            public IntPtr SimpleReasonString;
            public IntPtr Reserved1;         // 对齐到 x64 原生结构大小（32B），防止 API 按 Detailed 布局读取越界
            public IntPtr Reserved2;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr PowerCreateRequest(ref REASON_CONTEXT context);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool PowerSetRequest(IntPtr handle, int type);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool PowerClearRequest(IntPtr handle, int type);

        // POWER_REQUEST_TYPE 枚举：0=DisplayRequired, 1=SystemRequired, 2=AwayMode, 3=ExecutionRequired。
        // 原误用 2，请求被挂到 AWAYMODE 段（部分机型支持不佳）；PowerToys Awake 同款做法是 SystemRequired=1。
        const int PowerRequestSystemRequired = 1;
        static IntPtr handle = IntPtr.Zero;
        static IntPtr reasonPtr = IntPtr.Zero;   // 非托管字符串必须存存活过整个句柄生命周期

        public static void SetSystemRequired(bool on)
        {
            try
            {
                if (on)
                {
                    if (handle == IntPtr.Zero)
                    {
                        if (reasonPtr == IntPtr.Zero)
                            reasonPtr = Marshal.StringToCoTaskMemUni("无界电池管家：限充保护运行中，防止自动睡眠导致充电失控");
                        REASON_CONTEXT ctx = new REASON_CONTEXT();
                        ctx.Version = 0;
                        ctx.Flags = 1;
                        ctx.SimpleReasonString = reasonPtr;
                        handle = PowerCreateRequest(ref ctx);
                    }
                    if (handle != IntPtr.Zero) PowerSetRequest(handle, PowerRequestSystemRequired);
                }
                else if (handle != IntPtr.Zero)
                {
                    PowerClearRequest(handle, PowerRequestSystemRequired);
                }
            }
            catch { }
        }
    }
}
