# dsh-desktop-hand

> **English readers:** this is the detailed engineering log kept in the language it
> was written in. It records every bug hit during development, the measurement that
> identified each root cause, and the reused recipe. The English
> [`README.md`](../README.md) summarises the same findings.
>
> The machine referenced as "本机" is the author's Windows box:
> 2560x1440 at 150% scaling, PowerShell 5.1, with a remote-control tool running.
> Numbers in this document are from that machine.

---

给 DSH agent 装上**操作 Windows 桌面的手和眼睛**：截屏（含抓被遮挡的窗口）、按坐标或控件名点击、
注入键盘输入、滚轮、剪贴板、等窗口/控件、启动应用、聚焦窗口。装一次，**所有工作区、所有会话**都能用。

- 编写日期：2026-09-27；兼容性修复：2026-09-28（v1.0.1，适配 DSH 0.1.7-rc.2）；
  v1.1.0：2026-10-22（UIA 语义层 + 滚动 + 剪贴板 + 等待 + 启动应用）
- 位置：本仓库根目录（原始位置是作者本机的 `DSH环境/dsh-desktop-hand/`）
- 自检：**v1.0.x 记录 136 项全过**（引擎 32 / 插件层 79 / seam 契约 18 / 遮挡抓取 7）；
  v1.1 的新用例跑过之后再更新项数，本文不预填没跑过的数字
- 当前适配：DSH 0.9.2（harness `0.1.7-rc.2`）

---

## 零、升级兼容性（必读）

### 0.1 DSH 升级会删掉本地插件，升级后要重装

DSH 从 `0.1.5-rc.2` 升到 `0.1.7-rc.2`（Desktop 0.9.2）时，
`profiles/web/package.json` 被**重写**：`dependencies` 和 `dsh.profile.bundles` 里
本插件的条目被删掉了，但 `pnpm.overrides` 里的 `link:` 行**留了下来**（残留不一致状态）。

原因见 0.2：v1.0.0 让 DSH **启动失败**，DSH 于是进了安全模式并清理了配置。

**升级 DSH 后请检查这三处是否齐全**，缺就按第二节补回去再 `pnpm install`：

| 位置 | 应有内容 |
| --- | --- |
| `dependencies` | `"dsh-desktop-hand": "link:D:/Record/AIdatabase/09-杂项/DSH环境/dsh-desktop-hand"` |
| `dsh.profile.bundles` | 数组里有 `"dsh-desktop-hand"` |
| `pnpm.overrides` | 同 dependencies 的 `link:` 行 |

> ⚠️ 只有 `overrides` 而没有 `dependencies`/`bundles` 是**无效状态**：不会被加载。

### 0.2 v1.0.0 → v1.0.1 修的是什么（真实事故）

**症状**：升级 DSH 后启动失败，报

```
dsh: startup failed: 1 required plugin did not activate
  desktop-hand (required)
    TypeError: prompt section "tool:desktop-hand" order must be a finite number
```

**根因**：`systemPrompt.section()` 的 `order` 从"可选"变成了"必填且必须是有限数字"。

```js
// @deepseek-ai/dsh-system-prompt/lib/index.js:241  （0.1.7-rc.2）
section(section) {
  if (!Number.isFinite(section.order)) throw new TypeError(`prompt section "${section.name}" order must be a finite number`);
```

v1.0.0 调用时**没给 `order`**（旧版本容忍），升级后直接抛错。
又因为本插件在 profile 里是 `required: true`，**抛错会拖垮整个 DSH 启动**，
而不是仅仅少一段提示词。

**修复**（两处，缺一不可）：

1. 补上 `order: 3001`。取值依据 DSH 内部 `SECTION_ORDERS`：
   工具说明段排在 1000–3000（…`TOOL_REPORT: 2900`, `TOOL_COMPUTER_USE: 3000`,
   `MCP_SERVERS: 3100`），桌面控制属于 computer-use 一类，所以紧跟官方
   `TOOL_COMPUTER_USE` 之后、`MCP_SERVERS` 之前。那些常量未导出，故写死字面量。
2. **把整段 prompt section 包进 try/catch，失败只 warning 不抛出**。
   系统提示是锦上添花，工具本身不依赖它——**绝不能让一段提示词把宿主带崩**。

**已加回归测试**（`selftest.mjs`，之后别删）：
断言 `order` 是有限数字、落在 3000–3100，并且**用一个必定抛错的假 `section()`
验证 `apply()` 仍然成功**。

**已用真实服务复现并验证**：拿 `dsh-system-prompt` 真实现跑一次，
不给 `order` 得到与启动日志**逐字相同**的错误；修好后 `Number.isFinite(3001)` 通过。

### 0.3 升级后如何快速自检

```powershell
$d = "<本仓库根目录>"
& "$d\lib\link-deps.ps1"          # 仅本地自检需要
& "$d\lib\selftest.ps1"           # 32 项
node "$d\lib\selftest.mjs"        # 79 项（含 order 回归）
node "$d\lib\selftest-harness.mjs"# 18 项（harness seam 契约）
& "$d\lib\occlusion-test.ps1"     # 7 项（需看图）
& "$d\lib\link-deps.ps1" -Clean
```

> 这四套都是**脱离 DSH** 跑的，所以升级后不用重启就能先确认插件本身没坏。
> 真正加载成功与否要看 DSH 能否正常启动（见 0.4）。

### 0.4 升级后确认"没把 DSH 带崩"

