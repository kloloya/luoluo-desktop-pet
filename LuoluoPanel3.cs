using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

public class LuoluoPanel : Form
{
    static readonly string Base = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(System.IO.Path.DirectorySeparatorChar);
    static string ScriptPath { get { return Path.Combine(Base, "luoluo-proactive.ps1"); } }
    static string PidPath { get { return Path.Combine(Base, "data", "scheduler.pid"); } }
    static string UsagePath { get { return Path.Combine(Base, "data", "usage.json"); } }

    System.Windows.Forms.Timer anim;
    float t = 0f;
    Random rnd = new Random(11);
    Ember[] embers = new Ember[30];
    Petal[] petals = new Petal[16];

    Rectangle rToggle = new Rectangle(18, 98, 100, 38);
    Rectangle rTalk = new Rectangle(126, 98, 100, 38);
    Rectangle rAlarm = new Rectangle(18, 144, 100, 38);
    Rectangle rCall = new Rectangle(126, 144, 100, 38);
    Rectangle rPin = new Rectangle(244, 12, 24, 22);
    Rectangle rMin = new Rectangle(272, 12, 24, 22);
    Rectangle rClose = new Rectangle(300, 12, 24, 22);
    int hover = -1;
    int pressed = -1;

    bool running = false;
    bool pinned = false;
    int moodValue = 70;
    int minutesSinceSpoke = 999;
    DateTime lastCallAt = DateTime.MinValue;
    static string QqFlag { get { return Path.Combine(Base, "qqbot", "paused.flag"); } }
    string statusText = "检查中…";
    string lastLine = "";
    Color statusColor = Color.FromArgb(196, 168, 172);
    double costTotal = 0;
    long tokTotal = 0;
    string costText = "";

