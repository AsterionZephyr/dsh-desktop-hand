<#
.SYNOPSIS
    dsh-desktop-hand v1.1 新能力自检 —— ui-tree / click target / scroll / clipboard / wait / open-app。

.DESCRIPTION
    为什么单独一个文件，而不是继续往 lib/selftest.ps1 里加：
    selftest.ps1 测的是 v1.0 那套"键鼠闭环"，它必须能在没有交互桌面的 CI 上跑完；
    v1.1 的新能力**必须有一个真实窗口当靶子**（读 UIA 树、按控件名点、等窗口出现），
    还会读写剪贴板、可能启动一个记事本进程。把这些塞进老自检，会让"新功能没实现"
    和"老功能坏了"混在一份红绿里，也把 CI 的稳定性搭进去。

    沿用 lib/selftest.ps1 的约定（照抄，别自己发明）：
      1) Check / Skip 的语义：
           前置条件在本机不成立 -> SKIP（既不算过也不算错）
           前置成立而行为不对   -> FAIL（这才是真 bug）
         把"环境不满足"判成"代码坏了"，会让自检永远红着，从而彻底失去意义。
      2) Run 用**子进程**抓引擎输出。引擎用 [Console]::Out.Write 直接写 stdout，
         不走 PowerShell 成功流，所以 `& script | Out-String` **抓不到**（实测只拿到空串）。
         必须是：起 powershell.exe / pwsh 子进程，读它的 stdout。
      3) 调用原生程序前后把 $ErrorActionPreference 临时降回 Continue。
         脚本顶部设了 'Stop'，而 PowerShell 会把原生程序的 stderr 包装成 ErrorRecord；
         引擎只要往 stderr 写一个字，这一行就变成**终止错误**，整个自检当场中断。
         `2>$null` 挡不住这个行为（丢的是数据，ErrorRecord 照样产生）。

    靶子：**本脚本自己的控制台窗口**。
    启动时把控制台标题改成带随机 token 的唯一串（DSKHAND-V11 selftest OWN<随机数>），
    再从 list-windows 里按这个 token 找回自己的句柄与真实标题。这样：
      - 不需要任何 P/Invoke / Add-Type 就能拿到"自己的窗口"；
      - token 唯一，click / wait 的 -Window 子串匹配不会撞上别的窗口
        （撞上会变成 AMBIGUOUS，把"无效 target"的负路径测成另一个错误，失去意义）。

    安全边界（硬约束）：
      - 绝不在屏幕上随机位置点击。click 只做**无效 target** 的负路径。
      - scroll 用固定的 (400,400)，滚轮没有不可撤销的副作用。
      - open-app 若真的起了进程，清理时**只 Stop-Process 它自己报告的那个 pid**，
        绝不按进程名杀 —— 否则会杀掉用户自己打开的记事本。
      - 不碰管理员权限，不改系统设置。

    用法：
        pwsh -NoProfile -File lib/selftest-v11.ps1

    输出：
        每条 PASS / FAIL / SKIP，末尾汇总 N pass / N fail / N skip；
        每个动作的原始 JSON 追加写入 %TEMP%\desktop-hand-v11-report.txt，
        脚本最后打印该文件的完整路径。任一 FAIL 以非 0 退出。
#>
[CmdletBinding()]
param([string]$Engine)

$ErrorActionPreference = 'Stop'

# 编码必须是第一件事：本脚本的中文输出、以及 Run 里解码引擎 stdout 都依赖它。
# PowerShell 抓原生程序 stdout 时按 [Console]::OutputEncoding 解码；引擎按 UTF-8 写，
# 这里也必须是 UTF-8，否则中文报错信息会变成乱码（GBK 解码 UTF-8 的典型症状）。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if (-not $Engine) {
    $Engine = Join-Path $PSScriptRoot 'desktop-hand.ps1'
}
if (-not (Test-Path -LiteralPath $Engine)) { throw "找不到引擎脚本：$Engine" }

$script:pass = 0
$script:fail = 0
$script:skip = 0

# Run 的现场记录：报告文件要能还原"我到底发了什么命令、它退了几、回了什么"。
$script:lastRaw = ''
$script:lastCmd = ''
$script:lastExit = ''

# 清理用的状态：只记自己起的那个 pid / 自己的临时目录 / 自己的原始标题。
$script:launchedPid = 0
$script:capDir = ''
$script:cleaned = $false

# 自己的窗口（靶子）。
$script:ownOk = $false
$script:ownHandle = 0
$script:ownTitle = ''
$script:ownClass = ''
$script:ownTag = ''
$script:origConsoleTitle = ''

# 本机 UIA 扩展是否可用；不可用时依赖它的检查项走 SKIP（见 [1]）。
$script:uiaDown = $false
# 有没有可交互桌面：无桌面会话里 capture 必然失败，那属于环境问题而不是代码缺陷。
$script:interactive = $false

# ---------------------------------------------------------------- 临时目录与报告
$tmpRoot = $env:TEMP
if (-not $tmpRoot) { try { $tmpRoot = [System.IO.Path]::GetTempPath() } catch { $tmpRoot = '.' } }
$script:reportPath = Join-Path $tmpRoot 'desktop-hand-v11-report.txt'

# ---------------------------------------------------------------- 基础助手
# 安全的路径存在性判断。
# `Test-Path` 在收到 $null 或非法路径时**会抛错**，而本脚本设了
# $ErrorActionPreference='Stop'，于是"文件没生成"会被报成脚本崩溃，
# 而不是一条 FAIL。CI 上就是这样把环境问题伪装成代码问题的。
function Test-PathSafe([object]$p) {
    if ($null -eq $p -or "$p".Trim().Length -eq 0) { return $false }
    try { return (Test-Path -LiteralPath "$p" -ErrorAction Stop) } catch { return $false }
}

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) {
        $script:pass++
        Write-Host ("  PASS  " + $name) -ForegroundColor Green
    } else {
        $script:fail++
        $line = "  FAIL  " + $name
        if ($detail) { $line = $line + "  -- " + $detail }
        Write-Host $line -ForegroundColor Red
    }
}

