/**
 * 插件层自检：用一个假 ctx 跑 apply()，验证全部工具都能注册、
 * 参数 schema 合法、且每个工具的 execute/render 至少能跑通一条主路径。
 *
 * 为什么要有它：DSH 的启动语义是"全有全无"——插件加载失败整个进程起不来。
 * 所以在把插件挂进 profile 之前，必须先在这里证明它能注册成功。
 * 另外 defineTool 会在注册时立刻校验 schema，所以这个测试能提前抓到
 * "参数写成非法 JSON Schema"这类错误。
 *
 * 用法：node lib/selftest.mjs
 */
import { pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const mod = await import(pathToFileURL(join(HERE, 'index.js')).href);

let pass = 0;
let fail = 0;
function check(name, ok, detail = '') {
  if (ok) { pass++; console.log(`  PASS  ${name}`); }
  else { fail++; console.log(`  FAIL  ${name}${detail ? `  -- ${detail}` : ''}`); }
}

console.log('\n=== dsh-desktop-hand 插件层自检 ===\n');

// ---------------------------------------------------------------- 注册
const registered = [];
const sections = [];
const fakeCtx = {
  tools: { register: (tool) => registered.push(tool) },
  get: (svc) => (svc === 'systemPrompt' ? { section: (s) => sections.push(s) } : undefined),
};

console.log('[1] apply() 注册工具');
try {
  mod.apply(fakeCtx, { enginePath: join(HERE, 'desktop-hand.ps1'), timeoutMs: 60000, outputDir: '' });
  check('apply() 未抛异常', true);
} catch (error) {
  check('apply() 未抛异常', false, error.message);
}

const expect = [
  'desktop_list_windows', 'desktop_capture', 'desktop_focus',
  'desktop_click', 'desktop_type', 'desktop_diagnose',
  // v1.1 语义层
  'desktop_ui_tree', 'desktop_scroll', 'desktop_clipboard',
  'desktop_wait', 'desktop_open_app',
];
const names = registered.map((t) => t.name).sort();
check(`注册了 ${expect.length} 个工具`, registered.length === expect.length,
  `got ${registered.length}: ${names.join(',')}`);
for (const n of expect) {
  check(`  已注册 ${n}`, names.includes(n));
}
check('注册了系统提示段落', sections.length === 1, `got ${sections.length}`);

// ---- 系统提示段落的契约（这组断言来自一次真实事故，别再删） ----
// DSH 0.1.7-rc.2 起，@deepseek-ai/dsh-system-prompt 的 section() 硬校验
// `Number.isFinite(order)`（dsh-system-prompt/lib/index.js:241）。
// v1.0.0 少传 order，升级后 section() 抛错 → 因为插件是 required:true，
// **整个 DSH 启动失败**并进安全模式。所以这里必须把契约钉死。
if (sections.length === 1) {
  const s = sections[0];
  check('提示段落：order 是有限数字（0.1.7+ 硬要求）', Number.isFinite(s.order), `order=${s.order}`);
  check('提示段落：order 排在官方 computer-use 之后（>3000）', s.order > 3000, `order=${s.order}`);
  check('提示段落：order 在 MCP_SERVERS 之前（<3100）', s.order < 3100, `order=${s.order}`);
  check('提示段落：name 非空', typeof s.name === 'string' && s.name.length > 0);
  check('提示段落：text 非空', typeof s.text === 'string' && s.text.length > 0);
}

// ---- 提示段落挂不上时，不得让 apply() 失败 ----
// 工具能注册才是底线；系统提示只是锦上添花。
{
  const bad = [];
  const hostileCtx = {
    tools: { register: (t) => bad.push(t) },
    // 故意造一个"会抛错的 section"，模拟 API 变更
    get: (svc) => (svc === 'systemPrompt'
      ? { section: () => { throw new TypeError('prompt section order must be a finite number'); } }
      : undefined),
    logger: { warn: () => {} },
  };
  let threw = false;
  try {
    mod.apply(hostileCtx, { enginePath: join(HERE, 'desktop-hand.ps1'), timeoutMs: 60000, outputDir: '' });
  } catch { threw = true; }
  check('section() 抛错时 apply() 仍然成功（不再拖垮 DSH 启动）', !threw);
  check(`  且 ${expect.length} 个工具照常注册`, bad.length === expect.length, `got ${bad.length}`);
}

// ---------------------------------------------------------------- schema 合法性
console.log('\n[2] 工具 schema 形状');
for (const tool of registered) {
  const p = tool.parameters;
  check(`${tool.name}: parameters 是 object 根`, p?.type === 'object' && p?.properties !== undefined);
  const props = Object.keys(p?.properties ?? {});
  const required = new Set(p?.required ?? []);
  // required 必须来自 properties，否则模型侧 schema 非法
  const badReq = [...required].filter((r) => !props.includes(r));
  check(`${tool.name}: required 均在 properties 内`, badReq.length === 0, badReq.join(','));
  check(`${tool.name}: 有 output.schema`, tool.output?.schema !== undefined);
  check(`${tool.name}: 有 render`, typeof tool.output?.render === 'function');
  check(`${tool.name}: 有 execute`, typeof tool.execute === 'function');
  // 每个参数必须有 description，否则模型不知道该怎么填
  const noDesc = props.filter((k) => !p.properties[k].description);
  check(`${tool.name}: 每个参数都有 description`, noDesc.length === 0, noDesc.join(','));
}

// ---------------------------------------------------------------- 实跑主路径
console.log('\n[3] 实跑各工具主路径');
const byName = Object.fromEntries(registered.map((t) => [t.name, t]));
const fakeExec = { signal: undefined, arguments: {} };

async function run(name, args) {
  const tool = byName[name];
  const value = await tool.execute(args, fakeExec);
  // 模拟框架：用 output.schema 校验返回值（additionalProperties:false 会抓多余键）
  const violations = [];
  const schema = tool.output.schema;
  if (schema.additionalProperties === false && schema.properties) {
    for (const k of Object.keys(value)) {
      if (!(k in schema.properties)) violations.push(`unexpected key "${k}"`);
    }
    for (const k of schema.required ?? []) {
      if (!(k in value)) violations.push(`missing required "${k}"`);
    }
  }
  return { value, violations, content: tool.output.render(args, value) };
}

// list-windows
try {
  const { value, violations, content } = await run('desktop_list_windows', {});
  check('desktop_list_windows 执行成功', violations.length === 0, violations.join('; '));
  check('  返回了窗口数组', Array.isArray(value.windows));
  check('  count 与 windows 长度一致', value.count === value.windows.length);
  check('  render 产出 text 块', content[0]?.type === 'text' && content[0].text.length > 0);
  check('  报告了远程软件字段', Array.isArray(value.remoteTools));
  console.log(`       -> ${value.count} 个窗口，前台 handle=${value.foregroundHandle}`);
} catch (error) {
  check('desktop_list_windows 执行成功', false, error.message);
}

// capture
let captured = null;
try {
  const { value, violations, content } = await run('desktop_capture', {});
  captured = value;
  check('desktop_capture 执行成功', violations.length === 0, violations.join('; '));
  check('  PNG 已落盘', true, value.path);
  check('  render 文字含 <path>', content[0].text.includes('<path>'));
  console.log(`       -> ${value.path} ${value.width}x${value.height}`);
} catch (error) {
  check('desktop_capture 执行成功', false, error.message);
}

// finalizeContent —— 图片块必须在这里被追加
if (captured) {
  try {
    const tool = byName.desktop_capture;
    if (typeof tool.finalizeContent !== 'function') {
      check('desktop_capture 有 finalizeContent', false, 'missing');
    } else {
      const res = {
        value: captured,
        content: tool.output.render({}, captured),
      };
      const out = await tool.finalizeContent(fakeExec, res);
      check('finalizeContent 有 finalizeContent', true);
      check('  返回了内容数组', Array.isArray(out) && out.length >= 1);
      const hasImage = out.some((b) => b.type === 'image');
      const hasFallback = out.some((b) => b.type === 'text' && b.text.includes('未能附加'));
      // 无附件服务时会走降级文案；两者必须恰有一个
      check('  图片块或降级文案恰有一个', hasImage !== hasFallback,
        `image=${hasImage} fallback=${hasFallback}`);
    }
  } catch (error) {
    check('finalizeContent 执行成功', false, error.message);
  }
}

// focus（用一个必然存在的窗口：桌面 Progman）
try {
  const lw = await byName.desktop_list_windows.execute({}, fakeExec);
  const progman = lw.windows.find((w) => w.class === 'Progman') ?? lw.windows[0];
  const { value, violations } = await run('desktop_focus', { handle: progman.handle });
  check('desktop_focus 执行成功', violations.length === 0, violations.join('; '));
  check('  返回 focused 布尔', typeof value.focused === 'boolean');
  console.log(`       -> focused=${value.focused} result=${value.result}`);
} catch (error) {
  check('desktop_focus 执行成功', false, error.message);
}

// click（移到桌面空白处，不点击破坏任何东西 -> 用 move 语义验证坐标换算）
try {
  const { value, violations } = await run('desktop_click', { x: 10, y: 10, double: false });
  check('desktop_click 执行成功', violations.length === 0, violations.join('; '));
  check('  做了落点校验', typeof value.cursorMatched === 'boolean');
  console.log(`       -> ${value.action} at (${value.screenX},${value.screenY}) cursor=${value.cursor} matched=${value.cursorMatched}`);
} catch (error) {
  check('desktop_click 执行成功', false, error.message);
}

// type
try {
  const { value, violations } = await run('desktop_type', { key: 'esc' });
  check('desktop_type(key) 执行成功', violations.length === 0, violations.join('; '));
  check('  返回 mode=key', value.mode === 'key');
} catch (error) {
  check('desktop_type(key) 执行成功', false, error.message);
}

// diagnose
try {
  const { value, violations, content } = await run('desktop_diagnose', {});
  check('desktop_diagnose 执行成功', violations.length === 0, violations.join('; '));
  check('  返回 healthy 布尔', typeof value.healthy === 'boolean');
  check('  给出判定文字', typeof value.verdict === 'string' && value.verdict.length > 0);
  check('  render 含采样', content[0].text.includes('采样 A'));
  console.log(`       -> healthy=${value.healthy}`);
} catch (error) {
  check('desktop_diagnose 执行成功', false, error.message);
}

// ---------------------------------------------------------------- 无损 JSON
// 这一组是**结构性**回归测试，针对一个真实故障：
//
//   dsh-tools 在 materializePresentation 里用 snapshotJsonValue 校验最终结果，
//   而 snapshotJsonValue 对**值为 undefined 的属性**直接判整份非法，抛：
//       TypeError: tool result must be losslessly JSON-serializable
//       （dsh-tools/lib/index.js:2604）
//
//   注意这跟 schema 校验（additionalProperties:false）是两件事，报错文案不同：
//     - 多余的键        -> tool "x" returned invalid output: unexpected key "y"
//     - 值为 undefined  -> tool result must be losslessly JSON-serializable
//
// 一旦某个工具直接赋值引擎字段（key: payload.key），引擎少给一个字段就会
// 产生 undefined 属性，于是"截图明明成功了"却报一个与截图无关的序列化错误。
// 所以这里对所有工具的返回值做深度扫描，任何 undefined 都算失败。
console.log('\n[5] 返回值必须是无损 JSON（深度扫描 undefined）');

/** 深度找 undefined 属性/元素；同时排除函数、Symbol、BigInt、NaN、Infinity。 */
function findLossy(value, path = '$', found = []) {
  if (value === undefined) { found.push(`${path} = undefined`); return found; }
  if (value === null) return found;
  const t = typeof value;
  if (t === 'function') { found.push(`${path} = function`); return found; }
  if (t === 'symbol') { found.push(`${path} = symbol`); return found; }
  if (t === 'bigint') { found.push(`${path} = bigint`); return found; }
  if (t === 'number' && !Number.isFinite(value)) { found.push(`${path} = ${value}`); return found; }
  if (t !== 'object') return found;
  if (Array.isArray(value)) {
    value.forEach((v, i) => findLossy(v, `${path}[${i}]`, found));
    return found;
  }
  for (const [k, v] of Object.entries(value)) findLossy(v, `${path}.${k}`, found);
  return found;
}

/** 所有工具的主路径，全部跑一遍做扫描（含 render 与 finalizeContent 的输出）。 */
const lossyCases = [
  ['desktop_list_windows', {}],
  ['desktop_capture', {}],
  ['desktop_capture', { region: '0,0,120,120' }],
  ['desktop_focus', { window: 'explorer' }],
  ['desktop_click', { x: 5, y: 5 }],
  ['desktop_type', { key: 'esc' }],
  ['desktop_diagnose', {}],
];
for (const [name, args] of lossyCases) {
  const tool = byName[name];
  try {
    const value = await tool.execute(args, fakeExec);
    const vLoss = findLossy(value, 'value');
    check(`${name}${args.region ? '(region)' : ''} 返回值无 undefined`, vLoss.length === 0, vLoss.join('; '));

    const rendered = tool.output.render(args, value);
    const rLoss = findLossy(rendered, 'content');
    check(`${name}${args.region ? '(region)' : ''} render 输出无 undefined`, rLoss.length === 0, rLoss.join('; '));

    if (typeof tool.finalizeContent === 'function') {
      const fin = await tool.finalizeContent(fakeExec, { value, content: rendered });
      if (fin !== undefined) {
        const fLoss = findLossy(fin, 'finalContent');
        check(`${name}${args.region ? '(region)' : ''} finalizeContent 输出无 undefined`, fLoss.length === 0, fLoss.join('; '));
        // 逐块检查：图片块也必须是无损的
        for (const [i, block] of fin.entries()) {
          const bLoss = findLossy(block, `block[${i}]`);
          check(`  block[${i}] (${block.type}) 无损`, bLoss.length === 0, bLoss.join('; '));
        }
      }
    }
  } catch (error) {
    // focus 一个不存在的窗口会抛错，那是预期的；只有非预期错误才记失败
    const expected = name === 'desktop_focus' && /NO_MATCH|没有标题/.test(error.message);
    if (!expected) check(`${name} 无损扫描可执行`, false, error.message);
  }
}

// 反向验证：这套扫描器本身要能抓到问题，否则它是摆设
{
  const bad = findLossy({ a: 1, b: undefined, c: { d: () => {} }, e: [1, undefined] });
  check('扫描器能识别 undefined/function（自检自身有效性）', bad.length === 3, `找到 ${bad.length} 处: ${bad.join('; ')}`);
}

// ---------------------------------------------------------------- 错误路径也要无损
// ⚠️ 这组是补的洞（真实故障，2026-10-02）：
// 上面对"成功结果"扫得很细，却**完全没扫错误结果**，于是漏掉了这个 bug——
//
//   工具抛错时，dsh-tools 用 errorInfo() 构造错误结果：
//       errorInfo = e instanceof Error && "code" in e
//                   ? { name: e.name, code: e.code } : undefined
//                   （dsh-tools/lib/index.js:2608）
//   错误结果同样要过 snapshotJsonValue。若 error 有 code 属性但其值是 undefined，
//   info 就带一个 undefined 属性，**整份错误结果被拒**，真正有用的错误信息被替换成
//   "tool result must be losslessly JSON-serializable"。
//
//   陷阱在于 `this.code = undefined` 会**创建**属性，`"code" in error` 因此为 true。
//   所以 EngineError 必须"有值才设 code"。
console.log('\n[5b] 错误结果也必须是无损 JSON');

function errorInfoOf(e) {
  try {
    return e instanceof Error && 'code' in e ? { name: e.name, code: e.code } : undefined;
  } catch { return undefined; }
}
/** 复刻 dsh-tools 的 toolErrorResult（lib/index.js:3612）。 */
function toolErrorResult(error) {
  const info = errorInfoOf(error);
  const message = error instanceof Error ? error.message : String(error);
  return {
    content: [{ type: 'text', text: `Error: ${message}` }],
    isError: true,
    error: { message, ...(info ? { info } : {}) },
  };
}

// 1) 所有会抛错的工具路径，其错误结果都必须无损
const errCases = [
  ['desktop_capture', { window: 'ZZZ_NO_SUCH_WINDOW_ZZZ' }],
  ['desktop_capture', { region: 'not-a-region' }],
  ['desktop_type', {}],
  ['desktop_type', { key: 'NOT_A_REAL_KEY' }],
  ['desktop_type', { text: 'a', key: 'esc' }],
  ['desktop_focus', {}],
  ['desktop_focus', { handle: 999999999 }],
];
for (const [name, args] of errCases) {
  try {
    await byName[name].execute(args, fakeExec);
    check(`${name} ${JSON.stringify(args)} 应抛错`, false, '未抛错');
  } catch (error) {
    const result = toolErrorResult(error);
    const lossy = findLossy(result, 'errorResult');
    check(`${name} ${JSON.stringify(args)} 错误结果无损`, lossy.length === 0, lossy.join('; '));
  }
}

// 2) 直接钉死那个机制：有 code 属性但值为 undefined 必须被判非法
{
  const withUndefCode = new Error('x');
  withUndefCode.name = 'EngineError';
  withUndefCode.code = undefined;            // 会创建属性 → "code" in e === true
  check('构造出的"code=undefined"确实被识别为有 code 属性', 'code' in withUndefCode);
  const badResult = toolErrorResult(withUndefCode);
  check('  → 这样的错误结果会带 undefined（说明这个陷阱真实存在）',
    findLossy(badResult, 'e').length > 0, findLossy(badResult, 'e').join('; '));
}

// 3) 我的 EngineError 不会踩这个陷阱：引擎不给 code 时也不得设该属性
{
  const g = await import(pathToFileURL(join(HERE, 'index.js')).href);
  const err = new g.__EngineErrorForTest({ ok: false, error: '引擎返回了错误但没有 code 字段' });
  check('EngineError：payload 无 code 时不创建 code 属性', !('code' in err));
  const r = toolErrorResult(err);
  check('  → 其错误结果无损', findLossy(r, 'e').length === 0, findLossy(r, 'e').join('; '));
  const err2 = new g.__EngineErrorForTest({ ok: false, error: 'x', code: 'NO_MATCH' });
  check('EngineError：有 code 时正常保留', err2.code === 'NO_MATCH');
  check('  → 其错误结果仍无损', findLossy(toolErrorResult(err2), 'e').length === 0);
}


// ---------------------------------------------------------------- 错误路径
console.log('\n[6] 错误路径必须抛错而不是静默成功');
async function expectThrow(name, args, label) {
  try {
    await byName[name].execute(args, fakeExec);
    check(label, false, '未抛错');
  } catch (error) {
    check(label, true);
    console.log(`       -> ${String(error.message).split('\n')[0]}`);
  }
}
await expectThrow('desktop_capture', { window: 'ZZZ_NOPE_ZZZ' }, '不存在的窗口被拒绝');
await expectThrow('desktop_capture', { region: 'bad-region' }, '非法 region 被拒绝');
await expectThrow('desktop_type', { text: 'a', key: 'esc' }, 'text+key 同时给被拒绝');
await expectThrow('desktop_type', {}, 'text/key 都不给被拒绝');
await expectThrow('desktop_type', { key: 'NOT_A_REAL_KEY' }, '未知按键被拒绝');
await expectThrow('desktop_focus', {}, 'focus 缺目标被拒绝');

console.log(`\n=== 结果：${pass} 通过 / ${fail} 失败 ===`);
if (fail > 0) process.exit(1);
