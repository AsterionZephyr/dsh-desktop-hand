<#
.SYNOPSIS
    dsh-desktop-hand 的 Windows 执行引擎。

.DESCRIPTION
    这不是"又一个截屏脚本"，而是把三份实测脚本里**验证过的那些坑**固化下来的产物。
    所有设计约束都有实测依据，改动前先读这段和同目录 README 的"为什么"章节。

    四条硬约束（踩过的坑，不要"优化"掉）：

    1) DPI 感知必须每一层都声明。
       本机 2560x1440 + 150% 缩放。没声明 DPI 感知时 SetCursorPos(42,1046) 会被
       系统乘 1.333 落到物理 (56,1395)，而 GetCursorPos 又除回去报 1280,720。
       表现是"点的位置和说的不一样"。声明后坐标 1:1 直达物理像素。
       ⚠️ 只声明一次不够：SetProcessDpiAwareness 必须在**任何窗口/DC 创建之前**，
         而且截图前要复核。capture 冷启动第一次抓到 1920x1080 就是因为这个竞态。

    2) 文本注入必须走 SendInput + KEYEVENTF_UNICODE，不能用 VkKeyScan + keybd_event。
       后者走键盘布局/输入法通路，中文输入法会在中间转换 —— 实测想输入
       "third batch"，MATLAB 收到的是「第三批」。Unicode 直投绕过输入法。

    3) 抓窗口必须用 PrintWindow + PW_RENDERFULLCONTENT(2)，不是 CopyFromScreen。
       只有 PrintWindow 能抓到**被遮挡**的窗口（实测 0% 黑像素）；
       全屏 CopyFromScreen 抓到的永远是遮挡者。
       flag 必须是 2：flag=0 对 UWP 是 100% 黑，flag=2 降到 71.7%，即 0 更糟。

    4) 绝不能用"黑像素比例"判定抓取成功。
       实测 UWP 宿主 ApplicationFrameWindow 黑像素仅 2.9%，图像却是空白框架。
       黑像素只作参考，判断成功与否必须看图。

    本脚本输出 JSON，由 lib/index.js 消费。

.PARAMETER Action
    list-windows | capture | click | move | drag | type | key | focus | info |
    ui-tree | scroll | clipboard | wait | open-app

.PARAMETER Json
    仅作标记（本脚本恒以 JSON 输出），保留是为了调用处语义清晰。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Action,

    # ---- capture ----
    [string]$Window,
    [Int64]$Handle = 0,
    [switch]$FullScreen,
    [string]$Region,              # "x,y,w,h"，相对被抓对象
    [string]$OutPath,
    [int]$ScreenIndex = -1,       # 指定显示器序号（-1 = 全部/虚拟屏）

    # ---- mouse ----
    [int]$X = 0,
    [int]$Y = 0,
    [int]$ToX = [int]::MinValue,
    [int]$ToY = [int]::MinValue,
    [switch]$Double,
    [switch]$Right,
    [int]$ShotWidth = 0,          # 坐标所依据的截图宽度；0 = 按物理屏宽（1:1）
    [int]$SettleMs = 30,          # 移到→按下 之间的等待，压到最小以躲远程鼠标

    # ---- keyboard ----
    [string]$Text,
    [string]$Key,
    [switch]$Enter,
    [int]$Delay = 0,

    # ---- focus ----
    [switch]$Restore,

    # ---- v1.1：UI 语义层 / 滚动 / 剪贴板 / 等待 / 启动应用 ----
    [string]$Target,              # click: UIA 控件名；wait: 窗口标题片段或控件名；open-app: 应用名片段
    [string]$Until,               # wait: window（默认，等窗口出现）| gone（等消失）| text（等窗口里出现控件）
    [string]$Role,                # UIA 角色过滤（子串匹配，如 button / edit / text / menuitem）
    [int]$Depth = 3,              # ui-tree 最大深度（1 起）
    [int]$MaxNodes = 200,         # ui-tree 最多节点数
    [switch]$Flat,                # ui-tree 输出纯文本（给不带视觉的模型读）
    [switch]$AllNodes,            # ui-tree 包含 offscreen 节点（-All 会与 list-windows 里的 $all 撞名）
    [int]$Delta = 3,              # scroll 滚轮格数，正=下/右，负=上/左
    [switch]$Horizontal,          # scroll 横向滚
    [string]$Mode,                # clipboard: get | set
    [switch]$KeepPrevious,        # clipboard set: 把原内容一起返回
    [int]$WaitMs = 10000,         # wait / open-app 的超时（毫秒）
    [int]$PollMs = 250,           # wait 轮询间隔（毫秒）
    [switch]$NoWait,              # open-app: 启动后不等窗口出现

    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# =====================================================================
