// MihomoTray.cs — mihomo 托盘管家 v3
// 单文件 C# WinForms 托盘程序，由 .NET Framework 4.x 自带 csc 编译（C# 5 语法，无外部依赖）。
// 编译与部署见同目录 build.ps1 / README.md。本文件编码：UTF-8 with BOM。
//
// 相比 v2（PowerShell）的变化：
//   · 进程 PerMonitorV2 DPI 感知（manifest），不再被系统位图拉伸 → 175% 下锐利
//   · 自绘弹出菜单：所有尺寸按目标显示器 DPI 精确换算，96dpi 基准行高 24px
//   · 暗色主题、Win11 圆角 + 细边框 + 阴影；图标用 Segoe Fluent Icons 统一对齐
//   · 状态行右侧显示当前出口节点（从 external-controller API 读取，secret 取自 .url）
//   · 功能契约与 v2 一致：7 项菜单、双击开面板、气泡、免 UAC 启停（失败回退 UAC）

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("mihomo 托盘管家")]
[assembly: AssemblyProduct("mihomo 托盘管家")]
[assembly: AssemblyVersion("3.0.0.0")]
[assembly: AssemblyFileVersion("3.0.0.0")]

namespace MihomoTray
{
    // ═══════════════════════════ 配置 ═══════════════════════════
    static class Config
    {
        public const string ServiceName = "mihomo";
        public const string PanelShortcutName = "mihomo 面板.url";
        public const string PanelShortcutFallback = "";
        public const string ApiFallback = "http://127.0.0.1:9097";

        // 出口显示从哪个策略组开始解析；留空 = 自动（rule 模式取 MATCH 规则指向的组，global 模式取 GLOBAL）
        public const string ExitGroup = "";
        // dark | light | auto（auto 跟随任务栏深浅色）
        public const string Theme = "dark";

        public const int PollMs = 3000;          // 服务状态轮询间隔
        public const int ExitRefreshSec = 15;    // 出口节点刷新间隔
        public const int ServiceTimeoutSec = 20; // 启停等待上限

        public static readonly string TrayDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        public static readonly string RootDir = FindRoot();
        public static readonly string IconOn = Path.Combine(RootDir, "panel-icon.ico");
        public static readonly string IconOff = Path.Combine(RootDir, "panel-icon-off.ico");
        public static readonly string StatusScript = Path.Combine(RootDir, @"scripts\status.ps1");

        static string FindRoot()
        {
            try
            {
                DirectoryInfo parent = Directory.GetParent(TrayDir);
                if (parent != null && File.Exists(Path.Combine(parent.FullName, "panel-icon.ico")))
                    return parent.FullName;
            }
            catch { }
            return @"D:\mihomo";
        }
    }

    // ═══════════════════════════ 入口 ═══════════════════════════
    static class Program
    {
        [STAThread]
        static void Main()
        {
            bool created;
            using (Mutex mutex = new Mutex(true, @"Local\mihomo-tray-manager", out created))
            {
                if (!created) return; // 已有实例在运行

                Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                Application.ThreadException += delegate(object s, ThreadExceptionEventArgs e) { Log(e.Exception); };
                AppDomain.CurrentDomain.UnhandledException += delegate(object s, UnhandledExceptionEventArgs e) { Log(e.ExceptionObject as Exception); };

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new TrayApp());
                GC.KeepAlive(mutex);
            }
        }