看启动日志（每次启动一个文件）：

```powershell
Get-ChildItem "$env:APPDATA\dsh-desktop\harness\logs\startup-*.log" |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content -TotalCount 40
```

**只要日志里没有 `startup failed` / `required plugin did not activate` 就是好的。**
插件加载失败**必然会**写这个日志并进安全模式，不会静默。

---

## 一、为什么自己写，而不是装市场插件

**调研了 8 个能碰桌面的 DSH 插件，没有一个同时具备下面四项 + 遮挡抓取。**

| 插件 | 按标题抓窗口 | 坐标点击 | 键盘注入 | 窗口聚焦 | **抓被遮挡的窗口** | 后端 |
| --- | :-: | :-: | :-: | :-: | :-: | --- |
| **dsh-desktop-hand（本项目）** | ✅ | ✅ | ✅ | ✅ | ✅ **PrintWindow** | PowerShell |
| Altairpaca/dsh-computer-use-windows | ✅ | ✅ | ✅ | ✅ | ❌ **CopyFromScreen 裁矩形** | PowerShell |
| cbg33695/dsh-screen-reader | ✅ | ❌ | ❌ | ❌ | ✅ | PowerShell |
| @paicat1/dsh-screenshot | 仅悬停吸附 | ❌ | ❌ | ❌ | ✅ | PowerShell |
| 988hj7tczd-oss/dsh-computer-use | ✅ | ✅ | ✅ | ✅ | ⚠️ 未验证 | 外部二进制 |
| ysr666/dsh-vision-router | ❌ 仅虚拟屏 | ❌ | ❌ | ❌ | ❌ | PowerShell |
| ankye/dsh-client-vision | ✅ 按 id | ❌ | ❌ | ❌ | ❌ | PowerShell |
| FuqiangCraft/dsh-desktop | ❌ 仅主屏 | ❌ | ❌ | ❌ | ❌ | Rust/Tauri |

市场清晰地分成两半：

- **用了 PrintWindow（能抓遮挡）的，完全不碰输入**（screen-reader、dsh-screenshot）；
- **能注入输入的，抓窗口用的是 `CopyFromScreen` 裁窗口矩形**
  —— 窗口被盖住时抓到的是**遮挡者**的画面。

唯一"四项俱全"的 Altairpaca 插件，其 `helper/cu.ps1` 里是
`$g.CopyFromScreen($win.left, $win.top, 0, 0, $bmp.Size)`，整个文件**没有 PrintWindow**。
而 `988hj7tczd-oss/dsh-computer-use`（36★，架构最正规）的 README 明写
Windows **⛔ BLOCKED「当前无 Windows 10/11 真机；真实 GUI 未验收」**。

另外两个减分项：

- Altairpaca 插件的 `computer_keyboard type` 对非 ASCII **走剪贴板**——
  正是本机 AGENTS.md 记录的输入法风险点；本插件用 `SendInput + KEYEVENTF_UNICODE`，
  在这一点上严格更好。
- 现有本地脚本（`capture.ps1` / `mouse.ps1` / `type.ps1`）四项能力都覆盖且已实测，
  **但没有一个是插件**，所以别的会话/工作区用不到——这正是要补的缺口。

> **调研的置信度**：本次检索期间 `web_search`/SearXNG 不可用，本机 PowerShell 直连
> GitHub 也 TLS 失败，只能靠 `web_fetch` 走 DSH 通道。因此**不是**穷举注册表扫描，
> 可能仍有遗漏；但上表每一格结论都有 README 或源码原文支撑，未核实的一律标了 ⚠️。

**结论：自己写。** 不是重复造轮子，而是补上"能遮挡抓取"与"能注入输入"之间那个空缺的组合。

---

## 二、安装

插件已装进 `web` profile，**DSH 重启后生效**（bundle 列表在启动时读取）。
> ⚠️ **DSH 升级会清掉这三处配置**——升级后请按第零节检查并重装。