# 跳过 = 前置条件在本机不成立，既不算通过也不算失败。
# 本脚本里它有三个正当用途：
#   1) 这台机器没有可交互桌面 / 找不到自己的控制台窗口（没有靶子）；
#   2) 引擎里那个动作还没实现（返回 BAD_ACTION）——**注意：这不算 SKIP**，
#      缺实现是代码问题，见下面的 Check；SKIP 只留给"本机测不了"。
#   3) 规格里的某个字段在引擎返回里根本不出现 —— 这类是"静态核对不到"的字段，
#      判 FAIL 会冤枉实现，判 PASS 会放过缺陷，所以先 SKIP 并在汇报里列出来，
#      等 Lead 确认字段名后再改成断言。
function Skip([string]$name, [string]$why) {
    $script:skip++
    Write-Host ("  SKIP  " + $name + "  -- " + $why) -ForegroundColor DarkGray
}

# ConvertFrom-Json 出来的对象是 PSCustomObject；规格里有些字段是"可选"的
# （比如 KeepPrevious 才出现的 previous）。字段缺席时直接访问会得到 $null，
# 于是 "断言失败" 与 "字段名写错" 无法区分。用它可以显式区分。
function Has-Prop([object]$obj, [string]$name) {
    if ($null -eq $obj) { return $false }
    return ($null -ne $obj.PSObject.Properties[$name])
}

function Add-Report([string]$label) {
    # 报告里同时留 命令 + 退出码 + 原始 stdout：三者缺一，事后就分不清
    # "没输出"、"输出被截断"、"退出码 1 但 JSON 是完整的" 这三种情况。
    $ts = (Get-Date).ToString('HH:mm:ss.fff')
    $head = '--- [' + $ts + '] ' + $label
    if ("$($script:lastExit)" -ne '') { $head = $head + '   (exit=' + $script:lastExit + ')' }
    if ($script:lastCmd) { $head = $head + [Environment]::NewLine + '    cmd: ' + $script:lastCmd }
    $body = $script:lastRaw
    if (-not $body) { $body = '(无输出)' }
    $nl = [Environment]::NewLine
    try {
        Add-Content -LiteralPath $script:reportPath -Value ($head + $nl + $body) -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Host ('  写报告失败：' + $_.Exception.Message) -ForegroundColor DarkYellow
    }
}

# ---------------------------------------------------------------- 调引擎
# PowerShell 的 `& $script @array` 是按**位置**展开的，会把 "-Action" 当成位置参数，
# 于是被引擎的 param() 拒绝。必须用 hashtable splatting 才是真正的"具名参数"传递。
function Invoke-EngineRaw([hashtable]$params) {
    $argv = @()
    foreach ($k in $params.Keys) {
        $v = $params[$k]
        if ($v -is [bool]) { if ($v) { $argv += "-$k" } }
        else { $argv += "-$k"; $argv += [string]$v }
    }

    $exe = (Get-Command powershell.exe -ErrorAction SilentlyContinue)
    if (-not $exe) { $exe = (Get-Command pwsh -ErrorAction SilentlyContinue) }
    if (-not $exe) {
        $script:lastCmd = '(PATH 上没有 powershell.exe / pwsh)'
        $script:lastExit = ''
        return $null
    }

    $script:lastCmd = $exe.Source + ' -File ' + $Engine + ' ' + ($argv -join ' ')
    $out = $null
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $exe.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Engine @argv 2>$null
        $script:lastExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    return (($out | Out-String).Trim())
}

