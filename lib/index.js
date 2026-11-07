/**
 * dsh-desktop-hand — 给 DSH agent 装上操作 Windows 桌面的手和眼睛。
 *
 * ## 为什么要有这个插件
 *
 * 本机（以及任何 Windows 机器）上，"截屏 + 点鼠标 + 敲键盘"这套能力原先靠三份散落的
 * PowerShell 脚本（capture.ps1 / mouse.ps1 / type.ps1）加一段 skill 引导来用。
 * 那套东西**能用且已验证**，但有三个问题：
 *
 *   1. 脚本在某个工作区的目录里，**别的会话/工作区用不到**（需求原文：供其他工作区使用）。
 *   2. agent 每次要自己拼命令行，容易拼错；`-ShotWidth` 之类的参数漏了就点偏。
 *   3. 截图只能落盘，模型还得再调一次 read_image 才看得到。
 *
 * 本插件把这三件事收成一个真正的 DSH 插件：
 *   - 工具全局注册，**任意工作区、任意会话**都能用；
 *   - agent 只描述意图（`capture_window`、`click`），坐标换算/DPI/编码全在内部做对；
 *   - 截图**直接把图作为内容块交给当前模型**，不需要二次 read_image。
 *
 * ## 与市场插件的关系（2026-09-27 调研结论）
 *
 * 调研了 8 个能碰桌面的 DSH 插件，**没有一个同时具备以下四项**：
 *   窗口按标题抓取（含遮挡）+ 坐标点击 + 键盘注入 + 窗口聚焦。
 * 市场清晰地分成两半：
 *   - 用了 PrintWindow（能抓遮挡）的（dsh-screen-reader、@paicat1/dsh-screenshot）
 *     **完全不碰输入**；
 *   - 能注入输入的（Altairpaca/dsh-computer-use-windows，四项俱全）
 *     抓窗口用的是 `CopyFromScreen` 裁窗口矩形，**抓不到被遮挡的内容**。
 * 所以本插件不是重复造轮子，而是补上那个空缺的组合。
 *
 * ## 设计约束（改动前必读，每条都有实测依据）
 *
 * 1. **抓窗口用 PrintWindow + flag=2**，不是 CopyFromScreen。只有前者能抓到遮挡窗口。
 * 2. **文本注入用 SendInput + KEYEVENTF_UNICODE**，不是 VkKeyScan/keybd_event。
 *    中文输入法会把后者注入的按键转换掉（实测 "third batch" 变「第三批」）。
 * 3. **坐标一律按物理像素**，脚本内声明 DPI 感知
 *    （本机 2560x1440 + 150% 缩放，不声明会点偏）。
 * 4. **截图只传路径不传图是错的**——本插件把图交给模型；但**也要落盘**，
 *    因为人需要复核，而"黑像素比例"不能当成功判据。
 * 5. **批量一次性返回时会超限**：截图可能 2MB+，一张一张来。
 *
 * @module dsh-desktop-hand
 */

import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, isAbsolute, resolve } from 'node:path';
import z from '@deepseek-ai/schemastery';
import { defineTool } from '@deepseek-ai/dsh-tools';

export const name = 'desktop-hand';

export const inject = ['tools'];

// 仅供自检使用：把 EngineError 暴露出来，好让 selftest.mjs 能直接验证
// "引擎不给 code 时不会创建 undefined 属性"（这是个真实踩过的坑，见下面的类注释）。
// 下划线前缀表示非公开 API，不要在插件逻辑里依赖它。
export { EngineError as __EngineErrorForTest };
const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_ENGINE = join(HERE, 'desktop-hand.ps1');

/**
 * 运行时配置。注意：schemastery 只用于**插件自己的 Config**，
 * 工具参数用的是 dsh-tools 那套扁平 JSON-Schema 子集（见下面各 defineTool）。
 */
export const Config = z.object({
  /** 引擎脚本路径；默认用包内自带的 lib/desktop-hand.ps1。 */
  enginePath: z.string().default(DEFAULT_ENGINE),
  /** 单次调用超时（毫秒）。冷启动要编译 Add-Type，第一次约 1.2s，给足余量。 */
  timeoutMs: z.number().default(60000),
  /** 截图默认落盘目录；留空则用系统临时目录下的 dsh-desktop-hand。 */
  outputDir: z.string().default(''),
});

/** 引擎返回 ok:false 时，把结构和提示一起抛出去，让模型能自我纠正。 */
class EngineError extends Error {
  constructor(payload) {
    const hints = {
      NO_MATCH: '用 desktop_list_windows 查看当前有哪些窗口，再用完整标题或 handle 重试。',
      AMBIGUOUS: '该标题匹配到多个窗口，请改用 handle 精确指定。',
      NO_SUCH_WINDOW: '句柄可能已失效，重新 list_windows 取新句柄。',
      REGION_OOB: '裁切区域超出了被抓对象，先不裁切抓一次看实际尺寸。',
      BAD_REGION: 'region 必须形如 "x,y,w,h" 且宽高为正。',
      BAD_KEY: '该按键不在白名单内，改用支持的键名。',
      BAD_ACTION: '内部动作名错误（插件 bug）。',
      CAPTURE_FAILED: '抓取失败，可能是窗口已最小化或尺寸异常。',
      // v1.1 新增动作的错误码
      UIA_UNAVAILABLE: '这台机器/这个窗口拿不到 UI Automation 数据，退回截图 + 坐标点击。',
      NO_HIT_RECT: '目标控件没有可见边界（被卷出视野或还没渲染），先滚到它可见，或改用坐标点击。',
      MISSING_TEXT: 'clipboard set 必须带 text（哪怕空字符串也要显式给）。',
      CLIPBOARD_FAILED: '剪贴板被别的进程占用，稍等重试。',
      BAD_MODE: 'mode 只能是 get 或 set。',
      BAD_UNTIL: 'until 只能是 window / gone / text。',
      TIMEOUT: '等不到条件：确认窗口标题片段写对了，或加大 waitMs；应用没启动就先用 desktop_open_app。',
      MISSING_TARGET: '缺 target 参数。',
      NOT_LAUNCHED: '开始菜单/桌面里没有这个名字的快捷方式：换个片段（如 Word 而不是 Microsoft Word），或它已经在运行——用 desktop_list_windows 找窗口。',
    };
    const hint = hints[payload.code];
    super(`${payload.error}${hint ? `\n提示：${hint}` : ''}`);
    this.name = 'EngineError';

    // ⚠️ `code` 只在**确实有值**时才设成自有属性。
    //
    // 为什么（真实故障，2026-10-02）：dsh-tools 在工具抛错时会调 errorInfo()，
    // 它用 `"code" in error` 判断要不要把 { name, code } 放进结果：
    //     errorInfo = e instanceof Error && "code" in e ? { name: e.name, code: e.code } : undefined
    //     （dsh-tools/lib/index.js:2608）
    // 而错误结果同样要过 snapshotJsonValue 校验，**值为 undefined 的属性会让
    // 整份结果被拒**，于是真正有用的错误信息被替换成：
    //     tool result must be losslessly JSON-serializable
    //
    // 关键陷阱：`this.code = undefined` 会**创建**这个属性，
    // 所以 `"code" in error` 为 true，但 `error.code` 是 undefined。
    // 实测：{code: undefined} 的错误结果被拒；不设该属性则通过。
    //
    // 所以这里必须"有值才设"，不能无条件赋值。
    const code = payload.code;
    if (code !== undefined && code !== null && code !== '') this.code = code;
  }
}

/** 把 JS 值转成 PowerShell 具名参数需要的字符串形式。 */
function toArgv(params) {
  const argv = [];
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined || value === null) continue;
    if (typeof value === 'boolean') {
      if (value) argv.push(`-${key}`);
      continue;
    }
    argv.push(`-${key}`, String(value));
  }
  return argv;
}

/**
 * 跑一次引擎并解析其 JSON。
 *
 * ## 为什么优先走 `ctx.subprocess` 而不是裸 `node:child_process`
 *
 * 官方插件（dsh-pwsh-local、dsh-tool-bash）都通过 harness 自己的
 * `ctx.subprocess.spawn` 起子进程，而不是直接 import `node:child_process`。
 * 这不只是风格问题：**DSH 的文件沙箱会拒绝 node 以管道 stdio 起子进程**
 * （实测在本会话的 workspace-write 沙箱下，裸 spawn 直接 `EPERM`；
 *  换成 `stdio:'inherit'` 就能跑，可见拦的就是"捕获输出"这个动作）。
 * 走 harness 的 seam 由 harness 自己决定如何落盘/收集输出，不受该限制。
 *
 * 因此这里：有 `ctx.subprocess` 就用它（正式路径），没有才退回裸 spawn
 * （便于脱离 DSH 单独测试）。两条路都返回同一形状。
 */