改动的三个地方（profile 目录即 `%APPDATA%\dsh-desktop\harness\profiles\web\`）：

| 文件 | 改动 |
| --- | --- |
| `package.json` → `dependencies` | `"dsh-desktop-hand": "link:D:/Record/AIdatabase/09-杂项/DSH环境/dsh-desktop-hand"` |
| `package.json` → `dsh.profile.bundles` | 追加 `"dsh-desktop-hand"` |
| `package.json` → `pnpm.overrides` | `"dsh-desktop-hand": "link:D:/Record/.../dsh-desktop-hand"` |

然后 `pnpm install --dir <profile>`（已执行）。用 `link:` 而不是拷贝，
**改插件源码后重启即生效，不用重装**。

### 手工安装（换机器时）

```powershell
# 1) 复制插件目录到新机器（路径随意，建议跟本机同构）
# 2) 在 profile 目录里加三处配置（见上表），再：
& "$env:APPDATA\dsh-desktop\harness\.desktop-bin\pnpm.cmd" install --dir "$env:APPDATA\dsh-desktop\harness\profiles\web"
# 3) 重启 DSH
```

> ⚠️ **不要同时用 bundle 通道和 profile 的 `cordis.patch.yml` 手工挂载行**——
> 两者都写会**双重挂载**，工具注册两次会报 "already registered" 而让整个 DSH 起不来。
> 本插件只用 bundle 通道，profile 的 `cordis.patch.yml` **不需要**动。

### 卸载

删掉上表三处配置 → `pnpm install` → 重启。备份在同目录 `package.json.bak-desktop-hand-*`。

---

## 三、工具

装好后 agent 会多出 11 个工具（v1.1.0 新增 5 个，并把 `desktop_click` 扩展为可按控件名点）：

| 工具 | 说明 |
| --- | --- |
| `desktop_diagnose` | 体检：合成输入此刻可不可信（DPI / 屏幕 / 前台 / 输入法 / 远程软件 / 光标落点稳定性） |
| `desktop_list_windows` | 列可见窗口：handle、PID、进程、标题、位置尺寸、是否 UWP、是否最小化 |
| `desktop_capture` | 截屏：全屏 / 指定窗口（标题或 handle）/ 区域裁切。**图片直接返回给模型** |
| `desktop_focus` | 聚焦窗口（`SetForegroundWindow` + `AttachThreadInput` 兜底，并**报告是否真的成功**） |
| `desktop_click` | 点击 / 双击 / 右键 / 拖动，并**校验光标最终落点** |
| `desktop_type` | 输入文本（Unicode 直投）或发按键（白名单） |
| `desktop_ui_tree` | 读窗口的 UI Automation 树：逐个控件的 role / name / automationId / value / 屏幕边界；`flat` 输出纯文本，`all` 含 offscreen 节点。**穿透 AFH 空白壳** |
| `desktop_scroll` | 滚轮：`delta`（默认 3，正=下/右），`horizontal` 横向；坐标语义同 `click` |
| `desktop_clipboard` | 剪贴板 `get` / `set`；`keepPrevious` 时 set 结果带原内容 `previous` |
| `desktop_wait` | 等窗口出现/消失（`until=window/gone`）或等 UIA 控件出现（`until=text`），替代固定 sleep |
| `desktop_open_app` | 递归搜开始菜单与桌面 `*.lnk` 启动应用；返回 pid 与窗口标题，超时报 `NOT_LAUNCHED` |

典型流程：

**A. 有画面：看图量坐标。**

```
desktop_list_windows            → 找到目标，拿 handle
desktop_capture(handle=...)     → 看图，量坐标
desktop_focus(handle=...)       → 或 desktop_click 点窗口体拿焦点
desktop_type(text="...")        → 输入
desktop_capture(handle=...)     → 再看图确认
```

**B. 空白壳 / 不想量坐标：读 UIA 树，按控件名点。**

```
desktop_list_windows                    → 找到目标，拿 handle
desktop_capture(handle=...)             → 空白壳？不要据此判断界面状态
desktop_ui_tree(handle=..., flat=true)  → 读控件树；要结构/边界用 nodes[]
desktop_click(handle=..., target="保存") → 按控件名点，可加 role="button"
desktop_wait(until="text", target="已保存", handle=...)  → 等结果，别 sleep
desktop_capture(handle=...)             → 只有需要视觉确认时才再抓图
```

**C. 长文本 / 路径：走剪贴板。**

```
desktop_clipboard(mode="set", text="C:\path\file.txt", keepPrevious=true)
desktop_type(key="ctrl+v")              → 目标窗口必须在前台
desktop_clipboard(mode="set", text="<previous>")  → 需要还原就写回
```

---

## 四、四个关键设计（改动前必读）

### 1. 抓窗口用 `PrintWindow + PW_RENDERFULLCONTENT(2)`

这是本插件存在的理由。**只有它能抓到被遮挡窗口自己的内容**；全屏 `CopyFromScreen`
抓到的永远是遮挡者。`flag` 必须是 **2**：`flag=0` 对 UWP 是 100% 黑，`flag=2` 降到 71.7%。

实测对比见第六节第四项——同一时刻，全屏图只有遮挡者，窗口图是目标自己。

### 2. 键盘输入用 `SendInput + KEYEVENTF_UNICODE`

**不能用 `VkKeyScan` + `keybd_event`**：那走的是键盘布局/输入法通路，中文输入法会在中间
转换。实测想输入 `third batch`，目标程序收到的是「第三批」。
Unicode 直投绕过输入法，中文和 `%.15f` 都能原样送达。

### 3. 坐标一律物理像素，每层都声明 DPI 感知

本机 2560x1440 + 150% 缩放。不声明 DPI 感知时 `SetCursorPos(42,1046)` 会被系统乘 1.333
落到物理 (56,1395)，而 `GetCursorPos` 又除回去报 (1280,720)——表现是"点的位置和说的不一样"。
声明后 1:1 直达。截图结果里会给出 `coordScale`，不等于 1 时提示调用方换算。

### 4. 输出必须显式设成 UTF-8

PowerShell 5.1 在 stdout 被重定向时按**控制台 ANSI 代码页**（本机 GBK/936）编码输出。
Node 按 UTF-8 解码 → 中文错误信息全变乱码（实测踩到）。
所以引擎第一件事就是 `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`。
**这行删掉不会报错，只会让所有中文提示变乱码，很难查。**

### 4b. `.ps1` 源文件必须带 UTF-8 BOM（**踩过一次，整份引擎解析失败**）

PowerShell 5.1 读取**没有 BOM** 的脚本时按 ANSI(GBK) 解码，于是源码里的中文注释/字符串
被拆成一堆乱码字节，其中某些组合会顶掉引号 → 解析器报 `字符串缺少终止符` /
`只能将表达式作为管道的第一个元素`，**整份脚本连 switch 都进不去**，所有动作全挂。

实测（2026-10-22）：`lib/desktop-hand.ps1` 编辑后丢了 BOM，`desktop_diagnose` 直接
`exit=1` 并吐出一串 `ParserError`（报错行号还会漂到 C# here-string 里，看着像 C# 语法错，
其实是编码问题）。补回 BOM（`EF BB BF`）后立刻恢复，`info/probe` 正常。

**规矩：改完这个文件先看前三字节是不是 `EF BB BF`。** 编辑器/脚本化替换很容易丢掉它；
本包内 `lib/selftest.ps1`、`lib/selftest-v11.ps1` 都带 BOM，拿它们当模板。
`lib/index.js` 是 ESM，**不要**加 BOM（Node 能读但没必要，且会让 diff 噪音变大）。

### 4c. 参数名会和脚本里的局部变量撞名（**大小写不敏感**，2026-10-22 踩过）

v1.1 给 `param()` 加了 `[switch]$All`（ui-tree 含 offscreen 节点），而 `list-windows` 分支
第一行是 `$all = [DSKHand.Api]::ListWindows()`。PowerShell **变量名大小写不敏感**，`$all` 就是
那个 `[switch]` 参数本身 → 赋值时会去做参数类型转换，抛出：

```
ArgumentTransformationMetadataException: 无法将值“System.Collections.Generic.List`1[DSKHand.WinInfo]”
转换为类型“System.Management.Automation.SwitchParameter”。布尔参数仅接受布尔值和数字。
```