        public static void Log(Exception ex)
        {
            if (ex == null) return;
            try
            {
                File.AppendAllText(Path.Combine(Path.GetTempPath(), "mihomo-tray.log"),
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + ex + Environment.NewLine);
            }
            catch { }
        }
    }

    enum ServiceState { Unknown, Missing, Stopped, Starting, Running, Stopping }

    // ═══════════════════════════ 托盘主体 ═══════════════════════════
    sealed class TrayApp : ApplicationContext
    {
        readonly NotifyIcon tray = new NotifyIcon();
        readonly PopupMenu menu = new PopupMenu();
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        readonly Row header, startRow, stopRow, restartRow, panelRow, reportRow, quitRow;

        Icon iconOn, iconOff;
        ServiceState state = ServiceState.Unknown;
        ServiceState stable = ServiceState.Unknown; // 最近一次稳定态（Running/Stopped），用于判断是否弹气泡
        bool busy;
        string busyText;
        string exitName;
        DateTime exitAt = DateTime.MinValue;
        int fetching;
        bool cleaned;

        public TrayApp()
        {
            // 字形：Segoe Fluent Icons / MDL2 码位；无图标字体时回退到 v2 的 Unicode 符号
            header     = Row.Header();
            startRow   = Row.Cmd("\uE768", "▶", "启动代理", null, DoStart);
            stopRow    = Row.Cmd("\uE71A", "■", "停止代理", "完全直连", DoStop);
            restartRow = Row.Cmd("\uE72C", "↻", "重启代理", null, DoRestart);
            panelRow   = Row.Cmd("\uE774", "◈", "打开面板", "双击图标", OpenPanel);
            reportRow  = Row.Cmd("\uE946", "☰", "详细状态报告", null, OpenReport);
            quitRow    = Row.Cmd("\uE711", "✕", "退出托盘", "内核不受影响", ExitApp);

            menu.SetRows(new List<Row> {
                header, Row.Separator(),
                startRow, stopRow, restartRow, Row.Separator(),
                panelRow, reportRow, Row.Separator(),
                quitRow
            });
            IntPtr handle = menu.Handle; // 预建窗口句柄：后台线程要靠它 BeginInvoke 回 UI 线程
            if (handle == IntPtr.Zero) Program.Log(new InvalidOperationException("menu handle"));

            LoadIcons();
            tray.Text = "mihomo";
            tray.MouseUp += OnTrayMouseUp;
            tray.MouseDoubleClick += OnTrayDoubleClick;
            tray.Visible = true;

            SystemEvents.DisplaySettingsChanged += OnDisplayChanged;
            Application.ApplicationExit += delegate { Cleanup(); };

            timer.Interval = Config.PollMs;
            timer.Tick += delegate { Poll(); };
            timer.Start();
            Poll();
            UpdateUi();
        }

        // ── 状态 ──────────────────────────────────────────
        void Poll()
        {
            ServiceState s = ServiceOps.Query();
            if (s != state)
            {
                state = s;
                OnStateChanged();
            }
            if (state == ServiceState.Running && (DateTime.UtcNow - exitAt).TotalSeconds >= Config.ExitRefreshSec)
                RefreshExit();
        }

        void OnStateChanged()
        {
            if (!busy && (state == ServiceState.Running || state == ServiceState.Stopped))
            {
                if (stable != ServiceState.Unknown && stable != state) NotifyStable(state);
                stable = state;
            }
            if (state != ServiceState.Running) exitName = null;
            exitAt = DateTime.MinValue; // 状态一变就尽快刷新出口
            UpdateUi();
        }

        void NotifyStable(ServiceState s)
        {
            if (s == ServiceState.Running) Balloon("mihomo 已启动", "代理内核运行中", ToolTipIcon.Info);
            else Balloon("mihomo 已停止", "已切换为完全直连", ToolTipIcon.Info);
        }

        void UpdateUi()
        {
            bool running = state == ServiceState.Running;
            bool starting = state == ServiceState.Starting;
            string title;
            Dot dot = Dot.Muted;

            if (busy) { title = busyText; dot = Dot.Pending; }
            else
            {
                switch (state)
                {
                    case ServiceState.Running:  title = "运行中"; dot = Dot.Accent; break;
                    case ServiceState.Stopped:  title = "已停止（直连）"; break;
                    case ServiceState.Starting: title = "启动中…"; dot = Dot.Pending; break;
                    case ServiceState.Stopping: title = "停止中…"; dot = Dot.Pending; break;
                    case ServiceState.Missing:  title = "未找到服务 " + Config.ServiceName; dot = Dot.Pending; break;
                    default:                    title = "状态未知"; break;
                }
            }

            header.Text = title;
            header.DotKind = dot;
            header.Hint = running && !busy ? exitName : null;

            startRow.Enabled   = !busy && !running && !starting;
            stopRow.Enabled    = !busy && (running || starting);
            restartRow.Enabled = !busy && running;

            Icon want = running ? iconOn : iconOff;
            if (want != null && tray.Icon != want) tray.Icon = want;

            string tip = "mihomo · " + title;
            if (running && !busy && !string.IsNullOrEmpty(exitName)) tip += " · " + exitName;
            tray.Text = Truncate(tip, 63);

            menu.Repaint();
        }

        static string Truncate(string s, int max)
        {
            if (s.Length <= max) return s;
            int cut = max - 1;
            if (char.IsHighSurrogate(s[cut - 1])) cut--; // 不把 emoji 劈成半个
            return s.Substring(0, cut) + "…";
        }

        // ── 出口节点 ──────────────────────────────────────────
        void RefreshExit()
        {
            if (Interlocked.CompareExchange(ref fetching, 1, 0) != 0) return;
            exitAt = DateTime.UtcNow;
            ThreadPool.QueueUserWorkItem(delegate
            {
                string name = null;
                bool ok = true;
                try { name = MihomoApi.ResolveExit(); }
                catch { ok = false; }
                Post(delegate
                {
                    Interlocked.Exchange(ref fetching, 0);
                    if (!ok) { exitAt = DateTime.UtcNow.AddSeconds(3 - Config.ExitRefreshSec); return; } // 3 秒后重试
                    if (state != ServiceState.Running) return;
                    string display = MihomoApi.Friendly(name);
                    if (display != exitName) { exitName = display; UpdateUi(); }
                });
            });
        }

        // ── 托盘交互 ──────────────────────────────────────────
        void OnTrayMouseUp(object sender, MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Right) return;
            Poll(); // 打开前同步一次，所见即所得
            menu.ShowAt(Cursor.Position);
            if (state == ServiceState.Running && (DateTime.UtcNow - exitAt).TotalSeconds > 3) RefreshExit();
        }

        void OnTrayDoubleClick(object sender, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left) OpenPanel();
        }

        // ── 菜单动作 ──────────────────────────────────────────
        void DoStart()   { RunService("启动中…", ServiceOps.Start, false); }
        void DoStop()    { RunService("停止中…", ServiceOps.Stop, false); }
        void DoRestart() { RunService("重启中…", ServiceOps.Restart, true); }

        void RunService(string text, Func<string> op, bool isRestart)
        {
            if (busy) return;
            busy = true;
            busyText = text;
            UpdateUi();

            ThreadPool.QueueUserWorkItem(delegate
            {
                string err;
                try { err = op(); }
                catch (Exception ex) { err = ex.Message; }

                Post(delegate
                {
                    busy = false;
                    busyText = null;
                    ServiceState before = stable;
                    state = ServiceOps.Query();
                    if (state == ServiceState.Running || state == ServiceState.Stopped)
                    {
                        if (err == null)
                        {
                            if (isRestart && state == ServiceState.Running) Balloon("mihomo 已重启", "代理内核运行中", ToolTipIcon.Info);
                            else if (state != before) NotifyStable(state);
                        }
                        stable = state;
                    }
                    if (err != null) Balloon("操作未完成", err, ToolTipIcon.Warning);
                    if (state != ServiceState.Running) exitName = null;
                    exitAt = DateTime.MinValue;
                    UpdateUi();
                    Poll();
                });
            });
        }

        void OpenPanel()
        {
            string url = null;
            try { url = PanelLink.ReadUrl(); } catch { }
            if (string.IsNullOrEmpty(url))
            {
                Balloon("找不到面板地址", "请检查桌面上的「" + Config.PanelShortcutName + "」", ToolTipIcon.Warning);
                return;
            }
            Launch(url, null, null);
        }

        void OpenReport()
        {
            if (!File.Exists(Config.StatusScript))
            {
                Balloon("找不到状态脚本", Config.StatusScript, ToolTipIcon.Warning);
                return;
            }
            // 新控制台窗口展示报告；-NoExit 保留窗口供阅读（脚本自身的暂停由 -NoPause 关闭）
            Launch("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -NoExit -File \"" + Config.StatusScript + "\" -NoPause",
                Config.RootDir);
        }

        void Launch(string file, string args, string dir)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(file);
                if (args != null) psi.Arguments = args;
                if (dir != null) psi.WorkingDirectory = dir;
                psi.UseShellExecute = true;
                using (Process.Start(psi)) { }
            }
            catch (Exception ex)
            {
                Balloon("无法打开", ex.Message, ToolTipIcon.Warning);
            }
        }

        void ExitApp()
        {
            ExitThread(); // → ExitThreadCore → Cleanup；只退托盘，不碰内核
        }

        // ── 杂项 ──────────────────────────────────────────
        void Balloon(string title, string text, ToolTipIcon icon)
        {
            try { tray.ShowBalloonTip(3000, title, string.IsNullOrEmpty(text) ? " " : text, icon); }
            catch { }
        }

        void Post(Action action)
        {
            try
            {
                if (!cleaned && menu.IsHandleCreated && !menu.IsDisposed) menu.BeginInvoke(action);
            }
            catch { }
        }

        void LoadIcons()
        {
            int size = Dpi.TrayIconSize();
            Icon oldOn = iconOn, oldOff = iconOff;
            iconOn = IconLoader.Load(Config.IconOn, size);
            iconOff = IconLoader.Load(Config.IconOff, size);
            tray.Icon = state == ServiceState.Running ? iconOn : iconOff;
            if (oldOn != null) oldOn.Dispose();
            if (oldOff != null) oldOff.Dispose();
        }

        void OnDisplayChanged(object sender, EventArgs e)
        {
            Post(LoadIcons); // 缩放改变后按新尺寸重载托盘图标
        }

        protected override void ExitThreadCore()
        {
            Cleanup();
            base.ExitThreadCore();
        }

        void Cleanup()
        {
            if (cleaned) return;
            cleaned = true;
            try
            {
                timer.Stop();
                SystemEvents.DisplaySettingsChanged -= OnDisplayChanged;
                menu.CloseMenu();
                tray.Visible = false; // 先隐藏，避免退出后图标残留
                tray.Dispose();
            }
            catch { }
        }
    }

    // ═══════════════════════════ 服务控制 ═══════════════════════════
    static class ServiceOps
    {
        static string N { get { return Config.ServiceName; } }

        public static ServiceState Query()
        {
            try
            {
                using (ServiceController sc = new ServiceController(N))
                {
                    switch (sc.Status)
                    {
                        case ServiceControllerStatus.Running: return ServiceState.Running;
                        case ServiceControllerStatus.Stopped:
                        case ServiceControllerStatus.Paused: return ServiceState.Stopped;
                        case ServiceControllerStatus.StartPending:
                        case ServiceControllerStatus.ContinuePending: return ServiceState.Starting;
                        default: return ServiceState.Stopping;
                    }
                }
            }
            catch (InvalidOperationException) { return ServiceState.Missing; }
            catch { return ServiceState.Unknown; }
        }

        static TimeSpan Wait { get { return TimeSpan.FromSeconds(Config.ServiceTimeoutSec); } }

        // 返回 null = 成功（或已交给 UAC 提权进程），否则为错误说明
        public static string Start()
        {
            try
            {
                using (ServiceController sc = new ServiceController(N))
                {
                    EnsureAutoStart();
                    sc.Refresh();
                    if (sc.Status == ServiceControllerStatus.Running) return null;
                    if (sc.Status == ServiceControllerStatus.StopPending) sc.WaitForStatus(ServiceControllerStatus.Stopped, Wait);
                    if (sc.Status != ServiceControllerStatus.StartPending) sc.Start();
                    sc.WaitForStatus(ServiceControllerStatus.Running, Wait);
                    return null;
                }
            }
            catch (System.ServiceProcess.TimeoutException) { return "等待服务启动超时，可查看「详细状态报告」。"; }
            catch (Exception ex)
            {
                if (IsAccessDenied(ex))
                    return Elevated("Set-Service -Name '" + N + "' -StartupType Automatic; Start-Service -Name '" + N + "'");
                return "启动失败：" + Innermost(ex).Message;
            }
        }

        public static string Stop()
        {
            try
            {
                using (ServiceController sc = new ServiceController(N))
                {
                    sc.Refresh();
                    if (sc.Status == ServiceControllerStatus.Stopped) return null;
                    if (sc.Status != ServiceControllerStatus.StopPending) sc.Stop(); // 只停内核，不改启动类型
                    sc.WaitForStatus(ServiceControllerStatus.Stopped, Wait);
                    return null;
                }
            }
            catch (System.ServiceProcess.TimeoutException) { return "等待服务停止超时，可查看「详细状态报告」。"; }
            catch (Exception ex)
            {
                if (IsAccessDenied(ex)) return Elevated("Stop-Service -Name '" + N + "' -Force");
                return "停止失败：" + Innermost(ex).Message;
            }
        }

        public static string Restart()
        {
            try
            {
                using (ServiceController sc = new ServiceController(N))
                {
                    EnsureAutoStart();
                    sc.Refresh();
                    if (sc.Status != ServiceControllerStatus.Stopped)
                    {
                        if (sc.Status != ServiceControllerStatus.StopPending) sc.Stop();
                        sc.WaitForStatus(ServiceControllerStatus.Stopped, Wait);
                    }
                    sc.Start();
                    sc.WaitForStatus(ServiceControllerStatus.Running, Wait);
                    return null;
                }
            }
            catch (System.ServiceProcess.TimeoutException) { return "等待服务重启超时，可查看「详细状态报告」。"; }
            catch (Exception ex)
            {
                if (IsAccessDenied(ex))
                    return Elevated("Set-Service -Name '" + N + "' -StartupType Automatic; Restart-Service -Name '" + N + "' -Force");
                return "重启失败：" + Innermost(ex).Message;
            }
        }

        // start 语义：恢复 Automatic。已是 Automatic 就不碰（不需要 DC 权限）
        static void EnsureAutoStart()
        {
            int start = ReadStartType();
            if (start == 2 || start < 0) return; // 2 = SERVICE_AUTO_START；读不到则不动
            if (!Native.SetServiceAutoStart(N))
                throw new UnauthorizedAccessException("无权修改服务启动类型");
        }

        static int ReadStartType()
        {
            try
            {
                using (RegistryKey k = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\" + N))
                {
                    if (k == null) return -1;
                    object v = k.GetValue("Start");
                    return v is int ? (int)v : -1;
                }
            }
            catch { return -1; }
        }

        static bool IsAccessDenied(Exception ex)
        {
            for (Exception e = ex; e != null; e = e.InnerException)
            {
                if (e is UnauthorizedAccessException) return true;
                Win32Exception w = e as Win32Exception;
                if (w != null && w.NativeErrorCode == 5) return true;
            }
            return false;
        }

        static Exception Innermost(Exception ex)
        {
            while (ex.InnerException != null) ex = ex.InnerException;
            return ex;
        }

        // 回退：弹 UAC，用隐藏的 PowerShell 执行；被拒/取消不抛出
        static string Elevated(string psCommand)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
                    "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command \"" + psCommand + "\"");
                psi.Verb = "runas";
                psi.UseShellExecute = true;
                psi.WindowStyle = ProcessWindowStyle.Hidden;
                using (Process p = Process.Start(psi))
                {
                    if (p != null) p.WaitForExit((Config.ServiceTimeoutSec + 10) * 1000);
                }
                return null;
            }
            catch (Win32Exception ex)
            {
                return ex.NativeErrorCode == 1223 ? "已取消管理员授权，操作未执行。" : "提权失败：" + ex.Message;
            }
            catch (Exception ex)
            {
                return "提权失败：" + ex.Message;
            }
        }
    }

    // ═══════════════════════════ 面板地址 / API ═══════════════════════════
    sealed class ApiEndpoint
    {
        public string Base;
        public string Secret;
    }

    static class PanelLink
    {
        public static string ShortcutPath()
        {
            string[] candidates = {
                SafeCombine(Environment.SpecialFolder.DesktopDirectory),
                Config.PanelShortcutFallback,
                SafeCombine(Environment.SpecialFolder.CommonDesktopDirectory)
            };
            foreach (string c in candidates)
            {
                try { if (!string.IsNullOrEmpty(c) && File.Exists(c)) return c; } catch { }
            }
            return null;
        }

        static string SafeCombine(Environment.SpecialFolder folder)
        {
            try { return Path.Combine(Environment.GetFolderPath(folder), Config.PanelShortcutName); }
            catch { return null; }
        }

        // 每次现读，不缓存、不硬编码（URL 含密钥）
        public static string ReadUrl()
        {
            string path = ShortcutPath();
            if (path == null) return null;
            foreach (string line in File.ReadAllLines(path))
            {
                string t = line.Trim();
                if (t.StartsWith("URL=", StringComparison.OrdinalIgnoreCase)) return t.Substring(4).Trim();
            }
            return null;
        }

        public static ApiEndpoint ReadApi()
        {
            ApiEndpoint ep = new ApiEndpoint { Base = Config.ApiFallback, Secret = "" };
            string url = null;
            try { url = ReadUrl(); } catch { }
            if (string.IsNullOrEmpty(url)) return ep;

            // 兼容 metacubexd / zashboard / yacd：…#/setup?hostname=…&port=…&secret=…
            string host = Param(url, "hostname"), port = Param(url, "port"), secret = Param(url, "secret");
            Uri u;
            if (Uri.TryCreate(url, UriKind.Absolute, out u))
            {
                if (string.IsNullOrEmpty(host)) host = u.Host;
                if (string.IsNullOrEmpty(port)) port = u.Port.ToString();
            }
            if (!string.IsNullOrEmpty(host) && !string.IsNullOrEmpty(port)) ep.Base = "http://" + host + ":" + port;
            if (secret != null) ep.Secret = secret;
            return ep;
        }

        static string Param(string url, string key)
        {
            Match m = Regex.Match(url, "[?&#]" + key + "=([^&#]*)", RegexOptions.IgnoreCase);
            return m.Success ? Uri.UnescapeDataString(m.Groups[1].Value) : null;
        }
    }

    static class MihomoApi
    {
        static string matchGroup;
        static DateTime matchAt = DateTime.MinValue;

        // 解析当前“默认出口”：MATCH 规则指向的组 → 沿 now 一路展开到具体节点
        public static string ResolveExit()
        {
            ApiEndpoint ep = PanelLink.ReadApi();
            string mode = Str(Get(ep, "/configs"), "mode").ToLowerInvariant();
            if (mode == "direct") return "DIRECT";

            string start = Config.ExitGroup;
            if (string.IsNullOrEmpty(start)) start = mode == "global" ? "GLOBAL" : MatchGroup(ep);
            if (string.IsNullOrEmpty(start)) return null;

            string name = start;
            for (int depth = 0; depth < 8; depth++)
            {
                string now = Str(Get(ep, "/proxies/" + Uri.EscapeDataString(name)), "now");
                if (now.Length == 0 || now == name) break;
                name = now;
            }
            return name;
        }

        public static string Friendly(string name)
        {
            if (string.IsNullOrEmpty(name)) return null;
            if (name == "DIRECT") return "直连";
            if (name == "REJECT") return "拒绝";
            return name;
        }

        static string MatchGroup(ApiEndpoint ep)
        {
            if (matchGroup != null && (DateTime.UtcNow - matchAt).TotalMinutes < 5) return matchGroup;
            string found = null;
            Dictionary<string, object> r = Get(ep, "/rules");
            object[] list = (r != null && r.ContainsKey("rules")) ? r["rules"] as object[] : null;
            if (list != null)
            {
                foreach (object o in list)
                {
                    Dictionary<string, object> rule = o as Dictionary<string, object>;
                    if (rule != null && string.Equals(Str(rule, "type"), "Match", StringComparison.OrdinalIgnoreCase))
                        found = Str(rule, "proxy");
                }
            }
            matchGroup = found;
            matchAt = DateTime.UtcNow;
            return found;
        }

        static Dictionary<string, object> Get(ApiEndpoint ep, string path)
        {
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(ep.Base + path);
            req.Proxy = null; // 本机 API 绝不走系统代理
            req.Timeout = 2500;
            req.ReadWriteTimeout = 2500;
            req.KeepAlive = false;
            if (!string.IsNullOrEmpty(ep.Secret)) req.Headers[HttpRequestHeader.Authorization] = "Bearer " + ep.Secret;
            using (WebResponse resp = req.GetResponse())
            using (StreamReader sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
            {
                JavaScriptSerializer js = new JavaScriptSerializer();
                js.MaxJsonLength = int.MaxValue;
                return js.DeserializeObject(sr.ReadToEnd()) as Dictionary<string, object>;
            }
        }

        static string Str(Dictionary<string, object> d, string key)
        {
            object v;
            return d != null && d.TryGetValue(key, out v) && v != null ? v.ToString() : "";
        }
    }

    // ═══════════════════════════ 外观 ═══════════════════════════
    sealed class Palette
    {
        public Color Back, Hover, Text, TextDim, TextDisabled, Separator, Border, Accent, Muted, Pending;

        static Color C(int rgb)
        {
            return Color.FromArgb(255, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
        }

        public static Palette Dark()
        {
            Palette p = new Palette();
            p.Back = C(0x2A2A2E);         p.Hover = C(0x3F3F46);
            p.Text = C(0xF0F0F0);         p.TextDim = C(0x9C9CA4);      p.TextDisabled = C(0x66666D);
            p.Separator = C(0x3A3A40);    p.Border = C(0x46464D);
            p.Accent = C(0x3ECFA0);       p.Muted = C(0x85858D);        p.Pending = C(0xE8B04B);
            return p;
        }

        public static Palette Light()
        {
            Palette p = new Palette();
            p.Back = C(0xF9F9FB);         p.Hover = C(0xE9E9EE);
            p.Text = C(0x1B1B1F);         p.TextDim = C(0x6B6B73);      p.TextDisabled = C(0xA8A8AF);
            p.Separator = C(0xE2E2E7);    p.Border = C(0xD3D3D9);
            p.Accent = C(0x1FA37A);       p.Muted = C(0x9A9AA2);        p.Pending = C(0xC98A1C);
            return p;
        }

        public static Palette Current()
        {
            string mode = Config.Theme.ToLowerInvariant();
            if (mode == "light") return Light();
            if (mode == "auto" && SystemUsesLight()) return Light();
            return Dark();
        }

        static bool SystemUsesLight()
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                {
                    object v = k == null ? null : k.GetValue("SystemUsesLightTheme");
                    return v is int && (int)v == 1;
                }
            }
            catch { return false; }
        }
    }

    enum RowKind { Header, Item, Separator }
    enum Dot { Muted, Accent, Pending }

    sealed class Row
    {
        public RowKind Kind;
        public string Glyph;     // 图标字体码位
        public string AltGlyph;  // 无图标字体时的回退符号
        public string Text;
        public string Hint;      // 右侧弱化说明
        public bool Enabled = true;
        public Action Click;
        public Dot DotKind;      // 仅 Header

        public static Row Cmd(string glyph, string alt, string text, string hint, Action click)
        {
            Row r = new Row();
            r.Kind = RowKind.Item; r.Glyph = glyph; r.AltGlyph = alt; r.Text = text; r.Hint = hint; r.Click = click;
            return r;
        }

        public static Row Separator() { Row r = new Row(); r.Kind = RowKind.Separator; return r; }
        public static Row Header() { Row r = new Row(); r.Kind = RowKind.Header; r.Text = ""; return r; }
    }

    // ═══════════════════════════ 自绘弹出菜单 ═══════════════════════════
    // 不用 ContextMenuStrip：.NET Framework 的 ToolStrip 在高 DPI 下各项度量的缩放规则不透明、难以精确控制。
    // 这里所有尺寸 = 96dpi 基准值 × (目标显示器 DPI / 96)，像素级可控。
    sealed class PopupMenu : Form
    {
        const int WM_DPICHANGED = 0x02E0;

        // 96dpi 基准尺寸
        const float PadOuter = 4f, RowH = 24f, SepH = 9f, Radius = 4f;
        const float GlyphX = 6f, GlyphW = 24f, TextX = 34f, PadRight = 12f, HintGap = 20f;
        const float MinInnerW = 184f, MaxInnerW = 300f;
        const float TextPt = 9f, GlyphPx = 12f;

        const TextFormatFlags TF = TextFormatFlags.SingleLine | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix |
                                   TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis;

        // 中文为主，直接用 YaHei UI（其西文字形即 Segoe UI），避免字体链接造成的基线跳动
        static readonly string TextFontName = FontProbe.First("Microsoft YaHei UI", "Segoe UI") ?? "Segoe UI";
        static readonly string IconFontName = FontProbe.First("Segoe Fluent Icons", "Segoe MDL2 Assets");

        List<Row> rows = new List<Row>();
        Rectangle[] rects = new Rectangle[0];
        Palette pal = Palette.Dark();
        float scale = 1f;
        Font textFont, glyphFont;
        int hot = -1;
        bool pressed, dwmRounded;
        DateTime hiddenAt = DateTime.MinValue;

        public PopupMenu()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            TopMost = true;
            KeyPreview = true;
            Text = "mihomo";
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Relayout(96);
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x00000080 /* WS_EX_TOOLWINDOW：不进 Alt+Tab */ | 0x00000008 /* WS_EX_TOPMOST */;
                cp.ClassStyle |= 0x00020000; /* CS_DROPSHADOW */
                return cp;
            }
        }

        public void SetRows(List<Row> list)
        {
            rows = list;
            Relayout(96);
        }

        public void Repaint()
        {
            if (!Actionable(hot)) hot = -1;
            if (Visible) Invalidate();
        }

        // ── 弹出 / 收起 ──────────────────────────────
        public void ShowAt(Point anchor)
        {
            if (Visible) { CloseMenu(); return; }
            if ((DateTime.UtcNow - hiddenAt).TotalMilliseconds < 250) return; // 菜单开着时再点图标 = 关闭，不立即重开

            pal = Palette.Current();
            Size size = Relayout(Dpi.At(anchor));

            // 方向自适应：优先在光标右上方展开，越界则翻转，并夹在工作区（避开任务栏）内
            Rectangle wa = Screen.FromPoint(anchor).WorkingArea;
            int x = anchor.X;
            if (x + size.Width > wa.Right) x = anchor.X - size.Width;
            x = Math.Max(wa.Left, Math.Min(x, wa.Right - size.Width));
            int y = anchor.Y - size.Height;
            if (y < wa.Top) y = anchor.Y;
            y = Math.Max(wa.Top, Math.Min(y, wa.Bottom - size.Height));

            hot = -1;
            pressed = false;
            Bounds = new Rectangle(x, y, size.Width, size.Height);
            ApplyDwm();
            Show();
            Activate();
            Native.SetForegroundWindow(Handle); // 拿到前台，才能在点击别处时收到 Deactivate
        }

        public void CloseMenu()
        {
            if (!Visible) return;
            Hide();
            hiddenAt = DateTime.UtcNow;
            hot = -1;
            pressed = false;
        }

        protected override void OnDeactivate(EventArgs e)
        {
            base.OnDeactivate(e);
            CloseMenu();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; CloseMenu(); return; } // Alt+F4 只收起
            base.OnFormClosing(e);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_DPICHANGED) { m.Result = IntPtr.Zero; return; } // 尺寸由 ShowAt 按目标屏 DPI 自算
            base.WndProc(ref m);
        }

        void ApplyDwm()
        {
            try
            {
                int pref = 2; // DWMWA_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUND（Win11）
                dwmRounded = Native.DwmSetWindowAttribute(Handle, 33, ref pref, 4) == 0;
                int border = pal.Border.R | (pal.Border.G << 8) | (pal.Border.B << 16); // DWMWA_BORDER_COLOR
                Native.DwmSetWindowAttribute(Handle, 34, ref border, 4);
            }
            catch { dwmRounded = false; }
        }

        // ── 布局 ──────────────────────────────
        int S(float v) { return (int)Math.Round(v * scale); }

        Size Relayout(int dpi)
        {
            scale = dpi / 96f;
            if (textFont != null) textFont.Dispose();
            if (glyphFont != null) glyphFont.Dispose();
            textFont = new Font(TextFontName, TextPt * dpi / 72f, FontStyle.Regular, GraphicsUnit.Pixel);
            glyphFont = IconFontName != null
                ? new Font(IconFontName, GlyphPx * scale, FontStyle.Regular, GraphicsUnit.Pixel)
                : new Font("Segoe UI Symbol", TextPt * dpi / 72f, FontStyle.Regular, GraphicsUnit.Pixel);

            int inner = S(MinInnerW);
            foreach (Row r in rows)
            {
                if (r.Kind == RowKind.Separator) continue;
                int w = S(TextX) + Measure(r.Text) + S(PadRight);
                if (!string.IsNullOrEmpty(r.Hint)) w += S(HintGap) + Measure(r.Hint);
                inner = Math.Max(inner, w);
            }
            inner = Math.Min(inner, S(MaxInnerW));

            int pad = S(PadOuter), y = pad;
            rects = new Rectangle[rows.Count];
            for (int i = 0; i < rows.Count; i++)
            {
                int h = rows[i].Kind == RowKind.Separator ? S(SepH) : S(RowH);
                rects[i] = new Rectangle(pad, y, inner, h);
                y += h;
            }
            return new Size(inner + pad * 2, y + pad);
        }

        int Measure(string s)
        {
            if (string.IsNullOrEmpty(s)) return 0;
            return TextRenderer.MeasureText(s, textFont, new Size(int.MaxValue, int.MaxValue),
                TextFormatFlags.SingleLine | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix).Width;
        }

        // ── 绘制 ──────────────────────────────
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.Clear(pal.Back);

            for (int i = 0; i < rows.Count && i < rects.Length; i++)
            {
                Row r = rows[i];
                Rectangle rc = rects[i];

                if (r.Kind == RowKind.Separator)
                {
                    using (SolidBrush b = new SolidBrush(pal.Separator))
                        g.FillRectangle(b, rc.Left + S(8), rc.Top + rc.Height / 2, rc.Width - S(16), 1);
                    continue;
                }

                bool disabled = r.Kind == RowKind.Item && !r.Enabled;
                Color fg = disabled ? pal.TextDisabled : pal.Text;
                Color dim = disabled ? pal.TextDisabled : pal.TextDim;

                if (i == hot && Actionable(i)) FillRound(g, rc, S(Radius), pal.Hover);

                Rectangle glyphRc = new Rectangle(rc.Left + S(GlyphX), rc.Top, S(GlyphW), rc.Height);
                if (r.Kind == RowKind.Header) DrawDot(g, glyphRc, r.DotKind);
                else
                {
                    string glyph = IconFontName != null ? r.Glyph : r.AltGlyph;
                    TextRenderer.DrawText(g, glyph, glyphFont, glyphRc, fg, TF | TextFormatFlags.HorizontalCenter);
                }

                Rectangle textRc = Rectangle.FromLTRB(rc.Left + S(TextX), rc.Top, rc.Right - S(PadRight), rc.Bottom);
                int labelW = Math.Min(Measure(r.Text), textRc.Width);
                TextRenderer.DrawText(g, r.Text, textFont, textRc, fg, TF | TextFormatFlags.Left);

                if (!string.IsNullOrEmpty(r.Hint))
                {
                    Rectangle hintRc = Rectangle.FromLTRB(textRc.Left + labelW + S(HintGap), rc.Top, textRc.Right, rc.Bottom);
                    if (hintRc.Width > S(16))
                        TextRenderer.DrawText(g, r.Hint, textFont, hintRc, dim, TF | TextFormatFlags.Right);
                }
            }

            if (!dwmRounded) // Win10 等无 DWM 圆角/边框时自己描 1px 边
                using (Pen p = new Pen(pal.Border))
                    g.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
        }

        void DrawDot(Graphics g, Rectangle box, Dot kind)
        {
            Color c = kind == Dot.Accent ? pal.Accent : kind == Dot.Pending ? pal.Pending : pal.Muted;
            float cx = box.Left + box.Width / 2f, cy = box.Top + box.Height / 2f;
            SmoothingMode old = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            if (kind == Dot.Accent) // 运行中：一圈很淡的柔光
            {
                float rg = 6.5f * scale;
                using (SolidBrush halo = new SolidBrush(Color.FromArgb(56, c)))
                    g.FillEllipse(halo, cx - rg, cy - rg, rg * 2, rg * 2);
            }
            float rd = 3.5f * scale;
            using (SolidBrush b = new SolidBrush(c))
                g.FillEllipse(b, cx - rd, cy - rd, rd * 2, rd * 2);
            g.SmoothingMode = old;
        }

        static void FillRound(Graphics g, Rectangle r, int radius, Color c)
        {
            int d = Math.Max(2, radius * 2);
            using (GraphicsPath path = new GraphicsPath())
            using (SolidBrush b = new SolidBrush(c))
            {
                path.AddArc(r.Left, r.Top, d, d, 180, 90);
                path.AddArc(r.Right - d, r.Top, d, d, 270, 90);
                path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
                path.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
                path.CloseFigure();
                SmoothingMode old = g.SmoothingMode;
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.FillPath(b, path);
                g.SmoothingMode = old;
            }
        }

        // ── 鼠标 / 键盘 ──────────────────────────────
        bool Actionable(int i)
        {
            return i >= 0 && i < rows.Count && rows[i].Kind == RowKind.Item && rows[i].Enabled;
        }

        int HitTest(Point p)
        {
            for (int i = 0; i < rects.Length && i < rows.Count; i++)
                if (rects[i].Contains(p) && Actionable(i)) return i;
            return -1;
        }

        void SetHot(int i)
        {
            if (!Actionable(i)) i = -1;
            if (i != hot) { hot = i; Invalidate(); }
        }

        protected override void OnMouseMove(MouseEventArgs e) { base.OnMouseMove(e); SetHot(HitTest(e.Location)); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); SetHot(-1); }
        protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); pressed = true; }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            bool wasPressed = pressed;
            pressed = false;
            int i = HitTest(e.Location);
            if (wasPressed && i >= 0) RunRow(i);
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            switch (keyData)
            {
                case Keys.Up: MoveHot(-1); return true;
                case Keys.Down:
                case Keys.Tab: MoveHot(1); return true;
                case Keys.Enter:
                case Keys.Space: if (hot >= 0) RunRow(hot); return true;
                case Keys.Escape: CloseMenu(); return true;
            }
            return base.ProcessCmdKey(ref msg, keyData);
        }

        void MoveHot(int dir)
        {
            int n = rows.Count;
            if (n == 0) return;
            int i = hot < 0 ? (dir > 0 ? -1 : n) : hot;
            for (int k = 0; k < n; k++)
            {
                i += dir;
                if (i >= n) i = 0;
                if (i < 0) i = n - 1;
                if (Actionable(i)) { SetHot(i); return; }
            }
        }

        void RunRow(int i)
        {
            Action act = rows[i].Click;
            CloseMenu();
            if (act != null) BeginInvoke(act); // 先收起菜单，再执行动作
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (textFont != null) textFont.Dispose();
                if (glyphFont != null) glyphFont.Dispose();
            }
            base.Dispose(disposing);
        }
    }

    // ═══════════════════════════ 工具 ═══════════════════════════
    static class FontProbe
    {
        public static string First(params string[] candidates)
        {
            foreach (string c in candidates)
            {
                try { using (new FontFamily(c)) return c; } // 未安装会抛 ArgumentException
                catch { }
            }
            return null;
        }
    }

    static class Dpi
    {
        public static int At(Point p)
        {
            try
            {
                Native.POINT pt;
                pt.X = p.X;
                pt.Y = p.Y;
                IntPtr mon = Native.MonitorFromPoint(pt, 2 /* MONITOR_DEFAULTTONEAREST */);
                uint dx, dy;
                if (mon != IntPtr.Zero && Native.GetDpiForMonitor(mon, 0 /* MDT_EFFECTIVE_DPI */, out dx, out dy) == 0 && dx > 0)
                    return (int)dx;
            }
            catch { }
            using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) return Math.Max(96, (int)g.DpiX);
        }

        // 托盘图标像素尺寸 = 主屏 DPI 下的 SM_CXSMICON（175% → 28px）
        public static int TrayIconSize()
        {
            int dpi = At(new Point(0, 0)); // (0,0) 必在主屏
            try
            {
                int s = Native.GetSystemMetricsForDpi(49 /* SM_CXSMICON */, (uint)dpi);
                if (s > 0) return s;
            }
            catch { }
            int s2 = Native.GetSystemMetrics(49);
            return s2 > 0 ? s2 : 16;
        }
    }

    static class IconLoader
    {
        // LoadIconWithScaleDown：从 ico 里取更大的一档高质量缩小到目标尺寸，而不是把 16px 放大
        public static Icon Load(string path, int size)
        {
            if (File.Exists(path))
            {
                try
                {
                    IntPtr h;
                    if (Native.LoadIconWithScaleDown(IntPtr.Zero, path, size, size, out h) == 0 && h != IntPtr.Zero)
                    {
                        try { using (Icon tmp = Icon.FromHandle(h)) return (Icon)tmp.Clone(); }
                        finally { Native.DestroyIcon(h); }
                    }
                }
                catch { }
                try { return new Icon(path, size, size); }
                catch { }
            }
            return new Icon(SystemIcons.Application, size, size);
        }
    }

    static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int X; public int Y; }

        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
        [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll")] public static extern int GetSystemMetricsForDpi(int index, uint dpi);
        [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
        [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);
        [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        [DllImport("comctl32.dll", CharSet = CharSet.Unicode)]
        public static extern int LoadIconWithScaleDown(IntPtr hinst, string name, int cx, int cy, out IntPtr hicon);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr OpenSCManager(string machine, string database, uint access);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr OpenService(IntPtr scm, string name, uint access);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool ChangeServiceConfig(IntPtr svc, uint type, uint start, uint errorControl, string binaryPath,
            string loadOrderGroup, IntPtr tagId, string dependencies, string startName, string password, string displayName);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool CloseServiceHandle(IntPtr h);

        // 需要 SERVICE_CHANGE_CONFIG 权限；没有就返回 false，由调用方回退 UAC
        public static bool SetServiceAutoStart(string name)
        {
            const uint NoChange = 0xFFFFFFFF;
            IntPtr scm = OpenSCManager(null, null, 0x0001 /* SC_MANAGER_CONNECT */);
            if (scm == IntPtr.Zero) return false;
            try
            {
                IntPtr svc = OpenService(scm, name, 0x0002 /* SERVICE_CHANGE_CONFIG */);
                if (svc == IntPtr.Zero) return false;
                try { return ChangeServiceConfig(svc, NoChange, 2 /* AUTO_START */, NoChange, null, null, IntPtr.Zero, null, null, null, null); }
                finally { CloseServiceHandle(svc); }
            }
            finally { CloseServiceHandle(scm); }
        }
    }
}