#  输出编码 —— 必须是第一件事
# =====================================================================
# PowerShell 5.1 在 stdout 被重定向（管道/子进程捕获）时，默认按**控制台 ANSI 代码页**
# 编码输出，本机是 GBK(936)。Node 那边按 UTF-8 解码，中文就全成了乱码
# （实测错误信息变成乱码，模型读到的是无效字符串）。
# 把 OutputEncoding 显式设成 UTF-8 后，Node 侧 toString('utf8') 才是对的。
# ⚠️ 这行不能删：删掉不会报错，只会让所有中文提示变成乱码，很难查。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# =====================================================================
#  P/Invoke 层
# =====================================================================
if (-not ('DSKHand.Api' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

namespace DSKHand {

    public class WinInfo {
        public long Handle;
        public uint Pid;
        public int X, Y, W, H;
        public string Title;
        public string Class;
        public string Process;
        public bool IsUwp;
        public bool Minimized;
        public int BlackPermille;
        /// 是否是 ApplicationFrameHost 宿主壳（唯一真正抓不出内容的盲区）。
        /// 与 IsUwp 分开：CoreWindow 也是 UWP，但它能抓。
        public bool IsFrameHost;
    }

    /// 窗口类名的语义分类（2026-10-03 实测修正）。
    ///
    /// ⚠️ 历史错误：本文档与 SKILL.md 曾断言"UWP 应用是 PrintWindow 的盲区"。
    /// **该表述是错的，且会让人放弃一个本来能抓的窗口。** 实测对照：
    ///
    ///   | 窗口类名                        | 结果                                   |
    ///   | ------------------------------- | -------------------------------------- |
    ///   | Windows.UI.Core.CoreWindow      | **完整真实内容**（SystemSettings 418KB）|
    ///   | ApplicationFrameWindow          | 空白框架 + 齿轮 logo（31KB，零可操作信息）|
    ///
    /// 真正的判据是**类名**，不是"是不是 UWP"，也不是"是不是应用自己的进程"
    /// （本例两者恰好重合，极易被误当成因果）。
    ///
    /// CoreWindow：UWP 真实的 XAML 窗口，PrintWindow 抓得到 → 不该报警告。
    /// ApplicationFrameWindow：AFH 宿主壳，抓出来是空的 → 这才是唯一的盲区。
    public static class WinClass {
        public const string CoreWindow = "Windows.UI.Core.CoreWindow";
        public const string FrameHost = "ApplicationFrameWindow";

        /// UWP 真窗口：能抓，**不是**盲区。
        public static bool IsCoreWindow(string cls) { return cls == CoreWindow; }

        /// 宿主壳：抓出来可能是空白框架，需要提示。
        public static bool IsFrameHost(string cls) { return cls == FrameHost; }

        /// 宽泛的"与 UWP 有关"（仅用于列表标注，不用于决定警告）。
        public static bool IsUwpRelated(string cls) { return IsCoreWindow(cls) || IsFrameHost(cls); }
    }

    public class Shot {
        public string Path;
        public int Width, Height;
        public int BlackPermille;
        public string Target;
        public string TargetClass;
        public bool UwpWarning;
        public bool Minimized;
        public long Bytes;
        public bool BlackVerdict;
    }

    public class Api {
        // ---- window enumeration ----
        public delegate bool EnumProc(IntPtr h, IntPtr p);
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextLengthW(IntPtr h);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
        [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);

        // ---- capture ----
        [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
        [DllImport("user32.dll")] public static extern IntPtr GetWindowDC(IntPtr h);
        [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int cb);
        [DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr hdc, int i);
        [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);

        // ---- dpi ----
        [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);   // 2 = PER_MONITOR
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("shcore.dll")] public static extern int GetProcessDpiAwareness(IntPtr p, out int v);

        // ---- mouse ----
        [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out PT p);
        [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);

        // ---- keyboard: Unicode direct injection ----
        [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);

        public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;

        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
        [StructLayout(LayoutKind.Sequential)] public struct PT { public int X, Y; }

        [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)] public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL, wParamH; }
        [StructLayout(LayoutKind.Explicit)] public struct IU {
            [FieldOffset(0)] public KEYBDINPUT ki;
            [FieldOffset(0)] public MOUSEINPUT mi;
            [FieldOffset(0)] public HARDWAREINPUT hi; }
        [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public IU u; }

        public const uint INPUT_KEYBOARD = 1, INPUT_MOUSE = 0;
        public const uint KU = 0x0002, UNICODE = 0x0004;
        public const uint MOVE = 0x0001, LEFTDOWN = 0x0002, LEFTUP = 0x0004,
                           RIGHTDOWN = 0x0008, RIGHTUP = 0x0010, ABSOLUTE = 0x8000;
        public const byte VK_RETURN = 0x0D, VK_ESCAPE = 0x1B, VK_TAB = 0x09;
        public const byte VK_CONTROL = 0x11, VK_SHIFT = 0x10, VK_MENU = 0x12;
        public const byte VK_A = 0x41, VK_C = 0x43, VK_V = 0x56, VK_S = 0x53, VK_X = 0x58, VK_Z = 0x5A, VK_W = 0x57;
        public const byte VK_UP = 0x26, VK_DOWN = 0x28, VK_LEFT = 0x25, VK_RIGHT = 0x27;
        public const byte VK_HOME = 0x24, VK_END = 0x23, VK_PRIOR = 0x21, VK_NEXT = 0x22;
        public const byte VK_DELETE = 0x2E, VK_BACK = 0x08, VK_SPACE = 0x20;
        public const byte VK_F1 = 0x70;

        /// 声明 DPI 感知。必须在任何窗口/DC 创建之前调用，否则拿到虚拟化坐标。
        public static string Aware() {
            int cur;
            try { if (GetProcessDpiAwareness(IntPtr.Zero, out cur) == 0 && cur >= 2) return "already:" + cur; } catch { }
            try { if (SetProcessDpiAwareness(2) == 0) return "shcore:2"; } catch { }
            try { if (SetProcessDPIAware()) return "user32"; } catch { }
            return "FAILED";
        }

        private static int _vw = 0, _vh = 0;
        /// 物理屏幕尺寸（所有显示器的包围盒）。
        public static void RefreshScreen() {
            IntPtr dc = GetDC(IntPtr.Zero);
            _vw = GetDeviceCaps(dc, 118);   // DESKTOPHORZRES
            _vh = GetDeviceCaps(dc, 117);   // DESKTOPVERTRES
            ReleaseDC(IntPtr.Zero, dc);
        }
        public static int ScreenW { get { if (_vw == 0) RefreshScreen(); return _vw; } }
        public static int ScreenH { get { if (_vh == 0) RefreshScreen(); return _vh; } }
        public static string PhysScreen() { return ScreenW + "x" + ScreenH; }

        public static string Cur() { PT p; GetCursorPos(out p); return p.X + "," + p.Y; }

        // ---------------- window enumeration ----------------
        public static List<WinInfo> ListWindows() {
            var list = new List<WinInfo>();
            EnumWindows((h, p) => {
                if (!IsWindowVisible(h)) return true;
                int len = GetWindowTextLengthW(h);
                var sb = new StringBuilder(len + 2);
                GetWindowTextW(h, sb, sb.Capacity);
                string title = sb.ToString();
                var cb = new StringBuilder(256);
                GetClassNameW(h, cb, cb.Capacity);
                string cls = cb.ToString();
                // 无标题的壳窗口没有操作价值，跳过（Shell_TrayWnd 等仍保留供测量）
                if (title.Length == 0 && cls != "Shell_TrayWnd") return true;

                uint pid; GetWindowThreadProcessId(h, out pid);
                RECT r; GetWindowRect(h, out r);
                string pname = "";
                try { pname = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { }

                list.Add(new WinInfo {
                    Handle = (long)h, Pid = pid,
                    X = r.L, Y = r.T, W = r.R - r.L, H = r.B - r.T,
                    Title = title, Class = cls, Process = pname,
                    IsUwp = WinClass.IsUwpRelated(cls),
                    IsFrameHost = WinClass.IsFrameHost(cls),
                    Minimized = IsIconic(h)
                });
                return true;
            }, IntPtr.Zero);
            return list;
        }
        /// 按标题模糊匹配；返回所有命中（不擅自选第一个）。
        public static List<WinInfo> MatchWindows(string needle) {
            var all = ListWindows();
            var hit = new List<WinInfo>();
            string n = needle.ToLowerInvariant();
            foreach (var w in all)
                if (w.Title.ToLowerInvariant().Contains(n)) hit.Add(w);
            return hit;
        }

        public static WinInfo ByHandle(long h) {
            foreach (var w in ListWindows()) if (w.Handle == h) return w;
            // 句柄有效但不在可见列表（可能最小化）——仍构造一个
            IntPtr hp = (IntPtr)h;
            if (!IsWindow(hp)) return null;
            var cb = new StringBuilder(256); GetClassNameW(hp, cb, cb.Capacity);
            var tb = new StringBuilder(GetWindowTextLengthW(hp) + 2); GetWindowTextW(hp, tb, tb.Capacity);
            RECT r; GetWindowRect(hp, out r);
            uint pid; GetWindowThreadProcessId(hp, out pid);
            string pname = "";
            try { pname = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { }
            return new WinInfo {
                Handle = h, Pid = pid, X = r.L, Y = r.T, W = r.R - r.L, H = r.B - r.T,
                Title = tb.ToString(), Class = cb.ToString(), Process = pname,
                IsUwp = WinClass.IsUwpRelated(cb.ToString()),
                IsFrameHost = WinClass.IsFrameHost(cb.ToString()),
                Minimized = IsIconic(hp)
            };
        }

        // ---------------- focus ----------------
        /// SetForegroundWindow 会被前台锁挡掉（返回 True 但没生效）。
        /// AttachThreadInput + ALT 抖动是实测有效的组合。
        public static string Focus(IntPtr h) {
            if (!IsWindow(h)) return "invalid-handle";
            if (IsIconic(h)) ShowWindow(h, 9);   // SW_RESTORE
            IntPtr fg = GetForegroundWindow();
            if (fg == h) return "already-foreground";
            uint tidFg; GetWindowThreadProcessId(fg, out tidFg);
            uint myTid = GetCurrentThreadId();
            bool att = (tidFg != myTid) && AttachThreadInput(myTid, tidFg, true);
            try {
                keybd_event(VK_MENU, 0, 0, IntPtr.Zero);
                keybd_event(VK_MENU, 0, KU, IntPtr.Zero);
                SetForegroundWindow(h);
                BringWindowToTop(h);
            } finally { if (att) AttachThreadInput(myTid, tidFg, false); }
            System.Threading.Thread.Sleep(120);
            return GetForegroundWindow() == h ? "ok" : "failed(foreground-lock)";
        }

        public static string ForegroundTitle() {
            IntPtr h = GetForegroundWindow();
            var sb = new StringBuilder(GetWindowTextLengthW(h) + 2);
            GetWindowTextW(h, sb, sb.Capacity);
            var cb = new StringBuilder(256); GetClassNameW(h, cb, cb.Capacity);
            return sb.ToString() + " [" + cb.ToString() + "]";
        }

        // ---------------- capture ----------------
        /// PrintWindow 抓整个窗口（含被遮挡内容）。flag 必须为 2。
        public static Bitmap CaptureWindow(IntPtr h, out string err) {
            err = null;
            if (!IsWindow(h)) { err = "invalid-handle"; return null; }
            RECT r;
            // 优先用 DWM 扩展边框（去掉 Win10+ 的透明阴影边距）
            if (DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, out r, Marshal.SizeOf(typeof(RECT))) != 0)
                GetWindowRect(h, out r);
            int w = r.R - r.L, hh = r.B - r.T;
            if (w <= 0 || hh <= 0) { err = "zero-size(minimized?)"; return null; }
            if (w > 20000 || hh > 20000) { err = "absurd-size:" + w + "x" + hh; return null; }

            var bmp = new Bitmap(w, hh, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bmp)) {
                IntPtr hdc = g.GetHdc();
                try {
                    // flag=2 PW_RENDERFULLCONTENT —— 关键
                    if (!PrintWindow(h, hdc, 2)) {
                        if (!PrintWindow(h, hdc, 0)) { err = "printwindow-failed"; }
                    }
                } finally { g.ReleaseHdc(hdc); }
            }
            return bmp;
        }

        /// 全屏抓取（CopyFromScreen）。只能抓到屏幕上可见的像素。
        public static Bitmap CaptureScreen(int screenIndex) {
            if (screenIndex >= 0) {
                var scr = System.Windows.Forms.Screen.AllScreens;
                if (screenIndex < scr.Length) {
                    var b = scr[screenIndex].Bounds;
                    var bm = new Bitmap(b.Width, b.Height, PixelFormat.Format32bppArgb);
                    using (var g = Graphics.FromImage(bm)) g.CopyFromScreen(b.X, b.Y, 0, 0, b.Size);
                    return bm;
                }
            }
            var full = new Bitmap(ScreenW, ScreenH, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(full)) g.CopyFromScreen(0, 0, 0, 0, new Size(ScreenW, ScreenH));
            return full;
        }

        /// 黑像素千分比。**仅作参考，不是成功判据**（UWP 反例见文件头）。
        /// 粗采样（约 120x120 个点）算黑像素千分比。
        /// 用 GetPixel 而非 LockBits/unsafe：本机是 PowerShell 5.1，其 Add-Type
        /// 内部的 CodeDom 编译器**不支持 unsafe**（没有 /unsafe 开关可传）。
        /// 采样点很少，GetPixel 的开销可以忽略，不值得为它引入不安全代码。
        public static int BlackPermille(Bitmap bmp) {
            int dark = 0, total = 0;
            int stepX = Math.Max(1, bmp.Width / 120), stepY = Math.Max(1, bmp.Height / 120);
            for (int y = 0; y < bmp.Height; y += stepY) {
                for (int x = 0; x < bmp.Width; x += stepX) {
                    Color c = bmp.GetPixel(x, y);
                    total++;
                    if (c.R < 12 && c.G < 12 && c.B < 12) dark++;
                }
            }
            return total == 0 ? 0 : (int)(1000L * dark / total);
        }

        /// 空白度判据：**按实测像素**判断"抓出来的图是不是空的"，
        /// 而不是按"这个窗口是不是 UWP"。理由见 WinClass 的注释：
        /// 旧逻辑用 IsUwp 触发 warning，导致 418KB 的完整图也带警告、
        /// 31KB 的空白框架同样只是"带警告"——警告完全失去区分力。
        ///
        /// 判据（2026-10-03 实测标定，本机 Win11 25H2）：
        ///
        ///   | 窗口                      | PNG 字节 | dominant‰ | distinctColors |
        ///   | ------------------------- | -------- | --------- | -------------- |
        ///   | ApplicationFrameWindow 壳 | 31,176   | 977       | **17**         |
        ///   | CoreWindow（真内容）      | 418,069  | 944       | **173**        |
        ///
        /// 关键区分量是 **distinctColors**（相差 10 倍），不是 dominant
        /// （两者都高：空白壳是纯色，真内容也有大片同色背景）。
        /// 阈值取 distinctColors <= 48：远高于 17、远低于 173，两侧都留足余量。
        /// 再要求主导色偏暗，避免把"纯白空白页"（如新建记事本）误判成抓取失败。
        ///
        /// ⚠️ 这里**不**看 blackPermille：实测空白壳只有 16‰（不黑）、
        /// 真内容反而 617‰（深色主题）——黑像素比例是反的，本就不能当判据。
        ///
        /// 用 GetPixel 的理由同 BlackPermille：PS5.1 的 Add-Type 不支持 unsafe。
        public static bool LooksBlank(Bitmap bmp, out int dominantPermille, out int distinctColors) {
            dominantPermille = 0; distinctColors = 0;
            var counts = new Dictionary<int, int>();
            int total = 0;
            int stepX = Math.Max(1, bmp.Width / 160), stepY = Math.Max(1, bmp.Height / 160);
            for (int y = 0; y < bmp.Height; y += stepY) {
                for (int x = 0; x < bmp.Width; x += stepX) {
                    Color c = bmp.GetPixel(x, y);
                    // 量化到 8 级/通道（>>5 = 每通道 32 级）：抗 PNG 压缩与亚像素抖动。
                    // 量化粒度直接决定 distinctColors 的量级，改这里要重新标定阈值。
                    int key = ((c.R >> 5) << 10) | ((c.G >> 5) << 5) | (c.B >> 5);
                    int n; counts.TryGetValue(key, out n);
                    counts[key] = n + 1;
                    total++;
                }
            }
            if (total == 0) return false;
            int best = 0, bestKey = 0;
            foreach (var kv in counts) if (kv.Value > best) { best = kv.Value; bestKey = kv.Key; }
            dominantPermille = (int)(1000L * best / total);
            distinctColors = counts.Count;
            int domR = ((bestKey >> 10) & 31) << 5, domG = ((bestKey >> 5) & 31) << 5, domB = (bestKey & 31) << 5;
            bool dominantIsDark = domR < 192 && domG < 192 && domB < 192;
            // 主导色占比高 + 颜色种类极少 + 主导色不亮 → 空白壳
            return dominantPermille >= 900 && distinctColors <= 48 && dominantIsDark;
        }

        // ---------------- mouse ----------------
        /// 点击：SetCursorPos 后**尽快**按下。等 140ms 会给远程鼠标插进来的时间窗。
        public static void Click(int x, int y, bool right, bool dbl, int settleMs) {
            SetCursorPos(x, y);
            if (settleMs > 0) System.Threading.Thread.Sleep(settleMs);
            uint d = right ? RIGHTDOWN : LEFTDOWN;
            uint u = right ? RIGHTUP : LEFTUP;
            MouseEvent(d); System.Threading.Thread.Sleep(40); MouseEvent(u);
            if (dbl) {
                System.Threading.Thread.Sleep(80);
                MouseEvent(d); System.Threading.Thread.Sleep(40); MouseEvent(u);
            }
        }

        public static void MoveTo(int x, int y) { SetCursorPos(x, y); }

        public static void Drag(int x1, int y1, int x2, int y2) {
            SetCursorPos(x1, y1);
            System.Threading.Thread.Sleep(120);
            MouseEvent(LEFTDOWN);
            System.Threading.Thread.Sleep(80);
            int steps = 24;
            for (int i = 1; i <= steps; i++) {
                SetCursorPos(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps);
                System.Threading.Thread.Sleep(15);
            }
            System.Threading.Thread.Sleep(80);
            MouseEvent(LEFTUP);
        }

        /// 用 SendInput 做绝对定位鼠标事件（比 mouse_event 更规范）。
        private static void MouseEvent(uint flags) {
            INPUT[] a = new INPUT[1];
            a[0].type = INPUT_MOUSE;
            a[0].u.mi.dwFlags = flags;
            SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
        }

        /// 设定后连续采样，判断光标是被"覆盖"还是"被拒绝"。诊断用。
        public static string Probe(int x, int y) {
            SetCursorPos(x, y);
            var sb = new StringBuilder();
            for (int i = 0; i < 5; i++) {
                System.Threading.Thread.Sleep(70);
                PT c; GetCursorPos(out c);
                sb.Append(c.X).Append(",").Append(c.Y).Append("  ");
            }
            return sb.ToString();
        }

        // ---------------- keyboard ----------------
        /// KEYEVENTF_UNICODE 直投：绕过输入法。这是能打进中文/格式符的关键。
        public static int TypeUnicode(string s) {
            int sent = 0;
            foreach (char c in s) {
                INPUT[] a = new INPUT[2];
                a[0].type = INPUT_KEYBOARD; a[0].u.ki.wVk = 0; a[0].u.ki.wScan = (ushort)c; a[0].u.ki.dwFlags = UNICODE;
                a[1].type = INPUT_KEYBOARD; a[1].u.ki.wVk = 0; a[1].u.ki.wScan = (ushort)c; a[1].u.ki.dwFlags = UNICODE | KU;
                if (SendInput(2, a, Marshal.SizeOf(typeof(INPUT))) != 2)
                    throw new Exception("SendInput(unicode) failed at char " + sent + ", err=" + Marshal.GetLastWin32Error());
                sent++;
                System.Threading.Thread.Sleep(5);
            }
            return sent;
        }

        public static void KeyVk(byte vk) {
            keybd_event(vk, 0, 0, IntPtr.Zero);
            System.Threading.Thread.Sleep(35);
            keybd_event(vk, 0, KU, IntPtr.Zero);
        }

        public static void KeyCombo(byte mod, byte vk) {
            keybd_event(mod, 0, 0, IntPtr.Zero);
            keybd_event(vk, 0, 0, IntPtr.Zero);
            System.Threading.Thread.Sleep(35);
            keybd_event(vk, 0, KU, IntPtr.Zero);
            keybd_event(mod, 0, KU, IntPtr.Zero);
        }

        // ---- v1.1: 滚轮 ----
        // 用 mouse_event 而不是 SendInput：SendInput 需要的 INPUT 结构本类已有，
        // 但 mouse_event 的签名更短、语义就是"绝对定位一个滚轮事件"，读起来不易出错。
        // dwData 是 DWORD，负的 delta 必须 unchecked 转成 uint，否则编译不过。
        [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, IntPtr extra);
        public const uint WHEEL = 0x0800, HWHEEL = 0x01000;

        /// 在 (x,y) 处打一次滚轮。delta 正=向下/向右，一格 = 120。
        ///
        /// ⚠️ 垂直方向要**取反**：WM_MOUSEWHEEL 的正值是"向前滚"（内容上移），
        /// 而这里的对外语义是"正=向下"，和本文档/规格保持一致；
        /// 水平方向 HWHEEL 的正值本来就是"向右"，不用取反。
        public static void ScrollWheel(int x, int y, int delta, bool horizontal) {
            SetCursorPos(x, y);
            System.Threading.Thread.Sleep(30);
            int notches = horizontal ? delta : -delta;
            mouse_event(horizontal ? HWHEEL : WHEEL, 0, 0, unchecked((uint)(notches * 120)), IntPtr.Zero);
        }

        /// 输入法状态查询（诊断用）：能解释"输入被打进别处/被转换"。
        public static string ImeState() {
            try {
                IntPtr h = GetForegroundWindow();
                IntPtr himc = ImmGetContext(h);
                if (himc == IntPtr.Zero) return "no-ime-context";
                int mode, sent;
                int conv = ImmGetConversionStatus(himc, out mode, out sent);
                ImmReleaseContext(h, himc);
                if (conv == 0) return "unknown";
                return "conversion=0x" + mode.ToString("X") + (mode == 0 ? " (English/off)" : " (IME OPEN)");
            } catch { return "query-failed"; }
        }
        [DllImport("imm32.dll")] public static extern IntPtr ImmGetContext(IntPtr h);
        [DllImport("imm32.dll")] public static extern bool ImmReleaseContext(IntPtr h, IntPtr c);
        [DllImport("imm32.dll")] public static extern int ImmGetConversionStatus(IntPtr c, out int mode, out int sent);
    }
}
'@ -ReferencedAssemblies System.Drawing, System.Windows.Forms
}