于是整份引擎 `exit=1`、`desktop_list_windows` 全挂，但同一份脚本的 `info/probe`（diagnose）完全正常，
报错里还完全不提参数名，极具误导性。修法：参数改名 `-AllNodes`，`lib/index.js` 同步 `params.AllNodes`。

同类坑（v1.1 一并修掉）：

- `$matches` 是 PowerShell **自动变量**（`-match` 的捕获结果）；`wait` 分支曾用它当普通数组，已改名 `$waitHits`。
- 新动作漏声明 `[string]$Until`，于是 `-Until text` 会直接「找不到参数」；`$PSBoundParameters.ContainsKey('Text')`
  这类判断也只对**已声明**的参数有效（splat 传入才算）。
- **单字母循环变量也一样会撞**：`$x`/`$y` 就是 `[int]$X`/`[int]$Y`。`open-app` 的
  `foreach ($x in $exes)` 把 `System.IO.FileInfo` 赋给 `[int]$X`，报
  `Cannot convert the "Panel v1.4.0.exe" value of type "System.IO.FileInfo" to type "System.Int32"`
  （2026-10-22 自检抓到，且只有走到该兜底分支才炸）。现在用 `$exeItem` 这类多字母名字。
- **同类型的静默覆盖更阴**：ui-tree 的 `$text = $sb.ToString()` 撞 `[string]$Text`，不报错、
  只是悄悄改掉入参；已改名 `$flatText`。**改新动作时不要复用任何 param 名的局部变量。**
- 新增参数后一定要跑一遍「index.js 用到的 `params.X` ⊆ ps1 声明的参数」的交叉核对（本文档第十节旁边有清单）。
  反向也要核：**参数名集合 ⊆ 局部变量禁用集合** —— `param()` 里每个名字都不该在函数体/switch 里被赋值。

**诊断手法**：这类错误的 `$_.ScriptStackTrace` 会精确指到 `... 中: 第 NNN 行`，而且只有走到该分支才炸。
把可疑调用包进 `try/catch`，用 `Emit @{ ... ; note = $_.Exception.GetType().Name + ' :: ' + $_.Exception.Message }`
把异常带出来（JS 只透传它认识的字段时，可塞进 `windows[0].title` 之类必传字段），比反复删代码二分快得多。

### 4d. 启动 MSIX/UWP 应用：两个实测坑（2026-10-22）

Win11 的记事本、计算器、照片全是 **MSIX** 应用：开始菜单/桌面里**没有 `.lnk`**，只有
AppID（`Get-StartApps` 能查到，形如 `Microsoft.WindowsNotepad_8wekyb3d8bbwe!App`）。
`open-app` 因此分三级兜底：`.lnk` → 同名 `.exe` → `Get-StartApps` 的 AppID。

1. **`shell:AppsFolder` 后面必须是反斜杠。** 写成 `shell:AppsFolder/Microsoft...` 交给
   `explorer.exe` 时，实测弹出来的是「文档」资源管理器窗口 —— 参数被当成普通路径了。
   正确形式：`Start-Process explorer.exe -ArgumentList 'shell:AppsFolder\<AppID>'`。
   MSIX 也不能用 `Start-Process -FilePath 'shell:...'` 直接调（CreateProcess 不认协议，
   报「系统找不到指定的文件」）。
2. **启动后的窗口标题和 `-Target` 对不上。** 中文系统里记事本的窗口标题是
   `无标题 - Notepad`，进程名 `Notepad`，而 `-Target` 是「记事本」；pid 又恒为 0（MSIX 拿不到）。
   任何"按名字认领窗口"的做法都会误报「启动了但没窗口」。现在的做法：启动前先快照
   `ListWindows()` 的句柄集合；轮询时优先按 pid/标题/进程名匹配，等 800ms 还匹配不到，
   就用**句柄差集**认领"启动后新出现且宽高 > 60 的窗口"，返回 `matchedBy: "new-window"`。
   这条兜底只在 open-app 里用（别给 wait 加，那里"任意新窗口"是错语义）。

