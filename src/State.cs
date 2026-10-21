using System;
using System.Collections.Generic;
using System.IO;
using System.Web.Script.Serialization;

namespace WJB
{
    public class Cfg
    {
        public int MaxThreshold = 80;
        public int RecoverAt = 75;
        public int MinThreshold = 40;
        public int IntervalSec = 20;
        public int HoldMs = 500;
        public int FullPlugHours = 2;
        public int RemindMinutes = 10;
        public bool EnableToast = true;
        public bool EnableSound = true;
        public bool LogCsv = true;
        public bool HardwareMode = true;
        public int DesignMWh = 0;
        public int WindowX = -1;          // GUI 窗口位置记忆（-1 = 未保存，居中）
        public int WindowY = -1;

        static JavaScriptSerializer js = new JavaScriptSerializer();

        public static Cfg Load()
        {
            Cfg c = new Cfg();
            try
            {
                if (File.Exists(App.CfgFile))
                {
                    Dictionary<string, object> d = js.Deserialize<Dictionary<string, object>>(File.ReadAllText(App.CfgFile));
                    if (d != null)
                    {
                        c.MaxThreshold = GetInt(d, "MaxThreshold", 80);
                        c.RecoverAt = GetInt(d, "RecoverAt", 75);
                        c.MinThreshold = GetInt(d, "MinThreshold", 40);
                        c.IntervalSec = GetInt(d, "IntervalSec", 20);
                        c.HoldMs = GetInt(d, "HoldMs", 500);
                        c.FullPlugHours = GetInt(d, "FullPlugHours", 2);
                        c.RemindMinutes = GetInt(d, "RemindMinutes", 10);
                        c.EnableToast = GetBool(d, "EnableToast", true);
                        c.EnableSound = GetBool(d, "EnableSound", true);
                        c.LogCsv = GetBool(d, "LogCsv", true);
                        c.HardwareMode = GetBool(d, "HardwareMode", true);
                        c.DesignMWh = GetInt(d, "DesignMWh", 0);
                        c.WindowX = GetInt(d, "WindowX", -1);
                        c.WindowY = GetInt(d, "WindowY", -1);
                    }
                }
            }
            catch { }
            return c;
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(App.DataDir);
                Dictionary<string, object> d = new Dictionary<string, object>();
                d["MaxThreshold"] = MaxThreshold;
                d["RecoverAt"] = RecoverAt;
                d["MinThreshold"] = MinThreshold;
                d["IntervalSec"] = IntervalSec;
                d["HoldMs"] = HoldMs;
                d["FullPlugHours"] = FullPlugHours;
                d["RemindMinutes"] = RemindMinutes;
                d["EnableToast"] = EnableToast;
                d["EnableSound"] = EnableSound;
                d["LogCsv"] = LogCsv;
                d["HardwareMode"] = HardwareMode;
                d["DesignMWh"] = DesignMWh;
                d["WindowX"] = WindowX;
                d["WindowY"] = WindowY;
                File.WriteAllText(App.CfgFile, js.Serialize(d));
            }
            catch { }
        }

        static int GetInt(Dictionary<string, object> d, string k, int def)
        {
            object v;
            if (d.TryGetValue(k, out v) && v != null) { try { return Convert.ToInt32(v); } catch { } }
            return def;
        }
        static bool GetBool(Dictionary<string, object> d, string k, bool def)
        {
            object v;
            if (d.TryGetValue(k, out v) && v != null) { try { return Convert.ToBoolean(v); } catch { } }
            return def;
        }
    }

    public class Rt
    {
        public string phase = "idle";
        public string heartbeat = "";
        public string last_action = "";
        public string error = "";
        public string last_event = "";
        public string last_event_at = "";
        public bool hw_available = false;
        public bool stopped_by_us = false;
        public int restore_current = 0;
        public int last_charger_current = 0;

        static JavaScriptSerializer js = new JavaScriptSerializer();

        public static Rt Load()
        {
            Rt r = new Rt();
            try
            {
                if (File.Exists(App.RuntimeFile))
                {
                    Dictionary<string, object> d = js.Deserialize<Dictionary<string, object>>(File.ReadAllText(App.RuntimeFile));
                    if (d != null)
                    {
                        object v;
                        if (d.TryGetValue("phase", out v) && v != null) r.phase = v.ToString();
                        if (d.TryGetValue("heartbeat", out v) && v != null) r.heartbeat = v.ToString();
                        if (d.TryGetValue("last_action", out v) && v != null) r.last_action = v.ToString();
                        if (d.TryGetValue("error", out v) && v != null) r.error = v.ToString();
                        if (d.TryGetValue("last_event", out v) && v != null) r.last_event = v.ToString();
                        if (d.TryGetValue("last_event_at", out v) && v != null) r.last_event_at = v.ToString();
                        if (d.TryGetValue("hw_available", out v) && v != null) { try { r.hw_available = Convert.ToBoolean(v); } catch { } }
                        if (d.TryGetValue("stopped_by_us", out v) && v != null) { try { r.stopped_by_us = Convert.ToBoolean(v); } catch { } }
                        if (d.TryGetValue("restore_current", out v) && v != null) { try { r.restore_current = Convert.ToInt32(v); } catch { } }
                        if (d.TryGetValue("last_charger_current", out v) && v != null) { try { r.last_charger_current = Convert.ToInt32(v); } catch { } }
                    }
                }
            }
            catch { }
            return r;
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(App.AgentDir);
                Dictionary<string, object> d = new Dictionary<string, object>();
                d["phase"] = phase;
                d["heartbeat"] = heartbeat;
                d["last_action"] = last_action;
                d["error"] = error;
                d["last_event"] = last_event;
                d["last_event_at"] = last_event_at;
                d["hw_available"] = hw_available;
                d["stopped_by_us"] = stopped_by_us;
                d["restore_current"] = restore_current;
                d["last_charger_current"] = last_charger_current;
                File.WriteAllText(App.RuntimeFile, js.Serialize(d));
            }
            catch { }
        }
    }

    public static class CsvLog
    {
        public static void Append(int soc, int ecwr, int voltMv, int rate, string phase)
        {
            try
            {
                Directory.CreateDirectory(App.LogDir);
                string file = Path.Combine(App.LogDir, "battery-" + DateTime.Now.ToString("yyyy-MM") + ".csv");
                if (!File.Exists(file)) File.WriteAllText(file, "time,percent,state,voltage_mV,charge_rate,phase\r\n");
                File.AppendAllText(file, string.Format("{0},{1},{2},{3},{4},{5}\r\n",
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"), soc, ecwr, voltMv, rate, phase));
            }
            catch { }
        }
    }
}