function makeRunner(ctx, enginePath, timeoutMs) {
  const subprocess = ctx.get('subprocess');

  /** 正式路径：harness 的子进程 seam。 */
  async function runViaHarness(params, signal) {
    // ⚠️ `graceMs` 是**必填**的：validateSubprocessSpec 会拒绝缺失/非正数
    //    （runner-launch-*.js:883）。它不是超时，而是"发终止信号后宽限多久"。
    // ⚠️ 这个 seam **没有** timeoutMs 字段——超时由调用方自己管
    //    （官方 dsh-pwsh-local 用 deadline(...) 造 signal 再传进来）。
    //    所以这里用 AbortController + 定时器自己实现超时。
    const controller = new AbortController();
    const onOuterAbort = () => controller.abort(signal?.reason);
    if (signal !== undefined) {
      if (signal.aborted) controller.abort(signal.reason);
      else signal.addEventListener('abort', onOuterAbort, { once: true });
    }
    const timer = setTimeout(
      () => controller.abort(new Error(`engine timeout after ${timeoutMs}ms`)),
      timeoutMs,
    );

    let handle;
    try {
      handle = subprocess.spawn({
        argv: ['powershell.exe', '-NoProfile', '-NonInteractive',
          '-ExecutionPolicy', 'Bypass', '-File', enginePath, ...toArgv(params)],
        stdio: {
          stdin: 'ignore',
          stdout: { maxBytes: 4 * 1024 * 1024 },
          stderr: { maxBytes: 256 * 1024 },
        },
        graceMs: 3000,
        signal: controller.signal,
      });
    } catch (error) {
      clearTimeout(timer);
      if (signal !== undefined) signal.removeEventListener?.('abort', onOuterAbort);
      throw new Error(`无法启动桌面引擎：${error.message}`);
    }

    // ⚠️ `handle.collected.stdout` 是一个**收集器对象**，不是 {text} 字面量：
    // 必须调它的 finalize() 才拿到 { text, truncated, spillPath }
    // （见 dsh-subprocess-local/lib/runner-launch-*.js 的 finalize()）。
    // 直接读 .text 会静默拿到 undefined —— 那会让所有工具都报"引擎无输出"。
    //
    // 引擎侧已把 [Console]::OutputEncoding 设成 UTF-8，所以 finalize() 拿到的
    // 就是正确的中文。若某个实现返回 Buffer，也按 utf8 解一次兜底。
    const drain = (collector) => {
      if (collector === undefined || collector === null) return '';
      let raw;
      if (typeof collector.finalize === 'function') {
        try { raw = collector.finalize()?.text; } catch { return ''; }
      } else {
        raw = collector.text;
      }
      if (raw === undefined || raw === null) return '';
      return Buffer.isBuffer(raw) ? raw.toString('utf8') : String(raw);
    };

    try {
      const outcome = await handle.done;
      if (controller.signal.aborted && controller.signal.reason?.message?.includes('engine timeout')) {
        throw new Error(`引擎超时（${timeoutMs}ms）。若目标窗口无响应或系统繁忙，可调大 timeoutMs。`);
      }
      return {
        stdout: drain(handle.collected?.stdout),
        stderr: drain(handle.collected?.stderr),
        exitCode: outcome?.exitCode,
      };
    } finally {
      clearTimeout(timer);
      if (signal !== undefined) signal.removeEventListener?.('abort', onOuterAbort);
    }
  }

  /** 退路：裸 spawn。仅在没有 subprocess seam 时使用（例如独立跑自检）。 */
  function runViaChildProcess(params) {
    return new Promise((resolvePromise, rejectPromise) => {
      let child;
      try {
        child = spawn('powershell.exe', [
          '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
          '-File', enginePath, ...toArgv(params),
        ], { windowsHide: true });
      } catch (error) {
        rejectPromise(new Error(`无法启动 PowerShell：${error.message}`));
        return;
      }
      let stdout = '';
      let stderr = '';
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        try { child.kill(); } catch { /* 已退出 */ }
        rejectPromise(new Error(`引擎超时（${timeoutMs}ms）。若目标窗口无响应或系统繁忙，可调大 timeoutMs。`));
      }, timeoutMs);
      // 显式按 utf8 解码：引擎侧已设 OutputEncoding=UTF8，这里对齐
      child.stdout.setEncoding('utf8');
      child.stderr.setEncoding('utf8');
      child.stdout.on('data', (chunk) => { stdout += chunk; });
      child.stderr.on('data', (chunk) => { stderr += chunk; });
      child.on('error', (error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        rejectPromise(new Error(`引擎进程错误：${error.message}`));
      });
      child.on('close', (code) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolvePromise({ stdout, stderr, exitCode: code });
      });
    });
  }

  return async function call(params, signal) {
    const result = subprocess !== undefined
      ? await runViaHarness(params, signal)
      : await runViaChildProcess(params);

    const line = String(result.stdout ?? '')
      .split(/\r?\n/)
      .map((s) => s.trim())
      .filter((s) => s.startsWith('{'))
      .pop();

    if (!line) {
      const detail = String(result.stderr ?? '').trim()
        || String(result.stdout ?? '').trim()
        || '(无输出)';
      throw new Error(`桌面引擎未返回 JSON（exit=${result.exitCode}）。原始输出：\n${detail}`);
    }

    let payload;
    try {
      payload = JSON.parse(line);
    } catch {
      throw new Error(`桌面引擎返回的不是合法 JSON：${line.slice(0, 400)}`);
    }
    if (payload.ok !== true) throw new EngineError(payload);
    return payload;
  };
}

