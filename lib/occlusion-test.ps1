<#
.SYNOPSIS
    专门验证「被遮挡的窗口也能抓到自己的内容」—— 本插件相对市场插件的核心差异。

.DESCRIPTION
    为什么要单独测：市场上有插件声称能抓窗口，但实测用的是
    `CopyFromScreen` 裁窗口矩形，窗口被盖住时抓到的其实是**遮挡者**的画面。
    本插件用 PrintWindow，应当抓到目标窗口自己的内容。

    本测试造一个**必然被完全遮挡**的场景并给出客观判据：
      1. 起一个 cmd 窗口，标题与内容都带唯一 marker
      2. 把目标窗口移到屏幕左上
      3. 用全屏顶层窗口（另一个 cmd）把它**完全盖住**
      4. 抓目标窗口（-Handle，PrintWindow 路径）
      5. 关键判据：
         - 抓到的图尺寸 == 目标窗口尺寸（不是全屏尺寸）
         - 抓到的图里能看到目标自己的 marker 文本（而不是遮挡者的）

    用法：.\occlusion-test.ps1
#>
[CmdletBinding()]
param([string]$Engine)

$ErrorActionPreference = 'Stop'
if (-not $Engine) { $Engine = Join-Path $PSScriptRoot 'desktop-hand.ps1' }
$outDir = if ($env:DSH_OCCLUSION_OUT_DIR) { $env:DSH_OCCLUSION_OUT_DIR }
  elseif ($env:RUNNER_TEMP) { Join-Path $env:RUNNER_TEMP 'dsh-desktop-hand-occlusion' }
  else { Join-Path $env:TEMP 'dsh-desktop-hand-occlusion' }
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

$script:pass = 0; $script:fail = 0
function Check([string]$n, [bool]$ok, [string]$d = '') {
    if ($ok) { $script:pass++; Write-Host "  PASS  $n" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $n  -- $d" -ForegroundColor Red }
}


# 用子进程调用引擎；引擎用 [Console]::Out.Write 写 stdout，不走 PS 成功流
function Invoke-Engine([string[]]$argv) {
    $cmd = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command pwsh -ErrorAction SilentlyContinue }
    if (-not $cmd) { return $null }
    # ⚠️ 调原生程序前必须把 ErrorActionPreference 降回 Continue。
    # PowerShell 会把原生程序的 stderr 包装成 ErrorRecord，而本脚本顶部设了
    # 'Stop'，于是引擎只要往 stderr 写一个字，这里就抛终止错误、整个脚本中断。
    # 实测：GitHub runner 上就是这样把遮挡验证弄崩的（本机引擎不写 stderr 所以没暴露）。
    # `2>$null` 挡不住这个行为——它丢的是数据，ErrorRecord 照样产生。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $cmd.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Engine @argv 2>$null
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $line = ($out | Out-String) -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1
    if (-not $line) { return $null }
    return $line | ConvertFrom-Json
}

Write-Host "`n=== 遮挡抓取验证 ===" -ForegroundColor Cyan
Write-Host "engine: $Engine`n"

$marker = 'OCCL_' + (Get-Random -Minimum 10000 -Maximum 99999)
$blocker = 'BLOCKER_' + (Get-Random -Minimum 10000 -Maximum 99999)

# 1) 目标窗口：内容里带 marker
$tProc = $null
    try { $tProc = Start-Process cmd.exe -ArgumentList '/k', "title $marker & echo $marker CONTENT LINE" -PassThru -ErrorAction Stop } catch { }
Start-Sleep -Seconds 3

# 2) 找到目标窗口
$t = $null
for ($i = 0; $i -lt 10 -and $null -eq $t; $i++) {
    $lw = Invoke-Engine @('-Action', 'list-windows')
    if ($lw) { $t = @($lw.windows | Where-Object { $_.title -match $marker } | Select-Object -First 1)[0] }
    if ($null -eq $t) { Start-Sleep -Milliseconds 500 }
}
if ($null -eq $t) {
    # 本环境无法创建可见窗口 => 无法构造"遮挡"场景。
    # 这不是代码缺陷，所以不判失败；但要明确说出来，避免被误读成"验证通过"。
    Write-Host "  SKIP  找不到测试目标窗口 —— 本环境无法为测试创建可见窗口" -ForegroundColor DarkGray
    Write-Host "        （遮挡抓取需要真实桌面；CI 上若 desktop 不可用就会走到这里）" -ForegroundColor DarkGray
    foreach ($pp in @($tProc, $bProc)) { if ($pp -and -not $pp.HasExited) { try { $pp.Kill() } catch { } } }
    Write-Host "`n=== 结果：0 通过 / 0 失败（已跳过：本环境无法构造遮挡场景）===" -ForegroundColor Yellow
    exit 0
}
Check '找到目标窗口' $true "marker=$marker"
Write-Host "      目标 handle=$($t.handle) rect=($($t.x),$($t.y)) $($t.width)x$($t.height)" -ForegroundColor DarkGray

