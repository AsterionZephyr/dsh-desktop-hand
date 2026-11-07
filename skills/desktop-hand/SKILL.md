---
name: desktop-hand
description: 操作 Windows 桌面：截屏（含抓被遮挡窗口）、读 UIA 控件树、按控件名或坐标点击、滚轮、剪贴板、输入、聚焦、等窗口/控件、启动应用。当任务需要看屏幕、点界面、往别的程序里打字、或说"帮我操作那个软件/窗口"时使用。触发词：截屏、截图、看屏幕、点一下、鼠标、键盘输入、操作窗口、后台抓窗口、UI 树、控件名、滚动、剪贴板、等窗口、启动应用、desktop。
---

# 操作 Windows 桌面（dsh-desktop-hand）

用 `desktop_*` 工具，**不要现写 PowerShell 截屏/点击**（坑都填好了）。
找不到这些工具＝插件没加载：DSH 升级会清掉 profile 里的本地插件，见 `docs/COMPATIBILITY.md`。

## 工具

| 工具 | 关键参数 / 用途 |
| --- | --- |
| `desktop_diagnose` | 无。点不准、输入丢失先跑它 |
| `desktop_list_windows` | 无。handle / 进程 / 标题 / 尺寸 / 是否宿主壳 / 是否最小化 |
| `desktop_capture` | `window` 或 `handle`、`region`。图直接返回，不用再 read_image |
| `desktop_ui_tree` | `handle`、`depth`、`maxNodes`、`flat`、`role`、`all` |
| `desktop_click` | `target`(+`role`) 或 `x/y`(+`shotWidth`)；`double`/`right`/`toX,toY` |
| `desktop_scroll` | `x/y` 或 `window`；`delta`（正=下/右）、`horizontal` |
| `desktop_type` | `text`(+`enter`) 或 `key`（白名单，含 `ctrl+v`） |
| `desktop_clipboard` | `mode=get/set`、`text`、`keepPrevious` |
| `desktop_wait` | `until=window/gone/text`、`target`、`window/handle`、`waitMs` |
| `desktop_open_app` | `app`、`waitMs`、`noWait` |
| `desktop_focus` | `window` 或 `handle` |

## 流程

**A 有画面（多数情况）**：`list_windows` 拿 handle → `capture` 看图量坐标 → `focus`（或 click 点窗口体）→
`type`/`click` → **再 `capture` 确认**，别凭"返回 ok"断定成功。

**B 抓图空白**：`uwpWarning` 或图里只有边框 → 换同标题 `frameHost=false` 的另一个句柄重抓 →
仍空白就 `ui_tree(flat=true)` 找控件名 → `click(target=...)` / `wait(until="text")`。

**C 长文本 / 路径 / 多行**：`clipboard(mode="set", keepPrevious=true)` → `type(key="ctrl+v")`（窗口须在前台）
→ 用完把返回的 `previous` 写回。逐字符注入又慢又容易被输入逻辑打断。

## 硬规则

1. **抓窗口别抓全屏**：`PrintWindow` 连被完全遮挡的窗口也能抓到它自己的内容；抓全屏只能看到遮挡者。
2. **看图和点图用同一张图**：截图 `width` ≠ 物理屏宽时，把该 width 传给 `shotWidth`。
3. **有控件名就 `target=`，别混两套坐标**：`ui_tree` 的 `centerX/centerY` 是物理屏幕像素，
   `click` 的 `x/y` 是截图像素（跨屏宽要 `shotWidth`）。混用必点偏。
4. **判据永远是看图**：黑像素比例与空白是反的（空白壳 16‰、真内容 617‰）；`uwpWarning` 只是"底色占比高"，
   计算器 963‰ 而内容完整。轻信这两个信号会把自己带偏。
5. **点不准/输入丢失先 `diagnose`**：GameViewer 远端动鼠标时坐标被实时覆盖，等远端空闲，别改代码、别杀进程。

## 提示

- `ui_tree` 只在应用暴露 UIA 时有效：Electron/Chromium 要 `--force-renderer-accessibility`；Win11「设置」
  两个句柄都读不到（3 / 0 节点）→ **退回坐标点**。读到 1~3 个节点是应用没暴露 UIA，不是参数错。
- 树里没有画面：颜色、图表、花屏只能 `capture`。`offscreen=true` 的点不到（先滚动）；
  `truncated=true` 就调大 depth/maxNodes 或加 `role` 过滤。
- `click(target=)` 是**子串**匹配：0 命中会列出该窗口前 10 个可点控件名；多命中并列候选（加 `role` 或写全名）。
  命中后仍走坐标点击并校验落点（`action="click-target"`、`targetName`）。
- `wait` 一律替代固定 sleep。`until=text` 依赖 UIA，自绘/游戏应用改用 `until=window` 或看图；
  超时报 `TIMEOUT` 并带已等毫秒与最后状态，据此判断是"还没出来"还是"名字搞错了"。
- **输入前目标窗口必须在前台**：`focus` 被前台锁挡掉时，改用 `click` 点一下窗口体（真实点击能拿到激活）。
  `type` 会回报实际送达时的前台窗口——不是预期目标就说明焦点错了。
- **窗口标题会变**（终端会改标题）：优先 `handle`，用完即弃、需要时重新 list。标题多命中会报错并列候选。
- `open_app`：三级兜底 .lnk → 同名 .exe → `Get-StartApps` 的 AppID。MSIX 应用（记事本、计算器）
  `pid` 恒为 0、标题可能跟 `app` 毫无交集，靠 `matchedBy="new-window"` 认领；`titles` 空不代表失败。
- 剪贴板是**全局共享**的，搬完写回 `previous`，别悄悄改掉用户的剪贴板。
- Win11 任务栏图标居中，开始按钮不在左下角——别猜，裁出来量。

## 与浏览器分工

网页内的操作用 `pilot_*`（走 CDP，不碰光标和焦点，不受远程串流影响），优先。
`desktop_*` 留给非浏览器程序，或需要看整个屏幕 / 浏览器窗口之外的东西。
