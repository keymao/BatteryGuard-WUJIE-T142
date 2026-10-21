using System;
using System.IO;
using System.Reflection;
using System.ServiceProcess;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace WJB
{
    public static class I2ec
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr LoadLibrary(string path);
        [DllImport("inpoutx64.dll", EntryPoint = "IsInpOutDriverOpen")]
        public static extern bool IsOpen();
        [DllImport("inpoutx64.dll", EntryPoint = "DlPortReadPortUchar")]
        static extern byte In(ushort port);
        [DllImport("inpoutx64.dll", EntryPoint = "DlPortWritePortUchar")]
        static extern void Out(ushort port, byte value);

        static bool loaded = false;

        public static bool Load(string dllPath)
        {
            if (loaded && IsOpen()) return true;
            if (LoadLibrary(dllPath) == IntPtr.Zero) return false;
            loaded = true;
            Thread.Sleep(300);
            if (IsOpen()) return true;
            try
            {
                using (ServiceController sc = new ServiceController("inpoutx64"))
                {
                    if (sc.Status == ServiceControllerStatus.Stopped)
                    {
                        sc.Start();
                        try { sc.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(12)); }
                        catch { }
                    }
                }
            }
            catch { }
            Thread.Sleep(400);
            return IsOpen();
        }

        static byte RegisterRead(byte register)
        {
            Out(0x4E, 0x2E); Out(0x4F, register); Out(0x4E, 0x2F);
            return In(0x4F);
        }
        static void RegisterWrite(byte register, byte value)
        {
            Out(0x4E, 0x2E); Out(0x4F, register); Out(0x4E, 0x2F); Out(0x4F, value);
        }
        public static byte Read(ushort address)
        {
            byte low = RegisterRead(0x10), high = RegisterRead(0x11);
            try
            {
                RegisterWrite(0x10, (byte)address); RegisterWrite(0x11, (byte)(address >> 8));
                return RegisterRead(0x12);
            }
            finally { RegisterWrite(0x10, low); RegisterWrite(0x11, high); }
        }
        public static void Write(ushort address, byte value)
        {
            byte low = RegisterRead(0x10), high = RegisterRead(0x11);
            try
            {
                RegisterWrite(0x10, (byte)address); RegisterWrite(0x11, (byte)(address >> 8));
                RegisterWrite(0x12, value);
            }
            finally { RegisterWrite(0x10, low); RegisterWrite(0x11, high); }
        }
        public static int ReadWordEc(ushort address)
        {
            return Read(address) | (Read((ushort)(address + 1)) << 8);
        }
    }

    public static class Charger
    {
        static readonly Mutex Bus = new Mutex(false, "Global\\BatteryGuard-WUJIE-I2EC");

        static T Exclusive<T>(Func<T> operation)
        {
            bool acquired = false;
            try
            {
                try { acquired = Bus.WaitOne(2000); }
                catch (AbandonedMutexException) { acquired = true; }
                if (!acquired) throw new System.TimeoutException("I2EC is busy");
                return operation();
            }
            finally { if (acquired) Bus.ReleaseMutex(); }
        }

        static int Transfer(byte address, byte command, bool read, int value)
        {
            return Exclusive(delegate
            {
                const ushort routeRegister = 0x1C99, masterE = 0x1CA0, masterEData1 = 0x1CA6, masterEControl2 = 0x1CAA;
                byte savedRoute = I2ec.Read(routeRegister);
                byte savedStatus = I2ec.Read(masterE), savedControl = I2ec.Read((ushort)(masterE + 1));
                byte savedCommand = I2ec.Read((ushort)(masterE + 2)), savedAddress = I2ec.Read((ushort)(masterE + 3));
                byte savedData0 = I2ec.Read((ushort)(masterE + 4)), savedData1 = I2ec.Read(masterEData1);
                byte savedControl2 = I2ec.Read(masterEControl2);
                if ((savedStatus & 1) != 0 || (savedControl2 & 1) != 0)
                    throw new InvalidOperationException("SMBus master E is owned or busy");
                bool routeMayHaveChanged = false, transactionStarted = false;
                try
                {
                    routeMayHaveChanged = true;
                    I2ec.Write(routeRegister, (byte)((savedRoute & 0xF8) | 0x01));
                    I2ec.Write(masterEControl2, (byte)(savedControl2 | 0x01));
                    if ((I2ec.Read(masterEControl2) & 1) == 0) throw new InvalidOperationException("SMBus master E did not enable");

                    I2ec.Write(masterE, 0xFE);
                    I2ec.Write((ushort)(masterE + 2), command);
                    byte slave = (byte)((address << 1) | (read ? 1 : 0));
                    I2ec.Write((ushort)(masterE + 3), slave);
                    I2ec.Write((ushort)(masterE + 4), (byte)value);
                    I2ec.Write(masterEData1, (byte)(value >> 8));
                    System.Diagnostics.Stopwatch busFree = System.Diagnostics.Stopwatch.StartNew();
                    while ((I2ec.Read(0x1C00) & 1) != 0 || (I2ec.Read(0x1C0A) & 3) != 3)
                    {
                        if (busFree.ElapsedMilliseconds > 250) throw new IOException("Firmware SMBus master A is still using the physical bus");
                        Thread.Sleep(1);
                    }
                    transactionStarted = true;
                    I2ec.Write((ushort)(masterE + 1), 0x4C);
                    System.Diagnostics.Stopwatch timeout = System.Diagnostics.Stopwatch.StartNew();
                    byte status;
                    do
                    {
                        status = I2ec.Read(masterE);
                        if ((status & 1) == 0 && (status & 0x7E) != 0) break;
                        Thread.Sleep(1);
                    } while (timeout.ElapsedMilliseconds < 100);
                    if ((status & 1) != 0) throw new System.TimeoutException("SMBus master E did not finish within 100 ms");
                    int result = I2ec.Read((ushort)(masterE + 4)) | (I2ec.Read(masterEData1) << 8);
                    if (I2ec.Read((ushort)(masterE + 2)) != command || I2ec.Read((ushort)(masterE + 3)) != slave)
                        throw new InvalidOperationException("SMBus master E response does not match its request");
                    if ((status & 0x08) != 0 && (status & 0x75) == 0)
                        throw new IOException("ARBITRATION");
                    if ((status & 0x7D) == 0x24)
                        throw new IOException("NACK");
                    if ((status & 0x7D) != 0 || (status & 0x02) == 0)
                        throw new InvalidOperationException("SMBus master E failed; HOSTA=0x" + status.ToString("X2"));
                    if (!read && result != value)
                        throw new InvalidOperationException("SMBus write data did not match the request");
                    I2ec.Write(masterE, (byte)(status & 0xFE));
                    if ((I2ec.Read(masterE) & 0xFE) != 0) throw new InvalidOperationException("SMBus master E completion did not clear");
                    return result;
                }
                finally
                {
                    if (routeMayHaveChanged)
                    {
                        if (transactionStarted && (I2ec.Read(masterE) & 1) != 0)
                        {
                            I2ec.Write((ushort)(masterE + 1), (byte)(I2ec.Read((ushort)(masterE + 1)) | 0x02));
                            Thread.Sleep(2);
                            I2ec.Write((ushort)(masterE + 1), (byte)(I2ec.Read((ushort)(masterE + 1)) & 0xFD));
                        }
                        if ((I2ec.Read(masterE) & 1) == 0) I2ec.Write(masterE, (byte)(I2ec.Read(masterE) & 0xFE));
                        I2ec.Write(masterEControl2, savedControl2);
                        I2ec.Write((ushort)(masterE + 1), savedControl);
                        I2ec.Write((ushort)(masterE + 2), savedCommand);
                        I2ec.Write((ushort)(masterE + 3), savedAddress);
                        I2ec.Write((ushort)(masterE + 4), savedData0);
                        I2ec.Write(masterEData1, savedData1);
                        I2ec.Write(routeRegister, savedRoute);
                    }
                }
            });
        }

        static bool Retryable(IOException e)
        {
            string m = e.Message;
            return m == "ARBITRATION" || m == "NACK" ||
                   m.Contains("master A is still using") || m.Contains("did not finish");
        }
        static int ReadWord(byte address, byte command)
        {
            Exception last = null;
            for (int attempt = 0; attempt < 8; attempt++)
            {
                try { return Transfer(address, command, true, 0); }
                catch (IOException error)
                {
                    last = error;
                    if (!Retryable(error)) throw;
                    Thread.Sleep(5 + attempt * 5);
                }
            }
            throw new InvalidOperationException("EC SMBus read failed", last);
        }
        static int WriteWord(byte address, byte command, int value)
        {
            Exception last = null;
            for (int attempt = 0; attempt < 8; attempt++)
            {
                try
                {
                    Transfer(address, command, false, value);
                    if (ReadWord(address, command) != value)
                        throw new IOException("VERIFIED_MISMATCH");
                    return value;
                }
                catch (IOException error)
                {
                    last = error;
                    if (!Retryable(error) && error.Message != "VERIFIED_MISMATCH") throw;
                    Thread.Sleep(5 + attempt * 5);
                }
            }
            throw new InvalidOperationException("EC SMBus write failed", last);
        }

        public static int ReadChargerCurrent()
        {
            for (int attempt = 0; attempt < 4; attempt++)
            {
                int first = ReadWord(0x09, 0x14);
                int second = ReadWord(0x09, 0x14);
                if (first == second && first <= 0x0F00 && (first & 0x3F) == 0) return first;
                Thread.Sleep(5);
            }
            throw new IOException("Charger current register is inconsistent");
        }
        public static int ReadBatteryRequest() { return ReadWord(0x0B, 0x14); }
        public static int ReadBatteryStatus() { return ReadWord(0x0B, 0x16); }

        public static void SetChargeCurrent(int value)
        {
            if (value < 0 || value > 0x0F00 || (value & 0x3F) != 0)
                throw new ArgumentOutOfRangeException("value", "Current outside the verified original range");
            WriteWord(0x09, 0x14, value);
        }
        public static int EnforcePause()
        {
            int before = ReadChargerCurrent();
            if (before == 0) return 0;
            SetChargeCurrent(0);
            return before;
        }
        public static string ValidateIdentity()
        {
            int fe = ReadWord(0x09, 0xFE);
            int ff = ReadWord(0x09, 0xFF);
            if (fe != 0x4F32 || ff != 0x000A)
                throw new InvalidOperationException("Charger identity mismatch: 0x" + fe.ToString("X4") + "/0x" + ff.ToString("X4"));
            byte[] sig = new byte[15];
            for (int i = 0; i < 15; i++) sig[i] = I2ec.Read((ushort)(0x04B0 + i));
            string s = Encoding.ASCII.GetString(sig);
            if (s != "AEC4168126-4S1P")
                throw new InvalidOperationException("Battery signature mismatch: " + s);
            return "charger 0x4F32/0x000A, battery AEC4168126-4S1P";
        }
        public static int ReadEcRamWord(ushort address)
        {
            return Exclusive(delegate { return I2ec.ReadWordEc(address); });
        }
        public static byte ReadEcRamByte(ushort address)
        {
            return Exclusive(delegate { return I2ec.Read(address); });
        }

        public static bool Ensure(out string error)
        {
            error = "";
            try
            {
                if (File.Exists(App.BlockFile)) { error = "硬件访问已被熔断（存在 hardware-block.json）"; return false; }
                if (!File.Exists(App.DriverDll))
                {
                    Directory.CreateDirectory(App.DriverDir);
                    Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("WJB.inpoutx64.dll");
                    if (s == null) { error = "内嵌的 InpOut DLL 缺失"; return false; }
                    byte[] buf = new byte[s.Length];
                    s.Read(buf, 0, (int)s.Length);
                    s.Close();
                    File.WriteAllBytes(App.DriverDll, buf);
                }
                if (!I2ec.Load(App.DriverDll)) { error = "InpOut 驱动不可用（服务未运行？）"; return false; }
                ValidateIdentity();
                return true;
            }
            catch (Exception ex) { error = ex.Message; return false; }
        }
    }
}