### 4e. UWP 能不能抓、能不能读：2026-10-22 实测矩阵

旧说法是"UWP 抓不到，改用 ui_tree"。实测下来两句都不对：抓不抓得到看**句柄**，读不读得到看**应用有没有
暴露 UIA 内容树**。同一台机器、同一版引擎，两个样本给出相反结果：

| 窗口 | 抓 `ApplicationFrameWindow` 句柄 | 抓 `Windows.UI.Core.CoreWindow` 句柄 | `ui_tree` |
| --- | --- | --- | --- |
| 计算器 655438 | **完整内容**（963‰ / 9 色，`uwpWarning` 误报） | 未另开句柄 | 17 节点，`role=button` 时 34 个（含「九」「等于」），`click(target="关闭 计算器")` 成功 |
| 设置 196926 / 131990 | 纯背景（986‰ / 18 色） | **完整内容**（121 色） | **两个句柄都读不到**：frame 3 节点（标题栏）、CoreWindow 0 节点 |
| DeepSeek（Electron）460344 | — | — | 1 个 `Pane`（Chromium 未开无障碍） |

结论与做法：
1. **抓图**：先抓；图里没内容就换同标题的另一个句柄（「设置」靠这步救回）。`uwpWarning` 只是
   "底色占比高"的启发式，计算器 963‰ 反而内容是完整的 —— **不许拿它当判据**，是看图。
2. **读界面**：`ui_tree` 只在应用实现了 UIA 时有效。系统设置这类应用对整个 UIA 隐身，
   只能按坐标点；Electron/Chromium 需要启动参数 `--force-renderer-accessibility`。
3. **别再加"再兜底一次视图"的代码**：试过在 `Dump` 里用 `RawViewWalker` 重走一遍（当
   ControlView 结果 <=4 个节点时），**两个样本的节点数一个都没变**（设置 3 → 3，计算器 17 → 17）。
   说明"薄"不是视图剪枝，而是根本没有内容树可剪，代码已回滚。省下这段复杂度。
### 附：走 harness 的 `ctx.subprocess` 而不是裸 `spawn`

官方插件都用 `ctx.subprocess.spawn`。这不只是风格：**DSH 沙箱会拒绝 node 以管道 stdio
起子进程**（实测裸 `spawn` 直接 `EPERM`，换 `stdio:'inherit'` 就能跑）。
本插件正式路径走 `ctx.subprocess`，裸 `spawn` 只作脱离 DSH 时的退路。

三个**读源码才定下来、否则会静默出错**的契约（已在 `lib/selftest-harness.mjs` 里断言）：

| 契约 | 踩坑后果 |
| --- | --- |
| `graceMs` 必填（`validateSubprocessSpec` 拒绝缺失） | 每次调用都抛错 |
| `handle.collected.stdout` 是**收集器对象**，要调 `finalize()` 才拿到 `{text}` | 直接读 `.text` 得到 `undefined`，所有工具都报"引擎无输出" |
| spec **没有** `timeoutMs` 字段，超时要自己用 `AbortController` | 超时机制失效 |

---

## 五、已知边界（不是 bug）

- **`ApplicationFrameWindow` 宿主壳抓图是空白，但界面不是读不到**（v1.1 修正）。
  `PrintWindow` 拷的是窗口自己的像素表面，而 AFH 宿主壳（设置、计算器、
  Realtek Audio Console 等的框架窗口）没有内容层，所以抓出来只有边框、必须
  返回 `uwpWarning`：此时**不要根据该图判断界面状态**。
  正确的下一步不是放弃：先 `desktop_ui_tree` 读 UIA 树（内容进程的 provider
  仍然可用），再 `desktop_click(target="控件名")` 操作，等待用
  `desktop_wait(until="text")`。同标题常有两个句柄，也可以先试
  `frameHost=false` 的那个（`Windows.UI.Core.CoreWindow`，真内容可抓）。
  详见 `skills/desktop-hand/SKILL.md` 硬规则 3 与本文第十节第 1 条。
- **窗口最小化时**尺寸退化，抓到的内容无意义（返回 `minimized: true`）。
- **活跃的远程会话会让鼠标点击不可靠**。本机装了 GameViewer，远端一动鼠标，
  合成坐标就被实时覆盖。这是环境问题，改代码/调坐标都没用——用 `desktop_diagnose`
  确认，等远端空闲即可。**不要杀 GameViewer 进程**，那会断掉远程回连通道。
- **只支持 Windows**（依赖 `user32`/`gdi32`/`shcore`）。

---

## 六、实测记录（2026-09-27 初测；2026-09-28 升级后复测）

### 1. 引擎自检 `lib/selftest.ps1` —— **32 项全过**

```
info（DPI=shcore:2, 2560x1440）、list-windows、全屏抓取、区域裁切、
越界/格式错误拒绝、窗口不存在拒绝、move、probe 落点稳定、
focus + type 闭环（标题真的变了）、输入可重复、中文直投、按键白名单、未知键/未知动作拒绝
```

其中 **focus → type → 读回窗口标题** 那一项是闭环验证：输入内容会改变目标窗口的标题，
所以"输入是否送达"有**客观判据**，不靠猜。

**中文那一项是升级后新加的**：往目标窗口标题里打 `中文测试ABC`，
再断言标题里真的出现「中文测试」。这直接验证了"Unicode 直投绕过输入法"这个设计——
如果退回到 `VkKeyScan`，标题里出现的会是别的东西（实测过 `third batch` → 「第三批」）。

