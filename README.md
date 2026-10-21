# dsh-desktop-hand

[![tests](https://github.com/AsterionZephyr/dsh-desktop-hand/actions/workflows/tests.yml/badge.svg)](https://github.com/AsterionZephyr/dsh-desktop-hand/actions/workflows/tests.yml)

Windows desktop control for a DSH agent, as six agent-callable tools.

> A plugin for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness).
> **Windows only.**

---

## 特性

**抓被遮挡的窗口。** 这是本插件最重要的一条。`desktop_capture` 指定窗口时走
`PrintWindow`，抓到的是**窗口自己的内容**——即使它被别的窗口完全盖住。
抓全屏走 `CopyFromScreen`，只能抓到遮挡者。

同一时刻、同一个目标窗口，被一个最大化窗口完全盖住，两种抓法对比
（`lib/occlusion-test.ps1` 自动构造这个场景并给出客观判据）：

| 抓法 | 结果 |
| --- | --- |
| 全屏 | **屏幕上实际可见的整屏**，即只有遮挡者，目标窗口完全不可见 |
| 指定窗口 | **目标窗口自己的尺寸与内容**，标题栏和正文清晰可见，与遮挡前的抓取一致 |

关键判据不是尺寸大小（窗口本来就可以比屏幕大），而是：
**指定窗口抓到的图既等于目标窗口自身的 rect，又不等于全屏图**——这正是
`PrintWindow` 与 `CopyFromScreen` 的分水岭。

**截图直接返回给模型。** `desktop_capture` 的结果里带图片本体，
不需要再调一次 `read_image`。

**输入绕过输入法。** `desktop_type` 走 `SendInput + KEYEVENTF_UNICODE` 直投字符。
中文、`%.15f` 这类格式符都能原样送达——用 `VkKeyScan` 走的键盘布局通路会被中文
输入法改写。

**坐标是物理像素。** 引擎每层都声明 DPI 感知，截图里的像素坐标可直接用于点击。
若截图宽与物理屏宽不一致，结果里会给出 `coordScale` 供换算。

**点击会回报落点。** `desktop_click` 校验光标最终位置并与目标比对，
落点不对会明确告诉你，而不是静默失败。

**六个工具：**

| 工具 | 用途 |
| --- | --- |
| `desktop_diagnose` | 体检：此刻合成输入可不可信（DPI / 屏幕 / 前台窗口 / 输入法 / 远程软件 / 光标落点稳定性） |
| `desktop_list_windows` | 列窗口：句柄、PID、进程、标题、位置尺寸、是否 UWP、是否最小化 |
| `desktop_capture` | 截屏：全屏 / 指定窗口（标题或句柄）/ 区域裁切，**图片直接返回** |
| `desktop_focus` | 把窗口拉到前台，并**报告是否真的成功** |
| `desktop_click` | 点击 / 双击 / 右键 / 拖动，带落点校验 |
| `desktop_type` | 输入文本（Unicode 直投）或发送白名单按键 |

**已知边界（不是 bug）：**

- **UWP 应用抓不到内容**（设置、计算器等）。`PrintWindow` 对走 DirectComposition
  渲染的 UWP 是硬盲区，PowerShell 侧无法绕过。工具会返回 `uwpWarning`——
  此时**不要根据那张图判断界面状态**。
- **最小化的窗口**尺寸退化，抓到的内容无意义（返回 `minimized: true`）。
- **远程会话正在操作鼠标时，合成点击不可靠**：坐标会被实时覆盖，调参无用。
  用 `desktop_diagnose` 确认，等远端空闲即可。**不要杀远程控制进程**，那会断连。
- 黑像素比例仅供参考，**不是成功判据**（实测 UWP 宿主黑像素仅 2.9%，图像却是空白框架）。

---

## 安装

```bash
dsh plugin --profile web add github:AsterionZephyr/dsh-desktop-hand
```

或手工安装——把仓库 clone 到任意位置，然后在 profile 的 `package.json`
（`%APPDATA%\dsh-desktop\harness\profiles\web\package.json`）里加上**三处**：

```jsonc
{
  "dependencies": {
    "dsh-desktop-hand": "link:/absolute/path/to/dsh-desktop-hand"
  },
  "dsh": {
    "profile": {
      "bundles": [ /* ...原有条目..., */ "dsh-desktop-hand" ]
    }
  },
  "pnpm": {
    "overrides": {
      "dsh-desktop-hand": "link:/absolute/path/to/dsh-desktop-hand"
    }
  }
}
```

然后在 profile 目录里 `pnpm install`，重启 DSH（bundle 列表在启动时读取）。

**环境要求：** Windows 10/11、PowerShell 5.1（系统自带）、Node `^22.19.0 || >=24.0.0`。

**三处缺一不可**：只有 `overrides` 而没有 `dependencies` + `bundles` 是无效状态，不会加载。

> ⚠️ **bundle 通道和 profile 的 `cordis.patch.yml` 手工挂载行，只能用一个。**
> 两者都写会双重挂载，工具注册时报 "already registered"，可能导致 DSH 起不来。

> ⚠️ **DSH 升级会重写 profile，把本地插件条目删掉。** 升级后请复查上面三处是否齐全。
> 细节与排查见 [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md)。

**配置项**（在 profile 里作为插件的 `config` 传入，一般不用改）：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `enginePath` | 包内 `lib/desktop-hand.ps1` | 引擎脚本路径 |
| `timeoutMs` | `60000` | 单次调用超时（首次要编译 `Add-Type`，约 1.2 s） |
| `outputDir` | 系统临时目录 | 截图默认落盘目录 |

---

## 使用

agent 装上后会自动获得这六个工具。典型流程：

```
desktop_list_windows            → 找到目标，拿句柄
desktop_capture(handle=...)     → 看图，量出要点哪里
desktop_focus(handle=...)       → 或 desktop_click 点窗口体拿焦点
desktop_type(text="...")        → 输入
desktop_capture(handle=...)     → 再看图确认结果
```

### 四条使用要点

**1. 要看窗口内容就用 `window`/`handle`，不要抓全屏**——除非你确实要看屏幕上真实
可见的东西。指定窗口走 `PrintWindow`，被遮挡也能抓到目标自己的内容。

**2. 看图和点图用同一张图。** `desktop_capture` 结果的 `width` 若与物理屏宽不一致，
把该 `width` 作为 `shotWidth` 传给 `desktop_click`。一致时图中像素坐标 1:1 可用。

**3. 不要用黑像素比例判断抓取成功，必须看图。** UWP 应用是盲区，工具会给
`uwpWarning`。

**4. 点不准或输入丢失时，先跑 `desktop_diagnose`，不要调坐标。** 它会连采两次
光标落点：稳定=可用；持续漂移=有别的输入源在覆盖（通常是远程会话）。这是环境
问题，改代码没用。

### 命令行直接调引擎

引擎也可脱离 DSH 单独使用，输出单行 JSON：

```powershell
$e = ".\lib\desktop-hand.ps1"
& $e -Action info                                    # 体检：DPI/屏幕/前台/输入法/远程软件
& $e -Action list-windows                            # 列窗口，拿句柄
& $e -Action capture -Window "Notepad" -OutPath a.png # 后台抓窗口（被遮挡也行）
& $e -Action capture -Handle 1234567 -OutPath b.png   # 按句柄抓
& $e -Action capture -FullScreen -Region "0,0,800,600"  # 全屏后裁切
& $e -Action click -X 640 -Y 360 -ShotWidth 1280      # 点击（坐标取自截图）
& $e -Action click -X 100 -Y 100 -ToX 400 -ToY 400    # 拖动（给 ToX/ToY）
& $e -Action type -Text "disp(1+1)" -Enter            # 输入（绕过输入法）
& $e -Action key -Key ctrl+s                          # 发按键
& $e -Action focus -Window "MATLAB"                   # 拉到前台
& $e -Action probe -X 400 -Y 400                      # 检测有无输入源在覆盖光标
```

坐标系是**截图里的像素**。`-ShotWidth` 传你所用截图的真实宽度；截图与物理屏 1:1 时
可省略。`capture` 的结果里会给出 `coordScale` 与 `originX/originY` 供换算。

可用动作（9 个）：`info` `list-windows` `capture` `click` `move` `probe` `type` `key` `focus`。
拖动是 `click` 的参数（同时给 `-ToX`/`-ToY` 即为拖动），不是独立动作。

### 自检

```powershell
.\lib\link-deps.ps1               # 为脱离 DSH 的自检链接 peer 依赖
.\lib\selftest.ps1                # 37 项 — 引擎
node .\lib\selftest.mjs           # 111 项 — 工具层
node .\lib\selftest-harness.mjs   # 18 项 — harness 子进程契约
node .\lib\verify-serialization-contract.mjs   # 25 项 — 宿主序列化契约
.\lib\occlusion-test.ps1          #  8 项 — 遮挡抓取（需肉眼看图）
.\lib\link-deps.ps1 -Clean
```

199 项，本地与 GitHub `windows-latest` 均全绿。依赖真实桌面的检查（窗口枚举、
键鼠闭环、遮挡抓取）在环境不满足时**跳过而非失败**——环境无法构造场景不等于代码
有缺陷。`fail` 是唯一代表代码坏了的信号。

`verify-serialization-contract.mjs` 与其它四套不同：它读的是**宿主的源码**，
用来钉住我们依赖的上游行为（`snapshotJsonValue` 接受/拒绝哪些值、
`applyFinalContent` 是否 `await` 钩子、`undefined` 属性在 `in` 与 `JSON.stringify`
眼里不一致）。它在找不到桌面版 DSH 时**跳过**，因为 npm 上的 `dsh-tools`
与桌面安装的版本不同；找不到时打印一行 `SKIP` 并 exit 0。

CI 覆盖不到"插件能否在运行中的 DSH 里加载"，那需要装 DSH 并重启；
`docs/COMPATIBILITY.md` 第 5 节有手工检查清单。

---

## 架构

两层，中间用单行 JSON 通信。

```
┌─ DSH agent ────────────────────────────────────────────┐
│  desktop_diagnose / list_windows / capture / focus /   │
│  click / type          ← 6 个 defineTool               │
└───────────────────────┬────────────────────────────────┘
                        │  ctx.subprocess.spawn
                        │  argv + JSON on stdout
┌───────────────────────▼────────────────────────────────┐
│  lib/desktop-hand.ps1   PowerShell 引擎                │
│  P/Invoke → user32 / gdi32 / shcore / dwmapi / imm32   │
└────────────────────────────────────────────────────────┘
```

### `lib/index.js` — 工具层（Node, ESM）

- 用 `defineTool` 注册 6 个工具。参数是 dsh-tools 的**扁平 JSON-Schema 属性表**
  （不是 schemastery，后者只用于插件自己的 `Config`）。
- 经 `ctx.subprocess.spawn` 起引擎。**不用裸 `node:child_process`**：DSH 沙箱会
  拒绝 Node 以管道 stdio 起子进程（裸 `spawn` 报 `EPERM`）。裸 `spawn` 仅作脱离
  DSH 时的退路。
- 截图通过 `finalizeContent` 钩子把 PNG 交给附件服务，追加成 `image` 内容块。
  不能塞进返回值——`output.schema` 是 `additionalProperties: false`，多余键会校验失败。
- 引擎返回 `ok:false` 时抛带提示的异常，让模型能自我纠正（比如"标题匹配到多个窗口，
  请用 handle"）。

### `lib/desktop-hand.ps1` — 引擎（PowerShell）

单个脚本，`-Action` 分发，恒向 stdout 输出单行 JSON。设计上有五条硬约束，
每条都是实测踩出来的，改动前请先读文件头的注释：

**1. 抓窗口用 `PrintWindow` + `PW_RENDERFULLCONTENT(2)`。**
flag 必须是 `2`：`flag=0` 对 UWP 是 100% 黑，`flag=2` 降到 71.7%，即 0 更糟。

**2. 文本注入用 `SendInput + KEYEVENTF_UNICODE`。**
不能用 `VkKeyScan` + `keybd_event`——那条路经过键盘布局/输入法层，会被改写
（实测想要 `third batch`，目标程序收到的是「第三批」）。

**3. 坐标按物理像素，且 DPI 感知要显式声明。**
2560×1440 + 150% 缩放时，不声明 DPI 感知会让 `SetCursorPos(42,1046)` 落到物理
(56,1395)，而 `GetCursorPos` 又除回去报 (1280,720)——表现是"点的位置和说的不一样"。

**4. 输出必须是显式 UTF-8。**
PowerShell 5.1 在 stdout 被重定向时按**控制台 ANSI 代码页**（本机 GBK/936）编码，
而 Node 按 UTF-8 解码，于是所有非 ASCII 错误信息变乱码。引擎第一件事就是设
`[Console]::OutputEncoding = UTF8`。**删掉这行不会报错，只会静默毁掉所有中文提示。**

**5. `apply()` 绝不能抛异常。**
插件在 profile 里是 `required: true`，`apply()` 抛错会让**整个 DSH 启动失败**并进
安全模式，进而重写 profile 把插件删掉。所以系统提示段落这类锦上添花的东西整段包在
`try/catch` 里，失败只 warning。详见 [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md)。

### 文件

```
dsh-desktop-hand/
├── package.json                  dsh.bundle.patch 是能被加载的关键字段
├── cordis.patch.yml              bundle 挂载声明
├── README.md
├── docs/
│   ├── COMPATIBILITY.md          DSH 版本兼容、启动失败事故、三个序列化陷阱
│   ├── INCIDENT-2026-10-03-...  图片块序列化故障的原始排查报告（中文）
│   ├── evidence/                故障报告引用的实拍图
│   └── ENGINEERING-NOTES.zh-CN.md  详细工程笔记（中文，含每个 bug 的定位过程）
├── skills/desktop-hand/          给 agent 的用法 skill
└── lib/
    ├── index.js                  6 个 defineTool + 图片返回
    ├── desktop-hand.ps1          PowerShell 引擎
    ├── selftest.ps1              引擎自检
    ├── selftest.mjs              工具层自检
    ├── selftest-harness.mjs      子进程 seam 契约自检
    ├── verify-serialization-contract.mjs  宿主序列化契约守卫
    ├── occlusion-test.ps1        遮挡抓取验证
    ├── hold-windows.ps1          测试台：造一对"目标 + 完全遮挡"窗口
    └── link-deps.ps1             为脱离 DSH 的自检建/清依赖链接
```

MIT licensed — see [`LICENSE`](LICENSE).
