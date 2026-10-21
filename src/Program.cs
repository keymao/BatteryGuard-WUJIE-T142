using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Principal;
using System.Windows.Forms;

[assembly: AssemblyTitle("无界电池管家")]
[assembly: AssemblyProduct("WuJie BatteryGuard")]
[assembly: AssemblyDescription("MECHREVO 无界系列 硬件级电池限充守护")]
[assembly: AssemblyFileVersion("6.0.0.0")]
[assembly: AssemblyCompany("WuJie BatteryGuard Project")]
[assembly: AssemblyCopyright("MIT License")]

namespace WJB
{
    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            NativeMethods.SetProcessDPIAware();
            App.Init();

            string mode = "";
            bool quiet = false;
            if (args != null && args.Length > 0)
            {
                mode = args[0].ToLowerInvariant().TrimStart('-', '/');
                foreach (string a in args) { if (a == "-quiet" || a == "/quiet" || a == "quiet") quiet = true; }
            }

            if (mode == "daemon") { Daemon.Run(); return 0; }
            if (mode == "watchdog") { Daemon.WatchdogRun(); return 0; }
            if (mode == "install") { Installer.Install(!quiet); return 0; }
            if (mode == "uninstall") { Installer.Uninstall(!quiet); return 0; }

            // GUI 模式（自动 UAC 提权）
            if (!Util.IsAdmin())
            {
                try
                {
                    ProcessStartInfo psi = new ProcessStartInfo();
                    psi.FileName = Application.ExecutablePath;
                    psi.Arguments = "-gui";
                    psi.Verb = "runas";
                    psi.UseShellExecute = true;
                    Process.Start(psi);
                    return 0;
                }
                catch
                {
                    MessageBox.Show("需要管理员权限才能控制充电硬件。", "无界电池管家");
                    return 1;
                }
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
            return 0;
        }
    }

    static class NativeMethods
    {
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();
        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        public static extern bool GetSystemPowerStatus(ref POWER_STATUS ps);
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        public struct POWER_STATUS
        {
            public byte ACLineStatus;
            public byte BatteryFlag;
            public byte BatteryLifePercent;
            public byte Reserved1;
            public int BatteryLifeTime;
            public int BatteryFullLifeTime;
        }
    }

    static class App
    {
        public static string ExePath = "";
        public static string DataDir = "";
        public static string CfgFile = "";
        public static string AgentDir = "";
        public static string RuntimeFile = "";
        public static string BlockFile = "";
        public static string LogDir = "";
        public static string DriverDir = "";
        public static string DriverDll = "";

        public static void Init()
        {
            ExePath = Assembly.GetExecutingAssembly().Location;
            string exeDir = Path.GetDirectoryName(ExePath);
            DataDir = exeDir;
            try
            {
                string probe = Path.Combine(exeDir, ".wjbwrite");
                File.WriteAllText(probe, "1");
                File.Delete(probe);
            }
            catch
            {
                DataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "WuJieBatteryGuard");
            }
            try { Directory.CreateDirectory(DataDir); } catch { }
            CfgFile = Path.Combine(DataDir, "batteryguard.config.json");
            AgentDir = Path.Combine(DataDir, "agent");
            RuntimeFile = Path.Combine(AgentDir, "hw-runtime.json");
            BlockFile = Path.Combine(AgentDir, "hardware-block.json");
            LogDir = Path.Combine(DataDir, "logs");
            DriverDir = Path.Combine(DataDir, "driver");
            DriverDll = Path.Combine(DriverDir, "inpoutx64.dll");
        }
    }

    static class Util
    {
        public static bool IsAdmin()
        {
            WindowsIdentity id = WindowsIdentity.GetCurrent();
            WindowsPrincipal p = new WindowsPrincipal(id);
            return p.IsInRole(WindowsBuiltInRole.Administrator);
        }

        public static NativeMethods.POWER_STATUS Power()
        {
            NativeMethods.POWER_STATUS s = new NativeMethods.POWER_STATUS();
            NativeMethods.GetSystemPowerStatus(ref s);
            return s;
        }

        public static List<int> DaemonPids()
        {
            List<int> pids = new List<int>();
            try
            {
                using (System.Management.ManagementObjectSearcher s = new System.Management.ManagementObjectSearcher(
                    "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='BatteryGuard.exe' OR Name='powershell.exe'"))
                {
                    foreach (System.Management.ManagementObject o in s.Get())
                    {
                        string cl = o["CommandLine"] as string;
                        if (string.IsNullOrEmpty(cl)) continue;
                        bool exeDaemon = cl.IndexOf("BatteryGuard.exe", StringComparison.OrdinalIgnoreCase) >= 0
                                      && cl.IndexOf("-daemon", StringComparison.OrdinalIgnoreCase) >= 0;
                        bool legacy = cl.IndexOf("BatteryGuard.ps1", StringComparison.OrdinalIgnoreCase) >= 0
                                   && cl.IndexOf("-Watch", StringComparison.OrdinalIgnoreCase) >= 0;
                        if (exeDaemon || legacy)
                        {
                            try { pids.Add(Convert.ToInt32(o["ProcessId"])); }
                            catch { }
                        }
                    }
                }
            }
            catch { }
            return pids;
        }

        public static bool HasDaemonProcess() { return DaemonPids().Count > 0; }

        public static void KillDaemons()
        {
            foreach (int pid in DaemonPids())
            {
                try { Process.GetProcessById(pid).Kill(); }
                catch { }
            }
        }
    }
}