### 2. 插件层自检 `lib/selftest.mjs` —— **79 项全过**

假 `ctx` + 真引擎：**v1.0 的 6 个工具**全部注册、schema 合法（含"每个参数都有 description"）、
每个工具的主路径实跑成功、返回值经 `output.schema` 校验无多余键、
6 条错误路径全部正确抛错。（v1.1 的 11 个工具注册用例跑过之后再更新本节。）

### 3. 插件 × harness `ctx.subprocess` 契约自检 `lib/selftest-harness.mjs` —— **18 项全过**

用忠实模拟 seam（会像真实现一样**拒绝缺失 `graceMs`**、且 `collected.stdout`
**只提供 `finalize()`**）跑通全部工具，把第四节附表中那三个静默出错的契约钉死。

### 4. 遮挡抓取验证 `lib/occlusion-test.ps1` —— **7 项全过 + 看图确认**

造场景：目标 cmd 窗口（标题 `OCCL_38271`，内容 `OCCL_38271 CONTENT LINE`）
被另一个最大化的 cmd 窗口（`BLOCKER_47478`）**完全盖住**，同一时刻两种抓法对比：

| 抓法 | 结果 |
| --- | --- |
| 全屏 `CopyFromScreen` | 2560x1440，**只有 `BLOCKER_47478`**，目标完全不可见 |
| 指定窗口 `PrintWindow` | 1115x628，**`OCCL_38271` 的标题栏与 `CONTENT LINE` 清晰可见** |

**这是本插件相对市场插件的核心差异，已用图像证据确认。**

### 5. 开发期真实踩到并修掉的 bug

| 现象 | 根因 | 修法 |
| --- | --- | --- |
| PS 语法错误 `Unexpected token '$('` | 双引号字符串里的中文全角引号 `“ ”` 被 PS 当字符串定界符 | 换直引号 |
| `无效的表达式项"uint"` | PS 5.1 的 CodeDom 编译器不支持 C# 7 的 `out uint _` | 提前声明变量 |
| `不安全代码只会在使用 /unsafe` | `Add-Type` 在 PS 5.1 下无法传 `/unsafe` | 改用 `GetPixel` 粗采样 |
| `找不到入口点 ReleaseDC2` | DllImport 名写错（应为 `ReleaseDC`） | 修正 |
| `Cannot find type [DSKHand.RECT]` | 嵌套类型引用写法错（应为 `DSKHand.Api+RECT`） | 修正 |
| 中文错误信息全是乱码 | PS 5.1 重定向 stdout 用 GBK 编码 | 显式设 `OutputEncoding=UTF8` |
| `spawn EPERM` | DSH 沙箱禁止 node 管道 stdio 起子进程 | 走 `ctx.subprocess` seam |
| `graceMs` 缺失抛错 | 读源码发现它是必填 | 补上 |
| 引擎输出读不到 | `collected.stdout` 是收集器，要 `finalize()` | 修正 |
| 分三次调用测不出键盘闭环 | 两次 pwsh 调用之间焦点被收回、目标窗口被关 | 改成单进程内一次做完 |
| **升级后 DSH 起不来** | `section()` 的 `order` 由可选变必填（0.1.7-rc.2），插件没传 | 补 `order: 3001` + 整段 try/catch（见第零节） |
| 自检偶发"输入未送达" | 两次引擎调用之间焦点被抢（远程会话），测试没重新聚焦 | 每次 type 前重新 focus；顺带补了真正的中文输入测试 |

> 方法论沿用 AGENTS.md：**因果推断必须实测验证**。
> 上面每一条都是先有实测现象、再定位根因，没有一条是靠"读代码觉得应该没问题"下结论的。
>
> 最后一条尤其说明问题：**"偶发失败"要先怀疑测试本身，再怀疑被测代码。**
> 当时同时改了测试（每次重新聚焦）和自检项（补真正的中文断言），跑两轮确认稳定。

---

## 七、文件

```
dsh-desktop-hand/
├── package.json              插件清单（dsh.bundle.patch 是加载的关键字段）
├── cordis.patch.yml          bundle 挂载声明
├── README.md                 本文档
├── skills/desktop-hand/
│   └── SKILL.md              给 agent 的用法 skill（已装到 ~/.dsh/skills/）
└── lib/
    ├── index.js              Node 工具层：11 个 defineTool + 附件图片返回
    ├── desktop-hand.ps1      PowerShell 引擎：窗口枚举/抓取/鼠标/键盘
    ├── selftest.ps1          引擎自检（32 项）
    ├── selftest.mjs          插件层自检，假 ctx + 真引擎（79 项，含 order 回归）
    ├── selftest-harness.mjs  × harness subprocess seam 契约自检（18 项）
    ├── occlusion-test.ps1    遮挡抓取专项验证（7 项 + 看图）
    └── link-deps.ps1         为本地自检建/清 peer 依赖 junction
```

跑自检（`selftest.mjs` / `selftest-harness.mjs` 需要先建依赖链接）：

```powershell
$d = "<本仓库根目录>"
& "$d\lib\link-deps.ps1"                                  # 仅本地自检需要
& "$d\lib\selftest.ps1"                                   # 30 项
node "$d\lib\selftest.mjs"                                # 72 项
node "$d\lib\selftest-harness.mjs"                        # 18 项
& "$d\lib\occlusion-test.ps1"                             # 7 项（需肉眼看图确认）
& "$d\lib\link-deps.ps1" -Clean                           # 跑完清理
```