export function apply(ctx, config) {
  const enginePath = config.enginePath?.trim() || DEFAULT_ENGINE;
  const timeoutMs = config.timeoutMs > 0 ? config.timeoutMs : 60000;
  const outputDir = config.outputDir?.trim() || '';

  if (!existsSync(enginePath)) {
    throw new Error(
      `dsh-desktop-hand: 找不到引擎脚本 ${enginePath}。`
      + '请检查插件安装是否完整，或在 profile 的插件配置里改正 enginePath。',
    );
  }

  const call = makeRunner(ctx, enginePath, timeoutMs);

  /**
   * 最近一次 desktop_capture 预计算好的图片块，供**同步**的 finalizeContent 取用。
   *
   * 为什么需要这个模块级状态：`finalizeContent` 被 dsh-tools 同步调用
   * （applyFinalContent :3402 没有 await），而准备图片块必须 await
   * readFile/saveImage。所以把异步工作提前到 execute()，用这两个变量交接。
   *
   * 并发安全性：desktop_capture 同一时刻只应有一次在途（截图本身是串行资源，
   * 且插件设计约束第 5 条明确要求"一张一张来"）。用 `lastImagePath` 而不是
   * 只用一个 block 变量，是为了让 finalizeContent 能确认"这个块确实属于
   * 你这次 result"，避免把上一次的图错配给这一次。
   */
  let lastImagePath = '';
  let lastImageBlock = null;

  /**
   * 把落盘的 PNG 变成可交给模型的 image 内容块。
   *
   * 走的是 dsh 的附件服务：attachment 引用**只带元数据不带 base64**
   * （dsh-tool-fs 的 read_image 用的是同一套机制）。
   * 没有附件服务或模型不支持图片输入时，降级为纯文本返回路径，
   * 而不是硬失败——路径对人仍然有用。
   */
  async function imageBlock(exec, filePath, mediaType = 'image/png') {
    const attachments = ctx.get('attachments');
    if (attachments === undefined) return null;
    try {
      const data = await readFile(filePath);
      if (data.byteLength > attachments.imageLimits.maxImageBytes) return null;
      if (!attachments.imageLimits.mediaTypes.includes(mediaType)) return null;
      const ref = await attachments.saveImage({ data, mediaType, name: filePath.split(/[\\/]/).pop() });
      return {
        type: 'image',
        attachment: {
          attachmentId: ref.attachmentId,
          mediaType: ref.mediaType,
          bytes: ref.bytes,
          width: ref.width,
          height: ref.height,
          ...(ref.name === undefined ? {} : { name: ref.name }),
        },
      };
    } catch {
      // 附件服务拒绝（超限/不支持/解码失败）不该让"已经抓到图"这次调用失败
      return null;
    }
  }

  /**
   * 截图结果的文字部分。图片块由上方 `finalizeContent` 追加——见那里的注释：
   * `output.schema` 是 additionalProperties:false，图片不能搭返回值的车。
   */
  function shotRender(value) {
    const lines = [
      `<path>${value.path}</path>`,
      `<type>image</type>`,
      `<content>`,
      `${value.width}x${value.height} px, ${value.bytes} bytes, 目标: ${value.target}`,
    ];
    if (value.targetClass) lines.push(`窗口类名: ${value.targetClass}`);
    if (value.crop) {
      lines.push(`裁切区域: ${value.crop}，该区域在屏幕上的左上角为 (${value.originX},${value.originY})`);
    } else if (value.coordScale !== undefined && value.coordScale !== 1) {
      lines.push(`注意：这张图宽 ${value.width} 与物理屏宽 ${value.screenWidth} 不一致，`
        + `点击坐标需乘 ${value.coordScale}。`);
    } else {
      lines.push('图与物理屏 1:1，可直接用图中像素坐标传给 desktop_click。');
    }
    if (value.uwpWarning) {
      lines.push(`⚠️ 底色占比 ${value.dominantPermille ?? '?'}‰、颜色种类 ${value.distinctColors ?? '?'} 个`
        + `${value.targetClass ? `，窗口类名 ${value.targetClass}` : ''}——**比例高不等于空白**：`
        + '计算器这类面板本身大面积同一底色，实测 963‰ 而内容是完整的。以图为准。'
        + '如果图确实是空白壳，说明 PrintWindow 只拿到了 ApplicationFrameWindow 宿主窗口：'
        + '改用 desktop_list_windows 里**同名的另一个句柄**（frameHost=false 的 CoreWindow）重抓，'
        + '或改为全屏抓取（要求窗口可见）。');
    }
    if (value.minimized) lines.push('⚠️ 该窗口当前是最小化的，抓到的内容无意义。');
    lines.push('</content>');
    lines.push('黑像素比例仅供参考，不是成功判据——请看图。'
      + '（实测反例：ApplicationFrameWindow 空白壳只有 16‰，而 SystemSettings 真内容反而 617‰。）');
    return [{ type: 'text', text: lines.join('\n') }];
  }

  // ===================================================================
  //  工具 1：列出窗口
  // ===================================================================
  ctx.tools.register(defineTool({
    name: 'desktop_list_windows',
    description: 'List visible desktop windows on Windows with their handle, process, '
      + 'title, position and size. Use this first to discover the exact title or handle '
      + 'to pass to desktop_capture / desktop_focus, and to check which window is in the '
      + 'foreground. Also reports whether remote-control/streaming tools (GameViewer, '
      + 'ToDesk, Sunlogin, ...) are running, because an active remote session drives the '
      + 'cursor and makes synthetic clicks land unpredictably.',
    parameters: {
      filter: {
        type: 'string',
        description: 'Optional case-insensitive substring; only windows whose title or process name contains it are returned.',
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          count: { type: 'integer', required: true },
          foregroundHandle: { type: 'integer' },
          foregroundTitle: { type: 'string' },
          remoteTools: { type: 'array', required: true, items: { type: 'string' } },
          windows: {
            type: 'array',
            required: true,
            items: {
              type: 'object',
              additionalProperties: false,
              properties: {
                handle: { type: 'integer', required: true },
                pid: { type: 'integer', required: true },
                title: { type: 'string', required: true },
                process: { type: 'string', required: true },
                class: { type: 'string', required: true },
                x: { type: 'integer', required: true },
                y: { type: 'integer', required: true },
                width: { type: 'integer', required: true },
                height: { type: 'integer', required: true },
                uwp: { type: 'boolean', required: true },
                frameHost: { type: 'boolean', required: true },
                minimized: { type: 'boolean', required: true },
              },
            },
          },
        },
      },
      render: (_args, value) => {
        const rows = value.windows.map((w) => {
          // 标注区分宿主壳：同一标题常有两个句柄（真实进程 + ApplicationFrameHost），
          // 以前两个都只打 [UWP]，agent 无从判断该抓哪个，只能盲选。
          const flags = [
            w.frameHost ? 'UWP-宿主/可能空白' : (w.uwp ? 'UWP' : ''),
            w.minimized ? 'MINIMIZED' : '',
          ].filter(Boolean).join(',');
          return `${w.title || '(无标题)'} | handle=${w.handle} pid=${w.pid} `
            + `process=${w.process} ${w.width}x${w.height} at (${w.x},${w.y})`
            + (flags ? ` [${flags}]` : '');
        });
        const parts = [`${value.count} 个可见窗口：`, ...rows.map((r) => `- ${r}`)];
        if (value.foregroundHandle !== undefined) {
          parts.push(`\n当前前台窗口：${value.foregroundTitle ?? '(无标题)'} (handle=${value.foregroundHandle})`);
        }
        if (value.remoteTools.length > 0) {
          parts.push(`\n⚠️ 检测到远程/串流软件：${value.remoteTools.join(', ')}。`
            + '若远端正在操作鼠标，合成点击的落点会被实时覆盖而不可靠'
            + '（先用 desktop_diagnose 确认）。');
        }
        return [{ type: 'text', text: parts.join('\n') }];
      },
    },
    isConcurrencySafe: () => true,
    async execute(args) {
      const payload = await call({ Action: 'list-windows' });
      const all = payload.windows ?? [];
      const filter = args.filter?.trim().toLowerCase();
      const windows = filter
        ? all.filter((w) => (w.title ?? '').toLowerCase().includes(filter)
          || (w.process ?? '').toLowerCase().includes(filter))
        : all;

      // 复用引擎的 info 拿到前台标题与远程软件清单
      let foregroundTitle;
      let remoteTools = [];
      try {
        const info = await call({ Action: 'info' });
        foregroundTitle = info.foreground;
        remoteTools = info.remoteTools ?? [];
      } catch { /* info 失败不影响窗口列表 */ }

      return {
        count: windows.length,
        ...(payload.foregroundHandle === undefined || payload.foregroundHandle === null ? {} : { foregroundHandle: payload.foregroundHandle }),
        ...(foregroundTitle === undefined ? {} : { foregroundTitle: String(foregroundTitle) }),
        remoteTools: remoteTools.map(String),
        // 每个字段都保证不是 undefined —— 见 desktop_capture 里那段关于
        // "tool result must be losslessly JSON-serializable" 的说明：
        // 值为 undefined 的属性会让整份结果被拒，即使工具本身跑成功了。
        windows: windows.map((w) => ({
          handle: Number.isFinite(w.handle) ? w.handle : 0,
          pid: Number.isFinite(w.pid) ? w.pid : 0,
          title: String(w.title ?? ''),
          process: String(w.process ?? ''),
          class: String(w.class ?? ''),
          x: Number.isFinite(w.x) ? w.x : 0,
          y: Number.isFinite(w.y) ? w.y : 0,
          width: Number.isFinite(w.width) ? w.width : 0,
          height: Number.isFinite(w.height) ? w.height : 0,
          uwp: Boolean(w.uwp), frameHost: Boolean(w.frameHost), minimized: Boolean(w.minimized),
        })),
      };
    },
  }));

  // ===================================================================
  //  工具 2：截屏
  // ===================================================================
  ctx.tools.register(defineTool({
    name: 'desktop_capture',
    description: 'Capture the Windows desktop and return the image itself to the current '
      + 'model (no second read_image call needed). Three modes: '
      + '(1) whole virtual screen by default — this is what CopyFromScreen sees, so an '
      + 'occluded window shows whatever covers it; '
      + '(2) a specific window via `window` (title substring) or `handle` — this uses '
      + 'PrintWindow, so it captures the window\'s OWN content even when fully occluded; '
      + '(3) `region` crops the result. '
      + 'Always look at the returned image: the black-pixel ratio is NOT a success test. '
      + 'The real blind spot is ONLY the ApplicationFrameHost shell window '
      + '(class `ApplicationFrameWindow`, listed as [UWP-宿主/可能空白]) — it renders an empty '
      + 'frame. A genuine UWP XAML window (`Windows.UI.Core.CoreWindow`) IS capturable. '
      + 'When the same title shows two handles, capture the one WITHOUT the host marker; '
      + '`uwpWarning` is driven by measured blankness, so trust it and re-capture the other handle.',
    parameters: {
      window: {
        type: 'string',
        description: 'Case-insensitive substring of the target window title. Errors listing all candidates if ambiguous — prefer `handle` then.',
      },
      handle: {
        type: 'integer',
        description: 'Exact window handle from desktop_list_windows. Takes precedence over `window`.',
      },
      region: {
        type: 'string',
        description: 'Crop "x,y,w,h". Coordinates are relative to the captured target (window or screen). Rejected if out of bounds.',
      },
      outPath: {
        type: 'string',
        description: 'Where to save the PNG. Defaults to a timestamped file under the system temp directory.',
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          path: { type: 'string', required: true },
          width: { type: 'integer', required: true },
          height: { type: 'integer', required: true },
          bytes: { type: 'integer', required: true },
          target: { type: 'string', required: true },
          targetClass: { type: 'string' },
          originX: { type: 'integer' },
          originY: { type: 'integer' },
          screenWidth: { type: 'integer' },
          screenHeight: { type: 'integer' },
          coordScale: { type: 'number' },
          crop: { type: 'string' },
          uwpWarning: { type: 'boolean' },
          dominantPermille: { type: 'integer' },
          distinctColors: { type: 'integer' },
          isFrameHost: { type: 'boolean' },
          minimized: { type: 'boolean' },
        },
      },
      render: (_args, value) => shotRender(value),
    },

    /**
     * 图片必须在 render 之外附加：`output.schema` 是 additionalProperties:false，
     * 返回值里塞 `__image` 之类的额外键会被 validateJsonSchemaValue 直接判违规
     * （dsh-tools index.js:3413 抛 ToolOutputError）。
     *
     * ⚠️ **本函数必须保持同步（不能写成 async）**，这是 2026-10-03 那次
     * "tool result must be losslessly JSON-serializable" 故障的真正根因：
     *
     *   官方契约 `ToolDefinition.finalizeContent(exec, result): ContentBlock[] | undefined`
     *   （见 dsh-tool-cordis/lib/types/api-catalog.js:7416）**没有 Promise**，
     *   而调用方 `applyFinalContent`（dsh-tools/lib/index.js:3399-3407）是同步的：
     *
     *       const content = finalizeContent(exec, result);   // ← 没有 await
     *       return content === void 0 ? result : { ...result, content };
     *
     *   写成 async 时 `content` 是一个 **Promise 对象**，紧接着
     *   `materializeFinalResult` → `snapshotJsonValue` 会判定它不是纯 JSON
     *   （Promise 的原型不是 Object.prototype），抛出裸的
     *   `TypeError: tool result must be losslessly JSON-serializable`
     *   （dsh-tools/lib/index.js:2608），且**连已经渲染好的截图文字一起丢掉**
     *   （:3392-3394 把整次成功结果替换成错误）。
     *
     *   这个 bug 极难在插件侧复现，因为任何"把 finalizeContent 的返回值 await 一下
     *   再检查"的实验都会得到"完全合法"的结论——只有真正走 :3402 那条**不 await**
     *   的路径才会暴露。所以：**图片块的异步工作全部提前到 `execute()` 里做完**，
     *   这里只做同步拼装。
     *
     * 顺带说明为什么不能"在 execute 里直接返回图片块"：`output.schema` 是
     * additionalProperties:false，返回值里容不下图片块。
     */
    finalizeContent(exec, result) {
      const path = result.value?.path;
      if (typeof path !== 'string' || path === '') return undefined;
      if (path !== lastImagePath) return undefined;   // 没有对应图片就不动 content
      if (lastImageBlock === null) {
        return [...result.content, {
          type: 'text',
          text: '（图片未能附加到本消息：无附件服务、模型不支持图片输入，或超出图片限额。'
            + '可用 read_image 读取上面的 path。）',
        }];
      }
      return [...result.content, lastImageBlock];
    },

    async execute(args) {
      const params = { Action: 'capture' };
      if (args.handle !== undefined) params.Handle = args.handle;
      else if (args.window !== undefined) params.Window = args.window;
      else params.FullScreen = true;
      if (args.region !== undefined) params.Region = args.region;
      if (args.outPath !== undefined && args.outPath.trim() !== '') params.OutPath = args.outPath;
      else if (outputDir !== '') params.OutPath = join(outputDir, `shot_${Date.now()}.png`);

      const payload = await call(params);

      // 图片块的异步部分（读文件 + 交给附件服务）必须在这里做完。
      // 理由见上面 finalizeContent 的注释：那个钩子被同步调用，不能返回 Promise。
      // 放在截图成功之后、返回 value 之前；失败（含无附件服务）记 null，
      // 由 execute()/finalizeContent 决定降级文案。
      lastImagePath = String(payload.path ?? '');
      lastImageBlock = null;
      if (lastImagePath !== '') {
        lastImageBlock = await imageBlock(null, lastImagePath);
      }

      // ⚠️ 每个字段都必须**保证不是 undefined**。
      //
      // 为什么（真实故障，2026-10-01）：dsh-tools 在 materializePresentation
      // 里用 snapshotJsonValue 校验最终结果，而 snapshotJsonValue 对
      // **值为 undefined 的属性**直接判非法（不是转成 null，是整份拒绝），
      // 抛出：
      //     TypeError: tool result must be losslessly JSON-serializable
      //     （dsh-tools/lib/index.js:2604）
      // 一旦引擎因为任何原因少给一个字段，这里就会静默产生 undefined 属性，
      // 于是"截图明明成功了"却报一个和截图毫无关系的序列化错误。
      //
      // 注意与 schema 校验的区别：additionalProperties:false 管的是"多余的键"，
      // 这里管的是"值是 undefined 的键"，两者报错文案完全不同。
      //
      // 所以：必需的用 ?? 兜底，可选的用展开语法跳过（不能写成 key: undefined）。
      return {
        path: String(payload.path ?? ''),
        width: Number.isFinite(payload.width) ? payload.width : 0,
        height: Number.isFinite(payload.height) ? payload.height : 0,
        bytes: Number.isFinite(payload.bytes) ? payload.bytes : 0,
        target: String(payload.target ?? ''),
        ...(payload.targetClass ? { targetClass: String(payload.targetClass) } : {}),
        ...(payload.originX === undefined || payload.originX === null ? {} : { originX: payload.originX }),
        ...(payload.originY === undefined || payload.originY === null ? {} : { originY: payload.originY }),
        ...(payload.screenWidth === undefined || payload.screenWidth === null ? {} : { screenWidth: payload.screenWidth }),
        ...(payload.screenHeight === undefined || payload.screenHeight === null ? {} : { screenHeight: payload.screenHeight }),
        ...(payload.coordScale === undefined || payload.coordScale === null ? {} : { coordScale: payload.coordScale }),
        ...(args.region ? { crop: args.region } : {}),
        ...(payload.uwpWarning ? { uwpWarning: true } : {}),
        ...(Number.isFinite(payload.dominantPermille) ? { dominantPermille: payload.dominantPermille } : {}),
        ...(Number.isFinite(payload.distinctColors) ? { distinctColors: payload.distinctColors } : {}),
        ...(payload.isFrameHost ? { isFrameHost: true } : {}),
        ...(payload.minimized ? { minimized: true } : {}),
      };
    },
  }));

  // ===================================================================
  //  工具 3：聚焦窗口
  // ===================================================================
  ctx.tools.register(defineTool({
    name: 'desktop_focus',
    description: 'Bring a window to the foreground so that keyboard input reaches it. '
      + 'Uses SetForegroundWindow with an AttachThreadInput + ALT-nudge fallback, and '
      + 'reports whether the window really became foreground (SetForegroundWindow can '
      + 'return success while the foreground lock blocks it). If this reports failure, '
      + 'click on the window body with desktop_click first — a real click obtains '
      + 'activation when the API cannot.',
    parameters: {
      window: { type: 'string', description: 'Case-insensitive substring of the window title.' },
      handle: { type: 'integer', description: 'Exact window handle; takes precedence over `window`.' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          focused: { type: 'boolean', required: true },
          result: { type: 'string', required: true },
          target: { type: 'string' },
          foregroundTitle: { type: 'string' },
        },
      },
      render: (_args, value) => [{
        type: 'text',
        text: value.focused
          ? `已聚焦：${value.target}（当前前台：${value.foregroundTitle}）`
          : `聚焦失败（${value.result}）。改用 desktop_click 在目标窗口体上点一下拿到激活，再输入。`
            + `当前前台：${value.foregroundTitle}`,
      }],
    },
    async execute(args) {
      const params = { Action: 'focus' };
      if (args.handle !== undefined) params.Handle = args.handle;
      else if (args.window !== undefined) params.Window = args.window;
      else throw new Error('desktop_focus 需要 window 或 handle 之一。');

      const payload = await call(params);
      const focused = payload.result === 'ok' || payload.result === 'already-foreground';
      return {
        focused,
        result: String(payload.result ?? 'unknown'),
        ...(payload.target ? { target: payload.target } : {}),
        ...(payload.foreground ? { foregroundTitle: payload.foreground } : {}),
      };
    },
  }));

  // ===================================================================
  //  工具 4：鼠标点击 / 拖动
  // ===================================================================
  ctx.tools.register(defineTool({
    name: 'desktop_click',
    description: 'Click, double-click, right-click or drag on the Windows desktop at the '
      + 'given coordinates. Coordinates are pixels in the image returned by '
      + 'desktop_capture; pass that image\'s width as `shotWidth` when it does not match '
      + 'the physical screen width (the capture result tells you). '
      + 'IMPORTANT: synthetic clicks fail silently-but-visibly when a remote-control '
      + 'session is driving the real cursor — run desktop_diagnose if clicks land wrong. '
      + 'Prefer clicking the window body first to give it focus, then desktop_type.',
    parameters: {
      x: { type: 'integer', description: 'X in screenshot pixels. Required unless `target` is given.' },
      y: { type: 'integer', description: 'Y in screenshot pixels. Required unless `target` is given.' },
      target: {
        type: 'string',
        description: 'Visible name of a control to click by name (UI Automation), instead of coordinates. Uses the exact match when there are several; pass `role` or a longer name to disambiguate. See desktop_ui_tree for available names.',
      },
      role: { type: 'string', description: 'With `target`: restrict matching to a UIA control type, e.g. Button or ListItem.' },
      window: { type: 'string', description: 'With `target`: window title substring to search in. Defaults to the foreground window.' },
      handle: { type: 'integer', description: 'With `target`: exact window handle; takes precedence over `window`.' },
      shotWidth: {
        type: 'integer',
        description: 'Width of the screenshot these coordinates were read from. Omit when the screenshot is 1:1 with the physical screen.',
      },
      double: { type: 'boolean', description: 'Double-click.' },
      right: { type: 'boolean', description: 'Right-click.' },
      toX: { type: 'integer', description: 'Drag: destination X. Requires toY.' },
      toY: { type: 'integer', description: 'Drag: destination Y. Requires toX.' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          action: { type: 'string', required: true },
          screenX: { type: 'integer', required: true },
          screenY: { type: 'integer', required: true },
          cursor: { type: 'string', required: true },
          cursorMatched: { type: 'boolean', required: true },
          targetName: { type: 'string' },
          targetRole: { type: 'string' },
          window: { type: 'string' },
        },
      },
      render: (_args, value) => {
        // target 模式多报一句「点中了哪个控件」，比只给坐标有用得多。
        if (value.targetName !== undefined) {
          return [{
            type: 'text',
            text: '已在窗口 "' + (value.window ?? '') + '" 里点中控件 '
              + (value.targetRole ? '[' + value.targetRole + '] ' : '')
              + '"' + value.targetName + '" @(' + value.screenX + ',' + value.screenY + ')。'
              + (value.cursorMatched
                ? '光标就在落点上，点击已生效——用 desktop_capture 或 desktop_ui_tree 确认效果。'
                : '⚠️ 光标没停在落点（现为 ' + value.cursor + '）：有别的输入源在驱动鼠标，这次点击可能落到别处。'),
          }];
        }
        return [{
          type: 'text',
          text: `${value.action} 落在屏幕物理坐标 (${value.screenX},${value.screenY})，`
            + `光标现为 (${value.cursor})。`
            + (value.cursorMatched
              ? '落点与目标一致，点击应已生效——用 desktop_capture 看图确认。'
              : '⚠️ 光标未停在目标位置：有别的输入源在驱动鼠标（通常是远程会话）。'
                + '这次点击的落点不可信，请等远端空闲后重试。'),
        }];
      },
    },
    async execute(args) {
      // ---- v1.1：按控件名点（target 模式），不必先截图量坐标 ----
      const targetName = typeof args.target === 'string' ? args.target.trim() : '';
      if (targetName !== '') {
        if (args.toX !== undefined || args.toY !== undefined) {
          throw new Error('desktop_click 的 target 模式不支持拖拽；拖拽请用 x/y + toX/toY。');
        }
        const tp = { Action: 'click', Target: targetName };
        if (args.role !== undefined) tp.Role = args.role;
        if (args.window !== undefined) tp.Window = args.window;
        if (args.handle !== undefined) tp.Handle = args.handle;
        if (args.double) tp.Double = true;
        if (args.right) tp.Right = true;
        const byName = await call(tp);
        const [tx, ty] = String(byName.phys ?? '').split(',').map((s) => Number.parseInt(s, 10));
        const [bx, by2] = String(byName.cursor ?? '').split(',').map((s) => Number.parseInt(s, 10));
        const landed = Number.isFinite(bx) && Number.isFinite(tx)
          && Math.abs(bx - tx) <= 3 && Math.abs(by2 - ty) <= 3;
        return {
          action: String(byName.action ?? 'click-target'),
          screenX: Number.isFinite(tx) ? tx : 0,
          screenY: Number.isFinite(ty) ? ty : 0,
          cursor: String(byName.cursor ?? ''),
          cursorMatched: landed,
          ...(byName.targetName === undefined ? {} : { targetName: String(byName.targetName) }),
          ...(byName.targetRole === undefined ? {} : { targetRole: String(byName.targetRole) }),
          ...(byName.window === undefined ? {} : { window: String(byName.window) }),
        };
      }
      if (args.x === undefined || args.y === undefined) {
        throw new Error('desktop_click 需要 (x,y) 坐标，或 target 控件名（先用 desktop_ui_tree 看有哪些控件）。');
      }
      const params = { Action: 'click', X: args.x, Y: args.y };
      if (args.shotWidth !== undefined) params.ShotWidth = args.shotWidth;
      if (args.double) params.Double = true;
      if (args.right) params.Right = true;
      if (args.toX !== undefined && args.toY !== undefined) {
        params.ToX = args.toX;
        params.ToY = args.toY;
      }

      const payload = await call(params);
      const target = args.toX !== undefined && args.toY !== undefined
        ? (payload.toPhys ?? '')
        : (payload.phys ?? '');
      const [cx, cy] = target.split(',').map((s) => Number.parseInt(s, 10));
      const [ax, ay] = String(payload.cursor ?? '').split(',').map((s) => Number.parseInt(s, 10));
      // 落点校验：容差 3px，覆盖 Windows 的指针吸附/取整
      const matched = Number.isFinite(ax) && Number.isFinite(cx)
        && Math.abs(ax - cx) <= 3 && Math.abs(ay - cy) <= 3;

      return {
        action: String(payload.action ?? 'click'),
        screenX: Number.isFinite(cx) ? cx : 0,
        screenY: Number.isFinite(cy) ? cy : 0,
        cursor: String(payload.cursor ?? ''),
        cursorMatched: matched,
      };
    },
  }));

  // ===================================================================
  //  工具 5：键盘输入
  // ===================================================================
  ctx.tools.register(defineTool({
    name: 'desktop_type',
    description: 'Type text into the foreground window, or send a single key / key combo. '
      + 'Text is injected with SendInput + KEYEVENTF_UNICODE, which BYPASSES the active '
      + 'IME — this matters: the older VkKeyScan/keybd_event route gets mangled by a '
      + 'Chinese IME (typing "third batch" once arrived as the characters for "第三批"). '
      + 'Make sure the target window is focused first (desktop_focus, or desktop_click on '
      + 'its body). Reports which window was actually in the foreground when the input '
      + 'was delivered, so a misfire is visible instead of silent.',
    parameters: {
      text: {
        type: 'string',
        description: 'Text to type. Unicode, so Chinese and format specifiers work. Requires `key` to be omitted.',
      },
      key: {
        type: 'string',
        description: 'One key or combo instead of text: enter, esc, tab, space, backspace, delete, up, down, left, right, home, end, pageup, pagedown, f1-f12, ctrl+a, ctrl+c, ctrl+v, ctrl+s, ctrl+w, ctrl+x, ctrl+z, alt+f4.',
      },
      enter: { type: 'boolean', description: 'With `text`: press Enter after typing.' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          mode: { type: 'string', required: true },
          chars: { type: 'integer' },
          key: { type: 'string' },
          enter: { type: 'boolean' },
          foregroundTitle: { type: 'string', required: true },
        },
      },
      render: (_args, value) => [{
        type: 'text',
        text: value.key !== undefined
          ? `已发送按键 ${value.key}。输入送达时的前台窗口：${value.foregroundTitle || '(无标题)'}`
          : `已输入 ${value.chars} 个字符${value.enter ? ' 并回车' : ''}（${value.mode}）。`
            + `输入送达时的前台窗口：${value.foregroundTitle || '(无标题)'}`
            + `\n如果这不是你预期的目标，说明焦点不对：先用 desktop_focus 或 desktop_click 聚焦。`,
      }],
    },
    async execute(args, exec) {
      exec.signal?.throwIfAborted?.();
      if (args.key !== undefined && args.text !== undefined) {
        throw new Error('desktop_type 的 text 和 key 只能给一个。');
      }
      if (args.key === undefined && (args.text === undefined || args.text === '')) {
        throw new Error('desktop_type 需要 text 或 key 之一。');
      }

      if (args.key !== undefined) {
        const payload = await call({ Action: 'key', Key: args.key });
        return {
          mode: 'key',
          key: String(payload.key ?? args.key),
          foregroundTitle: String(payload.foreground ?? ''),
        };
      }

      const params = { Action: 'type', Text: args.text };
      if (args.enter) params.Enter = true;
      const payload = await call(params);
      return {
        mode: String(payload.mode ?? 'unicode'),
        chars: Number(payload.chars ?? 0),
        enter: Boolean(payload.enter),
        foregroundTitle: String(payload.foreground ?? ''),
      };
    },
  }));

  // ===================================================================
  //  工具 6：体检
  // ===================================================================
  ctx.tools.register(defineTool({
    name: 'desktop_diagnose',
    description: 'Check whether synthetic mouse/keyboard input can be trusted on this '
      + 'machine right now, and explain any problem. Run this FIRST whenever a click '
      + 'lands in the wrong place or keyboard input disappears. It sets the cursor and '
      + 'then samples its position repeatedly: a smoothly drifting cursor means another '
      + 'input source (typically an active remote-control session such as GameViewer) is '
      + 'overriding synthetic coordinates, in which case no amount of coordinate tweaking '
      + 'will help — wait for the remote session to go idle. It also reports DPI '
      + 'awareness, screen size, the foreground window and the IME state.',
    parameters: {},
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          healthy: { type: 'boolean', required: true },
          verdict: { type: 'string', required: true },
          stable: { type: 'boolean', required: true },
          probeA: { type: 'string' },
          probeB: { type: 'string' },
          screenWidth: { type: 'integer' },
          screenHeight: { type: 'integer' },
          dpiMode: { type: 'string' },
          foregroundTitle: { type: 'string' },
          ime: { type: 'string' },
          remoteTools: { type: 'array', required: true, items: { type: 'string' } },
        },
      },
      render: (_args, value) => [{
        type: 'text',
        text: [
          value.healthy ? '✅ 合成输入可信：光标落点稳定。' : '❌ 合成输入不可信，原因见下。',
          '',
          `判定：${value.verdict}`,
          `屏幕：${value.screenWidth}x${value.screenHeight}（DPI 感知：${value.dpiMode}）`,
          `前台窗口：${value.foregroundTitle || '(无标题)'}`,
          `输入法：${value.ime}`,
          `远程/串流软件：${value.remoteTools.length > 0 ? value.remoteTools.join(', ') : '未检测到'}`,
          '',
          `光标落点采样 A：${value.probeA}`,
          `光标落点采样 B：${value.probeB}`,
        ].join('\n'),
      }],
    },
    async execute() {
      const info = await call({ Action: 'info' });
      const probe = await call({ Action: 'probe', X: 400, Y: 400 });
      const a = String(probe.probeA ?? '');
      const b = String(probe.probeB ?? '');
      // 两次采样都以 "400,400" 开头 → 光标没有被推走
      const stable = /^400,400/.test(a.trim()) && /^400,400/.test(b.trim());

      let verdict;
      if (stable) {
        verdict = '落点稳定，鼠标点击可用。';
      } else if ((info.remoteTools ?? []).length > 0) {
        verdict = '光标被持续推走，且本机装有以下远程/串流软件：'
          + `${(info.remoteTools ?? []).join(', ')}。`
          + '极可能是远端有人正在操作鼠标，合成坐标被实时覆盖。'
          + '这不是插件缺陷：请等远端停止操作后重试。'
          + '也可考虑改用浏览器内自动化（pilot_* 工具走 CDP，不碰光标）。';
      } else {
        verdict = '光标被持续推走，但未检测到常见远程/串流软件。'
          + '请确认是否有物理鼠标被压住/漂移，或其它注入设备。';
      }

      return {
        healthy: stable,
        verdict: String(verdict),
        stable,
        probeA: String(a),
        probeB: String(b),
        ...(info.screenWidth === undefined || info.screenWidth === null ? {} : { screenWidth: info.screenWidth }),
        ...(info.screenHeight === undefined || info.screenHeight === null ? {} : { screenHeight: info.screenHeight }),
        ...(info.dpiMode === undefined ? {} : { dpiMode: String(info.dpiMode) }),
        ...(info.foreground === undefined ? {} : { foregroundTitle: String(info.foreground) }),
        ...(info.ime === undefined ? {} : { ime: String(info.ime) }),
        remoteTools: Array.isArray(info.remoteTools) ? info.remoteTools.map(String) : [],
      };
    },
  }));

  // ===================================================================
  //  工具 7：把窗口读成 UI Automation 语义树
  // ===================================================================
  // 为什么值得单独一个工具：PrintWindow 抓不到的窗口（ApplicationFrameWindow
  // 空白壳）在 UIA 树里是完好的；而且知道了控件名和边界矩形，
  // 「点那个按钮」就不必先截图量坐标了。这是吸收 copylee 那类
  // computer-use 插件的核心优点，但**不接管屏幕、不自动回图**。
  try {
    ctx.tools.register(defineTool({
      name: 'desktop_ui_tree',
    description: 'Read a window as a UI Automation tree: roles, names, values and '
      + 'per-control screen rectangles. This is the reliable way to understand a window '
      + 'when desktop_capture returns a blank shell (ApplicationFrameWindow / UWP host), '
      + 'and it lets you click a control by name instead of measuring pixels. Pass '
      + 'flat: true to get the tree as indented plain text (much cheaper to read). Use '
      + 'role to filter a large tree. Nodes with invokable: true can be activated, and '
      + 'their centerX/centerY is a safe click point.',
    parameters: {
      window: { type: 'string', description: 'Case-insensitive substring of the window title. Defaults to the foreground window.' },
      handle: { type: 'integer', description: 'Exact window handle; takes precedence over window.' },
      depth: { type: 'integer', description: 'Max tree depth to walk (default 3, clamped to 32). Use 1-2 for a quick top-level survey of a big window.' },
      maxNodes: { type: 'integer', description: 'Max nodes to return (default 200). Check the truncated flag in the result.' },
      role: { type: 'string', description: 'Only include controls of this UIA control type, e.g. Button, Text, Edit, ListItem, Hyperlink.' },
      all: { type: 'boolean', description: 'Include controls that are scrolled out of view or not rendered (default false).' },
      flat: { type: 'boolean', description: 'Also return the tree as indented plain text under text (indentation = depth).' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          target: { type: 'string', required: true },
          count: { type: 'integer', required: true },
          truncated: { type: 'boolean', required: true },
          isFrameHost: { type: 'boolean', required: true },
          minimized: { type: 'boolean', required: true },
          text: { type: 'string' },
          nodes: {
            type: 'array',
            required: true,
            items: {
              type: 'object',
              additionalProperties: false,
              properties: {
                depth: { type: 'integer', required: true },
                role: { type: 'string', required: true },
                name: { type: 'string', required: true },
                value: { type: 'string', required: true },
                automationId: { type: 'string' },
                offscreen: { type: 'boolean' },
                centerX: { type: 'integer', required: true },
                centerY: { type: 'integer', required: true },
                width: { type: 'integer', required: true },
                height: { type: 'integer', required: true },
                enabled: { type: 'boolean', required: true },
                invokable: { type: 'boolean', required: true },
              },
            },
          },
        },
      },
      render: (_args, value) => {
        const parts = ['窗口 "' + value.target + '" 的 UIA 树：' + value.count + ' 个控件'
          + (value.truncated ? '（已截断：缩小 depth 或加大 maxNodes）' : '')];
        if (value.minimized) parts.push('⚠️ 该窗口最小化，UIA 树可能不全——先 desktop_focus 还原。');
        if (typeof value.text === 'string' && value.text !== '') {
          parts.push('<content>', value.text, '</content>');
        } else {
          const shown = value.nodes.slice(0, 120);
          for (const n of shown) {
            let line = '  '.repeat(Math.min(n.depth, 12)) + n.role;
            if (n.name !== '') line += ' "' + n.name + '"';
            if (n.value !== '') line += ' = ' + n.value.slice(0, 200);
            if (n.invokable) line += ' @' + n.centerX + ',' + n.centerY;
            parts.push(line);
          }
          if (value.nodes.length > shown.length) {
            parts.push('...（还有 ' + (value.nodes.length - shown.length)
              + ' 个节点未显示；用 flat:true 或加 role 过滤）');
          }
        }
        if (value.isFrameHost) {
          parts.push('（该句柄是 ApplicationFrameHost 宿主壳：PrintWindow 抓它是空白，'
            + 'UIA 树却是真的——这正是它的用处。）');
        }
        parts.push('点控件用 desktop_click 的 target 参数（名字要够唯一）；要坐标就用上面的 @x,y。');
        return [{ type: 'text', text: parts.join('\n') }];
      },
    },
    isConcurrencySafe: () => true,
    async execute(args) {
      const params = { Action: 'ui-tree' };
      if (args.handle !== undefined) params.Handle = args.handle;
      if (args.window !== undefined) params.Window = args.window;
      if (args.depth !== undefined) params.Depth = args.depth;
      if (args.maxNodes !== undefined) params.MaxNodes = args.maxNodes;
      if (args.role !== undefined) params.Role = args.role;
      if (args.all) params.AllNodes = true;
      if (args.flat) params.Flat = true;
      const payload = await call(params);
      const raw = Array.isArray(payload.nodes) ? payload.nodes : [];
      // 每个字段都保证有值：值为 undefined 的属性会让整份结果被拒
      //（见 desktop_capture 里关于 losslessly JSON-serializable 的说明）。
      const nodes = raw.map((n) => ({
        depth: Number.isFinite(n.depth) ? n.depth : 0,
        role: String(n.role ?? ''),
        name: String(n.name ?? ''),
        value: String(n.value ?? ''),
        automationId: String(n.automationId ?? ''),
        offscreen: Boolean(n.offscreen),
        centerX: Number.isFinite(n.centerX) ? n.centerX : 0,
        centerY: Number.isFinite(n.centerY) ? n.centerY : 0,
        width: Number.isFinite(n.width) ? n.width : 0,
        height: Number.isFinite(n.height) ? n.height : 0,
        enabled: Boolean(n.enabled),
        invokable: Boolean(n.invokable),
      }));
      return {
        target: String(payload.target ?? ''),
        count: nodes.length,
        truncated: Boolean(payload.truncated),
        isFrameHost: Boolean(payload.isFrameHost),
        minimized: Boolean(payload.minimized),
        ...(typeof payload.text === 'string' ? { text: payload.text } : {}),
        nodes,
      };
    },
    }));
  } catch (error) {
    ctx.logger?.warn?.('dsh-desktop-hand: 注册 desktop_ui_tree 失败，该工具不可用：' + (error?.message ?? error));
  }

  // ===================================================================
  //  工具 8：滚轮
  // ===================================================================
  // 滚动是按**鼠标位置**生效的：要滚哪个区域，就把点放在那个区域里。
  // 这是坐标点击最常缺的一半能力——能点不能滚，翻长列表就得拖滚动条。
  try {
    ctx.tools.register(defineTool({
      name: 'desktop_scroll',
    description: 'Scroll the mouse wheel at a point (or at the center of a window). Use it '
      + 'to page through lists, web views and documents without dragging scrollbars. '
      + 'delta is in wheel notches: positive scrolls down/right, negative scrolls up/left (one notch '
      + 'is about 3 lines in most apps; delta -5 is a comfortable page-down). Scrolling '
      + 'applies to whatever is under the pointer, so aim it at the list, not at the '
      + 'window title. Coordinates follow the desktop_click convention.',
    parameters: {
      x: { type: 'integer', description: 'X in screenshot pixels. Omit both x and y to scroll at the cursor (or window center with window/handle).' },
      y: { type: 'integer', description: 'Y in screenshot pixels.' },
      delta: { type: 'integer', description: 'Wheel notches; negative scrolls down. Default 3.' },
      horizontal: { type: 'boolean', description: 'Scroll horizontally instead of vertically.' },
      shotWidth: { type: 'integer', description: 'Width of the screenshot the coordinates were read from.' },
      window: { type: 'string', description: 'Scroll at the center of this window (title substring) when x/y are omitted.' },
      handle: { type: 'integer', description: 'Window handle; takes precedence over window.' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          action: { type: 'string', required: true },
          atX: { type: 'integer', required: true },
          atY: { type: 'integer', required: true },
          delta: { type: 'integer', required: true },
          horizontal: { type: 'boolean', required: true },
          cursor: { type: 'string', required: true },
          foregroundTitle: { type: 'string' },
        },
      },
      render: (_args, value) => [{
        type: 'text',
        text: '已' + (value.horizontal ? '水平' : '垂直') + '滚动 ' + value.delta + ' 格，'
          + '鼠标位于 (' + value.atX + ',' + value.atY + ')，'
          + '前台窗口：' + (value.foregroundTitle || '(未知)')
          + '。\n滚动只对指针下的区域生效：如果页面没动，先把点放到列表/正文区域里再滚。',
      }],
    },
    async execute(args) {
      const params = { Action: 'scroll', Delta: args.delta ?? 3 };
      if (args.x !== undefined) params.X = args.x;
      if (args.y !== undefined) params.Y = args.y;
      if (args.shotWidth !== undefined) params.ShotWidth = args.shotWidth;
      if (args.horizontal) params.Horizontal = true;
      if (args.window !== undefined) params.Window = args.window;
      if (args.handle !== undefined) params.Handle = args.handle;
      const payload = await call(params);
      return {
        action: String(payload.action ?? 'scroll'),
        atX: Number.isFinite(payload.atX) ? payload.atX : 0,
        atY: Number.isFinite(payload.atY) ? payload.atY : 0,
        delta: Number.isFinite(payload.delta) ? payload.delta : Number(args.delta ?? 3),
        horizontal: Boolean(payload.horizontal),
        cursor: String(payload.cursor ?? ''),
        ...(payload.foreground === undefined ? {} : { foregroundTitle: String(payload.foreground) }),
      };
    },
    }));
  } catch (error) {
    ctx.logger?.warn?.('dsh-desktop-hand: 注册 desktop_scroll 失败，该工具不可用：' + (error?.message ?? error));
  }

  // ===================================================================
  //  工具 9：剪贴板
  // ===================================================================
  // 在应用之间搬文本，走剪贴板比 ctrl+a / ctrl+c 可靠得多（后者依赖焦点、
  // 还怕把已有选区弄乱）。写的时候可以把原内容带回来，用完还回去。
  try {
    ctx.tools.register(defineTool({
      name: 'desktop_clipboard',
    description: 'Read or write the Windows clipboard. Far more reliable than ctrl+a / '
      + 'ctrl+c for moving text between apps, and it does not disturb keyboard state. '
      + 'mode "get" returns the current text; mode "set" writes text. Pass '
      + 'keepPrevious: true on a write to get the old content back so you can restore it '
      + 'afterwards - the user may have had something useful copied.',
    parameters: {
      mode: { type: 'string', description: 'Either "get" (default) or "set".' },
      text: { type: 'string', description: 'Text to put on the clipboard (mode "set"); an empty string is allowed.' },
      keepPrevious: { type: 'boolean', description: 'With mode "set": also return the previous clipboard text.' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          mode: { type: 'string', required: true },
          chars: { type: 'integer', required: true },
          text: { type: 'string' },
          previous: { type: 'string' },
        },
      },
      render: (_args, value) => {
        if (value.mode === 'set') {
          const parts = ['已把 ' + value.chars + ' 个字符写入剪贴板。'];
          if (value.previous !== undefined) {
            parts.push('原剪贴板内容（' + value.previous.length + ' 字符）一并返回，需要的话可以再 set 回去：');
            parts.push('<content>');
            parts.push(value.previous.slice(0, 1500)
              + (value.previous.length > 1500 ? '\n...(已截断)' : ''));
            parts.push('</content>');
          }
          return [{ type: 'text', text: parts.join('\n') }];
        }
        const t = value.text ?? '';
        return [{
          type: 'text',
          text: '剪贴板里有 ' + value.chars + ' 个字符：\n<content>\n'
            + t.slice(0, 4000)
            + (t.length > 4000 ? '\n...(已截断，共 ' + t.length + ' 字符)' : '')
            + '\n</content>',
        }];
      },
    },
    async execute(args) {
      const mode = (args.mode ?? 'get').trim().toLowerCase();
      const params = { Action: 'clipboard', Mode: mode };
      if (mode === 'set') {
        if (typeof args.text !== 'string') {
          throw new Error('desktop_clipboard 的 mode=set 需要 text（空字符串也要显式给）。');
        }
        params.Text = args.text;
        if (args.keepPrevious) params.KeepPrevious = true;
      }
      const payload = await call(params);
      return {
        mode: String(payload.mode ?? mode),
        chars: Number.isFinite(payload.chars) ? payload.chars : 0,
        ...(typeof payload.text === 'string' ? { text: payload.text } : {}),
        ...(typeof payload.previous === 'string' ? { previous: payload.previous } : {}),
      };
    },
    }));
  } catch (error) {
    ctx.logger?.warn?.('dsh-desktop-hand: 注册 desktop_clipboard 失败，该工具不可用：' + (error?.message ?? error));
  }

  // ===================================================================
  //  工具 10：等条件
  // ===================================================================
  // 以前写 desktop 流程只能 Start-Sleep 猜时间：短了没加载完，长了白等。
  // 这个工具把「等某个窗口/控件出现」做成可等待条件，一次调用定成败。
  try {
    ctx.tools.register(defineTool({
      name: 'desktop_wait',
    description: 'Wait for a desktop condition instead of sleeping blindly: until "window" '
      + '(a window whose title contains target appears), until "gone" (it disappears, e.g. '
      + 'a progress dialog closes), or until "text" (a control whose name contains target '
      + 'appears in a window - the robust way to wait for an app to finish loading). '
      + 'Polls every pollMs up to waitMs, then fails with TIMEOUT. Keep waitMs below the '
      + 'plugin timeout (default 60s, config timeoutMs) or the engine gets killed first.',
    parameters: {
      until: { type: 'string', description: '"window" (default), "gone", or "text".' },
      target: { type: 'string', required: true, description: 'Window title substring, or (until "text") the control name substring.' },
      window: { type: 'string', description: 'Until "text": which window to search (title substring). Defaults to the foreground window.' },
      handle: { type: 'integer', description: 'Until "text": exact window handle.' },
      role: { type: 'string', description: 'Until "text": restrict to a UIA control type, e.g. Button.' },
      waitMs: { type: 'integer', description: 'Max wait in ms (default 10000).' },
      pollMs: { type: 'integer', description: 'Poll interval in ms (default 250, min 50).' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          satisfied: { type: 'boolean', required: true },
          until: { type: 'string', required: true },
          target: { type: 'string', required: true },
          elapsedMs: { type: 'integer', required: true },
          detail: { type: 'string', required: true },
          matches: { type: 'array', required: true, items: { type: 'string' } },
        },
      },
      render: (_args, value) => {
        const parts = ['条件已满足：until=' + value.until + '，target="' + value.target
          + '"，用时 ' + value.elapsedMs + 'ms。', '判定依据：' + value.detail];
        if (value.matches.length > 0) parts.push('匹配：' + value.matches.join(' | '));
        parts.push('接着用 desktop_capture 或 desktop_ui_tree 看现在的状态，别假设下一步一定成功。');
        return [{ type: 'text', text: parts.join('\n') }];
      },
    },
    async execute(args) {
      const params = { Action: 'wait', Target: args.target };
      if (args.until !== undefined) params.Until = args.until;
      if (args.window !== undefined) params.Window = args.window;
      if (args.handle !== undefined) params.Handle = args.handle;
      if (args.role !== undefined) params.Role = args.role;
      if (args.waitMs !== undefined) params.WaitMs = args.waitMs;
      if (args.pollMs !== undefined) params.PollMs = args.pollMs;
      const payload = await call(params);
      const matches = Array.isArray(payload.matches) ? payload.matches.map(String) : [];
      return {
        satisfied: Boolean(payload.satisfied),
        until: String(payload.until ?? 'window'),
        target: String(payload.target ?? args.target),
        elapsedMs: Number.isFinite(payload.elapsedMs) ? payload.elapsedMs : 0,
        detail: String(payload.detail ?? ''),
        matches,
      };
    },
    }));
  } catch (error) {
    ctx.logger?.warn?.('dsh-desktop-hand: 注册 desktop_wait 失败，该工具不可用：' + (error?.message ?? error));
  }

  // ===================================================================
  //  工具 11：启动应用
  // ===================================================================
  // 走开始菜单/桌面快捷方式，而不是"点开始按钮 → 打字 → 回车"。
  // 后者依赖任务栏图标坐标（本机还居中）和输入法状态，一错就点到别处。
  try {
    ctx.tools.register(defineTool({
      name: 'desktop_open_app',
    description: 'Start an application by name: searches Start Menu and desktop shortcuts, '
      + 'and falls back to the Start-menu app list so Store/MSIX apps (记事本, 计算器, 照片…) '
      + 'work too - no typing into the Start Menu, no guessed taskbar coordinates. Waits '
      + 'for a window to appear and returns the titles found. If the app is already '
      + 'running this does not help: use desktop_list_windows to find its window instead.',
    parameters: {
      app: { type: 'string', required: true, description: 'Name fragment of the app or shortcut, e.g. 记事本, Notepad, Word, Chrome.' },
      waitMs: { type: 'integer', description: 'Max wait for a window in ms (default 10000).' },
      noWait: { type: 'boolean', description: 'Launch and return immediately, without waiting for a window.' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          launched: { type: 'boolean', required: true },
          path: { type: 'string', required: true },
          pid: { type: 'integer', required: true },
          titles: { type: 'array', required: true, items: { type: 'string' } },
          waitedMs: { type: 'integer', required: true },
          candidates: { type: 'array', required: true, items: { type: 'string' } },
          // MSIX/Store 应用没有 .lnk：引擎按 AppID 调起，pid 拿不到，matchedBy=new-window。
          appId: { type: 'string' },
          appName: { type: 'string' },
          matchedBy: { type: 'string' },
        },
      },
      render: (_args, value) => {
        const what = value.appId
          ? (value.appName || value.appId) + '（MSIX 应用，AppID ' + value.appId + '）'
          : value.path + '（pid ' + value.pid + '）';
        const parts = ['已启动：' + what];
        if (value.titles.length > 0) {
          parts.push('已出现窗口：' + value.titles.join(' | ') + '（等待 ' + value.waitedMs + 'ms'
            + (value.matchedBy === 'new-window' ? '，按"启动后新出现的窗口"认领' : '') + '）');
        } else {
          parts.push('等了 ' + value.waitedMs + 'ms 还没看到窗口：可能仍在启动，'
            + '也可能它是个托盘/后台应用。用 desktop_list_windows 再找一次。');
        }
        if (value.candidates.length > 1) {
          parts.push('其它候选快捷方式（换 app 名称可选中）：' + value.candidates.slice(1, 6).join(' | '));
        }
        return [{ type: 'text', text: parts.join('\n') }];
      },
    },
    async execute(args) {
      const params = { Action: 'open-app', Target: args.app };
      if (args.waitMs !== undefined) params.WaitMs = args.waitMs;
      if (args.noWait) params.NoWait = true;
      const payload = await call(params);
      return {
        launched: Boolean(payload.launched),
        path: String(payload.path ?? ''),
        pid: Number.isFinite(payload.pid) ? payload.pid : 0,
        titles: Array.isArray(payload.titles) ? payload.titles.map(String) : [],
        waitedMs: Number.isFinite(payload.waitedMs) ? payload.waitedMs : 0,
        candidates: Array.isArray(payload.candidates) ? payload.candidates.map(String) : [],
        ...(payload.appId ? { appId: String(payload.appId) } : {}),
        ...(payload.appName ? { appName: String(payload.appName) } : {}),
        ...(payload.matchedBy ? { matchedBy: String(payload.matchedBy) } : {}),
      };
    },
    }));
  } catch (error) {
    ctx.logger?.warn?.('dsh-desktop-hand: 注册 desktop_open_app 失败，该工具不可用：' + (error?.message ?? error));
  }

  // 把用法要点挂进系统提示，让 agent 不必猜。
  //
  // ⚠️ 整段包在 try/catch 里，而且**失败只警告、不抛出**。
  // 原因（真实事故，2026-09-28）：本插件在 profile 里是 `required: true`，
  // 所以 apply() 抛异常会**让整个 DSH 启动失败**，而不是仅仅少一段提示词。
  // v1.0.0 就是因为 section() 少传 order，升级到 0.1.7-rc.2 后直接
  // 把 DSH 带崩（启动日志：'dsh: startup failed: 1 required plugin did not activate'），
  // DSH 随后进安全模式并把 profile 里的插件条目删掉了。
  //
  // 系统提示只是**锦上添花**：11 个工具本身不依赖它，文字说明也已写进 skill。
  // 所以这里遵循"工具能注册就行，提示挂不上不算致命"。
  try {
    const systemPrompt = ctx.get('systemPrompt');
    if (systemPrompt !== undefined && typeof systemPrompt.section === 'function') {
      // ⚠️ `order` 是**必填**，且必须是有限数字。
      // DSH 0.1.7-rc.2 起 section() 硬校验：
      //     if (!Number.isFinite(section.order)) throw new TypeError(...)
      //     —— @deepseek-ai/dsh-system-prompt/lib/index.js:241
      //
      // 取值依据：DSH 内部 SECTION_ORDERS 把工具说明段排在 1000~3000
      // （…TOOL_REPORT: 2900, TOOL_COMPUTER_USE: 3000, MCP_SERVERS: 3100）。
      // 桌面控制属于 computer-use 一类，取 **3001**：紧跟官方
      // TOOL_COMPUTER_USE(3000)、在 MCP_SERVERS(3100) 之前。
      // 那些常量没有对外导出，所以这里写死字面量并注明来源。
      systemPrompt.section({
        name: 'tool:desktop-hand',
        order: 3001,
        text: 'Windows desktop control is available through `desktop_*` tools. '
          + 'Workflow: `desktop_diagnose` first if anything seems off, '
          + '`desktop_list_windows` to find the target, `desktop_capture` to see it '
          + '(the image comes back to you directly), `desktop_focus` or `desktop_click` '
          + 'on the window body to give it focus, then `desktop_type`. '
          + 'When a capture comes back blank, or when you want names instead of pixels, '
          + 'use `desktop_ui_tree`: it returns the window as a UI Automation tree (that is '
          + 'the way around the ApplicationFrameHost shell), and `desktop_click` also '
          + 'accepts a control `target` name. Also available: `desktop_scroll` (wheel at '
          + 'a point), `desktop_clipboard` (get/set text), `desktop_wait` (wait for a '
          + 'window or control instead of sleeping) and `desktop_open_app` (launch by '
          + 'Start Menu shortcut). '
          + 'Capture a WINDOW rather than the full screen when you need the content of a '
          + 'window even while it is occluded. Never judge a capture by its black-pixel '
          + 'ratio — look at the image.',
      });
    }
  } catch (error) {
    ctx.logger?.warn?.(
      `dsh-desktop-hand: 系统提示段落未挂上（工具仍可用）：${error?.message ?? error}`,
    );
  }
}
