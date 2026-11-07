/**
 * 用**忠实模拟的 `ctx.subprocess` seam** 跑一遍插件，验证正式路径（harness 路径）
 * 的契约细节是否正确。这些细节都是读源码定下来、但必须实跑才能确认的：
 *
 *   1. `graceMs` 必填（缺失会让 validateSubprocessSpec 抛错）
 *   2. `handle.collected.stdout` 是收集器对象，要调 `finalize()` 才拿到 { text }
 *   3. `handle.done` 解析出 { exitCode }
 *   4. 超时靠 AbortController，而不是 spec.timeoutMs（seam 没有这个字段）
 *
 * 这样就能在不重启 DSH 的前提下，证明插件在真实 harness 里的行为。
 *
 * 用法：node lib/selftest-harness.mjs
 */
import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { spawnSync } from 'node:child_process';

const HERE = dirname(fileURLToPath(import.meta.url));
const mod = await import(pathToFileURL(join(HERE, 'index.js')).href);

let pass = 0;
let fail = 0;
function check(name, ok, detail = '') {
  if (ok) { pass++; console.log(`  PASS  ${name}`); }
  else { fail++; console.log(`  FAIL  ${name}${detail ? `  -- ${detail}` : ''}`); }
}

console.log('\n=== 插件 × harness subprocess seam 契约自检 ===\n');

// ------------------------------------------------------------------
// 一个忠实于 dsh-subprocess-local 语义的假 seam。
// 关键点：拒绝缺失 graceMs（照抄 validateSubprocessSpec 的行为），
// collected.stdout 只提供 finalize()，不提供 .text。
// ------------------------------------------------------------------
const spawnLog = [];
function makeFakeSubprocess({ rejectMissingGrace = true } = {}) {
  return {
    spawn(spec) {
      spawnLog.push(spec);
      if (rejectMissingGrace
        && (!Number.isFinite(spec.graceMs) || spec.graceMs <= 0)) {
        throw new Error('subprocess graceMs must be a positive finite number');
      }
      if (!Array.isArray(spec.argv) || !spec.argv[0]) {
        throw new Error('invalid argv: expected a non-empty program name at argv[0]');
      }

      // 真正去跑一次（用 spawnSync 避免本次会话里 node 管道 stdio 的 EPERM）
      const [program, ...rest] = spec.argv;
      const res = spawnSync(program, rest, { encoding: 'utf8', windowsHide: true });
      const outText = res.stdout ?? '';
      const errText = res.stderr ?? '';

      // 造收集器：**故意不暴露 .text**，只给 finalize()，以逼出错误实现
      const collector = (text) => ({ finalize: () => ({ text, truncated: false }) });

      return {
        collected: {
          stdout: collector(outText),
          stderr: collector(errText),
        },
        done: Promise.resolve({ exitCode: res.status ?? 0, signal: null }),
        terminate: () => {},
        waitForExit: () => Promise.resolve(true),
      };
    },
  };
}

// ------------------------------------------------------------------
function makeCtx(subprocess) {
  const registered = [];
  return {
    registered,
    ctx: {
      tools: { register: (t) => registered.push(t) },
      get: (svc) => {
        if (svc === 'subprocess') return subprocess;
        if (svc === 'systemPrompt') return { section: () => {} };
        return undefined;
      },
    },
  };
}

// ------------------------------------------------------------------
console.log('[1] 注册（走 harness 路径）');
const fake = makeFakeSubprocess();
const { ctx, registered } = makeCtx(fake);
try {
  mod.apply(ctx, { enginePath: join(HERE, 'desktop-hand.ps1'), timeoutMs: 60000, outputDir: '' });
  check('apply() 未抛异常', true);
} catch (error) {
  check('apply() 未抛异常', false, error.message);
}
check('注册了 11 个工具', registered.length === 11, `got ${registered.length}`);

const byName = Object.fromEntries(registered.map((t) => [t.name, t]));
const fakeExec = { arguments: {} };

// ------------------------------------------------------------------
console.log('\n[2] spec 契约：graceMs 必填、argv[0] 合法');
spawnLog.length = 0;
await byName.desktop_list_windows.execute({}, fakeExec);
// list-windows 会调两次引擎（list_windows 本身 + info 取前台标题），故断言 >= 1
check('确实调用了 seam.spawn', spawnLog.length >= 1, `calls=${spawnLog.length}`);
const spec = spawnLog[0];
check('spec.graceMs 是正数（否则 seam 会抛错）',
  Number.isFinite(spec?.graceMs) && spec.graceMs > 0, `graceMs=${spec?.graceMs}`);