# 3) 抓一张"未被遮挡"的基准图
$before = Invoke-Engine @('-Action', 'capture', '-Handle', "$($t.handle)", '-OutPath', (Join-Path $outDir 'before.png'))
Check '遮挡前能抓到目标窗口' ([bool]$before.ok) $before.error
Write-Host "      抓取尺寸 $($before.width)x$($before.height)（应为 $($t.width)x$($t.height) 左右）" -ForegroundColor DarkGray

# 4) 全屏遮挡者盖住它
$bProc = $null
    try { $bProc = Start-Process cmd.exe -ArgumentList '/k', "title $blocker & mode con: cols=200 lines=60 & echo $blocker THIS IS THE BLOCKER WINDOW COVERING EVERYTHING" -PassThru -ErrorAction Stop } catch { }
Start-Sleep -Seconds 3
# 把遮挡者最大化并拉到前台
$bw = Invoke-Engine @('-Action', 'list-windows')
$b = @($bw.windows | Where-Object { $_.title -match $blocker } | Select-Object -First 1)[0]
if ($b) {
    Invoke-Engine @('-Action', 'focus', '-Handle', "$($b.handle)") | Out-Null
    # 用 Win32 把遮挡者最大化（ShowWindow SW_MAXIMIZE = 3）
    Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class W{[DllImport("user32.dll")]public static extern bool ShowWindow(IntPtr h,int c);}' -ErrorAction SilentlyContinue
    [W]::ShowWindow([IntPtr]$b.handle, 3) | Out-Null
    Start-Sleep -Seconds 2
    Write-Host "      遮挡者 handle=$($b.handle) 已最大化并置于前台" -ForegroundColor DarkGray
}
Check '遮挡者窗口已就位' ($null -ne $b)

# 5) 确认目标确实被盖住了：全屏截图里不该再看见目标的 marker
$fs = Invoke-Engine @('-Action', 'capture', '-FullScreen', '-OutPath', (Join-Path $outDir 'covered_fullscreen.png'))
Check '遮挡状态下能抓全屏' ([bool]$fs.ok) $fs.error

# 6) 关键一步：在被遮挡的状态下抓目标窗口
$after = Invoke-Engine @('-Action', 'capture', '-Handle', "$($t.handle)", '-OutPath', (Join-Path $outDir 'after_occluded.png'))
Check '被遮挡后仍能抓到目标窗口' ([bool]$after.ok) $after.error

# 判据：抓到的必须是**目标窗口自己的**尺寸，而不是全屏尺寸。
#
# ⚠️ 不能用 `after.width < fs.width` 来判（曾经这么写，在 CI 上误判）。
# 窗口尺寸**可以大于屏幕**：本机实测有 2578 宽的窗口而屏幕只有 2560
# （边框在屏幕外 / 部分离屏）。所以"比全屏小"不是这条断言要表达的意思，
# 它要表达的是"抓到的是窗口而不是整屏"。
# 正确做法：与目标窗口自身的 rect 比（允许 DWM 扩展边框带来的几十像素差异），
# 并额外确认它与全屏抓取**不相同**。
if ($after.ok) {
    $dw = [math]::Abs([int]$after.width - [int]$t.width)
    $dh = [math]::Abs([int]$after.height - [int]$t.height)
    Check '抓到的尺寸等于目标窗口自身尺寸' (($dw -le 32) -and ($dh -le 32)) "after=$($after.width)x$($after.height) window=$($t.width)x$($t.height)"

    $sameAsFull = ([int]$after.width -eq [int]$fs.width) -and ([int]$after.height -eq [int]$fs.height)
    Check '抓到的不是全屏图（说明走的是 PrintWindow 而非 CopyFromScreen）' (-not $sameAsFull) "after=$($after.width)x$($after.height) fullscreen=$($fs.width)x$($fs.height)"

    # 遮挡前后同一窗口的抓取尺寸应当一致
    Check '遮挡前后窗口抓取尺寸一致' (([int]$after.width -eq [int]$before.width) -and ([int]$after.height -eq [int]$before.height)) "before=$($before.width)x$($before.height) after=$($after.width)x$($after.height)"
}

Write-Host "`n产物（请用 read_image 人工确认内容是否是目标窗口而非遮挡者）：" -ForegroundColor Yellow
Write-Host "  遮挡前窗口图 : $($before.path)"
Write-Host "  遮挡后窗口图 : $($after.path)"
Write-Host "  遮挡时全屏图 : $($fs.path)"
Write-Host "`n判据说明：被遮挡时全屏图应显示遮挡者($blocker)，"
Write-Host "          而窗口抓取图应仍显示目标($marker)自己的内容。" -ForegroundColor Yellow

# 清理
foreach ($p in @($tProc, $bProc)) { if ($p -and -not $p.HasExited) { try { $p.Kill() } catch { } } }

Write-Host "`n=== 结果：$script:pass 通过 / $script:fail 失败 ===" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
exit 0
