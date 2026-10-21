using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

namespace WJB
{
    public static class Installer
    {
        public static void Install(bool interactive)
        {
            string msg = "";
            try
            {
                Util.KillDaemons();
                Schtasks("/Delete /F /TN BatteryGuard");
                Schtasks("/Delete /F /TN BatteryGuardWatchdog");

                // 任务 XML 文件方式创建（UTF-16 写盘后经 schtasks /XML 导入）：
                // 规避 schtasks 命令行直接传中文路径（D:\Software\电池保护\...）时的编码问题，
                // 该问题曾导致任务创建失败/路径损坏 → 开机自启不生效。
                RegisterTask("BatteryGuard", BuildDaemonTaskXml());
                RegisterTask("BatteryGuardWatchdog", BuildWatchdogTaskXml());
                Schtasks("/Run /TN BatteryGuard");
                msg = "✔ 已安装开机自启（登录启动守护 + 每 10 分钟看门狗）并已启动守护。";
            }
            catch (Exception ex) { msg = "安装失败: " + ex.Message; }
            if (interactive) MessageBox.Show(msg, "无界电池管家");
        }

        static string XmlEscape(string s)
        {
            if (string.IsNullOrEmpty(s)) return s;
            return s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");
        }

        static string BuildDaemonTaskXml()
        {
            return "<?xml version=\"1.0\" encoding=\"UTF-16\"?>" +
                "<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">" +
                "<RegistrationInfo><Description>无界电池管家守护进程（登录自启）</Description></RegistrationInfo>" +
                "<Triggers><LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers>" +
                "<Principals><Principal id=\"Author\"><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>" +
                "<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>" +
                "<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>" +
                "<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>" +
                "<StartWhenAvailable>true</StartWhenAvailable><Enabled>true</Enabled></Settings>" +
                "<Actions Context=\"Author\"><Exec><Command>" + XmlEscape(App.ExePath) + "</Command><Arguments>-daemon</Arguments></Exec></Actions>" +
                "</Task>";
        }

        static string BuildWatchdogTaskXml()
        {
            string start = DateTime.Now.AddMinutes(1).ToString("yyyy-MM-ddTHH:mm:ss");
            return "<?xml version=\"1.0\" encoding=\"UTF-16\"?>" +
                "<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">" +
                "<RegistrationInfo><Description>无界电池管家看门狗（守护死亡时恢复充电并重启）</Description></RegistrationInfo>" +
                "<Triggers><TimeTrigger><StartBoundary>" + start + "</StartBoundary>" +
                "<Repetition><Interval>PT10M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>" +
                "<Enabled>true</Enabled></TimeTrigger></Triggers>" +
                "<Principals><Principal id=\"Author\"><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>" +
                "<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>" +
                "<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>" +
                "<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>" +
                "<StartWhenAvailable>true</StartWhenAvailable><Enabled>true</Enabled></Settings>" +
                "<Actions Context=\"Author\"><Exec><Command>" + XmlEscape(App.ExePath) + "</Command><Arguments>-watchdog</Arguments></Exec></Actions>" +
                "</Task>";
        }

        static void RegisterTask(string name, string xml)
        {
            string file = Path.Combine(Path.GetTempPath(), "wjb-" + name + ".xml");
            File.WriteAllText(file, xml, Encoding.Unicode);   // UTF-16 LE 带 BOM
            try
            {
                string r = Schtasks("/Create /F /TN " + name + " /XML \"" + file + "\"");
                if (r.IndexOf("ERROR", StringComparison.OrdinalIgnoreCase) >= 0)
                    throw new InvalidOperationException(name + ": " + r.Trim());
            }
            finally { try { File.Delete(file); } catch { } }
        }

        public static void Uninstall(bool interactive)
        {
            string msg = "";
            try
            {
                Rt rt = Rt.Load();
                if (rt.stopped_by_us)
                {
                    string err;
                    if (Charger.Ensure(out err))
                    {
                        try { DaemonOps.HwResume(rt); rt.Save(); }
                        catch { }
                    }
                }
                Util.KillDaemons();
                Schtasks("/Delete /F /TN BatteryGuard");
                Schtasks("/Delete /F /TN BatteryGuardWatchdog");
                msg = "✔ 已移除自启并停止守护（若此前处于停充状态已恢复充电）。InpOut 驱动服务保留。";
            }
            catch (Exception ex) { msg = "卸载失败: " + ex.Message; }
            if (interactive) MessageBox.Show(msg, "无界电池管家");
        }

        public static string Schtasks(string args)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo("schtasks.exe", args);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                using (Process p = Process.Start(psi))
                {
                    p.WaitForExit();
                    string o = p.StandardOutput.ReadToEnd();
                    string e2 = p.StandardError.ReadToEnd();
                    return o + e2;
                }
            }
            catch (Exception ex) { return "ERROR: " + ex.Message; }
        }
    }
}