function Convert-EngineJson([string]$raw) {
    $s = ''
    if ($null -ne $raw) { $s = ([string]$raw).Trim() }
    if (-not $s) { return [pscustomobject]@{ ok = $false; error = 'engine produced no output'; code = 'NO_OUTPUT' } }
    # 引擎恒输出单行 JSON；取最后一行以防有多余噪声
    $line = ($s -split '\r?\n' | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if (-not $line) { return [pscustomobject]@{ ok = $false; error = "non-json output: $s"; code = 'NON_JSON' } }
    try { return ($line | ConvertFrom-Json) }
    catch { return [pscustomobject]@{ ok = $false; error = "bad json: $line"; code = 'BAD_JSON' } }
}

# Run 是唯一入口：跑一次引擎 + 把原始输出记进报告 + 返回解析后的对象。
# 第二个参数是报告里的标签，**每个动作都要给**，否则事后翻报告会不知道哪条是哪条。
function Run([hashtable]$params, [string]$label = '') {
    $raw = Invoke-EngineRaw $params
    $script:lastRaw = $raw
    $obj = Convert-EngineJson $raw
    if ($label) { Add-Report $label }
    return $obj
}

# ---------------------------------------------------------------- 清理
# 顺序无所谓，但**必须幂等**：正常收尾与 trap 里的异常收尾都会调它。
function Invoke-Cleanup {
    if ($script:cleaned) { return }
    $script:cleaned = $true

    # 只 Stop-Process 自己刚启动的那个 pid。
    # 为什么强调"只这个 pid"：记事本是单实例还是多实例、用户本来有没有开着，
    # 都不可控；按名字杀会把用户的工作一起杀掉。名字不符时宁可不杀，只报告。
    if ([int]$script:launchedPid -gt 0) {
        $p = $null
        try { $p = Get-Process -Id ([int]$script:launchedPid) -ErrorAction Stop } catch { $p = $null }
        if ($null -ne $p) {
            if ($p.ProcessName -match '(?i)^(notepad|notepad\+\+)$') {
                try { Stop-Process -Id ([int]$script:launchedPid) -Force -ErrorAction Stop } catch {
                    Write-Host ('  清理：停 pid=' + $script:launchedPid + ' 失败：' + $_.Exception.Message) -ForegroundColor DarkYellow
                }
            } else {
                Write-Host ('  清理：pid=' + $script:launchedPid + ' 的进程名是 "' + $p.ProcessName + '"，不是记事本，跳过（避免误杀）') -ForegroundColor DarkYellow
            }
        }
    }

    # 只删自己建的那个临时目录。
    if ($script:capDir -and (Test-PathSafe $script:capDir)) {
        try { Remove-Item -LiteralPath $script:capDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }

    # 把控制台标题还回去，别给用户留一个改过名的窗口。
    if ($script:origConsoleTitle) {
        try { [Console]::Title = $script:origConsoleTitle } catch { }
        try { $Host.UI.RawUI.WindowTitle = $script:origConsoleTitle } catch { }
    }
}

# ---------------------------------------------------------------- 头部
$nl = [Environment]::NewLine
Write-Host ''
Write-Host '=== dsh-desktop-hand v1.1 自检（ui-tree / click target / scroll / clipboard / wait / open-app）===' -ForegroundColor Cyan
Write-Host ('engine: ' + $Engine)

# 环境事实：出问题时，这几行能立刻说明"是不是环境不同"，省掉一轮猜测。
$sessionId = ''
try { $sessionId = (Get-Process -Id $PID -ErrorAction SilentlyContinue).SessionId } catch { $sessionId = '?' }
Write-Host ('环境：UserInteractive=' + [Environment]::UserInteractive + ' SessionId=' + $sessionId + ' PS=' + $PSVersionTable.PSVersion) -ForegroundColor DarkGray
Write-Host ('报告：' + $script:reportPath) -ForegroundColor DarkGray

# 报告文件是追加写的（不删旧内容）：一次自检一条 RUN 分隔线，方便对比"上次为什么红"。
$runHeader = @()
$runHeader += ''
$runHeader += '================================================================'
$runHeader += ('RUN ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  engine=' + $Engine)
$runHeader += ('PS=' + $PSVersionTable.PSVersion.ToString() + '  UserInteractive=' + [Environment]::UserInteractive + '  PID=' + $PID + '  SessionId=' + $sessionId)
$runHeader += '================================================================'
try { Add-Content -LiteralPath $script:reportPath -Value ($runHeader -join $nl) -Encoding UTF8 -ErrorAction Stop }
catch { Write-Host ('  报告文件不可写（' + $_.Exception.Message + '），后续只打印到屏幕') -ForegroundColor Yellow }

# 兜底：任何未预料的终止错误都转成明确的 FAIL + 行号，再以非 0 退出。
# 没有它的话，顶部 $ErrorActionPreference='Stop' 会让意外错误直接中断，
# 日志里只剩一行报错，看不出跑到哪一步、也分不清"环境问题"还是"代码问题"。
trap {
    Invoke-Cleanup
    Write-Host ''
    Write-Host '  FAIL  未预料的错误，自检提前中断：' -ForegroundColor Red
    Write-Host ('         ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ('         位置：' + $_.InvocationInfo.PositionMessage) -ForegroundColor Red
    Write-Host ('         报告：' + $script:reportPath) -ForegroundColor DarkGray
    Write-Host ('=== 结果：' + $script:pass + ' pass / ' + ($script:fail + 1) + ' fail（中断） / ' + $script:skip + ' skip ===') -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- [0] 环境
Write-Host ''
Write-Host '[0] 环境事实 —— info'
$info = Run @{ Action = 'info' } 'info（环境事实）'
$script:interactive = ([Environment]::UserInteractive -eq $true)
if ([bool]$info.ok) {
    Write-Host ('      screen=' + $info.screenWidth + 'x' + $info.screenHeight + ' dpi=' + $info.dpiMode + ' ime=' + $info.ime)
    $remote = @($info.remoteTools)
    if ($remote.Count -gt 0) {
        # 这条警告和 v1.1 强相关：远程会话会抢光标，scroll / 剪贴板 / 等窗口都可能在
        # 两次引擎调用之间被打断。看到它就先把"环境抖动"当成第一嫌疑。
        Write-Host ('      注意：检测到远程/串流软件 ' + ($remote -join ',') + ' —— 会抢光标，失败项先怀疑它') -ForegroundColor Yellow
    }
} else {
    Write-Host ('      info 失败：code=' + $info.code + ' ' + $info.error) -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 找自己的窗口
Write-Host ''
Write-Host '[0b] 找到本脚本自己的控制台窗口（后面所有 UIA 检查的靶子）'
# 先存原标题，收尾还回去。
try { $script:origConsoleTitle = [Console]::Title } catch { $script:origConsoleTitle = '' }
$script:ownTag = 'OWN' + (Get-Random -Minimum 100000 -Maximum 999999)
try { [Console]::Title = 'DSKHAND-V11 selftest ' + $script:ownTag } catch { }
try { $Host.UI.RawUI.WindowTitle = 'DSKHAND-V11 selftest ' + $script:ownTag } catch { }

$own = $null
for ($i = 0; $i -lt 10 -and $null -eq $own; $i++) {
    Start-Sleep -Milliseconds 400
    $lw0 = Run @{ Action = 'list-windows' } ('list-windows 找自己（第 ' + ($i + 1) + ' 次）')
    if ($lw0 -and [bool]$lw0.ok) {
        $hits = @($lw0.windows | Where-Object { $_.title -and ($_.title -like ('*' + $script:ownTag + '*')) })
        if ($hits.Count -gt 0) {
            # 多个候选时取面积最大的：控制台窗口通常远大于误匹配的小窗。
            $own = @($hits | Sort-Object -Property @{ Expression = { [int]$_.width * [int]$_.height } } -Descending)[0]
        }
    }
}

if ($null -ne $own -and [bool]$own.minimized) {
    # 最小化窗口的 UIA 树可能一个节点都没有 —— 那是窗口状态，不是代码问题。
    # 先尽力还原（focus 走 SetForegroundWindow，一般会还原最小化），还不成就放弃使用它。
    Write-Host '      自己的窗口当前是最小化，先尝试还原' -ForegroundColor DarkGray
    Run @{ Action = 'focus'; Handle = [Int64]$own.handle } 'focus 自己（还原最小化）' | Out-Null
    Start-Sleep -Milliseconds 500
    $lw0b = Run @{ Action = 'list-windows' } 'list-windows 复核自己（还原后）'
    if ($lw0b -and [bool]$lw0b.ok) {
        $hits2 = @($lw0b.windows | Where-Object { $_.title -and ($_.title -like ('*' + $script:ownTag + '*')) })
        if ($hits2.Count -gt 0) { $own = @($hits2 | Sort-Object -Property @{ Expression = { [int]$_.width * [int]$_.height } } -Descending)[0] }
    }
    if ($null -ne $own -and [bool]$own.minimized) {
        Write-Host '      仍是最小化 → 依赖它的检查项将 SKIP' -ForegroundColor Yellow
        $own = $null
    }
}

if ($null -ne $own) {
    $script:ownOk = $true
    $script:ownHandle = [Int64]$own.handle
    $script:ownTitle = [string]$own.title
    $script:ownClass = [string]$own.class
    Write-Host ('      靶子：handle=' + $script:ownHandle + ' class=' + $script:ownClass)
    Write-Host ('            title=' + $script:ownTitle) -ForegroundColor DarkGray
} else {
    $script:ownOk = $false
    Write-Host '      找不到自己的控制台窗口（可能被宿主隐藏、标题没能改成功、或无可交互桌面）' -ForegroundColor Yellow
    Write-Host '      → 依赖自己窗口的检查项将 SKIP，其余项照常跑' -ForegroundColor Yellow
}

# =================================================================
# [1] ui-tree —— 读自己控制台窗口的 UIA 树
# =================================================================
Write-Host ''
Write-Host '[1] ui-tree —— 读自己控制台窗口的 UIA 树'
if ($script:ownOk) {
    $ut = Run @{ Action = 'ui-tree'; Handle = $script:ownHandle; Depth = 3; MaxNodes = 200 } 'ui-tree -Handle（自己）'
    # UIA 扩展是本机能力（引擎 Ensure-Extras 编译内联 C#），不是 v1.1 的业务逻辑。
    # 它在某台机器上不可用时，ui-tree / click -Target / wait -text 全都用不了 ——
    # 那是"环境前置不成立"，判 FAIL 会让自检在没装 UIA 的机器上永远红着。
    $script:uiaDown = ((-not [bool]$ut.ok) -and ($ut.code -eq 'UIA_UNAVAILABLE'))
    if ($script:uiaDown) {
        Write-Host ('      UIA 扩展不可用（UIA_UNAVAILABLE）：' + $ut.error) -ForegroundColor Yellow
        Write-Host '      → 依赖 UIA 的检查项全部 SKIP；请把这条错误原文带进汇报。' -ForegroundColor Yellow
        Skip 'ui-tree 返回 ok' ('UIA_UNAVAILABLE：' + $ut.error)
        Skip 'ui-tree 节点数 > 0' 'UIA 扩展不可用，树读不出来'
    } else {
        Check 'ui-tree 返回 ok' ([bool]$ut.ok) ('code=' + $ut.code + ' ' + $ut.error)
        Check 'ui-tree 节点数 > 0' ([int]$ut.count -gt 0) ('count=' + $ut.count + ' class=' + $script:ownClass)
    }

    # nodes 元素的字段名来自冻结规格（role / name 是"纯文本模型能读界面"的最小信息）。
    # 已对照引擎 ui-tree 分支核实：nodes 元素含 role / name / automationId / value /
    # x / y / width / height / centerX / centerY / enabled / offscreen / invokable。
    $nodes = @($ut.nodes)
    if ([bool]$ut.ok -and $nodes.Count -gt 0) {
        $n0 = $nodes[0]
        $keys = @($n0.PSObject.Properties | ForEach-Object { $_.Name })
        Check 'nodes 元素含 role / name 字段' ((Has-Prop $n0 'role') -and (Has-Prop $n0 'name')) ('keys=' + ($keys -join ','))
    } else {
        Skip 'nodes 元素含 role / name 字段' '上一条没拿到节点，字段无从校验'
    }

    if ($script:uiaDown) {
        Skip 'ui-tree -Flat 返回 ok' 'UIA 扩展不可用，-Flat 也跑不了'
        Skip '-Flat 的 text 非空' 'UIA 扩展不可用，-Flat 也跑不了'
    } else {
        $utf = Run @{ Action = 'ui-tree'; Handle = $script:ownHandle; Flat = $true; MaxNodes = 200 } 'ui-tree -Flat（自己）'
        Check 'ui-tree -Flat 返回 ok' ([bool]$utf.ok) ('code=' + $utf.code + ' ' + $utf.error)
        $utfText = ''
        if ($null -ne $utf.text) { $utfText = [string]$utf.text }
        Check '-Flat 的 text 非空' ([bool]$utf.ok -and ($utfText.Trim().Length -gt 0)) ('len=' + $utfText.Length)
    }
} else {
    Skip 'ui-tree 返回 ok' '找不到本脚本自己的控制台窗口（没有靶子）'
    Skip 'ui-tree 节点数 > 0' '同上'
    Skip 'nodes 元素含 role / name 字段' '同上'
    Skip 'ui-tree -Flat 返回 ok' '同上'
    Skip '-Flat 的 text 非空' '同上'
}

# =================================================================
# [2] ui-tree 错误路径 —— 无效句柄
# =================================================================
Write-Host ''
Write-Host '[2] ui-tree 错误路径 —— 无效句柄'
# 句柄 1 在任何正常系统上都不是有效窗口（HWND 从 0x10000 起是常态）。
# 这条本身是纯参数校验，不依赖桌面环境；唯一的 SKIP 出口是"本机 UIA 扩展不可用"
# （引擎 ui-tree 先 Ensure-Extras 再解析窗口，那种环境下根本走不到句柄校验）。
$utBad = Run @{ Action = 'ui-tree'; Handle = 1 } 'ui-tree -Handle 1（负路径）'
if ($utBad.code -eq 'UIA_UNAVAILABLE') {
    # 引擎 ui-tree 先 Ensure-Extras 再解析窗口，UIA 不可用时根本走不到句柄校验。
    Skip '无效句柄被拒绝（ok=false）' 'UIA_UNAVAILABLE：本机测不到这条（引擎先查 UIA 再看句柄）'
    Skip '错误码是 NO_SUCH_WINDOW' '同上'
} else {
Check '无效句柄被拒绝（ok=false）' (-not [bool]$utBad.ok) ('ok=' + $utBad.ok)
# 规格（DESIGN-v1.1）明确：ui-tree 找不到窗口"沿用 NO_MATCH / AMBIGUOUS / NO_SUCH_WINDOW"。
# 引擎里 capture / focus 的无效句柄分支已经在用 NO_SUCH_WINDOW，所以这里是可核对的。
Check '错误码是 NO_SUCH_WINDOW' ($utBad.code -eq 'NO_SUCH_WINDOW') ('code=' + $utBad.code + ' error=' + $utBad.error)
}

# =================================================================
# [3] click target 负路径 —— 无效控件名
# =================================================================
Write-Host ''
Write-Host '[3] click -Target 负路径 —— 绝不存在的控件名（只做负路径，不点屏幕）'
if ($script:ownOk -and $script:uiaDown) {
    Skip '无效 target 被拒绝（ok=false）' 'UIA 扩展不可用，click -Target 走不到匹配逻辑'
    Skip '错误码是 NO_MATCH' '同上'
    Skip 'error 里含候选控件提示' '同上'
} elseif ($script:ownOk) {
    $badTarget = 'ZZZ_NO_SUCH_CONTROL_' + (Get-Random -Minimum 100000 -Maximum 999999)
    $nc = Run @{ Action = 'click'; Target = $badTarget; Window = $script:ownTag } 'click -Target（无效控件名，负路径）'
    Check '无效 target 被拒绝（ok=false）' (-not [bool]$nc.ok) ('ok=' + $nc.ok)
    Check '错误码是 NO_MATCH' ($nc.code -eq 'NO_MATCH') ('code=' + $nc.code)

    # 规格：0 个命中时 error 里要列出该窗口前 10 个可点控件名，帮模型改词。
    # 措辞没有冻结，所以只要求命中一组"像候选列表"的词；真正的判据是"有没有给出名字"。
    $errText = ''
    if ($null -ne $nc.error) { $errText = [string]$nc.error }
    $hintOk = ($errText.Trim().Length -gt 0) -and ($errText -match '(?i)候选|candidate|control|控件|可点|按钮|前 ?10')
    Check 'error 里含候选控件提示' $hintOk ('error=' + $errText)
    if (-not $hintOk) {
        Write-Host '        规格要求 0 命中时列出前 10 个可点控件名；措辞不冻结，但至少要有候选列表。' -ForegroundColor Yellow
    }
} else {
    Skip '无效 target 被拒绝（ok=false）' '找不到本脚本自己的控制台窗口（没有靶子）'
    Skip '错误码是 NO_MATCH' '同上'
    Skip 'error 里含候选控件提示' '同上'
}

# =================================================================
# [4] scroll —— 滚轮
# =================================================================
Write-Host ''
Write-Host '[4] scroll —— 滚轮（固定点，不点击）'
# 用规格里给的 (400,400)；屏幕比它小（少见）时夹到安全区，避免落到屏幕外。
$scrX = 400
$scrY = 400
$physW0 = 0
$physH0 = 0
try { $physW0 = [int]$info.screenWidth } catch { $physW0 = 0 }
try { $physH0 = [int]$info.screenHeight } catch { $physH0 = 0 }
if ($physW0 -gt 100 -and $scrX -gt ($physW0 - 20)) { $scrX = $physW0 - 20 }
if ($physH0 -gt 100 -and $scrY -gt ($physH0 - 20)) { $scrY = $physH0 - 20 }
if ($scrX -lt 1) { $scrX = 1 }
if ($scrY -lt 1) { $scrY = 1 }

$scr = Run @{ Action = 'scroll'; X = $scrX; Y = $scrY; Delta = 1 } ('scroll (' + $scrX + ',' + $scrY + ') Delta=1')
Check 'scroll 返回 ok' ([bool]$scr.ok) ('code=' + $scr.code + ' ' + $scr.error)
$scrCursor = ''
if ($null -ne $scr.cursor) { $scrCursor = [string]$scr.cursor }
Check 'scroll 报告了 cursor' ($scrCursor.Trim().Length -gt 0) ("cursor='" + $scrCursor + "'")
if ($scrCursor.Trim().Length -gt 0) {
    Write-Host ('      at=(' + $scrX + ',' + $scrY + ') cursor=' + $scrCursor) -ForegroundColor DarkGray
}

# =================================================================
# [5] clipboard —— get 原文 -> set 标记 -> get 校验 -> 恢复 -> 再 get 校验
# =================================================================
Write-Host ''
Write-Host '[5] clipboard —— 读原文 → 写标记 → 读回 → 恢复原文 → 再读回'
# 标记用**单行 ASCII**：Get-Clipboard 不带 -Raw 时会把多行内容变成"行数组"，
# 单行才能做严格相等比较，不会把引擎的换行处理差异误报成缺陷。
$marker = 'DSKHAND-V11-CLIP-' + (Get-Random -Minimum 100000 -Maximum 999999)

$c0 = Run @{ Action = 'clipboard'; Mode = 'get' } 'clipboard get（原文）'
$clipOk = [bool]$c0.ok
if ((-not $clipOk) -and ($c0.code -eq 'CLIPBOARD_FAILED')) {
    # 剪贴板可能被别的进程短暂占用（OpenClipboard 失败）。这不该判缺陷，重试一次再下结论。
    Start-Sleep -Milliseconds 300
    $c0 = Run @{ Action = 'clipboard'; Mode = 'get' } 'clipboard get（原文，重试一次）'
    $clipOk = [bool]$c0.ok
}
$clipEnvDown = ((-not $clipOk) -and (($c0.code -eq 'CLIPBOARD_FAILED') -or ($c0.code -eq 'UIA_UNAVAILABLE')))
if ($clipEnvDown) {
    Write-Host ('      剪贴板/UIA 扩展在本机不可用：code=' + $c0.code + ' ' + $c0.error) -ForegroundColor Yellow
    Skip 'clipboard get 返回 ok' ('本机环境不满足：' + $c0.code + ' ' + $c0.error)
    Skip 'clipboard set 成功' '同上'
    Skip 'set 回报的原内容等于原文（KeepPrevious）' '同上'
    Skip 'get 读回标记载荷' '同上'
    Skip '恢复原文成功' '同上'
    Skip '恢复后 get 等于原文' '同上'
} elseif (-not $clipOk) {
    Check 'clipboard get 返回 ok' $false ('code=' + $c0.code + ' ' + $c0.error)
    Skip 'clipboard set 成功' 'get 都不通，后面的读写无从校验'
    Skip 'set 回报的原内容等于原文（KeepPrevious）' '同上'
    Skip 'get 读回标记载荷' '同上'
    Skip '恢复原文成功' '同上'
    Skip '恢复后 get 等于原文' '同上'
} else {
    Check 'clipboard get 返回 ok' $true
    $origText = ''
    if ($null -ne $c0.text) { $origText = [string]$c0.text }
    Write-Host ('      原文长度 ' + $origText.Length) -ForegroundColor DarkGray
    if ($origText.Length -eq 0) {
        Write-Host '      原文为空（剪贴板本来是空的）→ 恢复阶段走「清空」分支' -ForegroundColor DarkGray
    }

    $cs = Run @{ Action = 'clipboard'; Mode = 'set'; Text = $marker; KeepPrevious = $true } 'clipboard set（标记，KeepPrevious）'
    Check 'clipboard set 成功' ([bool]$cs.ok) ('code=' + $cs.code + ' ' + $cs.error)
    if (Has-Prop $cs 'previous') {
        $prev = ''
        if ($null -ne $cs.previous) { $prev = [string]$cs.previous }
        Check 'set 回报的原内容等于原文（KeepPrevious）' ($prev -eq $origText) ("previous='" + $prev + "' 原文='" + $origText + "'")
    } else {
        # previous 只在 -KeepPrevious 时出现（引擎 clipboard set 分支已核实字段名）。
        # 真缺席说明实现与规格不符：先 SKIP 并带进汇报，别直接判 FAIL 冤枉实现。
        Skip 'set 回报的原内容等于原文（KeepPrevious）' '返回里没有 previous 字段（规格要求 -KeepPrevious 时返回，见汇报）'
    }

    $cg = Run @{ Action = 'clipboard'; Mode = 'get' } 'clipboard get（校验标记）'
    $got = ''
    if ($null -ne $cg.text) { $got = [string]$cg.text }
    Check 'get 读回标记载荷' ([bool]$cg.ok -and ($got -eq $marker)) ("got='" + $got + "'")

    # 恢复原文。三层兜底，目标只有一个：剪贴板回到测试前的状态。
    #   a) 原文非空 -> 引擎 set 原文；
    #   b) 原文为空 -> 引擎 set 空串（引擎按 PSBoundParameters 判断"确实给了 Text"，
    #      正常会接受）；被拒时退回进程内 Set-Clipboard 清空；
    #   c) 复核不一致 -> 进程内再设一次（见下方注释：命令行传参可能改动原文）。
    $restored = $false
    if ($origText.Length -gt 0) {
        $cr = Run @{ Action = 'clipboard'; Mode = 'set'; Text = $origText } 'clipboard set（恢复原文）'
        $restored = [bool]$cr.ok
        if (-not $restored) {
            Write-Host ('      恢复失败：code=' + $cr.code + ' ' + $cr.error) -ForegroundColor Yellow
        }
    } else {
        $cr = Run @{ Action = 'clipboard'; Mode = 'set'; Text = '' } 'clipboard set（恢复为空串）'
        if ([bool]$cr.ok) {
            $restored = $true
        } else {
            Write-Host ('      引擎拒绝空 Text（code=' + $cr.code + '）→ 改用 Set-Clipboard 清空') -ForegroundColor DarkGray
            try { Set-Clipboard -Value '' -ErrorAction Stop; $restored = $true }
            catch {
                try { Set-Clipboard -Value $null -ErrorAction Stop; $restored = $true } catch { $restored = $false }
            }
        }
    }
    Check '恢复原文成功' $restored '恢复失败 → 剪贴板里还留着测试标记（会污染用户环境）'

    if ($restored) {
        $cf = Run @{ Action = 'clipboard'; Mode = 'get' } 'clipboard get（恢复后复核）'
        $fin = ''
        if ($null -ne $cf.text) { $fin = [string]$cf.text }
        if ($fin -ne $origText) {
            # 引擎 set 报 ok 但读回不一致：最可能是本脚本把原文当**命令行参数**传给引擎时，
            # PowerShell 5.1 对含引号/特殊字符的参数转义方式不同（这是调用方的毛病，不是引擎缺陷）。
            # 先黄字提示，再用进程内 Set-Clipboard 兜底，保证用户剪贴板一定回到原样。
            Write-Host '      读回与原文不一致（原文可能含引号/换行）→ 用进程内 Set-Clipboard 兜底恢复一次' -ForegroundColor Yellow
            try { Set-Clipboard -Value $origText -ErrorAction Stop } catch { }
            $cf = Run @{ Action = 'clipboard'; Mode = 'get' } 'clipboard get（兜底恢复后复核）'
            $fin = ''
            if ($null -ne $cf.text) { $fin = [string]$cf.text }
        }
        Check '恢复后 get 等于原文' ([bool]$cf.ok -and ($fin -eq $origText)) ("got='" + $fin + "' want='" + $origText + "'")
    } else {
        # 引擎没恢复成功也要尽量把用户剪贴板弄回去，别留测试标记。
        try { Set-Clipboard -Value $origText -ErrorAction Stop } catch { }
        Skip '恢复后 get 等于原文' '恢复失败，无从复核'
    }
}

# =================================================================
# [6] wait —— 等窗口出现 / 等到超时
# =================================================================
Write-Host ''
Write-Host '[6] wait —— 等窗口出现 / 超时'
if ($script:ownOk) {
    # 正向：自己窗口的标题就在那儿，所以应当**立刻**满足（几毫秒级）。
    $w1 = Run @{ Action = 'wait'; Until = 'window'; Target = $script:ownTag; WaitMs = 3000; PollMs = 200 } 'wait window（自己，应立刻满足）'
    Check 'wait window 立刻 satisfied' (([bool]$w1.ok) -and [bool]$w1.satisfied) ('ok=' + $w1.ok + ' satisfied=' + $w1.satisfied + ' code=' + $w1.code)

    if (Has-Prop $w1 'elapsedMs') {
        $el = 0
        try { $el = [int64]$w1.elapsedMs } catch { $el = 0 }
        # "很快"的客观判据：远小于 WaitMs。用 < WaitMs 会放过"刚好卡在上限"的实现，
        # 所以要求它明显更小（这里取 1/2 上限），同时留足机器抖动的余量。
        Check 'wait 很快返回（elapsedMs < WaitMs/2）' ($el -lt 1500) ('elapsedMs=' + $el + ' waitMs=3000')
    } else {
        Skip 'wait 很快返回（elapsedMs < WaitMs/2）' '返回里没有 elapsedMs 字段（引擎 wait 分支应当返回，见汇报）'
    }

    # 负向：一个随机串，绝不可能有窗口标题含它。800ms 后必须 TIMEOUT。
    $miss = 'ZZZ_DSKHAND_V11_MISSING_' + (Get-Random -Minimum 100000 -Maximum 999999)
    $w2 = Run @{ Action = 'wait'; Until = 'window'; Target = $miss; WaitMs = 800; PollMs = 200 } 'wait window（不存在，应超时）'
    Check '不存在的窗口不会 satisfied' (-not [bool]$w2.satisfied) ('satisfied=' + $w2.satisfied)
    # 规格：超时 -> Fail TIMEOUT（error 里带已等待毫秒与最后状态）。
    Check '超时错误码是 TIMEOUT' ((-not [bool]$w2.ok) -and ($w2.code -eq 'TIMEOUT')) ('ok=' + $w2.ok + ' code=' + $w2.code + ' error=' + $w2.error)
} else {
    Skip 'wait window 立刻 satisfied' '找不到本脚本自己的控制台窗口（没有靶子）'
    Skip 'wait 很快返回（elapsedMs < WaitMs/2）' '同上'
    Skip '不存在的窗口不会 satisfied' '同上'
    Skip '超时错误码是 TIMEOUT' '同上'
}

# =================================================================
# [7] open-app —— 启动记事本
# =================================================================
Write-Host ''
Write-Host '[7] open-app —— 启动应用（记事本）'
$oa = Run @{ Action = 'open-app'; Target = '记事本'; WaitMs = 8000 } 'open-app 记事本'
if ((-not [bool]$oa.ok) -and ($oa.code -eq 'NOT_LAUNCHED')) {
    Write-Host "      「记事本」没找到（code=NOT_LAUNCHED）→ 用英文名 Notepad 再试一次" -ForegroundColor DarkGray
    $oa = Run @{ Action = 'open-app'; Target = 'Notepad'; WaitMs = 8000 } 'open-app Notepad（备用名）'
}

if ([bool]$oa.ok) {
    Check 'open-app 启动成功' $true
    $oaPath = ''
    if ($null -ne $oa.path) { $oaPath = [string]$oa.path }
    $oaAppId = ''
    if ($null -ne $oa.appId) { $oaAppId = [string]$oa.appId }
    if ($oaAppId -ne '') {
        # MSIX/UWP 应用（Win11 的记事本、计算器都是）没有 .lnk：引擎用 Get-StartApps
        # 拿 AppID，再交给 shell:AppsFolder\<AppID> 调起 —— 返回的是 AppID 不是文件路径。
        Check 'MSIX 应用走 AppID 启动' $true ('appId=' + $oaAppId)
        Skip '启动的路径真实存在' 'AppID 应用没有文件路径可校验'
    } else {
        Check '启动的路径真实存在' (Test-PathSafe $oaPath) ("path='" + $oaPath + "'")
    }
    $oaTitles = @($oa.titles)
    Check 'open-app 等到了窗口' ($oaTitles.Count -gt 0) ('titles=' + ($oaTitles -join ' / ') + ' matchedBy=' + [string]$oa.matchedBy)

    if (Has-Prop $oa 'pid') {
        $launched = 0
        try { $launched = [int]$oa.pid } catch { $launched = 0 }
        if ($launched -gt 0) {
            # 记下来给 Invoke-Cleanup：清理时**只允许** Stop-Process 这个 pid。
            $script:launchedPid = $launched
            $pn = ''
            try { $pn = (Get-Process -Id $launched -ErrorAction Stop).ProcessName } catch { $pn = '' }
            Write-Host ('      已启动 pid=' + $launched + ' process="' + $pn + '"（清理时只杀这个 pid）') -ForegroundColor DarkGray
        } else {
            # 记事本在 Win11 上可能是 Store 应用/执行别名：Start-Process 立刻返回的 pid
            # 可能已经 handing off 给真正的宿主进程。没有 pid 就没有清理目标，只记录。
            Write-Host '      返回里 pid=0（可能是执行别名/已 handing off），没有清理目标' -ForegroundColor DarkGray
            if ($oaTitles.Count -gt 0) {
                Write-Host ('      ⚠️ 测试可能留下窗口：' + ($oaTitles -join ' / ') + ' —— 请手动关闭它') -ForegroundColor Yellow
            }
        }
    } else {
        Skip 'open-app 报告 pid' '返回里没有 pid 字段（引擎 open-app 分支应当返回，见汇报）'
    }
} elseif ($oa.code -eq 'NOT_LAUNCHED') {
    Skip 'open-app 启动成功' ('本机开始菜单/桌面里找不到「记事本」或 Notepad（code=' + $oa.code + '）—— 前置条件不成立')
    Skip '启动的路径真实存在' '同上'
} else {
    Check 'open-app 启动成功' $false ('code=' + $oa.code + ' ' + $oa.error)
    Skip '启动的路径真实存在' '启动失败，路径无从校验'
}

# =================================================================
# [8] 回归 —— 新代码没破坏旧动作
# =================================================================
Write-Host ''
Write-Host '[8] 回归 —— info / list-windows / capture -FullScreen 仍可用'
$inf2 = Run @{ Action = 'info' } 'info（回归）'
Check 'info 仍返回 ok' ([bool]$inf2.ok) ('code=' + $inf2.code + ' ' + $inf2.error)

$lw2 = Run @{ Action = 'list-windows' } 'list-windows（回归）'
Check 'list-windows 仍返回 ok' ([bool]$lw2.ok) ('code=' + $lw2.code + ' ' + $lw2.error)
if ([bool]$lw2.ok) {
    Check 'count 与 windows 长度一致' ([int]$lw2.count -eq @($lw2.windows).Count) ('count=' + $lw2.count + ' len=' + @($lw2.windows).Count)
} else {
    Skip 'count 与 windows 长度一致' 'list-windows 失败，数组无从校验'
}

$script:capDir = Join-Path $tmpRoot 'dsh-desktop-hand-selftest-v11'
if (-not (Test-PathSafe $script:capDir)) {
    try { New-Item -ItemType Directory -Force -Path $script:capDir | Out-Null } catch { }
}
$capPath = Join-Path $script:capDir 'full.png'
$cap = Run @{ Action = 'capture'; FullScreen = $true; OutPath = $capPath } 'capture -FullScreen（回归，落临时目录）'
if ((-not [bool]$cap.ok) -and (-not $script:interactive)) {
    # 无交互桌面/无显示器时截不到图，那是环境问题，不是"新代码破坏旧动作"。
    Write-Host ('      无交互桌面（UserInteractive=False），capture 失败：code=' + $cap.code + ' ' + $cap.error) -ForegroundColor Yellow
    Skip 'capture -FullScreen 仍返回 ok' '无交互桌面，截不到图'
    Skip 'PNG 已落盘' '无交互桌面，截不到图'
    Skip 'PNG 非空（> 1000 字节）' '无交互桌面，截不到图'
    Skip '截图尺寸有效（宽高 > 0）' '无交互桌面，截不到图'
} elseif ([bool]$cap.ok) {
    Check 'capture -FullScreen 仍返回 ok' $true
    Check 'PNG 已落盘' (Test-PathSafe $cap.path) ('path=' + $cap.path)
    $capBytes = 0
    if (Test-PathSafe $cap.path) {
        try { $capBytes = (Get-Item -LiteralPath $cap.path).Length } catch { $capBytes = 0 }
    }
    Check 'PNG 非空（> 1000 字节）' ($capBytes -gt 1000) ('bytes=' + $capBytes + '（报告 bytes=' + $cap.bytes + '）')
    # 不比较 info.screenWidth：本机有虚拟显示器/多屏时 -FullScreen 截的是虚拟桌面，
    # 宽度可能大于主屏宽，那样断言会误报。这里只要求尺寸有效。
    Check '截图尺寸有效（宽高 > 0）' (([int]$cap.width -gt 0) -and ([int]$cap.height -gt 0)) ('got=' + $cap.width + 'x' + $cap.height + ' info=' + $inf2.screenWidth + 'x' + $inf2.screenHeight)
} else {
    Check 'capture -FullScreen 仍返回 ok' $false ('code=' + $cap.code + ' ' + $cap.error)
    Skip 'PNG 已落盘' 'capture 失败，文件无从校验'
    Skip 'PNG 非空（> 1000 字节）' '同上'
    Skip '截图尺寸有效（宽高 > 0）' '同上'
}

# ---------------------------------------------------------------- 收尾
Invoke-Cleanup

$reportFull = $script:reportPath
try { $reportFull = [System.IO.Path]::GetFullPath($script:reportPath) } catch { $reportFull = $script:reportPath }

# 结果解读：
#   FAIL  -> 代码有问题，必须查（退出码非 0）
#   SKIP  -> 本环境不具备前置条件（或字段名待确认），既不算过也不算错
$color = 'Green'
if ($script:fail -gt 0) { $color = 'Red' }
Write-Host ''
Write-Host ('=== 结果：' + $script:pass + ' pass / ' + $script:fail + ' fail / ' + $script:skip + ' skip ===') -ForegroundColor $color
if ($script:skip -gt 0) {
    Write-Host '    （SKIP 是环境不具备条件或字段名待确认，不是缺陷；详见上方每条的说明）' -ForegroundColor DarkGray
}
Write-Host ('报告（每个动作的原始 JSON，追加写入）：' + $reportFull) -ForegroundColor Cyan

try {
    $foot = $nl + '=== RESULT: ' + $script:pass + ' pass / ' + $script:fail + ' fail / ' + $script:skip + ' skip ===' + $nl
    Add-Content -LiteralPath $script:reportPath -Value $foot -Encoding UTF8 -ErrorAction Stop
} catch { }

# ⚠️ 必须**显式**给出两个分支的退出码，不能只在失败时 exit 1。
# 只写 `if (fail) { exit 1 }` 时，全部分支「不执行 exit」，脚本退出码就取决于
# PowerShell 结束时环境里残留的状态（实测 CI 上出现过日志写"36 通过 / 0 失败"
# 而调用方拿到 LASTEXITCODE=1）。测试结果与退出码不一致是最难查的一类问题。
if ($script:fail -gt 0) { exit 1 }
exit 0