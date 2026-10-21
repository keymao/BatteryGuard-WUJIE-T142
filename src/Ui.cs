using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace WJB
{
    static class Skin
    {
        public static Color BgTop = Color.FromArgb(0x20, 0x23, 0x2C);
        public static Color BgBottom = Color.FromArgb(0x12, 0x14, 0x1B);
        public static Color CardBg = Color.FromArgb(0x23, 0x26, 0x30);
        public static Color CardBorder = Color.FromArgb(0x34, 0x38, 0x47);
        public static Color TextPrimary = Color.FromArgb(0xEC, 0xEE, 0xF4);
        public static Color TextSecondary = Color.FromArgb(0x9A, 0xA0, 0xAF);
        public static Color AccentBlue = Color.FromArgb(0x4C, 0x8D, 0xFF);
        public static Color Green = Color.FromArgb(0x2F, 0xC4, 0x6E);
        public static Color Red = Color.FromArgb(0xE5, 0x48, 0x4D);
        public static Color Orange = Color.FromArgb(0xF5, 0xA5, 0x24);
        public static Color BtnBg = Color.FromArgb(0x2C, 0x30, 0x3B);
        public static Color BtnBorder = Color.FromArgb(0x46, 0x4B, 0x5C);
        public static Color BtnHover = Color.FromArgb(0x3A, 0x3F, 0x4D);
        public static Color ListBg = Color.FromArgb(0x1B, 0x1D, 0x24);

        public static Font FontN = new Font("Microsoft YaHei UI", 9.5F);
        public static Font FontB = new Font("Microsoft YaHei UI", 10.5F, FontStyle.Bold);
        public static Font FontBig = new Font("Microsoft YaHei UI", 44F, FontStyle.Bold);
        public static Font FontState = new Font("Microsoft YaHei UI", 13.5F, FontStyle.Bold);
        public static Font FontSmall = new Font("Microsoft YaHei UI", 8.75F);
        public static Font FontMono = new Font("Consolas", 9F);

        static float K = 1f;

        public static void Init(float dpi)
        {
            if (dpi <= 0) dpi = 96f;
            K = dpi / 96f;
            // 注意：字号不要乘 K！Font 的 point 单位会被 GDI 按 DPI 自动换算成物理像素，
            // 坐标才需要手动缩放。若字号再乘 K 会双重放大（曾导致文字溢出截断）。
            FontN = new Font("Microsoft YaHei UI", 9.5F);
            FontB = new Font("Microsoft YaHei UI", 10.5F, FontStyle.Bold);
            FontBig = new Font("Microsoft YaHei UI", 44F, FontStyle.Bold);
            FontState = new Font("Microsoft YaHei UI", 13.5F, FontStyle.Bold);
            FontSmall = new Font("Microsoft YaHei UI", 8.75F);
            FontMono = new Font("Consolas", 9F);
        }

        public static int S(int v) { return (int)Math.Round(v * K); }
    }

    static class Gfx
    {
        public static GraphicsPath Round(RectangleF r, float rad)
        {
            GraphicsPath gp = new GraphicsPath();
            float d = 2 * rad;
            if (d > r.Width) d = r.Width;
            if (d > r.Height) d = r.Height;
            gp.AddArc(r.X, r.Y, d, d, 180, 90);
            gp.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            gp.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            gp.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            gp.CloseFigure();
            return gp;
        }
    }

    public class Card : Panel
    {
        public string Title = "";
        public Color TitleColor = Skin.TextSecondary;

        public Card()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Color.Transparent;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1f, Height - 1f);
            using (GraphicsPath p = Gfx.Round(r, 12f))
            {
                using (SolidBrush b = new SolidBrush(Skin.CardBg)) g.FillPath(b, p);
                using (Pen pen = new Pen(Skin.CardBorder)) g.DrawPath(pen, p);
            }
            if (!string.IsNullOrEmpty(Title))
            {
                using (SolidBrush b = new SolidBrush(TitleColor))
                    g.DrawString(Title, Skin.FontSmall, b, Skin.S(14), Skin.S(8));
            }
            base.OnPaint(e);
        }
    }

    public class AccentButton : Control
    {
        public Color Accent = Skin.AccentBlue;
        public bool DrawAsLine = false;   // true 时画一条居中横线（最小化符号）：不用字体渲染，避免全角破折号在 GDI 下超宽触发 EndEllipsis 显示成“—…”
        bool hovered = false, pressed = false;

        public AccentButton()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw |
                     ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            Font = Skin.FontN;
            Cursor = Cursors.Hand;
        }
        protected override void OnMouseEnter(EventArgs e) { hovered = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hovered = false; pressed = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left) { pressed = true; Invalidate(); }
            base.OnMouseDown(e);
        }
        protected override void OnMouseUp(MouseEventArgs e) { pressed = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1f, Height - 1f);
            Color fill = Skin.BtnBg;
            if (hovered) fill = Skin.BtnHover;
            if (pressed) fill = Color.FromArgb(0x24, 0x27, 0x31);
            using (GraphicsPath p = Gfx.Round(r, 8f))
            {
                using (SolidBrush b = new SolidBrush(fill)) g.FillPath(b, p);
                using (Pen pen = new Pen(hovered ? Accent : Skin.BtnBorder, 1.2f)) g.DrawPath(pen, p);
            }
            if (DrawAsLine)
            {
                int lw = Math.Max(10, Skin.S(12)), lh = Math.Max(2, Skin.S(2));
                using (SolidBrush b = new SolidBrush(Enabled ? Skin.TextPrimary : Skin.TextSecondary))
                    g.FillRectangle(b, (Width - lw) / 2, (Height - lh) / 2, lw, lh);
                return;
            }
            // 防御：仅当文本实测超出可用宽度时才允许省略号，避免短符号（如“—”“✕”）因字体宽度测量差异被误截断
            var flags = TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter;
            Rectangle textRect = new Rectangle(Skin.S(6), 0, Width - Skin.S(12), Height);
            if (TextRenderer.MeasureText(Text, Font).Width > textRect.Width) flags |= TextFormatFlags.EndEllipsis;
            TextRenderer.DrawText(g, Text, Font, textRect,
                Enabled ? Skin.TextPrimary : Skin.TextSecondary, flags);
        }
    }

    public enum GaugeMode { Normal, Charging, Stopped, BatteryMode, Paused }

    public class BatteryGauge : Control
    {
        public int SoC = 0;
        public GaugeMode Mode = GaugeMode.Normal;

        public BatteryGauge()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw |
                     ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            int W = Width, H = Height;
            float bodyX = 2, bodyY = H * 0.16f, bodyW = W - 18, bodyH = H * 0.68f;

            float nubX = bodyX + bodyW + 4, nubW = 8, nubY = bodyY + bodyH * 0.3f, nubH = bodyH * 0.4f;
            using (GraphicsPath np = Gfx.Round(new RectangleF(nubX, nubY, nubW, nubH), 3f))
            using (SolidBrush nb = new SolidBrush(Color.FromArgb(0xB0, 0xB6, 0xC4)))
                g.FillPath(nb, np);

            using (GraphicsPath bp = Gfx.Round(new RectangleF(bodyX, bodyY, bodyW, bodyH), 8f))
            using (Pen pen = new Pen(Color.FromArgb(0xD5, 0xDA, 0xE6), 3f))
                g.DrawPath(pen, bp);

            Color fc = Skin.AccentBlue;
            if (Mode == GaugeMode.Charging) fc = Skin.Green;
            else if (Mode == GaugeMode.Stopped) fc = Skin.Red;
            else if (Mode == GaugeMode.BatteryMode) fc = Skin.Orange;
            else if (Mode == GaugeMode.Paused) fc = Color.FromArgb(0x8B, 0x91, 0x9F);

            float pad = 7;
            float availW = bodyW - 2 * pad, availH = bodyH - 2 * pad;
            float fillW = availW * Math.Max(0, Math.Min(100, SoC)) / 100f;
            if (fillW > 2)
            {
                using (GraphicsPath fp = Gfx.Round(new RectangleF(bodyX + pad, bodyY + pad, fillW, availH), 4f))
                using (LinearGradientBrush lb = new LinearGradientBrush(
                    new RectangleF(bodyX + pad, bodyY + pad, fillW, availH), fc, ControlPaint.Dark(fc, 0.18f), 90f))
                    g.FillPath(lb, fp);
            }

            if (Mode == GaugeMode.Charging) DrawBolt(g, bodyX, bodyY, bodyW, bodyH);
            else if (Mode == GaugeMode.Stopped)
            {
                float s = bodyH * 0.36f;
                float cx = bodyX + bodyW / 2, cy = bodyY + bodyH / 2;
                using (SolidBrush b = new SolidBrush(Color.White))
                    g.FillRectangle(b, cx - s / 2, cy - s / 2, s, s);
            }
            else if (Mode == GaugeMode.Paused)
            {
                float bh = bodyH * 0.42f, bw = Math.Max(3f, bodyH * 0.12f);
                float cx = bodyX + bodyW / 2, cy = bodyY + bodyH / 2;
                using (SolidBrush b = new SolidBrush(Color.White))
                {
                    g.FillRectangle(b, cx - bw - 3, cy - bh / 2, bw, bh);
                    g.FillRectangle(b, cx + 3, cy - bh / 2, bw, bh);
                }
            }
        }
        static void DrawBolt(Graphics g, float bx, float by, float bw, float bh)
        {
            PointF[] pts = new PointF[7];
            pts[0] = new PointF(bx + bw * 0.56f, by + bh * 0.10f);
            pts[1] = new PointF(bx + bw * 0.30f, by + bh * 0.58f);
            pts[2] = new PointF(bx + bw * 0.47f, by + bh * 0.58f);
            pts[3] = new PointF(bx + bw * 0.41f, by + bh * 0.90f);
            pts[4] = new PointF(bx + bw * 0.72f, by + bh * 0.40f);
            pts[5] = new PointF(bx + bw * 0.53f, by + bh * 0.40f);
            pts[6] = new PointF(bx + bw * 0.64f, by + bh * 0.10f);
            using (SolidBrush b = new SolidBrush(Color.White)) g.FillPolygon(b, pts);
        }
    }

    public static class IconGen
    {
        static Icon cached32;
        public static Icon AppIcon(int size)
        {
            if (size == 32 && cached32 != null) return cached32;
            using (Bitmap bmp = Draw(size))
            {
                Icon ic = Icon.FromHandle(bmp.GetHicon());
                if (size == 32) cached32 = ic;
                return ic;
            }
        }

        public static Bitmap Draw(int S)
        {
            Bitmap bmp = new Bitmap(S, S);
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);

                float pad = (float)(S * 0.045), rad = (float)(S * 0.22);
                RectangleF bgRect = new RectangleF(pad, pad, S - 2 * pad - 1, S - 2 * pad - 1);
                using (GraphicsPath bg = Gfx.Round(bgRect, rad))
                {
                    using (LinearGradientBrush lb = new LinearGradientBrush(bgRect,
                        Color.FromArgb(0x27, 0x2E, 0x44), Color.FromArgb(0x11, 0x14, 0x1D), 65f))
                        g.FillPath(lb, bg);
                    using (Pen p = new Pen(Color.FromArgb(0x3E, 0x46, 0x60), Math.Max(1f, S / 110f)))
                        g.DrawPath(p, bg);
                }

                float bx = (float)(S * 0.17), by = (float)(S * 0.335);
                float bw = (float)(S * 0.585), bh = (float)(S * 0.33);
                using (GraphicsPath body = Gfx.Round(new RectangleF(bx, by, bw, bh), (float)(S * 0.055)))
                using (Pen pen = new Pen(Color.FromArgb(0xE9, 0xED, 0xF5), Math.Max(1.5f, (float)(S / 85.0))))
                    g.DrawPath(pen, body);

                using (GraphicsPath nub = Gfx.Round(new RectangleF((float)(S * 0.775), (float)(S * 0.445), (float)(S * 0.05), (float)(S * 0.11)), (float)(S * 0.02)))
                using (SolidBrush nb = new SolidBrush(Color.FromArgb(0xE9, 0xED, 0xF5)))
                    g.FillPath(nb, nub);

                float ip = (float)(S * 0.03);
                float iw = (bw - 2 * ip) * 0.74f, ih = bh - 2 * ip;
                RectangleF fillRect = new RectangleF(bx + ip, by + ip, iw, ih);
                using (GraphicsPath fp = Gfx.Round(fillRect, (float)(S * 0.018)))
                using (LinearGradientBrush fb = new LinearGradientBrush(fillRect,
                    Color.FromArgb(0x3B, 0xDF, 0x8B), Color.FromArgb(0x15, 0xA0, 0x59), 45f))
                    g.FillPath(fb, fp);

                PointF[] pts = new PointF[7];
                pts[0] = new PointF(bx + bw * 0.55f, by + bh * 0.06f);
                pts[1] = new PointF(bx + bw * 0.27f, by + bh * 0.62f);
                pts[2] = new PointF(bx + bw * 0.46f, by + bh * 0.62f);
                pts[3] = new PointF(bx + bw * 0.39f, by + bh * 0.94f);
                pts[4] = new PointF(bx + bw * 0.74f, by + bh * 0.36f);
                pts[5] = new PointF(bx + bw * 0.53f, by + bh * 0.36f);
                pts[6] = new PointF(bx + bw * 0.65f, by + bh * 0.06f);
                using (SolidBrush wb = new SolidBrush(Color.White)) g.FillPolygon(wb, pts);
            }
            return bmp;
        }
    }

    public class MainForm : Form
    {
        BatteryGauge gauge;
        Label lblSoC, lblState, lblDetail, lblDaemon, lblFoot;
        Card cardHero, cardDetails, cardDaemon, cardRange, cardCtrl, cardLog;
        AccentButton btnMin, btnClose, btnStart, btnStop, btnRestart, btnInstall, btnUninstall;
        AccentButton btnApply, btnStopCharge, btnResumeCharge, btnPause;
        NumericUpDown numMax, numRecover, numMin;
        ListBox listLog;
        NotifyIcon tray;
        Timer timer;
        Timer posSaveTimer;
        Icon appIcon;
        Bitmap titleIcon;
        bool realExit = false;
        bool hwOk = false;
        string hwErr = "";
        string lastEventAt = "";
        bool? lastStopped = null;

        // 基准布局（96dpi 逻辑像素），实际坐标 = Skin.S() 缩放
        const int BASE_W = 680;
        const int BASE_H = 840;

        public MainForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            MaximizeBox = false;                // 无边框窗口：禁止最大化（双击拖动区不放大，布局为固定坐标）
            StartPosition = FormStartPosition.CenterScreen;
            Font = Skin.FontN;
            ShowInTaskbar = true;
            Text = "无界电池管家 v6";
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);

            // DPI 缩放初始化（必须在建控件之前）
            using (Graphics g0 = CreateGraphics())
            {
                Skin.Init(g0.DpiX);
            }

            appIcon = IconGen.AppIcon(32);
            Icon = appIcon;
            titleIcon = IconGen.Draw(Skin.S(22));

            BuildUi();

            // 恢复上次窗口位置（未保存过则保持居中）
            try
            {
                Cfg c0 = Cfg.Load();
                if (c0.WindowX > -30000 && c0.WindowY > -30000)
                {
                    StartPosition = FormStartPosition.Manual;
                    Location = new Point(c0.WindowX, c0.WindowY);
                }
            }
            catch { }
            ClampToScreen();

            // 窗口位置防抖落盘（拖动停止 600ms 后写一次配置）
            posSaveTimer = new Timer();
            posSaveTimer.Interval = 600;
            posSaveTimer.Tick += delegate { posSaveTimer.Stop(); SaveWindowPos(); };

            string err;
            hwOk = Charger.Ensure(out err);
            hwErr = err;

            tray = new NotifyIcon();
            tray.Icon = appIcon;
            tray.Text = "无界电池管家 v6";
            tray.Visible = true;
            BuildTrayMenu();
            tray.DoubleClick += delegate(object s, EventArgs e)
            {
                Show(); WindowState = FormWindowState.Normal; EnsureOnScreen(); Activate();
            };

            timer = new Timer();
            timer.Interval = 2000;
            timer.Tick += delegate { UpdateAll(); };
            timer.Start();

            Cfg c = Cfg.Load();
            numMax.Value = ClampDec(c.MaxThreshold, 50, 100);
            numRecover.Value = ClampDec(c.RecoverAt, 20, 99);
            numMin.Value = ClampDec(c.MinThreshold, 5, 60);

            AddLog(string.Format("GUI 启动（硬件层：{0}，DPI 缩放 {1:F0}%）",
                hwOk ? "就绪" : "不可用 - " + hwErr, Skin.S(100)));
            if (!hwOk) AddLog("提示：硬件层不可用时仅能查看守护状态与调整配置");
            UpdateAll();
        }

        static decimal ClampDec(int v, int lo, int hi)
        {
            if (v < lo) return lo;
            if (v > hi) return hi;
            return v;
        }

        // 屏幕自适应：窗口超出工作区时压缩日志卡，并强制位置回到可见区，绝不裁掉功能内容
        void ClampToScreen()
        {
            Rectangle wa = Screen.GetWorkingArea(this);
            if (Width > wa.Width)
            {
                int cut = Width - wa.Width;
                Width = wa.Width;
                cardLog.Width = Math.Max(200, cardLog.Width - cut);
                listLog.Width = Math.Max(160, cardLog.Width - Skin.S(24));
                lblFoot.Width = Math.Max(200, lblFoot.Width - cut);
            }
            if (Height > wa.Height)
            {
                int cut = Height - wa.Height;
                Height = wa.Height;
                int newLogH = cardLog.Height - cut;
                if (newLogH < Skin.S(56)) newLogH = Skin.S(56);
                cardLog.Height = newLogH;
                listLog.Height = Math.Max(Skin.S(40), newLogH - Skin.S(38));
                int footY = cardLog.Bottom + Skin.S(4);
                if (footY + lblFoot.Height <= Height - Skin.S(2))
                {
                    lblFoot.Location = new Point(lblFoot.Location.X, footY);
                }
                else lblFoot.Visible = false;
            }
            // 位置强制夹回工作区（窗口被拖到屏幕边缘外时自动拉回）
            if (Left < wa.Left) Left = wa.Left;
            if (Top < wa.Top) Top = wa.Top;
            if (Right > wa.Right) Left = wa.Right - Width;
            if (Bottom > wa.Bottom) Top = wa.Bottom - Height;
        }

        // 从托盘恢复时同样保证窗口在屏幕内
        void EnsureOnScreen()
        {
            try
            {
                Rectangle wa = Screen.GetWorkingArea(this);
                if (Left < wa.Left) Left = wa.Left;
                if (Top < wa.Top) Top = wa.Top;
                if (Right > wa.Right) Left = wa.Right - Width;
                if (Bottom > wa.Bottom) Top = wa.Bottom - Height;
            }
            catch { }
        }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Rectangle r = new Rectangle(0, 0, Width, Height);
            using (LinearGradientBrush lb = new LinearGradientBrush(r, Skin.BgTop, Skin.BgBottom, 90f))
                g.FillRectangle(lb, r);
            using (Pen p = new Pen(Color.FromArgb(0x3A, 0x6A, 0xC8), 2f))
                g.DrawLine(p, 0, 0, Width, 0);
            if (titleIcon != null) g.DrawImage(titleIcon, Skin.S(16), Skin.S(13), titleIcon.Width, titleIcon.Height);
            using (SolidBrush b = new SolidBrush(Skin.TextPrimary))
                g.DrawString("无界电池管家 v6", Skin.FontB, b, Skin.S(46), Skin.S(13));
            SizeF tsize = g.MeasureString("无界电池管家 v6", Skin.FontB);
            using (SolidBrush b = new SolidBrush(Skin.TextSecondary))
                g.DrawString("硬件级充电保护", Skin.FontSmall, b, Skin.S(46) + tsize.Width + Skin.S(8), Skin.S(21));
        }

        protected override void WndProc(ref Message m)
        {
            const int WM_NCHITTEST = 0x84;
            if (m.Msg == WM_NCHITTEST)
            {
                Point pt = PointToClient(Cursor.Position);
                if (pt.Y < Skin.S(46)) { m.Result = (IntPtr)2; return; }  // HTCAPTION：顶部标题区可拖动（原返回 1=HTCLIENT，导致窗口无法拖动）
            }
            base.WndProc(ref m);
        }

        void SaveWindowPos()
        {
            try
            {
                if (WindowState == FormWindowState.Minimized) return;
                Cfg cfg = Cfg.Load();
                cfg.WindowX = Left; cfg.WindowY = Top;
                cfg.Save();
            }
            catch { }
        }

        protected override void OnLocationChanged(EventArgs e)
        {
            base.OnLocationChanged(e);
            if (posSaveTimer != null && WindowState != FormWindowState.Minimized) posSaveTimer.Start();
        }

        void BuildUi()
        {
            ClientSize = new Size(Skin.S(BASE_W), Skin.S(BASE_H));

            btnMin = new AccentButton();
            btnMin.DrawAsLine = true;   // 几何横线替代字符“—”，任何 DPI/字体下都不会变成“—…”
            btnMin.Text = "";
            btnMin.SetBounds(Skin.S(BASE_W - 84), Skin.S(10), Skin.S(34), Skin.S(28));
            btnMin.Accent = Skin.TextSecondary;
            btnMin.Click += delegate { WindowState = FormWindowState.Minimized; };
            Controls.Add(btnMin);

            btnClose = new AccentButton();
            btnClose.Text = "✕"; btnClose.SetBounds(Skin.S(BASE_W - 44), Skin.S(10), Skin.S(34), Skin.S(28));
            btnClose.Accent = Skin.Red;
            btnClose.Click += delegate { HideToTray(); };
            Controls.Add(btnClose);

            // ---- 状态卡（y=52, h=164）----
            cardHero = new Card();
            cardHero.Title = " 电池状态（EC 实时直读）";
            cardHero.SetBounds(Skin.S(16), Skin.S(52), Skin.S(BASE_W - 32), Skin.S(164));
            Controls.Add(cardHero);

            gauge = new BatteryGauge();
            gauge.SetBounds(Skin.S(26), Skin.S(48), Skin.S(224), Skin.S(102));
            cardHero.Controls.Add(gauge);

            lblSoC = new Label();
            lblSoC.Text = "--%";
            lblSoC.Font = Skin.FontBig;
            lblSoC.ForeColor = Skin.AccentBlue;
            lblSoC.SetBounds(Skin.S(272), Skin.S(30), Skin.S(200), Skin.S(76));
            lblSoC.BackColor = Color.Transparent;
            lblSoC.AutoEllipsis = true;
            cardHero.Controls.Add(lblSoC);

            lblState = new Label();
            lblState.Text = "初始化...";
            lblState.Font = Skin.FontState;
            lblState.ForeColor = Skin.TextSecondary;
            lblState.SetBounds(Skin.S(272), Skin.S(112), Skin.S(372), Skin.S(42));
            lblState.BackColor = Color.Transparent;
            lblState.AutoEllipsis = true;
            cardHero.Controls.Add(lblState);

            // ---- 详情卡（y=226, h=124）----
            cardDetails = new Card();
            cardDetails.Title = " 实时详情";
            cardDetails.SetBounds(Skin.S(16), Skin.S(226), Skin.S(BASE_W - 32), Skin.S(124));
            Controls.Add(cardDetails);

            lblDetail = new Label();
            lblDetail.Text = "";
            lblDetail.Font = Skin.FontSmall;
            lblDetail.ForeColor = Skin.TextSecondary;
            lblDetail.SetBounds(Skin.S(24), Skin.S(34), Skin.S(BASE_W - 32 - 48), Skin.S(84));
            lblDetail.BackColor = Color.Transparent;
            cardDetails.Controls.Add(lblDetail);

            // ---- 守护卡（y=356, h=128）----
            cardDaemon = new Card();
            cardDaemon.Title = " 守护进程";
            cardDaemon.SetBounds(Skin.S(16), Skin.S(356), Skin.S(BASE_W - 32), Skin.S(128));
            Controls.Add(cardDaemon);

            lblDaemon = new Label();
            lblDaemon.Text = "检测中...";
            lblDaemon.Font = Skin.FontN;
            lblDaemon.ForeColor = Skin.TextSecondary;
            lblDaemon.SetBounds(Skin.S(24), Skin.S(36), Skin.S(316), Skin.S(80));
            lblDaemon.BackColor = Color.Transparent;
            cardDaemon.Controls.Add(lblDaemon);

            btnStart = MkBtn("启动", 346, 36, 82, 34, Skin.Green); btnStart.Click += delegate { DoStartDaemon(); };
            cardDaemon.Controls.Add(btnStart);
            btnStop = MkBtn("停止", 436, 36, 82, 34, Skin.Red); btnStop.Click += delegate { DoStopDaemon(); };
            cardDaemon.Controls.Add(btnStop);
            btnRestart = MkBtn("重启", 526, 36, 92, 34, Skin.AccentBlue); btnRestart.Click += delegate { DoStopDaemon(); System.Threading.Thread.Sleep(600); DoStartDaemon(); };
            cardDaemon.Controls.Add(btnRestart);
            btnInstall = MkBtn("安装开机自启", 346, 78, 132, 34, Skin.Green); btnInstall.Click += delegate { Installer.Install(true); UpdateAll(); };
            cardDaemon.Controls.Add(btnInstall);
            btnUninstall = MkBtn("移除自启", 486, 78, 132, 34, Skin.Red); btnUninstall.Click += delegate { Installer.Uninstall(true); UpdateAll(); };
            cardDaemon.Controls.Add(btnUninstall);

            // ---- 区间卡（y=490, h=104）----
            cardRange = new Card();
            cardRange.Title = " 充电区间（守护下轮自动生效）";
            cardRange.SetBounds(Skin.S(16), Skin.S(490), Skin.S(BASE_W - 32), Skin.S(104));
            Controls.Add(cardRange);

            Label la = MkLbl("停充上限 %", 24, 50, 78);
            cardRange.Controls.Add(la);
            numMax = MkNum(108, 44, 70);
            cardRange.Controls.Add(numMax);

            Label lb = MkLbl("恢复点 %", 194, 50, 66);
            cardRange.Controls.Add(lb);
            numRecover = MkNum(264, 44, 70);
            cardRange.Controls.Add(numRecover);

            Label lc = MkLbl("下限提醒 %", 350, 50, 78);
            cardRange.Controls.Add(lc);
            numMin = MkNum(430, 44, 70);
            cardRange.Controls.Add(numMin);

            btnApply = MkBtn("应用配置", 524, 42, 118, 38, Skin.AccentBlue);
            btnApply.Click += delegate { DoApply(); };
            cardRange.Controls.Add(btnApply);

            // ---- 手动控制卡（y=600, h=88）----
            cardCtrl = new Card();
            cardCtrl.Title = " 手动控制";
            cardCtrl.SetBounds(Skin.S(16), Skin.S(600), Skin.S(BASE_W - 32), Skin.S(88));
            Controls.Add(cardCtrl);

            btnStopCharge = MkBtn("🛡 立即停充", 24, 42, 200, 42, Skin.Red);
            btnStopCharge.Click += delegate { DoStopCharge(); };
            cardCtrl.Controls.Add(btnStopCharge);

            btnResumeCharge = MkBtn("🔌 恢复充电", 236, 42, 200, 42, Skin.Green);
            btnResumeCharge.Click += delegate { DoResumeCharge(); };
            cardCtrl.Controls.Add(btnResumeCharge);

            btnPause = MkBtn("⏸ 暂停保护", 448, 42, 194, 42, Skin.Orange);
            btnPause.Click += delegate { DoPauseToggle(); };
            cardCtrl.Controls.Add(btnPause);

            // ---- 日志卡（y=696, h=118）----
            cardLog = new Card();
            cardLog.Title = " 事件日志";
            cardLog.SetBounds(Skin.S(16), Skin.S(696), Skin.S(BASE_W - 32), Skin.S(118));
            Controls.Add(cardLog);

            listLog = new ListBox();
            listLog.SetBounds(Skin.S(24), Skin.S(36), Skin.S(BASE_W - 32 - 48), Skin.S(74));
            listLog.BackColor = Skin.ListBg;
            listLog.ForeColor = Skin.TextSecondary;
            listLog.BorderStyle = BorderStyle.None;
            listLog.Font = Skin.FontMono;
            listLog.HorizontalScrollbar = true;
            cardLog.Controls.Add(listLog);

            lblFoot = new Label();
            lblFoot.Text = "关闭窗口 = 最小化到托盘（托盘右键退出）· 插电时守护阻止自动睡眠；手动睡眠/合盖/关机仍会充满 · 单文件绿色版";
            lblFoot.Font = Skin.FontSmall;
            lblFoot.ForeColor = Color.FromArgb(0x70, 0x76, 0x84);
            lblFoot.SetBounds(Skin.S(16), Skin.S(820), Skin.S(BASE_W - 32), Skin.S(20));
            lblFoot.BackColor = Color.Transparent;
            Controls.Add(lblFoot);
        }

        AccentButton MkBtn(string text, int x, int y, int w, int h, Color accent)
        {
            AccentButton b = new AccentButton();
            b.Text = text;
            b.SetBounds(Skin.S(x), Skin.S(y), Skin.S(w), Skin.S(h));
            b.Accent = accent;
            return b;
        }
        Label MkLbl(string text, int x, int y, int w)
        {
            Label l = new Label();
            l.Text = text;
            l.Font = Skin.FontN;
            l.ForeColor = Skin.TextSecondary;
            l.SetBounds(Skin.S(x), Skin.S(y), Skin.S(w), Skin.S(22));
            l.BackColor = Color.Transparent;
            return l;
        }
        NumericUpDown MkNum(int x, int y, int w)
        {
            NumericUpDown n = new NumericUpDown();
            n.SetBounds(Skin.S(x), Skin.S(y), Skin.S(w), Skin.S(26));
            n.BackColor = Color.FromArgb(0x2A, 0x2D, 0x36);
            n.ForeColor = Skin.TextPrimary;
            n.BorderStyle = BorderStyle.FixedSingle;
            n.Font = Skin.FontN;
            return n;
        }

        void BuildTrayMenu()
        {
            ContextMenu cm = new ContextMenu();
            cm.MenuItems.Add(new MenuItem("显示面板", delegate { Show(); WindowState = FormWindowState.Normal; EnsureOnScreen(); Activate(); }));
            cm.MenuItems.Add(new MenuItem("立即停充", delegate { DoStopCharge(); }));
            cm.MenuItems.Add(new MenuItem("恢复充电", delegate { DoResumeCharge(); }));
            cm.MenuItems.Add(new MenuItem("暂停/恢复保护", delegate { DoPauseToggle(); }));
            cm.MenuItems.Add(new MenuItem("-"));
            cm.MenuItems.Add(new MenuItem("退出", delegate
            {
                realExit = true;
                tray.Visible = false;
                Close();
            }));
            tray.ContextMenu = cm;
        }

        void HideToTray()
        {
            Hide();
            try { tray.ShowBalloonTip(2000, "无界电池管家", "已最小化到托盘，双击图标恢复。", ToolTipIcon.Info); }
            catch { }
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            SaveWindowPos();
            if (!realExit)
            {
                e.Cancel = true;
                HideToTray();
                return;
            }
            base.OnFormClosing(e);
        }
        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            if (timer != null) timer.Stop();
            if (tray != null) tray.Visible = false;
            base.OnFormClosed(e);
        }

        void AddLog(string text)
        {
            string line = DateTime.Now.ToString("HH:mm:ss") + "  " + text;
            listLog.Items.Add(line);
            if (listLog.Items.Count > 300) listLog.Items.RemoveAt(0);
            listLog.TopIndex = Math.Max(0, listLog.Items.Count - 1);
        }

        // ============ 动作 ============

        void DoStopCharge()
        {
            if (!hwOk) { MessageBox.Show("硬件层不可用: " + hwErr, "无界电池管家"); return; }
            try
            {
                int before = Charger.EnforcePause();
                Rt rt = Rt.Load();
                if (before > 0) rt.restore_current = before;
                rt.stopped_by_us = true;
                rt.last_event = "GUI 手动停充";
                rt.last_event_at = DateTime.Now.ToString("o");
                rt.Save();
                if (before > 0) AddLog(string.Format("手动停充完成：电流 0x{0:X4} → 0（守护将按策略维持）", before));
                else AddLog("充电电流本已为 0（未充电或已停充）");
            }
            catch (Exception ex) { AddLog("停充失败: " + ex.Message); }
            UpdateAll();
        }

        void DoResumeCharge()
        {
            if (!hwOk) { MessageBox.Show("硬件层不可用: " + hwErr, "无界电池管家"); return; }
            try
            {
                int request = Charger.ReadBatteryRequest();
                int status = Charger.ReadBatteryStatus();
                if (request <= 0 || (status & 0xD000) != 0)
                {
                    AddLog("电池未请求充电（已满/温度保护/告警），无需恢复");
                    UpdateAll();
                    return;
                }
                int value = request & 0x3FC0;
                Rt rt = Rt.Load();
                if (rt.restore_current > 0) value = Math.Min(rt.restore_current, value);
                if (value <= 0) { AddLog("有效恢复电流为 0，取消"); return; }
                Charger.SetChargeCurrent(value);
                Cfg cfg = Cfg.Load();
                if (cfg.HardwareMode)
                {
                    cfg.HardwareMode = false;
                    cfg.Save();
                    AddLog(string.Format("已恢复充电（0x{0:X4}）并自动暂停保护；充满后请点[恢复保护]", value));
                }
                else AddLog(string.Format("已恢复充电（0x{0:X4}），保护处于暂停状态", value));
                rt.stopped_by_us = false;
                rt.last_event = "GUI 恢复充电（暂停保护）";
                rt.last_event_at = DateTime.Now.ToString("o");
                rt.Save();
            }
            catch (Exception ex) { AddLog("恢复失败: " + ex.Message); }
            UpdateAll();
        }

        void DoPauseToggle()
        {
            Cfg cfg = Cfg.Load();
            cfg.HardwareMode = !cfg.HardwareMode;
            cfg.Save();
            if (cfg.HardwareMode)
            {
                AddLog("保护已恢复：守护将在下轮按区间接管");
            }
            else
            {
                if (hwOk)
                {
                    try
                    {
                        int request = Charger.ReadBatteryRequest();
                        int status = Charger.ReadBatteryStatus();
                        if (request > 0 && (status & 0xD000) == 0)
                        {
                            int value = request & 0x3FC0;
                            Rt rt0 = Rt.Load();
                            if (rt0.restore_current > 0) value = Math.Min(rt0.restore_current, value);
                            if (value > 0)
                            {
                                Charger.SetChargeCurrent(value);
                                AddLog(string.Format("保护已暂停并恢复充电（0x{0:X4}）", value));
                            }
                            else AddLog("保护已暂停");
                        }
                        else AddLog("保护已暂停（电池当前未请求充电）");
                    }
                    catch (Exception ex) { AddLog("保护已暂停（恢复充电失败: " + ex.Message + "）"); }
                }
                else AddLog("保护已暂停");
                Rt rt = Rt.Load();
                rt.stopped_by_us = false;
                rt.last_event = "GUI 暂停保护";
                rt.last_event_at = DateTime.Now.ToString("o");
                rt.Save();
            }
            UpdateAll();
        }

        void DoApply()
        {
            Cfg cfg = Cfg.Load();
            cfg.MaxThreshold = (int)numMax.Value;
            cfg.RecoverAt = (int)numRecover.Value;
            cfg.MinThreshold = (int)numMin.Value;
            cfg.Save();
            AddLog(string.Format("配置已保存：{0}% ~ {1}% 停充窗口 / {2}% 下限提醒（守护下轮生效）",
                cfg.RecoverAt, cfg.MaxThreshold, cfg.MinThreshold));
        }

        void DoStartDaemon()
        {
            try { Installer.Schtasks("/Change /TN BatteryGuardWatchdog /ENABLE"); }
            catch { }
            if (!Util.HasDaemonProcess())
            {
                try
                {
                    System.Diagnostics.ProcessStartInfo psi = new System.Diagnostics.ProcessStartInfo();
                    psi.FileName = App.ExePath;
                    psi.Arguments = "-daemon";
                    psi.UseShellExecute = false;
                    psi.CreateNoWindow = true;
                    System.Diagnostics.Process.Start(psi);
                    AddLog("守护进程已启动（看门狗已启用）");
                }
                catch (Exception ex) { AddLog("守护启动失败: " + ex.Message); }
            }
            else AddLog("守护已在运行");
            UpdateAll();
        }

        void DoStopDaemon()
        {
            Rt rt = Rt.Load();
            if (rt.stopped_by_us && hwOk)
            {
                try { DaemonOps.HwResume(rt); rt.Save(); AddLog("充电已恢复"); }
                catch (Exception ex) { AddLog("恢复充电失败: " + ex.Message); }
            }
            try { Installer.Schtasks("/Change /TN BatteryGuardWatchdog /DISABLE"); }
            catch { }
            Util.KillDaemons();
            AddLog("守护进程已停止（看门狗已禁用）");
            UpdateAll();
        }

        // ============ 刷新 ============

        void UpdateAll()
        {
            Cfg cfg = Cfg.Load();
            EcBat ec = null;
            if (hwOk) ec = DaemonOps.ReadEc();
            NativeMethods.POWER_STATUS ps = Util.Power();
            int soc = ec != null ? ec.SoC : (int)ps.BatteryLifePercent;
            if (soc < 0 || soc > 100) soc = (int)ps.BatteryLifePercent;
            bool ac = ec != null ? ec.AcOnline : ps.ACLineStatus == 1;
            bool charging = ec != null ? ec.Charging : false;

            Rt rt = Rt.Load();
            bool stopped = rt.stopped_by_us;
            bool paused = !cfg.HardwareMode;
            bool daemonAlive = Util.HasDaemonProcess();

            gauge.SoC = soc;
            lblSoC.Text = soc + "%";

            string stateTxt;
            if (!ac)
            {
                gauge.Mode = GaugeMode.BatteryMode;
                lblSoC.ForeColor = Skin.Orange;
                stateTxt = "🔋 电池供电";
            }
            else if (stopped)
            {
                gauge.Mode = GaugeMode.Stopped;
                lblSoC.ForeColor = Skin.Red;
                stateTxt = "🛡 已停充（硬件）";
            }
            else if (charging)
            {
                gauge.Mode = GaugeMode.Charging;
                lblSoC.ForeColor = Skin.Green;
                stateTxt = "⚡ 充电中";
            }
            else
            {
                gauge.Mode = paused ? GaugeMode.Paused : GaugeMode.Normal;
                lblSoC.ForeColor = Skin.AccentBlue;
                stateTxt = "🔌 已插电（未充电）";
            }
            if (paused) stateTxt += "  [保护已暂停]";
            lblState.Text = stateTxt;
            lblState.ForeColor = lblSoC.ForeColor;

            // 详情
            List<string> lines = new List<string>();
            lines.Add(ec != null ? string.Format("电压 {0:F2} V   ·   ECWR=0x{1:X2}", ec.VoltageMV / 1000.0, ec.Raw)
                                 : "电压 --（硬件层不可用）");
            int cur = rt.last_charger_current;
            if (hwOk && ac && !daemonAlive)
            {
                try { cur = Charger.ReadChargerCurrent(); }
                catch { }
            }
            lines.Add(string.Format("充电芯片电流寄存器 0x{0:X4}（{1} mA）", cur, cur * 64));
            if (rt.heartbeat != "")
            {
                try
                {
                    DateTime hb = DateTime.Parse(rt.heartbeat);
                    int age = (int)((DateTime.Now - hb).TotalSeconds);
                    string hbState = age < 45 ? "● 正常" : (age < 120 ? "● 迟滞" : "● 异常");
                    lines.Add(string.Format("守护心跳 {0}s 前 {1}   phase={2}", age, hbState, rt.phase));
                }
                catch { }
            }
            else lines.Add("守护心跳 --（守护未运行）");
            if (rt.last_event != "")
            {
                string when = "";
                try { if (rt.last_event_at != "") when = DateTime.Parse(rt.last_event_at).ToString("HH:mm"); }
                catch { }
                lines.Add(string.Format("最近事件 [{0}] {1}", when, rt.last_event));
            }
            if (rt.error != "") lines.Add("守护错误：" + rt.error);
            lblDetail.Text = string.Join("\r\n", lines.ToArray());

            // 守护卡
            if (daemonAlive)
            {
                string mode = rt.hw_available ? "硬件限充" : "软提醒";
                if (paused) mode += "（已暂停）";
                lblDaemon.Text = string.Format("● 守护运行中（{0}）\r\n区间 {1}% ~ {2}% 停充\r\n{3}% 下限提醒",
                    mode, cfg.RecoverAt, cfg.MaxThreshold, cfg.MinThreshold);
                lblDaemon.ForeColor = Skin.Green;
            }
            else
            {
                lblDaemon.Text = string.Format("○ 守护未运行\r\n（电池不受限充保护）\r\n区间 {0}% ~ {1}% / {2}% 下限",
                    cfg.RecoverAt, cfg.MaxThreshold, cfg.MinThreshold);
                lblDaemon.ForeColor = Skin.TextSecondary;
            }

            btnPause.Text = paused ? "▶ 恢复保护" : "⏸ 暂停保护";
            btnPause.Accent = paused ? Skin.Green : Skin.Orange;

            // 事件流
            if (rt.last_event_at != null && rt.last_event_at != lastEventAt)
            {
                lastEventAt = rt.last_event_at;
                if (rt.last_event != "") AddLog(rt.last_event);
            }
            if (lastStopped.HasValue && lastStopped.Value != stopped)
            {
                AddLog("充电控制状态切换：" + (stopped ? "停充" : "允许充电"));
            }
            lastStopped = stopped;

            string tt = string.Format("无界电池管家 {0}% {1}", soc,
                stopped ? "已停充" : (charging ? "充电中" : (ac ? "插电" : "电池")));
            try { tray.Text = tt.Length > 63 ? tt.Substring(0, 63) : tt; }
            catch { }
        }
    }
}