check('spec.argv[0] 是 powershell.exe', spec?.argv?.[0] === 'powershell.exe', spec?.argv?.[0]);
check('spec.argv 含 -File 与引擎路径',
  spec?.argv?.includes('-File') && spec?.argv?.some((a) => a.endsWith('desktop-hand.ps1')));
check('spec.stdio.stdout 是 collect 模式（带 maxBytes）',
  spec?.stdio?.stdout?.maxBytes > 0, JSON.stringify(spec?.stdio?.stdout));
check('spec.stdio.stdin 是 ignore', spec?.stdio?.stdin === 'ignore');
check('spec 带 signal（用于超时/取消）', spec?.signal !== undefined);

// ------------------------------------------------------------------
console.log('\n[3] collected 契约：必须调用 finalize() 才能拿到输出');
let lw;
try {
  lw = await byName.desktop_list_windows.execute({}, fakeExec);
  check('desktop_list_windows 走 harness 路径成功', true);
  check('  解析出了窗口数组', Array.isArray(lw.windows) && lw.windows.length > 0,
    `count=${lw.windows?.length}`);
  console.log(`       -> ${lw.count} 个窗口`);
} catch (error) {
  check('desktop_list_windows 走 harness 路径成功', false, error.message);
}

// ------------------------------------------------------------------
console.log('\n[4] 逐个工具走 harness 路径实跑');
try {
  const cap = await byName.desktop_capture.execute({}, fakeExec);
  check('desktop_capture 成功', typeof cap.path === 'string' && cap.width > 0);
  console.log(`       -> ${cap.width}x${cap.height} ${cap.path}`);
} catch (error) {
  check('desktop_capture 成功', false, error.message);
}

try {
  const dg = await byName.desktop_diagnose.execute({}, fakeExec);
  check('desktop_diagnose 成功', typeof dg.healthy === 'boolean');
  console.log(`       -> healthy=${dg.healthy}`);
} catch (error) {
  check('desktop_diagnose 成功', false, error.message);
}

try {
  const ty = await byName.desktop_type.execute({ key: 'esc' }, fakeExec);
  check('desktop_type(key) 成功', ty.mode === 'key');
} catch (error) {
  check('desktop_type(key) 成功', false, error.message);
}

try {
  const cl = await byName.desktop_click.execute({ x: 10, y: 10 }, fakeExec);
  check('desktop_click 成功', typeof cl.cursorMatched === 'boolean');
  console.log(`       -> matched=${cl.cursorMatched} cursor=${cl.cursor}`);
} catch (error) {
  check('desktop_click 成功', false, error.message);
}

// ------------------------------------------------------------------
console.log('\n[5] 错误契约：引擎报错必须变成可读异常');
try {
  await byName.desktop_capture.execute({ window: 'ZZZ_NOPE_ZZZ' }, fakeExec);
  check('不存在的窗口抛错', false, '未抛错');
} catch (error) {
  const hasHint = error.message.includes('提示：');
  check('不存在的窗口抛错且带可操作提示', hasHint);
  console.log(`       -> ${error.message.split('\n')[0]}`);
}

// ------------------------------------------------------------------
console.log('\n[6] 缺失 graceMs 时应该被 seam 拒绝 —— 证明这个字段真的必需');
{
  const strict = makeFakeSubprocess({ rejectMissingGrace: true });
  const c2 = makeCtx(strict);
  mod.apply(c2.ctx, { enginePath: join(HERE, 'desktop-hand.ps1'), timeoutMs: 60000, outputDir: '' });
  const t2 = Object.fromEntries(c2.registered.map((t) => [t.name, t]));
  // 手动构造一个缺 graceMs 的调用，确认 seam 会抛（对照说明我们的实现是对的）
  let seamRejected = false;
  try {
    strict.spawn({ argv: ['powershell.exe'], stdio: { stdin: 'ignore' }, });
  } catch {
    seamRejected = true;
  }
  check('假 seam 会拒绝缺失 graceMs 的 spec（对照）', seamRejected);
  // 而真实实现带 graceMs，应当成功
  const okCall = await t2.desktop_list_windows.execute({}, fakeExec).then(() => true, () => false);
  check('我们的实现带 graceMs，因此成功', okCall);
}

console.log(`\n=== 结果：${pass} 通过 / ${fail} 失败 ===`);
if (fail > 0) process.exit(1);