    Font fTitle, fStatus, fBtn, fHint, fSeal, fCost;
    System.Windows.Forms.Timer poll;

    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int m, int w, int l);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SetCurrentProcessExplicitAppUserModelID(string id);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    struct Ember { public float x, y, vy, size, phase; }
    struct Petal { public float x, y, vy, drift, phase, size, rot; }

    [STAThread]
    static void Main()
    {
        bool created;
        Mutex mutex = new Mutex(true, "LuoluoPanel_SingleInstance", out created);
        if (!created) return;
        try { SetCurrentProcessExplicitAppUserModelID("Shinymoon.Luoluo.Panel"); }
        catch { }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new LuoluoPanel());
    }

    public LuoluoPanel()
    {
        Text = "克劳洛娅";
        FormBorderStyle = FormBorderStyle.None;
        MinimizeBox = true;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(340, 272);
        BackColor = Color.FromArgb(10, 7, 9);
        DoubleBuffered = true;
        ShowInTaskbar = true;
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
        try { Icon = new Icon(Path.Combine(Base, "luoluo.ico")); }
        catch { }

        fTitle = new Font("Microsoft YaHei UI", 17f, FontStyle.Bold, GraphicsUnit.Pixel);
        fStatus = new Font("Microsoft YaHei UI", 11f, FontStyle.Regular, GraphicsUnit.Pixel);
        fBtn = new Font("Microsoft YaHei UI", 12f, FontStyle.Regular, GraphicsUnit.Pixel);
        fHint = new Font("Microsoft YaHei UI", 10f, FontStyle.Regular, GraphicsUnit.Pixel);
        fSeal = new Font("Microsoft YaHei UI", 9f, FontStyle.Bold, GraphicsUnit.Pixel);
        fCost = new Font("Microsoft YaHei UI", 9f, FontStyle.Regular, GraphicsUnit.Pixel);

        for (int i = 0; i < embers.Length; i++) ResetEmber(ref embers[i], true);
        for (int i = 0; i < petals.Length; i++) ResetPetal(ref petals[i], true);

        anim = new System.Windows.Forms.Timer();
        anim.Interval = 33;
        anim.Tick += delegate { t += 0.033f; Step(); Invalidate(); };
        anim.Start();

        poll = new System.Windows.Forms.Timer();
        poll.Interval = 1000;
        poll.Tick += delegate { RefreshState(); };
        poll.Start();
        RefreshState();

        if (!IsRunning()) { RunScript(""); Thread.Sleep(500); RefreshState(); }
        EnsureWatchdog();

        MouseMove += OnMove;
        MouseDown += OnDown;
        MouseUp += OnUp;
        MouseLeave += delegate { hover = -1; Invalidate(); };
        MouseDoubleClick += delegate { AnchorToPet(); };
    }

    void ResetEmber(ref Ember e, bool randomY)
    {
        e.x = (float)(rnd.NextDouble() * 340);
        e.y = randomY ? (float)(rnd.NextDouble() * 204) : 206f;
        e.vy = (float)(5 + rnd.NextDouble() * 13);
        e.size = (float)(0.8 + rnd.NextDouble() * 1.5);
        e.phase = (float)(rnd.NextDouble() * 6.28);
    }

    void ResetPetal(ref Petal p, bool randomY)
    {
        p.x = (float)(rnd.NextDouble() * 360) - 10;
        p.y = randomY ? (float)(rnd.NextDouble() * 204) : -10f;
        p.vy = (float)(6 + rnd.NextDouble() * 9);
        p.drift = (float)(rnd.NextDouble() * 2 - 1);
        p.phase = (float)(rnd.NextDouble() * 6.28);
        p.size = (float)(2.0 + rnd.NextDouble() * 2.2);
        p.rot = (float)(rnd.NextDouble() * 360);
    }

    void Step()
    {
        for (int i = 0; i < embers.Length; i++)
        {
            embers[i].y -= embers[i].vy * 0.033f;
            embers[i].x += (float)Math.Sin(t * 0.9 + embers[i].phase) * 0.22f;
            if (embers[i].y < -4) ResetEmber(ref embers[i], false);
        }
        for (int i = 0; i < petals.Length; i++)
        {
            petals[i].y += petals[i].vy * 0.033f;
            petals[i].x += (float)Math.Sin(t * 0.7 + petals[i].phase) * 0.38f + petals[i].drift * 0.12f;
            petals[i].rot += 0.5f;
            if (petals[i].y > 210) ResetPetal(ref petals[i], false);
        }
    }

    bool IsRunning()
    {
        try
        {
            if (!File.Exists(PidPath)) return false;
            int pid;
            if (!int.TryParse(File.ReadAllText(PidPath).Trim(), out pid)) return false;
            Process.GetProcessById(pid);
            return true;
        }
        catch { return false; }
    }

    void ShowAlarmDialog()
    {
        Form dlg = new Form();
        dlg.Text = "设闹钟";
        dlg.FormBorderStyle = FormBorderStyle.FixedDialog;
        dlg.StartPosition = FormStartPosition.CenterParent;
        dlg.ClientSize = new Size(290, 150);
        dlg.BackColor = Color.FromArgb(26, 18, 22);
        dlg.ForeColor = Color.FromArgb(240, 230, 228);
        dlg.MaximizeBox = false;
        dlg.MinimizeBox = false;

        Label l1 = new Label(); l1.Text = "时间 (HH:mm)"; l1.SetBounds(16, 14, 110, 20); l1.ForeColor = dlg.ForeColor;
        TextBox t1 = new TextBox(); t1.SetBounds(132, 12, 130, 24); t1.Text = DateTime.Now.AddMinutes(30).ToString("HH:mm");
        Label l2 = new Label(); l2.Text = "提醒内容"; l2.SetBounds(16, 50, 110, 20); l2.ForeColor = dlg.ForeColor;
        TextBox t2 = new TextBox(); t2.SetBounds(132, 48, 130, 24);
        Button ok = new Button(); ok.Text = "确定"; ok.SetBounds(60, 98, 72, 26); ok.DialogResult = DialogResult.OK;
        Button cancel = new Button(); cancel.Text = "取消"; cancel.SetBounds(152, 98, 72, 26); cancel.DialogResult = DialogResult.Cancel;
        dlg.Controls.Add(l1); dlg.Controls.Add(t1); dlg.Controls.Add(l2); dlg.Controls.Add(t2); dlg.Controls.Add(ok); dlg.Controls.Add(cancel);
        dlg.AcceptButton = ok;
        dlg.CancelButton = cancel;

        if (dlg.ShowDialog(this) == DialogResult.OK)
        {
            string time = t1.Text.Trim();
            string text = t2.Text.Trim();
            if (text.Length == 0) text = "到点了";
            try { RunScript("-AddAlarm \"" + time + "\" -AlarmText \"" + text + "\" -Daily"); } catch { }
        }
        dlg.Dispose();
    }

    static void EnsureWatchdog()
    {
        try
        {
            string pidFile = Path.Combine(Base, "data", "watchdog.pid");
            if (File.Exists(pidFile))
            {
                int pid;
                if (int.TryParse(File.ReadAllText(pidFile).Trim(), out pid))
                {
                    try { Process.GetProcessById(pid); return; } catch { }
                }
            }
            ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"D:\\MateEngineTools\\watchdog.ps1\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            Process.Start(psi);
        }
        catch { }
    }

    static void RunPs(string scriptName)
    {
        ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"D:\\MateEngineTools\\qqbot\\" + scriptName + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        Process.Start(psi);
    }

    static void RunScript(string extra)
    {
        ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ScriptPath + "\" " + extra);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        Process.Start(psi);
    }

    void RefreshState()
    {
        try
        {
            if (File.Exists(UsagePath))
            {
                string js = File.ReadAllText(UsagePath);
                Match mc = Regex.Match(js, "cost\"?\\s*:\\s*([0-9.]+)");
                if (mc.Success) costTotal = double.Parse(mc.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture);
                long tk = 0;
                foreach (string key in new string[] { "inMiss", "inHit", "out" })
                {
                    Match mm = Regex.Match(js, key + "\"?\\s*:\\s*(\\d+)");
                    if (mm.Success) tk += long.Parse(mm.Groups[1].Value);
                }
                tokTotal = tk;
            }
        }
        catch { }

        string tokStr = tokTotal >= 1000 ? (tokTotal / 1000.0).ToString("0.0") + "k" : tokTotal.ToString();
        string money = costTotal < 0.01 ? ("今日 ≈¥" + costTotal.ToString("0.0000")) : ("今日 ≈¥" + costTotal.ToString("0.00"));
        costText = money + " · " + tokStr + " tok";

        minutesSinceSpoke = 999;
        running = IsRunning();
        try
        {
            string mp = Path.Combine(Base, "data", "memory.json");
            if (File.Exists(mp))
            {
                string mj = File.ReadAllText(mp);
                Match mm2 = Regex.Match(mj, "moodValue\"?\\s*:\\s*(\\d+)");
                Match ml = Regex.Match(mj, "\"line\"\\s*:\\s*\"([^\"]{0,60})\"");
                if (ml.Success) lastLine = ml.Groups[1].Value;
                Match ms = Regex.Match(mj, "lastSpoke\"?\\s*:\\s*\"([^\"]+)\"");
                if (ms.Success)
                {
                    DateTime last;
                    if (DateTime.TryParse(ms.Groups[1].Value, out last))
                        minutesSinceSpoke = Math.Max(0, (int)(DateTime.Now - last.ToLocalTime()).TotalMinutes);
                }
                if (mm2.Success) moodValue = int.Parse(mm2.Groups[1].Value);
            }
        }
        catch { }
        if (!running) statusText = "睡着了";
        else if (moodValue <= 35) statusText = "在生气";
        else if (moodValue <= 55) statusText = "不太高兴";
        else if (minutesSinceSpoke <= 2) statusText = "刚说完话";
        else if (minutesSinceSpoke >= 20) statusText = "在等你说话";
        else statusText = "在发呆";
        statusColor = running ? Color.FromArgb(228, 174, 108) : Color.FromArgb(150, 136, 140);
        Invalidate();
    }

    void Toggle()
    {
        RunScript(running ? "-StopProactive" : "");
        Thread.Sleep(700);
        RefreshState();
    }

    void AnchorToPet()
    {
        try
        {
            Process[] ps = Process.GetProcessesByName("MateEngineX");
            if (ps.Length == 0) return;
            RECT r;
            if (!GetWindowRect(ps[0].MainWindowHandle, out r)) return;
            int petW = r.Right - r.Left;
            Rectangle wa = Screen.FromHandle(ps[0].MainWindowHandle).WorkingArea;
            int left = r.Left + (int)(0.72 * petW) - Width;
            int top = r.Top + 40;
            if (left < wa.Left + 8) left = wa.Left + 8;
            if (left + Width > wa.Right - 8) left = wa.Right - Width - 8;
            if (top + Height > wa.Bottom - 8) top = wa.Bottom - Height - 8;
            Location = new Point(left, top);
        }
        catch { }
    }

    int HitTest(Point p)
    {
        if (rToggle.Contains(p)) return 0;
        if (rTalk.Contains(p)) return 1;
        if (rAlarm.Contains(p)) return 6;
        if (rCall.Contains(p)) return 7;
        if (rPin.Contains(p)) return 8;
        if (rMin.Contains(p)) return 2;
        if (rClose.Contains(p)) return 3;
        return -1;
    }

    void OnMove(object s, MouseEventArgs e)
    {
        int h = HitTest(e.Location);
        if (h != hover) { hover = h; Cursor = h >= 0 ? Cursors.Hand : Cursors.SizeAll; Invalidate(); }
    }

    void OnDown(object s, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        int h = HitTest(e.Location);
        if (h >= 0) { pressed = h; Invalidate(); return; }
        if (e.Clicks >= 2) { AnchorToPet(); return; }
        ReleaseCapture();
        SendMessage(Handle, 0xA1, 0x2, 0);
    }

    void OnUp(object s, MouseEventArgs e)
    {
        int h = HitTest(e.Location);
        if (pressed >= 0 && h == pressed)
        {
            if (h == 8) { pinned = !pinned; TopMost = pinned; if (pinned) BringToFront(); Invalidate(); }
            else if (h == 0) Toggle();
            else if (h == 1) RunScript("-YejinChat");
            else if (h == 6) ShowAlarmDialog();
            else if (h == 7) {
                if ((DateTime.Now - lastCallAt).TotalSeconds >= 5) { lastCallAt = DateTime.Now; RunScript("-Once -Called"); }
            }
            else if (h == 2) WindowState = FormWindowState.Minimized;
            else if (h == 3) Close();
            else if (h == 4) { bool p2 = !File.Exists(QqFlag); if (p2) File.Create(QqFlag).Close(); else File.Delete(QqFlag); RefreshState(); }
        }
        pressed = -1;
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        int W = ClientSize.Width, H = ClientSize.Height;

        using (LinearGradientBrush bg = new LinearGradientBrush(new Rectangle(0, 0, W, H),
            Color.FromArgb(14, 9, 12), Color.FromArgb(26, 8, 12), 75f))
            g.FillRectangle(bg, 0, 0, W, H);

        using (LinearGradientBrush band = new LinearGradientBrush(new Rectangle(W - 150, 0, 150, H),
            Color.FromArgb(0, 120, 12, 22), Color.FromArgb(58, 120, 12, 22), 0f))
            g.FillRectangle(band, W - 150, 0, 150, H);

        for (int i = 0; i < 4; i++)
        {
            float cx = W * (0.12f + 0.22f * i) + (float)Math.Sin(t * 0.22 + i) * 7f;
            float cy = H * (0.28f + 0.2f * (i % 3)) + (float)Math.Cos(t * 0.18 + i) * 5f;
            float rad = 78 + 26 * i;
            using (GraphicsPath gp = new GraphicsPath())
            {
                gp.AddEllipse(cx - rad / 2, cy - rad / 2, rad, rad);
                using (PathGradientBrush pb = new PathGradientBrush(gp))
                {
                    pb.CenterColor = Color.FromArgb(34, 34, 28, 34);
                    pb.SurroundColors = new Color[] { Color.FromArgb(0, 34, 28, 34) };
                    g.FillPath(pb, gp);
                }
            }
        }

        float pulse = 0.5f + 0.5f * (float)Math.Sin(t * 0.75);
        using (GraphicsPath gp = new GraphicsPath())
        {
            gp.AddEllipse(W - 190, H - 150, 300, 260);
            using (PathGradientBrush pb = new PathGradientBrush(gp))
            {
                pb.CenterColor = Color.FromArgb((int)(46 + 32 * pulse), 172, 28, 40);
                pb.SurroundColors = new Color[] { Color.FromArgb(0, 172, 28, 40) };
                g.FillPath(pb, gp);
            }
        }

        using (Pen glow = new Pen(Color.FromArgb(22, 210, 46, 62), 9f))
            g.DrawArc(glow, W - 96, -26, 190, 250, 196 + 5 * (float)Math.Sin(t * 0.3), 74f);
        using (Pen arc = new Pen(Color.FromArgb(88, 224, 58, 74), 1.6f))
            g.DrawArc(arc, W - 96, -26, 190, 250, 196 + 5 * (float)Math.Sin(t * 0.3), 74f);

        for (int i = 0; i < 3; i++)
        {
            float off = 26 + i * 42 + 5 * (float)Math.Sin(t * 0.33 + i);
            using (Pen p = new Pen(Color.FromArgb(12, 226, 74, 86), 1f))
                g.DrawLine(p, W - 30 - off, -8, W - 120 - off, H + 8);
        }

        DrawStar4(g, 296, 44, 9f, Color.FromArgb(70, 236, 88, 102), t * 0.6f);
        DrawStar4(g, 268, 150, 6f, Color.FromArgb(44, 236, 88, 102), -t * 0.45f);
        DrawStar4(g, 60, 176, 5f, Color.FromArgb(34, 236, 88, 102), t * 0.5f);

        foreach (Petal p in petals)
        {
            g.TranslateTransform(p.x, p.y);
            g.RotateTransform(p.rot);
            using (SolidBrush b = new SolidBrush(Color.FromArgb(120, 150, 22, 40)))
                g.FillEllipse(b, -p.size, -p.size * 0.5f, p.size * 2f, p.size);
            g.ResetTransform();
        }

        foreach (Ember em in embers)
        {
            float a = 0.2f + 0.65f * (float)Math.Abs(Math.Sin(t * 1.5 + em.phase));
            if (em.size > 1.5f)
            {
                using (SolidBrush halo = new SolidBrush(Color.FromArgb((int)(a * 42), 255, 120, 70)))
                    g.FillEllipse(halo, em.x - 2.5f, em.y - 2.5f, em.size + 5, em.size + 5);
            }
            using (SolidBrush b = new SolidBrush(Color.FromArgb((int)(a * 255), 255, 138, 84)))
                g.FillEllipse(b, em.x, em.y, em.size, em.size);
        }

        using (LinearGradientBrush scrim = new LinearGradientBrush(new Rectangle(0, 36, W, H - 36),
            Color.FromArgb(120, 6, 4, 6), Color.FromArgb(178, 6, 4, 6), 90f))
            g.FillRectangle(scrim, 0, 36, W, H - 36);

        using (SolidBrush glow = new SolidBrush(Color.FromArgb(34, 224, 54, 70)))
            g.DrawString("克劳洛娅", fTitle, glow, 45.6f, 11.4f);
        g.DrawString("克劳洛娅", fTitle, new SolidBrush(Color.FromArgb(246, 240, 238)), 45, 11);

        Rectangle seal = new Rectangle(18, 11, 21, 21);
        using (GraphicsPath sp = RoundRect(seal, 4))
        {
            using (SolidBrush sf = new SolidBrush(Color.FromArgb(255, 0, 0, 0)))
                g.FillPath(sf, sp);
        }

        using (LinearGradientBrush line = new LinearGradientBrush(new Rectangle(18, 0, 300, 1),
            Color.FromArgb(150, 170, 30, 44), Color.FromArgb(0, 170, 30, 44), 0f))
            g.FillRectangle(line, 18, 44, 300, 1f);

        using (SolidBrush dot = new SolidBrush(statusColor))
            g.FillEllipse(dot, 18f, 58f, 5f, 5f);
        if (running)
        {
            float pa = 0.35f + 0.65f * (float)Math.Abs(Math.Sin(t * 1.1));
            using (SolidBrush halo = new SolidBrush(Color.FromArgb((int)(pa * 90), 226, 70, 84)))
                g.FillEllipse(halo, 15f, 55f, 11f, 11f);
        }
        using (SolidBrush st = new SolidBrush(statusColor))
            g.DrawString(statusText, fStatus, st, 29f, 54f);


        // 心情条
        {
            float bx = 214f, by = 58f, bw = 96f, bh = 5f;
            using (SolidBrush lb = new SolidBrush(Color.FromArgb(150, 200, 182, 186)))
                g.DrawString("心情", fHint, lb, bx - 30f, 52f);
            using (SolidBrush bgB = new SolidBrush(Color.FromArgb(60, 240, 220, 220)))
                g.FillRectangle(bgB, bx, by, bw, bh);
            int mv = moodValue < 0 ? 0 : (moodValue > 100 ? 100 : moodValue);
            float fill = bw * mv / 100f;
            Color mc = mv >= 60 ? Color.FromArgb(210, 210, 120, 70)
                     : (mv >= 35 ? Color.FromArgb(210, 220, 90, 74) : Color.FromArgb(220, 190, 40, 54));
            if (fill > 0)
                using (SolidBrush fb = new SolidBrush(mc))
                    g.FillRectangle(fb, bx, by, fill, bh);
            using (SolidBrush nb = new SolidBrush(Color.FromArgb(170, 235, 220, 220)))
                g.DrawString(mv.ToString(), fCost, nb, bx + bw + 4f, by - 5f);
        }

        DrawButton(g, rToggle, running ? "暂停" : "启动", 0, false);
        DrawButton(g, rTalk, "给夜烬告状", 1, true);
        DrawButton(g, rAlarm, "闹钟", 6, false);
        DrawButton(g, rCall, "叫她", 7, true);

        using (SolidBrush hint = new SolidBrush(Color.FromArgb(170, 176, 152, 158)))
        {
            g.DrawString("点「给夜烬告状」叫他出来", fHint, hint, 18f, 192f);
            g.DrawString("关掉这个窗口 = 全部停止", fHint, hint, 18f, 212f);
        }

        DrawPin(g, rPin, pinned);
        DrawGlyph(g, rMin, 2);
        DrawGlyph(g, rClose, 3);

        if (lastLine.Length > 0)
        {
            string shown = lastLine;
            if (shown.Length > 18) shown = shown.Substring(0, 18) + "…";
            SizeF lsz = g.MeasureString(shown, fHint);
            using (SolidBrush lb = new SolidBrush(Color.FromArgb(165, 205, 186, 190)))
                g.DrawString(shown, fHint, lb, W - lsz.Width - 14, H - lsz.Height - 34);
        }

        if (costText.Length > 0)
        {
            SizeF csz = g.MeasureString(costText, fCost);
            using (SolidBrush cb = new SolidBrush(Color.FromArgb(175, 190, 162, 168)))
                g.DrawString(costText, fCost, cb, W - csz.Width - 14, H - csz.Height - 6);
        }

        using (Pen border = new Pen(Color.FromArgb(120, 158, 34, 46), 1f))
            g.DrawPath(border, RoundRect(new Rectangle(0, 0, W - 1, H - 1), 12));
        using (Pen inner = new Pen(Color.FromArgb(40, 0, 0, 0), 1f))
            g.DrawPath(inner, RoundRect(new Rectangle(1, 1, W - 3, H - 3), 11));
    }

    void DrawStar4(Graphics g, float cx, float cy, float r, Color color, float rot)
    {
        using (GraphicsPath p = new GraphicsPath())
        {
            float inner = r * 0.2f;
            PointF[] pts = new PointF[8];
            for (int i = 0; i < 8; i++)
            {
                float ang = (float)(Math.PI / 4 * i - Math.PI / 2) + rot;
                float rad = (i % 2 == 0) ? r : inner;
                pts[i] = new PointF(cx + (float)Math.Cos(ang) * rad, cy + (float)Math.Sin(ang) * rad);
            }
            p.AddPolygon(pts);
            using (SolidBrush b = new SolidBrush(color))
                g.FillPath(b, p);
        }
    }

    void DrawButton(Graphics g, Rectangle r, string label, int id, bool accent)
    {
        bool hov = hover == id;
        bool down = pressed == id;

        Color fill = accent
            ? Color.FromArgb(down ? 120 : (hov ? 92 : 62), 168, 30, 44)
            : Color.FromArgb(down ? 46 : (hov ? 34 : 20), 240, 226, 226);
        Color line = accent
            ? Color.FromArgb(hov ? 235 : 195, 226, 76, 90)
            : Color.FromArgb(hov ? 210 : 130, 178, 52, 64);

        using (GraphicsPath p = RoundRect(r, 6))
        {
            using (SolidBrush fb = new SolidBrush(fill))
                g.FillPath(fb, p);
            using (Pen pen = new Pen(line, 1f))
                g.DrawPath(pen, p);
        }
        SizeF sz = g.MeasureString(label, fBtn);
        Color fg = accent ? Color.FromArgb(252, 240, 238) : Color.FromArgb(238, 226, 224);
        using (SolidBrush b = new SolidBrush(fg))
            g.DrawString(label, fBtn, b, r.X + (r.Width - sz.Width) / 2f, r.Y + (r.Height - sz.Height) / 2f - 0.5f);
    }

    void DrawPin(Graphics g, Rectangle r, bool on)
    {
        Color c = on ? Color.FromArgb(245, 226, 96, 110) : Color.FromArgb(150, 200, 190, 190);
        float cx = r.X + r.Width / 2f, cy = r.Y + r.Height / 2f;
        using (SolidBrush b = new SolidBrush(c))
            g.FillEllipse(b, cx - 4f, cy - 6f, 8f, 8f);
        using (Pen p = new Pen(c, 1.6f))
            g.DrawLine(p, cx, cy + 2f, cx, cy + 9f);
    }

    void DrawGlyph(Graphics g, Rectangle r, int id)
    {
        bool hov = hover == id;
        Color c = Color.FromArgb(hov ? 250 : 165, 222, 196, 198);
        if (hov)
        {
            using (SolidBrush hb = new SolidBrush(Color.FromArgb(40, 226, 60, 76)))
                g.FillEllipse(hb, r.X + 2, r.Y + 2, r.Width - 4, r.Height - 4);
        }
        float cx = r.X + r.Width / 2f, cy = r.Y + r.Height / 2f;
        using (Pen pen = new Pen(c, 1.5f))
        {
            if (id == 2) g.DrawLine(pen, cx - 6, cy, cx + 6, cy);
            else
            {
                g.DrawLine(pen, cx - 5, cy - 5, cx + 5, cy + 5);
                g.DrawLine(pen, cx + 5, cy - 5, cx - 5, cy + 5);
            }
        }
    }

    static GraphicsPath RoundRect(Rectangle r, int radius)
    {
        GraphicsPath p = new GraphicsPath();
        int d = radius * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        try { RunScript("-Stop"); }
        catch { }
        base.OnFormClosing(e);
    }
}