# =====================================================================
#  v1.1 扩展层：UI Automation 语义树 + 剪贴板（惰性编译）
# =====================================================================
# 为什么单独一段、而且惰性编译：
#   1) 隔离风险。这一段要引用 WPF 程序集（UIAutomationClient / UIAutomationTypes /
#      WindowsBase）。万一某台机器解析不到它们，Add-Type 就会抛异常。若和上面的主类
#      写在同一个 Add-Type 里，抓图/点击/输入会跟着一起不可用——不能拿小概率的
#      环境问题去换掉已经验证过的核心能力。
#   2) 省时间。引擎每个动作都是一次新的 powershell 进程，Add-Type 每次都重新编译。
#      多编译两百行 C# 大约多花 0.5~1.5s，而 ui-tree/clipboard 之外的动作根本用不到它。
# 所以：包成函数，只有真正用 UIA / 剪贴板的动作才调用。
$script:ExtrasError = ''
function Ensure-Extras {
    if ('DSKHand.Extra' -as [type]) { return $true }
    if ($script:ExtrasError -ne '') { return $false }   # 已经失败过，别重复编译
    try {
        # .NET Framework 里 UIAutomation* 与 WindowsBase 不在框架根目录，而在 WPF 子目录。
        # 只写程序集短名时 csc 未必解析得到（System.Windows.Rect 就在 WindowsBase 里），
        # 所以优先拼完整路径，拼不到再退回短名（GAC 里有的话短名也能解析）。
        $refs = New-Object System.Collections.Generic.List[string]
        $candidates = @(
            (Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/WPF'),
            (Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/WPF')
        )
        $wpf = $null
        foreach ($d in $candidates) {
            if (Test-Path -LiteralPath (Join-Path $d 'UIAutomationClient.dll')) { $wpf = $d; break }
        }
        if ($null -ne $wpf) {
            $refs.Add((Join-Path $wpf 'UIAutomationClient.dll'))
            $refs.Add((Join-Path $wpf 'UIAutomationTypes.dll'))
            $refs.Add((Join-Path $wpf 'WindowsBase.dll'))
        } else {
            $refs.Add('UIAutomationClient')
            $refs.Add('UIAutomationTypes')
            $refs.Add('WindowsBase')
        }
        $refs.Add('System.Windows.Forms')

        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Windows.Automation;
using System.Windows;

namespace DSKHand
{
    /// 一个 UIA 节点，只保留"做决策需要"的字段：
    /// 角色、名称、值、屏幕矩形（可直接当点击坐标）、是否可动作。
    public class UiNode
    {
        public int Depth;
        public string Role = "";
        public string Name = "";
        public string AutomationId = "";
        public string Value = "";
        public int X, Y, W, H, CenterX, CenterY;
        public bool Enabled = true;
        public bool Offscreen;
        public bool Invokable;
    }

    public static class Extra
    {
        // ---------------- 剪贴板 ----------------
        public static string ClipGet()
        {
            try { return System.Windows.Forms.Clipboard.GetText(); }
            catch { return null; }
        }

        public static bool ClipSet(string text)
        {
            if (text == null) text = "";
            // SetText("") 会抛 ArgumentException（空串是非法的），要清空只能 Clipboard.Clear()。
            if (text.Length == 0)
            {
                try { System.Windows.Forms.Clipboard.Clear(); return true; }
                catch { return false; }
            }
            // 剪贴板可能被别的进程临时占用（OpenClipboard 失败），重试几次是标准做法。
            for (int i = 0; i < 6; i++)
            {
                try { System.Windows.Forms.Clipboard.SetText(text); return true; }
                catch { System.Threading.Thread.Sleep(70); }
            }
            return false;
        }

        // ---------------- UI Automation ----------------
        static string Clip(string s, int max)
        {
            if (s == null) return "";
            s = s.Replace(Environment.NewLine, " ").Trim();
            return s.Length <= max ? s : s.Substring(0, max) + "...";
        }

        static string RoleOf(AutomationElement el)
        {
            try
            {
                ControlType t = el.Current.ControlType;
                if (t == null) return "";
                string p = t.ProgrammaticName;
                if (p == null) return "";
                if (p.StartsWith("ControlType.")) return p.Substring(12);
                return p;
            }
            catch { return ""; }
        }

        static string NameOf(AutomationElement el)
        {
            try { string n = el.Current.Name; return n == null ? "" : n; }
            catch { return ""; }
        }

        static string ReadValue(AutomationElement el)
        {
            object p = null;
            try
            {
                if (el.TryGetCurrentPattern(ValuePattern.Pattern, out p))
                    return Clip(((ValuePattern)p).Current.Value, 200);
            }
            catch { }
            p = null;
            try
            {
                if (el.TryGetCurrentPattern(TextPattern.Pattern, out p))
                    return Clip(((TextPattern)p).DocumentRange.GetText(200), 200);
            }
            catch { }
            return "";
        }

        static bool Actionable(AutomationElement el)
        {
            object p = null;
            try { if (el.TryGetCurrentPattern(InvokePattern.Pattern, out p)) return true; } catch { }
            p = null;
            try { if (el.TryGetCurrentPattern(TogglePattern.Pattern, out p)) return true; } catch { }
            p = null;
            try { if (el.TryGetCurrentPattern(SelectionItemPattern.Pattern, out p)) return true; } catch { }
            p = null;
            try { if (el.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out p)) return true; } catch { }
            p = null;
            try { if (el.TryGetCurrentPattern(ScrollItemPattern.Pattern, out p)) return true; } catch { }
            return false;
        }

        static UiNode Describe(AutomationElement el, int depth)
        {
            UiNode n = new UiNode();
            n.Depth = depth;
            n.Role = RoleOf(el);
            n.Name = NameOf(el);
            try { string a = el.Current.AutomationId; n.AutomationId = a == null ? "" : a; } catch { }
            try { n.Enabled = el.Current.IsEnabled; } catch { }
            try { n.Offscreen = el.Current.IsOffscreen; } catch { }
            try
            {
                Rect r = el.Current.BoundingRectangle;
                if (!r.IsEmpty)
                {
                    n.X = (int)Math.Round(r.X);
                    n.Y = (int)Math.Round(r.Y);
                    n.W = (int)Math.Round(r.Width);
                    n.H = (int)Math.Round(r.Height);
                    n.CenterX = n.X + n.W / 2;
                    n.CenterY = n.Y + n.H / 2;
                }
            }
            catch { }
            n.Value = ReadValue(el);
            n.Invokable = Actionable(el);
            return n;
        }

        static void Walk(TreeWalker w, AutomationElement parent, int parentDepth, int maxDepth,
                         int maxNodes, bool includeOffscreen, string roleFilter, List<UiNode> list)
        {
            if (parentDepth >= maxDepth || list.Count >= maxNodes) return;
            AutomationElement child = null;
            try { child = w.GetFirstChild(parent); } catch { return; }
            string rf = roleFilter == null ? "" : roleFilter.ToLowerInvariant();
            while (child != null && list.Count < maxNodes)
            {
                UiNode n = Describe(child, parentDepth + 1);
                bool keep = includeOffscreen || !n.Offscreen;
                if (keep && rf.Length > 0 && n.Role.ToLowerInvariant().IndexOf(rf) < 0) keep = false;
                if (keep) list.Add(n);
                if (parentDepth + 1 < maxDepth)
                    Walk(w, child, parentDepth + 1, maxDepth, maxNodes, includeOffscreen, roleFilter, list);
                AutomationElement next = null;
                try { next = w.GetNextSibling(child); } catch { break; }
                child = next;
            }
        }

        /// 把窗口读成 UIA 节点列表。用 ControlView 走查：跳过纯排版容器，留下可操作/可读的元素。
        /// 实测过的无效兜底（2026-10-22）：结果太薄时改走 RawViewWalker 并不会多出内容（设置仍 3 个
        /// 节点、计算器仍是 ControlView 那 17 个），说明薄不是"视图剪枝"，而是该应用没提供 UIA 内容树。
        public static List<UiNode> Dump(long hwnd, int maxDepth, int maxNodes, bool includeOffscreen, string roleFilter)
        {
            List<UiNode> list = new List<UiNode>();
            if (maxDepth < 1) maxDepth = 1;
            if (maxDepth > 32) maxDepth = 32;
            if (maxNodes < 1) maxNodes = 1;
            AutomationElement root = null;
            try { root = AutomationElement.FromHandle(new IntPtr(hwnd)); } catch { return list; }
            if (root == null) return list;
            TreeWalker w = TreeWalker.ControlViewWalker;
            Walk(w, root, 0, maxDepth, maxNodes, includeOffscreen, roleFilter, list);
            return list;
        }

        /// 按名称片段找控件。深度放宽（真实应用层级很深），用节点数上限控成本。
        public static List<UiNode> Find(long hwnd, string name, string roleFilter, int maxNodes)
        {
            List<UiNode> hit = new List<UiNode>();
            string needle = name == null ? "" : name.ToLowerInvariant().Trim();
            if (needle.Length == 0) return hit;
            List<UiNode> all = Dump(hwnd, 24, 3000, true, roleFilter);
            foreach (UiNode n in all)
            {
                if (n.Name.Length == 0) continue;
                if (n.Name.ToLowerInvariant().IndexOf(needle) < 0) continue;
                hit.Add(n);
                if (hit.Count >= maxNodes) break;
            }
            return hit;
        }
    }
}
'@ -ReferencedAssemblies $refs.ToArray()
        return $true
    } catch {
        $script:ExtrasError = $_.Exception.Message
        return $false
    }
}

# =====================================================================
#  目标窗口解析（v1.1 新增的四个动作共用）
# =====================================================================
# 为什么抽成函数：ui-tree / click(target) / scroll / wait 都要回答"目标是谁"，
# 而 -Window 模糊匹配到多个时必须报 AMBIGUOUS、不能擅自选第一个（实测过：
# 同一标题会有 ApplicationFrameWindow 壳 + 真实进程两个句柄，选错就抓空白）。
# 四份重复实现必然漂移成三份规矩，所以只留这一份。
function Resolve-Window([string]$Narrow, [Int64]$HandleArg, [bool]$AllowForeground) {
    if ($HandleArg -ne 0) {
        $w = [DSKHand.Api]::ByHandle($HandleArg)
        if ($null -eq $w) { Fail "窗口句柄 $HandleArg 无效或已关闭。" 'NO_SUCH_WINDOW' }
        return $w
    }
    if ($Narrow) {
        $hits = @([DSKHand.Api]::MatchWindows($Narrow))
        if ($hits.Count -eq 0) { Fail "没有标题包含'$Narrow'的可见窗口。用 list-windows 看当前有哪些窗口。" 'NO_MATCH' }
        if ($hits.Count -gt 1) {
            $cand = ($hits | ForEach-Object { "handle=$($_.Handle) title='$($_.Title)' process=$($_.Process)" }) -join ' | '
            Fail "标题'$Narrow'匹配到 $($hits.Count) 个窗口，请用 handle 精确指定：$cand" 'AMBIGUOUS'
        }
        return $hits[0]
    }
    if (-not $AllowForeground) { Fail '需要 -Window 或 -Handle 之一。' 'MISSING_TARGET' }
    $fg = [DSKHand.Api]::GetForegroundWindow()
    $w2 = [DSKHand.Api]::ByHandle([long]$fg)
    if ($null -eq $w2) { Fail '当前没有可用的前台窗口，请用 -Window 或 -Handle 指定。' 'MISSING_TARGET' }
    return $w2
}

# =====================================================================
#  输出助手：恒输出 JSON
# =====================================================================
function Emit($obj) {
    $json = $obj | ConvertTo-Json -Depth 6 -Compress
    [Console]::Out.Write($json)
}

function Fail([string]$msg, [string]$code = 'ERROR') {
    Emit @{ ok = $false; error = $msg; code = $code }
    exit 1
}

# =====================================================================
#  DPI 感知 —— 第一件事，任何窗口/DC 创建之前
# =====================================================================
$dpiMode = [DSKHand.Api]::Aware()
[DSKHand.Api]::RefreshScreen()
$physW = [DSKHand.Api]::ScreenW
$physH = [DSKHand.Api]::ScreenH

if ($Delay -gt 0) { Start-Sleep -Milliseconds $Delay }

# =====================================================================
#  动作分发
# =====================================================================
try {
    switch ($Action.ToLower()) {

        # ---------------------------------------------------------------
        'info' {
            $fg = [DSKHand.Api]::ForegroundTitle()
            $remote = @(Get-Process -ErrorAction SilentlyContinue |
                Where-Object { $_.ProcessName -match 'GameViewer|Sunlogin|ToDesk|AnyDesk|rustdesk|Parsec|TeamViewer|mstsc' } |
                Select-Object -ExpandProperty ProcessName -Unique)
            $displays = @()
            try {
                $displays = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
                    ForEach-Object { "$($_.Name) $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)" })
            } catch { }
            Emit @{
                ok = $true
                dpiMode = $dpiMode
                screenWidth = $physW
                screenHeight = $physH
                cursor = [DSKHand.Api]::Cur()
                foreground = $fg
                ime = [DSKHand.Api]::ImeState()
                remoteTools = $remote
                displays = $displays
                foregroundHandle = [long]([DSKHand.Api]::GetForegroundWindow())
                psVersion = $PSVersionTable.PSVersion.ToString()
            }
        }

        # ---------------------------------------------------------------
        'list-windows' {
            $all = [DSKHand.Api]::ListWindows()
            $items = @($all | Where-Object { $_.W -gt 0 -and $_.H -gt 0 } | Sort-Object -Property @{E={$_.Process}}, @{E={$_.Title}} |
                ForEach-Object {
                    @{
                        handle = $_.Handle; pid = $_.Pid
                        x = $_.X; y = $_.Y; width = $_.W; height = $_.H
                        title = $_.Title; class = $_.Class; process = $_.Process
                        uwp = $_.IsUwp; minimized = $_.Minimized
                        # 区分宿主壳：同一标题出现多个句柄时，该抓哪个靠这个字段判断
                        # （以前两个窗口都打 [UWP]，agent 只能盲选）。
                        frameHost = $_.IsFrameHost
                    }
                })
            $fgw = [DSKHand.Api]::GetForegroundWindow()
            Emit @{ ok = $true; count = $items.Count; foregroundHandle = [long]$fgw; windows = $items }
        }

        # ---------------------------------------------------------------
        'capture' {
            $bmp = $null
            $targetDesc = ''
            $targetClass = ''
            $isFrameHost = $false
            $uwpWarn = $false
            $minimized = $false
            $clipX = 0; $clipY = 0

            if ($Window -or $Handle -ne 0) {
                $w = $null
                if ($Handle -ne 0) {
                    $w = [DSKHand.Api]::ByHandle($Handle)
                    if ($null -eq $w) { Fail "窗口句柄 $Handle 无效或已关闭。" 'NO_SUCH_WINDOW' }
                } else {
                    $hits = @([DSKHand.Api]::MatchWindows($Window))
                    if ($hits.Count -eq 0) {
                        Fail "没有标题包含'$Window'的可见窗口。用 list-windows 看当前有哪些窗口。" 'NO_MATCH'
                    }
                    if ($hits.Count -gt 1) {
                        $cand = ($hits | ForEach-Object { "handle=$($_.Handle) title='$($_.Title)' process=$($_.Process)" }) -join ' | '
                        Fail "标题'$Window'匹配到 $($hits.Count) 个窗口，请用 handle 精确指定：$cand" 'AMBIGUOUS'
                    }
                    $w = $hits[0]
                }
                $targetDesc = $w.Title
                $targetClass = $w.Class
                $isFrameHost = $w.IsFrameHost
                $minimized = $w.Minimized
                # 窗口被抓时的原点（DWM 扩展边框）
                $rect = New-Object 'DSKHand.Api+RECT'
                $rc = [DSKHand.Api]::DwmGetWindowAttribute([IntPtr]$w.Handle, 9, [ref]$rect, 16)
                if ($rc -eq 0) { $clipX = $rect.L; $clipY = $rect.T } else { $clipX = $w.X; $clipY = $w.Y }
                $err = $null
                $bmp = [DSKHand.Api]::CaptureWindow([IntPtr]$w.Handle, [ref]$err)
                if ($null -eq $bmp) { Fail "抓取窗口失败：$err" 'CAPTURE_FAILED' }
            }
            else {
                $targetDesc = if ($ScreenIndex -ge 0) { "display[$ScreenIndex]" } else { 'virtual-screen' }
                $bmp = [DSKHand.Api]::CaptureScreen($ScreenIndex)
                if ($ScreenIndex -lt 0) { $clipX = 0; $clipY = 0 }
            }

            # 区域裁切（相对被抓对象）
            if ($Region) {
                $parts = $Region -split ','
                if ($parts.Count -ne 4) { Fail "Region 格式应为 `"x,y,w,h`"，收到：$Region" 'BAD_REGION' }
                $rx = [int]$parts[0]; $ry = [int]$parts[1]; $rw = [int]$parts[2]; $rh = [int]$parts[3]
                if ($rw -le 0 -or $rh -le 0) { Fail "Region 的宽高必须为正数：$Region" 'BAD_REGION' }
                if ($rx -lt 0 -or $ry -lt 0 -or ($rx + $rw) -gt $bmp.Width -or ($ry + $rh) -gt $bmp.Height) {
                    Fail "Region $Region 超出被抓对象范围 $($bmp.Width)x$($bmp.Height)。" 'REGION_OOB'
                }
                $crop = New-Object System.Drawing.Bitmap $rw, $rh
                $g = [System.Drawing.Graphics]::FromImage($crop)
                $g.DrawImage($bmp, (New-Object System.Drawing.Rectangle 0,0,$rw,$rh),
                             (New-Object System.Drawing.Rectangle $rx,$ry,$rw,$rh), [System.Drawing.GraphicsUnit]::Pixel)
                $g.Dispose()
                $bmp.Dispose()
                $bmp = $crop
                $clipX += $rx; $clipY += $ry
            }

            if (-not $OutPath) {
                $dir = Join-Path $env:TEMP 'dsh-desktop-hand'
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
                $OutPath = Join-Path $dir ("shot_{0:yyyyMMdd_HHmmss_fff}.png" -f (Get-Date))
            } else {
                $OutPath = [System.IO.Path]::GetFullPath($OutPath)
                $parent = Split-Path $OutPath -Parent
                if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            }

            $black = [DSKHand.Api]::BlackPermille($bmp)
            # 警告按**实测空白度**决定，不按"是不是 UWP"（2026-10-03 修正）。
            # 旧逻辑 $uwpWarn = $w.IsUwp 有两个问题：
            #   1. CoreWindow（能抓）也被判成需要警告，警告失去区分力；
            #   2. 真正该警告的是"抓出来是空白"，与窗口类别只是相关而非等同。
            $domPermille = 0; $distinct = 0
            $blank = [DSKHand.Api]::LooksBlank($bmp, [ref]$domPermille, [ref]$distinct)
            $uwpWarn = $blank
            $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
            $wi = $bmp.Width; $hi = $bmp.Height
            $bmp.Dispose()
            $bytes = (Get-Item $OutPath).Length

            Emit @{
                ok = $true
                path = $OutPath
                width = $wi
                height = $hi
                bytes = $bytes
                target = $targetDesc
                targetClass = $targetClass
                originX = $clipX
                originY = $clipY
                screenWidth = $physW
                screenHeight = $physH
                # 坐标换算提示：截图宽 != 物理屏宽时，点击坐标需乘这个系数。
                # ⚠️ 只在"整对象抓取"时有意义：区域裁切后的图宽是裁切宽，
                #    拿它算比例会得到荒谬的值（实测裁 600 宽得到 4.2667）。
                #    所以裁切时不报这个字段，改报 originX/originY 供换算。
                coordScale = $(if ($Region) { $null } else { [math]::Round([double]$physW / [double]$wi, 4) })
                blackPermille = $black
                uwpWarning = $uwpWarn
                # 判据透明化：让 agent 能自己复核"为什么说它空白/不空白"。
                dominantPermille = $domPermille
                distinctColors = $distinct
                isFrameHost = $isFrameHost
                minimized = $minimized
                note = '黑像素比例仅供参考，不是成功判据。空白判据见 dominantPermille/distinctColors。'
            }
        }

        # ---------------------------------------------------------------
        'click' {
            # ---- v1.1：按 UIA 控件名点击（不必先截图量坐标）----
            # 为什么这条很重要：ApplicationFrameWindow 宿主壳用 PrintWindow 抓出来是空白，
            # 但它的 UIA 树里有真实控件和边界矩形。所以"看不见"不等于"点不到"。
            if ($Target) {
                if (-not (Ensure-Extras)) {
                    Fail "UI Automation 扩展不可用（$($script:ExtrasError)）。改用坐标点击：先 desktop_capture 看图量坐标。" 'UIA_UNAVAILABLE'
                }
                $tw = Resolve-Window $Window $Handle $true
                $hits = @([DSKHand.Extra]::Find([long]$tw.Handle, $Target, $Role, 40))
                if ($hits.Count -eq 0) {
                    $sample = @([DSKHand.Extra]::Dump([long]$tw.Handle, 6, 400, $true, '') |
                        Where-Object { $_.Invokable -and $_.Name -ne '' } |
                        Select-Object -First 10 |
                        ForEach-Object { "$($_.Role) '$($_.Name)'" })
                    $tip = if ($sample.Count -gt 0) {
                        "该窗口可点的控件（前 10 个）：$($sample -join ' | ')"
                    } else {
                        '这个窗口的 UIA 树里没有可点控件，可能是自绘界面，只能用坐标点击。'
                    }
                    Fail "窗口'$($tw.Title)'里没有名称包含'$Target'的控件。$tip" 'NO_MATCH'
                }
                # 精确同名优先：'确定' 和 '确定并关闭' 都含搜索词时，别擅自点第一个长名字。
                $exact = @($hits | Where-Object { $_.Name -eq $Target })
                if ($exact.Count -ge 1) {
                    $pick = $exact[0]
                } elseif ($hits.Count -eq 1) {
                    $pick = $hits[0]
                } else {
                    $cand = ($hits | ForEach-Object { "$($_.Role) '$($_.Name)' @$($_.CenterX),$($_.CenterY)" }) -join ' | '
                    Fail "名称包含'$Target'的控件有 $($hits.Count) 个，请写更完整的名称或用 -Role 限定：$cand" 'AMBIGUOUS'
                }
                if ($pick.W -le 0 -or $pick.H -le 0) {
                    Fail "控件'$($pick.Name)'没有可见边界（offscreen 或还没渲染），改用坐标点击。" 'NO_HIT_RECT'
                }
                [DSKHand.Api]::Click($pick.CenterX, $pick.CenterY, [bool]$Right, [bool]$Double, $SettleMs)
                Emit @{ ok = $true; action = 'click-target'
                        targetName = $pick.Name; targetRole = $pick.Role
                        shot = "$($pick.CenterX),$($pick.CenterY)"
                        phys = "$($pick.CenterX),$($pick.CenterY)"; scale = 1
                        window = $tw.Title; cursor = [DSKHand.Api]::Cur() }
                break
            }
            $sw = if ($ShotWidth -le 0) { $physW } else { $ShotWidth }
            $scale = [double]$physW / [double]$sw
            $px = [int][math]::Round($X * $scale)
            $py = [int][math]::Round($Y * $scale)
            if ($ToX -ne [int]::MinValue -and $ToY -ne [int]::MinValue) {
                $tx = [int][math]::Round($ToX * $scale)
                $ty = [int][math]::Round($ToY * $scale)
                [DSKHand.Api]::Drag($px, $py, $tx, $ty)
                Emit @{ ok = $true; action = 'drag'; fromShot = "$X,$Y"; toShot = "$ToX,$ToY"
                       fromPhys = "$px,$py"; toPhys = "$tx,$ty"; scale = $scale
                       cursor = [DSKHand.Api]::Cur() }
            } else {
                [DSKHand.Api]::Click($px, $py, [bool]$Right, [bool]$Double, $SettleMs)
                Emit @{ ok = $true; action = $(if ($Right) { 'right-click' } elseif ($Double) { 'double-click' } else { 'click' })
                       shot = "$X,$Y"; phys = "$px,$py"; scale = $scale
                       cursor = [DSKHand.Api]::Cur() }
            }
        }

        # ---------------------------------------------------------------
        'move' {
            $sw = if ($ShotWidth -le 0) { $physW } else { $ShotWidth }
            $scale = [double]$physW / [double]$sw
            $px = [int][math]::Round($X * $scale)
            $py = [int][math]::Round($Y * $scale)
            [DSKHand.Api]::MoveTo($px, $py)
            Emit @{ ok = $true; action = 'move'; phys = "$px,$py"; cursor = [DSKHand.Api]::Cur() }
        }

        # ---------------------------------------------------------------
        'probe' {
            $a = [DSKHand.Api]::Probe($X, $Y)
            $b = [DSKHand.Api]::Probe($X, $Y)
            Emit @{ ok = $true; probeA = $a.Trim(); probeB = $b.Trim()
                   note = 'A/B 不同或设定值被推走 = 有别的输入源在覆盖（远程会话在动鼠标）。' }
        }

        # ---------------------------------------------------------------
        'type' {
            if (-not $Text) { Fail 'type 动作需要 -Text。' 'MISSING_TEXT' }
            $n = [DSKHand.Api]::TypeUnicode($Text)
            if ($Enter) { [DSKHand.Api]::KeyVk([DSKHand.Api]::VK_RETURN) }
            Emit @{ ok = $true; action = 'type'; chars = $n; enter = [bool]$Enter
                   mode = 'SendInput+KEYEVENTF_UNICODE (绕过输入法)'
                   foreground = [DSKHand.Api]::ForegroundTitle() }
        }

        # ---------------------------------------------------------------
        'key' {
            if (-not $Key) { Fail 'key 动作需要 -Key。' 'MISSING_KEY' }
            $k = $Key.ToLower().Trim()
            $A = [DSKHand.Api]
            switch -Regex ($k) {
                '^enter$'    { $A::KeyVk($A::VK_RETURN) }
                '^return$'   { $A::KeyVk($A::VK_RETURN) }
                '^esc(ape)?$'{ $A::KeyVk($A::VK_ESCAPE) }
                '^tab$'      { $A::KeyVk($A::VK_TAB) }
                '^space$'    { $A::KeyVk($A::VK_SPACE) }
                '^backspace$'{ $A::KeyVk($A::VK_BACK) }
                '^delete$'   { $A::KeyVk($A::VK_DELETE) }
                '^up$'       { $A::KeyVk($A::VK_UP) }
                '^down$'     { $A::KeyVk($A::VK_DOWN) }
                '^left$'     { $A::KeyVk($A::VK_LEFT) }
                '^right$'    { $A::KeyVk($A::VK_RIGHT) }
                '^home$'     { $A::KeyVk($A::VK_HOME) }
                '^end$'      { $A::KeyVk($A::VK_END) }
                '^pageup$'   { $A::KeyVk($A::VK_PRIOR) }
                '^pagedown$' { $A::KeyVk($A::VK_NEXT) }
                '^f1$'       { $A::KeyVk($A::VK_F1) }
                '^ctrl\+a$'  { $A::KeyCombo($A::VK_CONTROL, $A::VK_A) }
                '^ctrl\+c$'  { $A::KeyCombo($A::VK_CONTROL, $A::VK_C) }
                '^ctrl\+v$'  { $A::KeyCombo($A::VK_CONTROL, $A::VK_V) }
                '^ctrl\+s$'  { $A::KeyCombo($A::VK_CONTROL, $A::VK_S) }
                '^ctrl\+w$'  { $A::KeyCombo($A::VK_CONTROL, $A::VK_W) }
                '^ctrl\+x$'  { $A::KeyCombo($A::VK_CONTROL, $A::VK_X) }
                '^ctrl\+z$'  { $A::KeyCombo($A::VK_CONTROL, $A::VK_Z) }
                '^alt\+f4$'  { $A::KeyCombo($A::VK_MENU, 0x73) }   # VK_F4
                default {
                    if ($k -match '^f([1-9]|1[0-2])$') {
                        $A::KeyVk([byte]($A::VK_F1 + [int]$Matches[1] - 1))
                    } else {
                        Fail "不认识的按键 `"$Key`"。可用：enter esc tab space backspace delete up down left right home end pageup pagedown f1-f12 ctrl+a/c/v/s/w/x/z alt+f4" 'BAD_KEY'
                    }
                }
            }
            Emit @{ ok = $true; action = 'key'; key = $k; foreground = [DSKHand.Api]::ForegroundTitle() }
        }

        # ---------------------------------------------------------------
        'focus' {
            $w = $null
            if ($Handle -ne 0) {
                $w = [DSKHand.Api]::ByHandle($Handle)
                if ($null -eq $w) { Fail "窗口句柄 $Handle 无效。" 'NO_SUCH_WINDOW' }
            } else {
                if (-not $Window) { Fail 'focus 需要 -Window 或 -Handle。' 'MISSING_TARGET' }
                $hits = @([DSKHand.Api]::MatchWindows($Window))
                if ($hits.Count -eq 0) { Fail "没有标题包含'$Window'的可见窗口。" 'NO_MATCH' }
                if ($hits.Count -gt 1) {
                    $cand = ($hits | ForEach-Object { "handle=$($_.Handle) title='$($_.Title)'" }) -join ' | '
                    Fail "标题'$Window'匹配到 $($hits.Count) 个窗口，请用 handle 指定：$cand" 'AMBIGUOUS'
                }
                $w = $hits[0]
            }
            $res = [DSKHand.Api]::Focus([IntPtr]$w.Handle)
            Emit @{ ok = ($res -eq 'ok' -or $res -eq 'already-foreground'); action = 'focus'
                   result = $res; target = $w.Title; handle = $w.Handle
                   foreground = [DSKHand.Api]::ForegroundTitle()
                   note = $(if ($res -eq 'failed(foreground-lock)') {
                       '前台锁挡掉了 SetForegroundWindow。改用 click_shot 在目标窗口体上点一下（真实点击能拿到激活），再 type_text。'
                   } else { '' }) }
        }

        # ---------------------------------------------------------------
        #  v1.1：把窗口读成 UIA 语义树
        # ---------------------------------------------------------------
        # 这是 ApplicationFrameWindow 空白壳盲区的正解：那类窗口用 PrintWindow 只能
        # 抓到空壳，但 UIA 树里是真实的控件、名称、值和边界矩形。
        'ui-tree' {
            if (-not (Ensure-Extras)) {
                Fail "UI Automation 扩展不可用（$($script:ExtrasError)）。抓图与坐标点击仍然可用。" 'UIA_UNAVAILABLE'
            }
            $w = Resolve-Window $Window $Handle $true
            $nodes = @([DSKHand.Extra]::Dump([long]$w.Handle, $Depth, $MaxNodes, [bool]$AllNodes, $Role))
            $arr = @()
            foreach ($n in $nodes) {
                $arr += @{
                    depth = $n.Depth; role = $n.Role; name = $n.Name; automationId = $n.AutomationId
                    value = $n.Value
                    x = $n.X; y = $n.Y; width = $n.W; height = $n.H
                    centerX = $n.CenterX; centerY = $n.CenterY
                    enabled = $n.Enabled; offscreen = $n.Offscreen; invokable = $n.Invokable
                }
            }
            $out = @{
                ok = $true; target = $w.Title; targetClass = $w.Class
                count = $arr.Count; truncated = ($arr.Count -ge $MaxNodes); flat = [bool]$Flat
                isFrameHost = $w.IsFrameHost; minimized = $w.Minimized
                nodes = $arr
            }
            if ($Flat) {
                # 纯文本视图：给没有视觉能力的模型读界面内容，也方便人 grep。
                $sb = New-Object System.Text.StringBuilder
                foreach ($n in $nodes) {
                    if ($n.Name -eq '' -and $n.Value -eq '') { continue }
                    $line = ('  ' * $n.Depth) + $n.Role
                    if ($n.Name -ne '') { $line += ' "' + $n.Name + '"' }
                    if ($n.Value -ne '') { $line += ' = ' + $n.Value }
                    if ($n.Invokable) { $line += ' @' + $n.CenterX + ',' + $n.CenterY }
                    [void]$sb.AppendLine($line)
                }
                $flatText = $sb.ToString().TrimEnd()
                if ($flatText.Length -gt 8000) { $flatText = $flatText.Substring(0, 8000) + '...(已截断)' }
                $out.text = $flatText
            }
            Emit $out
        }

        # ---------------------------------------------------------------
        #  v1.1：滚轮
        # ---------------------------------------------------------------
        'scroll' {
            # 坐标口径与 click 一致：默认物理像素；给了 ShotWidth 就按截图宽度换算。
            $w = $null
            if ($Handle -ne 0 -or $Window) { $w = Resolve-Window $Window $Handle $false }
            $atX = $X; $atY = $Y
            if ($atX -eq 0 -and $atY -eq 0) {
                if ($null -ne $w) {
                    $atX = $w.X + [int]($w.W / 2); $atY = $w.Y + [int]($w.H / 2)
                } else {
                    # 没给点也没给窗口：就地滚（别把光标挪到 0,0 去）
                    $parts = ([DSKHand.Api]::Cur()) -split ','
                    if ($parts.Count -eq 2) { $atX = [int]$parts[0]; $atY = [int]$parts[1] }
                }
            }
            if ($ShotWidth -gt 0) {
                $scale2 = [double]$physW / [double]$ShotWidth
                $atX = [int][math]::Round($atX * $scale2)
                $atY = [int][math]::Round($atY * $scale2)
            }
            [DSKHand.Api]::ScrollWheel($atX, $atY, $Delta, [bool]$Horizontal)
            Emit @{ ok = $true; action = 'scroll'; atX = $atX; atY = $atY
                    delta = $Delta; horizontal = [bool]$Horizontal
                    cursor = [DSKHand.Api]::Cur(); foreground = [DSKHand.Api]::ForegroundTitle() }
        }

        # ---------------------------------------------------------------
        #  v1.1：剪贴板读写
        # ---------------------------------------------------------------
        'clipboard' {
            if (-not (Ensure-Extras)) {
                Fail "剪贴板扩展不可用（$($script:ExtrasError)）。" 'UIA_UNAVAILABLE'
            }
            $m = if ($Mode) { $Mode.ToLower().Trim() } else { 'get' }
            if ($m -eq 'get') {
                $t = [DSKHand.Extra]::ClipGet()
                if ($null -eq $t) { Fail '读剪贴板失败（可能被别的进程占用），稍后重试。' 'CLIPBOARD_FAILED' }
                Emit @{ ok = $true; mode = 'get'; text = $t; chars = $t.Length }
            } elseif ($m -eq 'set') {
                if (-not $PSBoundParameters.ContainsKey('Text')) { Fail 'clipboard set 需要 -Text。' 'MISSING_TEXT' }
                $old = $null
                if ($KeepPrevious) { $old = [DSKHand.Extra]::ClipGet() }
                $val = [string]$Text
                if (-not [DSKHand.Extra]::ClipSet($val)) {
                    Fail '写剪贴板失败（可能被别的进程占用），稍后重试。' 'CLIPBOARD_FAILED'
                }
                $o = @{ ok = $true; mode = 'set'; chars = $val.Length }
                # 只有显式要了才把原内容带回来，避免把用户剪贴板内容无谓地塞进上下文
                if ($KeepPrevious) { $o.previous = $(if ($null -eq $old) { '' } else { $old }) }
                Emit $o
            } else {
                Fail "未知 -Mode '$Mode'，可用 get 或 set。" 'BAD_MODE'
            }
        }

        # ---------------------------------------------------------------
        #  v1.1：等窗口 / 等控件（替代固定 Start-Sleep，消除竞态）
        # ---------------------------------------------------------------
        'wait' {
            $u = if ($Until) { $Until.ToLower().Trim() } else { 'window' }
            if ($u -ne 'window' -and $u -ne 'gone' -and $u -ne 'text') {
                Fail "未知的 -Until '$Until'，可用 window / gone / text。" 'BAD_UNTIL'
            }
            if (-not $Target) { Fail 'wait 需要 -Target（窗口标题片段；-Until text 时是控件名）。' 'MISSING_TARGET' }
            $poll = if ($PollMs -lt 50) { 50 } else { $PollMs }
            $limit = if ($WaitMs -lt 100) { 100 } else { $WaitMs }
            $t0 = Get-Date
            $waitHits = @()
            $detail = ''
            $satisfied = $false
            while (-not $satisfied) {
                $elapsed = [int]((Get-Date) - $t0).TotalMilliseconds
                if ($u -eq 'text') {
                    if (-not (Ensure-Extras)) {
                        Fail "UI Automation 扩展不可用（$($script:ExtrasError)）。" 'UIA_UNAVAILABLE'
                    }
                    $tw = Resolve-Window $Window $Handle $true
                    $found = @([DSKHand.Extra]::Find([long]$tw.Handle, $Target, $Role, 10))
                    if ($found.Count -gt 0) {
                        $satisfied = $true
                        $waitHits = @($found | ForEach-Object { $_.Name })
                        $detail = "窗口'$($tw.Title)'里出现了 $($found.Count) 个匹配控件"
                    }
                } else {
                    $hits = @([DSKHand.Api]::MatchWindows($Target))
                    if ($u -eq 'window' -and $hits.Count -gt 0) {
                        $satisfied = $true
                        $waitHits = @($hits | Select-Object -First 5 | ForEach-Object { $_.Title })
                        $detail = "出现 $($hits.Count) 个匹配窗口，首个 handle=$($hits[0].Handle)"
                    } elseif ($u -eq 'gone' -and $hits.Count -eq 0) {
                        $satisfied = $true
                        $detail = '目标窗口已消失'
                    }
                }
                if ($satisfied) { break }
                if ($elapsed -ge $limit) {
                    Fail "等待 $limit ms 后仍未满足 -Until $u -Target '$Target'。" 'TIMEOUT'
                }
                Start-Sleep -Milliseconds $poll
            }
            Emit @{ ok = $true; satisfied = $true; until = $u; target = $Target
                    elapsedMs = [int]((Get-Date) - $t0).TotalMilliseconds
                    detail = $detail; matches = $waitHits }
        }

        # ---------------------------------------------------------------
        #  v1.1：启动应用（搜开始菜单/桌面快捷方式，不碰焦点也不打字）
        # ---------------------------------------------------------------
        'open-app' {
            if (-not $Target) { Fail 'open-app 需要 -Target（应用名片段，如 "记事本" 或 "Notepad"）。' 'MISSING_TARGET' }
            $needle2 = $Target.ToLower()
            $roots = @()
            $roots += (Join-Path $env:APPDATA 'Microsoft/Windows/Start Menu/Programs')
            $roots += (Join-Path $env:ProgramData 'Microsoft/Windows/Start Menu/Programs')
            $roots += (Join-Path $env:USERPROFILE 'Desktop')
            try {
                $pub = [Environment]::GetFolderPath('CommonDesktopDirectory')
                if ($pub) { $roots += $pub }
            } catch { }
            $cands = @()
            foreach ($root in $roots) {
                if (-not (Test-Path -LiteralPath $root)) { continue }
                $links = @(Get-ChildItem -LiteralPath $root -Filter '*.lnk' -Recurse -File -ErrorAction SilentlyContinue)
                foreach ($l in $links) {
                    $base = [System.IO.Path]::GetFileNameWithoutExtension($l.Name)
                    if ($base.ToLower().Contains($needle2)) { $cands += $l.FullName }
                }
                if ($cands.Count -gt 0) { break }
            }
            if ($cands.Count -eq 0) {
                # 兜底：少数应用只放了 .exe 没有 .lnk（绿色版拷进开始菜单目录的）。
                foreach ($root in $roots) {
                    if (-not (Test-Path -LiteralPath $root)) { continue }
                    $exes = @(Get-ChildItem -LiteralPath $root -Filter '*.exe' -Recurse -File -ErrorAction SilentlyContinue)
                    foreach ($exeItem in $exes) {
                        # ⚠️ 循环变量别用单字母：$X/$Y/$Text/$Key/$Mode 等都是 param() 里
                        # 声明过的变量（变量名大小写不敏感），赋值会被参数类型检查拦下。
                        $base = [System.IO.Path]::GetFileNameWithoutExtension($exeItem.Name)
                        if ($base.ToLower().Contains($needle2)) { $cands += $exeItem.FullName }
                    }
                    if ($cands.Count -gt 0) { break }
                }
            }
            $appIdTarget = $null
            $appNameTarget = $null
            if ($cands.Count -eq 0) {
                # 兜底 2：UWP/MSIX 应用根本没有 .lnk（记事本、计算器、照片… 在 Win11 全是 MSIX），
                # 只能查 Get-StartApps 拿 AppID，再用 shell:AppsFolder 交给 shell 调起。
                try {
                    $appHits = @(Get-StartApps | Where-Object { $_.Name -and $_.Name.ToLower().Contains($needle2) })
                    if ($appHits.Count -gt 0) {
                        $best = @($appHits | Sort-Object -Property @{ Expression = { $_.Name.Length } })[0]
                        $appIdTarget = $best.AppID
                        $appNameTarget = $best.Name
                    }
                } catch { }
            }
            if ($cands.Count -eq 0 -and -not $appIdTarget) {
                Fail "开始菜单/桌面里找不到名称含'$Target'的快捷方式，Get-StartApps 里也没有同名应用。如果它已经在运行，直接用 list-windows 找窗口即可。" 'NOT_LAUNCHED'
            }
            $t0 = Get-Date
            $launchedPid = 0
            # 启动前的窗口句柄集合：MSIX 应用的窗口标题可能和 Target 完全对不上
            # （实测 Win11 记事本标题是 "无标题 - Notepad"，而 Target 是「记事本」），
            # 所以除了 pid/标题/进程名匹配，还得兜底「启动后冒出来的新窗口」。
            $beforeH = @([DSKHand.Api]::ListWindows() | ForEach-Object { $_.Handle })
            try {
                $launchPath = $null
                if ($appIdTarget) {
                    # MSIX 应用不能用 Start-Process 直接调（CreateProcess 不认 shell: 协议），
                    # 交给 explorer 解析，代价是拿不到 pid —— 后面按标题/进程名兜底找窗口。
                    # ⚠️ 必须用反斜杠：写成 shell:AppsFolder/xxx 时 explorer 会把参数当普通
                    # 路径，实测打开的是「文档」而不是应用（2026-10-22 自检踩到）。
                    $launchPath = 'shell:AppsFolder\' + $appIdTarget
                    $null = Start-Process -FilePath 'explorer.exe' -ArgumentList ('shell:AppsFolder\' + $appIdTarget) -ErrorAction Stop
                } else {
                    $launchPath = $cands[0]
                    $proc = Start-Process -FilePath $launchPath -PassThru -ErrorAction Stop
                    if ($null -ne $proc) { $launchedPid = $proc.Id }
                }
            } catch {
                Fail "启动'$launchPath'失败：$($_.Exception.Message)" 'NOT_LAUNCHED'
            }
            $titles = @()
            $matchedBy = ''
            if (-not $NoWait) {
                $limit2 = if ($WaitMs -lt 500) { 500 } else { $WaitMs }
                while (((Get-Date) - $t0).TotalMilliseconds -lt $limit2) {
                    # .lnk 常常先起一个转发进程，真正的窗口属于子进程 —— 所以 pid 之外
                    # 还要按标题/进程名兜底匹配，否则会误报"启动了但没窗口"。
                    $allW = @([DSKHand.Api]::ListWindows())
                    $mine = @($allW | Where-Object {
                        ($launchedPid -gt 0 -and $_.Pid -eq $launchedPid) -or
                        ($_.Title -and $_.Title.ToLower().Contains($needle2)) -or
                        ($_.Process -and $_.Process.ToLower().Contains($needle2)) -or
                        ($appNameTarget -and $_.Title -and $_.Title.ToLower().Contains($appNameTarget.ToLower())) })
                    if ($mine.Count -gt 0) {
                        $titles = @($mine | ForEach-Object { $_.Title })
                        $matchedBy = 'pattern'
                        break
                    }
                    # 兜底：启动后新冒出来的够大的窗口。先给 pattern 匹配 800ms 机会，别抢跑。
                    if (((Get-Date) - $t0).TotalMilliseconds -gt 800) {
                        $fresh = @($allW | Where-Object { $_.W -gt 60 -and $_.H -gt 60 -and ($beforeH -notcontains $_.Handle) })
                        if ($fresh.Count -gt 0) {
                            $titles = @($fresh | ForEach-Object { $_.Title })
                            $matchedBy = 'new-window'
                            break
                        }
                    }
                    Start-Sleep -Milliseconds 250
                }
            }
            Emit @{ ok = $true; launched = $true; path = $launchPath; appId = $appIdTarget
                    appName = $appNameTarget; pid = $launchedPid
                    titles = $titles; matchedBy = $matchedBy
                    waitedMs = [int]((Get-Date) - $t0).TotalMilliseconds
                    candidates = @($cands | Select-Object -First 10) }
        }

        default { Fail "未知动作 `"$Action`"。可用：info list-windows capture click move drag probe type key focus ui-tree scroll clipboard wait open-app" 'BAD_ACTION' }
    }
}
catch {
    Emit @{ ok = $false; error = $_.Exception.Message; code = 'EXCEPTION'; stack = $_.ScriptStackTrace }
    exit 1
}