> 遮挡验证脚本会在屏幕上短暂开两个 cmd 窗口并最大化其中一个，跑完自动关闭。

---

## 八、配置项

在 profile 里给 `desktop-hand` 传 config（一般不用改）：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `enginePath` | 包内 `lib/desktop-hand.ps1` | 引擎脚本路径 |
| `timeoutMs` | `60000` | 单次调用超时（冷启动要编译 Add-Type，首次约 1.2s） |
| `outputDir` | 系统临时目录 | 截图默认落盘目录 |

---

## 九、与 `DSH环境/脚本/` 下旧脚本的关系

旧的 `capture.ps1` / `mouse.ps1` / `type.ps1` **仍然可用**，本插件是它们的插件化封装：

- 逻辑与实测结论**一致**（PrintWindow / Unicode 直投 / DPI 感知 / 黑像素不可作判据）；
- 本插件额外做了：坐标落点校验、错误码与可操作提示、图片直接返回模型、
  全局可用、参数错误提前拒绝。

**新任务优先用 `desktop_*` 工具**；旧脚本保留作为不依赖 DSH 时的命令行工具。

---

## 十、v1.1 设计取舍（2026-10-22）

接口已冻结在 `DESIGN-v1.1-ui-layer.zh-CN.md`（同目录）；本节只记"为什么"，参数与返回字段以规格为准。
v1.1 新增 5 个工具（`desktop_ui_tree` / `desktop_scroll` / `desktop_clipboard` /
`desktop_wait` / `desktop_open_app`），并把 `desktop_click` 扩展为可按控件名点。

### 1. UIA 为什么能穿透 AFH 宿主壳

- `PrintWindow` 拷的是**窗口的像素表面**。`ApplicationFrameWindow` 是
  ApplicationFrameHost.exe 持有的宿主壳，XAML 内容由内容进程渲染并合成到另一层；
  宿主窗口自己那层没有可拷贝的像素，所以抓出来只有边框。这不是 flag 没选对——
  `PW_RENDERFULLCONTENT(2)` 也救不了（第四节第 1 条）。
- UI Automation 不走像素：控件树由内容进程注册的 UIA provider 提供，经
  UIAutomationCore 跨进程桥接读出，节点带 `ControlType / Name / AutomationId / Value /
  BoundingRectangle / IsOffscreen / IsEnabled`。所以"画面抓不到"不等于"界面读不到"，
  这是两条独立的读取路径。
- **边界**：UIA 是逻辑结构，不是视觉。自绘控件（Canvas / 游戏 / 部分 Electron）可能
  没有 provider 或 Name 为空；颜色、图表、渲染是否错乱，仍然只能靠 `desktop_capture`。
  所以 ui_tree 是补的一条腿，不是抓图的替代品。
- 空白壳的实拍对照在 `evidence/uwp-ApplicationFrameWindow-空白壳.png` 与
  `evidence/uwp-CoreWindow-完整内容.png`（v1.0 时期证据）。空白壳
  `distinctColors=17`、真内容 `173`，这是 `uwpWarning` 判据的来源——
  `lib/desktop-hand.ps1` 的 `LooksBlank`：`dominantPermille >= 900 &&
  distinctColors <= 48 && dominantIsDark`（阈值两侧都留了余量）。

### 2. 为什么惰性编译 UIA 扩展（不让基础动作变慢）

- UIA 是 COM（UIAutomationCore / CUIAutomation）。PS 5.1 下要先 `Add-Type` 引
  `UIAutomationClient` / `UIAutomationTypes`，这段加载发生在本就紧张的引擎冷启动里
  （现有冷启动约 1.2s，是 `Add-Type` 编译 P/Invoke 的代价）。日常绝大多数调用是
  capture / click / type / focus，不该为用不到的能力付这份时间。UIA 那段加载
  未单独计时，但方向明确：能不加就不加。
- 做法：只在三个分支惰性加载——`ui-tree`、`click` 带 `-Target`、`wait -Until text`。
  加载失败统一 `Fail UIA_UNAVAILABLE`，并把**真实异常消息**放进 error。必须让模型
  区分"UIA 起不来"和"这个窗口没有控件"，否则它会误判界面为空而放弃。
- 为什么放 PowerShell 引擎而不是 Node 工具层：窗口句柄解析、DPI 感知、点击落点校验
  都在引擎里；UIA 的 `BoundingRectangle` 拿到就是屏幕物理坐标，按控件名点击可以直接
  复用 `[DSKHand.Extra]::ClickAt`，不必在工具层再实现一套坐标换算与校验。

### 3. 为什么不做"动作后自动回图"

- **token 成本**：图是 PNG，一张就是个不小的附件（实测一张窗口图 418,069 字节）。
  全屏 2560×1440 只会更大。
  每次 click / scroll / type 都回一张，长会话很快被图挤爆。本插件取向是"要图才要图"：
  agent 明确调 `desktop_capture` 才知道自己为什么付这张图的成本，也能决定抓哪个窗口、
  要不要裁切。
- **契约成本**：`desktop_capture` 是唯一走 `finalizeContent` 同步钩子把 PNG 交给附件
  服务的工具。把这条链复制到每个动作上，等于把图片序列化与超时风险扩散到全部工具。
  v1.1 只在 `info` 增补 `foregroundHandle`（给确需句柄的场景），不动 capture 的同步契约。
