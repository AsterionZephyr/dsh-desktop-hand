# v1.1 设计：吸收 @copylee/dsh-computer-use 的优点（UI 语义层 + 滚动 + 剪贴板 + 等待 + 启动应用）

状态：**接口已冻结（2026-10-22）**，代码按本文实现。改接口先改本文。

## 背景与取舍

对 `@copylee/dsh-computer-use` v0.8.0 做过源码级比对（结论见 2026-10-22 会话）：

| 它的能力 | 本插件要不要 | 理由 |
| --- | --- | --- |
| UIA 语义树 / 按控件名点击 | **要**（v1.1） | 唯一能穿透 `ApplicationFrameWindow` 空白壳盲区的办法；也让纯文本模型能读界面 |
| 滚动滚轮 | **要** | 现版本完全缺失，长列表无法操作 |
| 剪贴板读写 | **要** | 长文本/路径搬运的刚需，且能避免逐字符注入 |
| 等窗口/等控件出现 | **要** | 替代固定 Start-Sleep，直接消除竞态 |
| 启动应用（搜开始菜单快捷方式） | **要** | 比"开始菜单搜索框打名字"稳，不受输入法/焦点影响 |
| 动作后自动回图 | **不要** | 每次点击都产一张图，token 成本高；本插件的取向是"要图才要图"，agent 明确调 `desktop_capture` 更可控 |
| 全屏橙色光晕 / 迷你进度卡 / 接管状态机 | **不要** | 那是"接管整台电脑"的产品形态；本插件是低干扰原语层 |
| 应用级授权 UI（request_access） | **不要** | DSH 自己已有审批层，插件不重复造 |
| 视觉模型兜底 | **不要** | 截图直接交给当前模型，不需要再内置一个视觉模型 |

## 引擎（lib/desktop-hand.ps1）

新增参数（全部可选，追加在 `[switch]$Json` 之前）：

```powershell
[string]$Target,          # click: UIA 名称；wait: 标题/文本；open-app: 应用名
[string]$Role,            # UIA 角色过滤（button/edit/text/...，子串匹配）
[int]$Depth = 3,          # ui-tree 深度
[int]$MaxNodes = 200,     # ui-tree 最多节点
[switch]$Flat,            # ui-tree 输出纯文本而非结构化节点
[switch]$All,             # ui-tree 包含 offscreen 节点
[int]$Delta = 3,          # scroll 滚轮格数，正=下/右
[switch]$Horizontal,      # scroll 横向
[string]$Mode,            # clipboard: get|set
[switch]$KeepPrevious,    # clipboard set: 返回原内容
[int]$WaitMs = 10000,     # wait 超时
[int]$PollMs = 250,       # wait 轮询间隔
[switch]$NoWait           # open-app: 不等窗口
```

新增动作（`switch ($Action.ToLower())` 新增分支，全部**惰性加载** UIA 扩展）：

### ui-tree
读某窗口的 UI Automation 树。**这是 ApplicationFrameWindow 空白壳盲区的解**：宿主壳
用 PrintWindow 抓出来是空的，但 UIA 树里有真实控件（name/role/value/bounds）。

- 入参：Window / Handle（二选一；都不给则用前台窗口），Depth, MaxNodes, Flat, All, Role
- 出参：`ok, target, targetClass, count, truncated, flat, uiaMode, nodes[], text?`
- nodes 元素：`depth, role, name, automationId, value, x, y, width, height, centerX, centerY, enabled, offscreen, invokable`
- Flat 模式额外给 `text`（整窗文本，供纯文本模型直接读；上限 8000 字符）
- 找不到窗口：沿用 NO_MATCH / AMBIGUOUS / NO_SUCH_WINDOW
- UIA 编译/加载失败：Fail `UIA_UNAVAILABLE`，error 里带真实异常消息

### click（扩展：按控件名点）
- 新增入参：Target（UIA 名称，子串匹配，优先精确匹配）, Role, Window, Handle
- 给了 Target 时 X/Y 不必填：把命中的控件 BoundingRectangle 中心当点击点
- 0 个命中 → Fail `NO_MATCH`（消息里列出该窗口前 10 个可点控件名，帮模型改词）
- 多个命中 → Fail `AMBIGUOUS`（列出候选：role/name/bounds，最多 10 个）
- 出参在原有基础上加：`action='click-target', targetName, targetRole, matched`
- 仍走 `[DSKHand.Extra]::ClickAt`→ 复用既有 Click 语义（SetCursorPos+SendInput），保留落点校验

### scroll
- 入参：X/Y（可选，缺省用窗口中心或当前光标），ShotWidth（坐标换算，同 click），Delta, Horizontal, Window/Handle
- 实现：mouse_event(MOUSEEVENTF_WHEEL=0x0800 / HWHEEL=0x01000, dwData=Delta*120)
- 出参：`ok, action='scroll', atX, atY, delta, horizontal, cursor, foreground`

### clipboard
- 入参：Mode=get|set，Text（set 必填），KeepPrevious
- get → `ok, mode='get', text, chars`；set → `ok, mode='set', chars, previous?(KeepPrevious 时), restored`
- 失败 → Fail `CLIPBOARD_FAILED`