- 结论：自动回图是产品取向差异，不是能力缺口；真需要时 agent 多调一次
  `desktop_capture` 即可，还能顺便确认"这张图是不是我要的那张"。

### 4. 为什么不做全屏橙色光晕 / 迷你进度卡 / 接管状态机

- 那是"接管整台电脑"的产品形态（`@copylee/dsh-computer-use` v0.8.0 的取向）。
  本插件定位是**低干扰原语层**：不改变用户桌面观感、不抢焦点、不维护"会话租约"。
- 桌面是用户和 agent **共用**的。全屏光晕/进度卡会盖住用户正在看的东西；
  "接管状态机"则把权限与生命周期问题引进来，收益远小于复杂度。
- 同样的目的用无侵入方式达成：`desktop_wait` 替代 sleep、`desktop_ui_tree` 让模型
  读到结构、`desktop_diagnose` 报告环境是否可信。

### 5. 为什么不做应用级授权 UI（request_access）

- DSH 自己已有审批层（工具调用审批 / 沙箱）。插件再实现一套应用级授权会**双重确认、
  口径不一**，还会把"授权"这个词的语义搞乱。
- 插件该做的是把失败说清楚：错误码 + 可操作提示（`NO_MATCH` 列出前 10 个可点控件名、
  `AMBIGUOUS` 列候选、`TIMEOUT` 带已等待毫秒与最后状态）。决定权留给宿主。

### 6. 为什么不内置视觉模型兜底

- 截图已经**直接返回给当前模型**（多模态）。再内置一个视觉模型，等于把同一张图先转述
  成文本再给模型：多一次调用、多一次信息损失，模型看到的不是原始像素。
- "视觉不可用"的正确兜底是 UIA 树（结构化文本），不是第二个模型；两者解决的是不同问题。

### 7. 新工具各自的取舍

- **`desktop_wait` 用轮询，不用固定 sleep**：固定 sleep 要么慢、要么仍然竞态；超时返回
  `TIMEOUT` 并附"已等待毫秒 + 最后一次观察到的状态"，模型据此判断是还没出来，
  还是窗口名/控件名写错。
- **`desktop_scroll` 用 `mouse_event`**（`MOUSEEVENTF_WHEEL=0x0800` /
  `HWHEEL=0x01000`，`dwData=delta*120`）：沿用既有合成输入通路，落点仍可校验，
  不引入第二套输入机制。
  ⚠️ **垂直方向要取反**：`WM_MOUSEWHEEL` 的正值是"向前滚"（内容上移），而本插件对外
  的 `delta` 语义是"正 = 向下"（与 README/规格一致），所以实际发的是 `-delta*120`；
  水平 `HWHEEL` 正值本来就是"向右"，不取反。这是唯一一处"两套约定"的地方，改前先读注释。
- **`desktop_clipboard` 的 `keepPrevious`**：剪贴板是全局共享状态，插件不能悄悄覆盖
  用户的剪贴板；set 时把原内容一并返回，搬运完由调用方决定是否写回。失败统一
  `CLIPBOARD_FAILED`，不静默。
- **`desktop_open_app` 搜快捷方式而不是开始菜单搜索框**：递归搜用户/公共开始菜单与
  桌面 `*.lnk`（再兜底 `*.exe`），走 `Start-Process`（ShellExecute），不经过输入法与
  焦点——比"打开开始菜单搜索框打字"稳。启动后按新 pid 轮询窗口，超时 `NOT_LAUNCHED`。

### 8. 与 `@copylee/dsh-computer-use` v0.8.0 的取舍一览

| 它的能力 | 取舍 | 理由 |
| --- | --- | --- |
| UIA 语义树 / 按控件名点击 | **要** | 唯一能穿透 AFH 空白壳盲区的办法；也让纯文本模型能读界面 |
| 滚动滚轮 | **要** | 现版本完全缺失，长列表无法操作 |
| 剪贴板读写 | **要** | 长文本/路径搬运的刚需，避免逐字符注入 |
| 等窗口/等控件 | **要** | 替代固定 sleep，直接消除竞态 |
| 启动应用 | **要** | 比开始菜单搜索框打字稳，不受输入法/焦点影响 |
| 动作后自动回图 | **不要** | 每次点击都产图，token 成本高；本插件取向是"要图才要图" |
| 全屏光晕 / 进度卡 / 接管状态机 | **不要** | 那是"接管整台电脑"的产品形态；本插件是低干扰原语层 |
| 应用级授权 UI | **不要** | DSH 已有审批层，插件不重复造 |
| 内置视觉模型兜底 | **不要** | 截图直接交给当前模型，不需要再内置一个视觉模型 |

### 9. 文档与自检的口径

- `README.md` 与本文的自检项数**不预填**：v1.1 新增用例（ui-tree / scroll / clipboard /
  wait / open-app / click-target）跑过之后再更新。本文开头 136 项是 v1.0.x 的记录。
- `desktop_capture` 的空白壳提示仍保留"换另一个 handle 重抓"（AFH 应用常同时暴露宿主壳
  与内容窗口）；v1.1 要求补上第二条出路："或改用 `desktop_ui_tree` + `desktop_click target=`"。
- 接口变更先改 `DESIGN-v1.1-ui-layer.zh-CN.md`（同目录），再改代码与文档——规格是唯一可信来源。