### wait
- 入参：Until=window|text|gone，Target，Window/Handle，Role，WaitMs，PollMs
- window：等到有窗口标题含 Target；gone：等到没有；text：等到该窗口 UIA 树里出现名称含 Target 的控件
- 超时 → Fail `TIMEOUT`（error 里带上已等待毫秒与最后一次观察到的状态）
- 成功 → `ok, satisfied=true, until, elapsedMs, detail, matches[]`

### open-app
- 入参：Target（应用名，子串匹配），NoWait，WaitMs
- 搜索顺序：`%APPDATA%\Microsoft\Windows\Start Menu\Programs` → `%ProgramData%\...\Start Menu\Programs` → 用户桌面 → 公共桌面，递归 `*.lnk`；再兜底开始菜单里的 `*.exe`
- 启动：`Start-Process`（走 ShellExecute，.lnk 正常解析）
- 找窗口：按新进程 pid 轮询（最多 WaitMs），出参 `ok, launched, path, pid, titles[], waitedMs`
- 找不到应用 → Fail `NOT_LAUNCHED`

### info 增补
`foregroundHandle`（长整型），供 JS 侧"动作后回图"之类需要句柄的场景用。

## 工具面（lib/index.js）

新增 5 个工具 + 扩展 `desktop_click`：

| 工具 | 关键参数 | 用途 |
| --- | --- | --- |
| `desktop_ui_tree` | window, handle, depth, maxNodes, flat, all, role | 把窗口读成结构化树/纯文本；穿透 AFH 空白壳 |
| `desktop_click`（扩展） | target, window, handle, role + 原有 x/y/double/right/toX/toY | 按控件名点，不必先量坐标 |
| `desktop_scroll` | x, y, shotWidth, delta, horizontal, window, handle | 滚轮 |
| `desktop_clipboard` | mode, text, keepPrevious | 剪贴板读写 |
| `desktop_wait` | until, target, window, handle, role, timeoutMs | 等窗口/等控件 |
| `desktop_open_app` | name, wait, timeoutMs | 启动应用 |

约定（沿用现有代码，不得违反）：
- 每个工具 `output.schema` 必须 `additionalProperties: false` 且列出全部字段；返回值里**不允许有值为 undefined 的属性**（可选字段用 `...(x ? {k} : {})`）。
- `render` 返回内容块数组；`finalizeContent` 只有 `desktop_capture` 需要（保持同步）。
- 新增注册全部包 `try { ctx.tools.register(...) } catch (e) { ctx.logger?.warn?.() }`：插件在 profile 里是 `required: true`，单个工具注册失败**不能**拖垮 DSH 启动。
- 新错误码补进 `EngineError` 的 hints：`UIA_UNAVAILABLE / TIMEOUT / BAD_MODE / CLIPBOARD_FAILED / NOT_LAUNCHED`。

## 系统提示与 skill 的必改点

旧文案说"ApplicationFrameWindow 是唯一抓不到的"——现在它能用 `desktop_ui_tree` 读。
新文案必须写成：**抓图失败（空白壳）→ 先 `desktop_ui_tree` 看 UIA 树 → 再用 `desktop_click target=` 按控件名操作**。
另外补一句：`desktop_wait` 替代固定等待；长文本用 `desktop_clipboard` 粘贴。

## 版本

`package.json` → 1.1.0。README 能力表加 5 个工具；ENGINEERING-NOTES 记录"为什么不做全屏接管/自动回图"。
## 实施偏差（2026-10-22 落地时记录，以此为准）

规格写完之后实现时有四处调整，**文档与代码都按下面这份执行**：

1. **`scroll` 的垂直方向取反。** 规格写 `dwData = delta*120` 且"正=下"，但
   `WM_MOUSEWHEEL` 的正值实际是"向前滚"（内容上移）。为了让对外的 `delta` 语义
   真是"正=向下"，垂直实际发 `-delta*120`；水平 `HWHEEL` 正值本来就是"向右"，不取反。
2. **工具参数名以 `lib/index.js` 为准**：`desktop_open_app` 用 `app`/`waitMs`/`noWait`
   （规格表里写的 `name`/`wait`/`timeoutMs` 作废）；`desktop_ui_tree` 用
   `window/handle/depth/maxNodes/role/all/flat`（`all` = 含 offscreen 节点，对应引擎 `-AllNodes`）。
3. **`ui_tree` 的节点字段暴露 `automationId` 与 `offscreen`**，与规格第 49 行一致；
   规格里的 `uiaMode` 没实现（无消费方），`clipboard` 的 `restored` 也没实现
   （`keepPrevious` 满足同一需求）。
4. **`open-app` 增加了 `*.exe` 兜底**：开始菜单/桌面里没有匹配的 `.lnk` 时，
   再在同样的目录树里找同名 `.exe`（极少数绿色版只放 exe）。
5. **`open-app` 还要能启 MSIX/Store 应用**（2026-10-22 自检暴露：记事本在 Win11 没有 `.lnk`）。
   加第三级兜底 `Get-StartApps` 查 AppID → `explorer.exe shell:AppsFolder\<AppID>`；返回多出
   `appId`/`appName`/`matchedBy`，`pid` 为 0，窗口靠"启动前后句柄差集"认领。细节见 ENGINEERING-NOTES 4d。
