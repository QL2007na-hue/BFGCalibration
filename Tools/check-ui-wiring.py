#!/usr/bin/env python3
"""Check the page ⇄ native contract, in both directions.

This exists because the two worst UI defects so far were both contract breaks,
and neither one is visible to the compiler, the unit tests, or a screenshot:

  * a button the page declares but never sends (`dump-registers`,
    `compare-dump`, `restore-dis` were all silently dead), and
  * native re-sending `screen`/`modal` as durable state, so every later push
    dragged the rider back to a page they had left or re-opened a dialog they
    had closed — the home button became unreachable.

Part 1 is a mechanical diff of the four action sets. Part 2 drives the real page
in headless Chrome and asserts the navigation/dialog behaviour through the same
channel the native side uses (`screen` and `modal-state` reports).

Usage: Tools/check-ui-wiring.py
Requires: google-chrome or chromium (same as render-screens.sh).
"""
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HTML = os.path.join(ROOT, "ios/BFGCalibration/Resources/bfg-calibration-flow.html")
SWIFT = os.path.join(ROOT, "ios/BFGCalibration/PrototypeWebView.swift")

failures = []


def fail(message):
    failures.append(message)
    print(f"  ✗ {message}")


def part1_contract_diff(html, swift):
    """Every action the page declares must reach either the page's own handler
    or the native side; every action the page sends must be handled there."""
    print("── 1. 页面动作契约（机械比对）")

    declared = set(re.findall(r'data-action="([a-z-]+)"', html))
    handled_locally = set(re.findall(r"action === '([a-z-]+)'", html))
    sent_literally = set(re.findall(r"nativeAction\('([a-z-]+)'", html))
    # `nativeAction(action)` and `nativeAction(pairing ? ... : ...)` are indirect
    # sends; treat any action mentioned by a data-action attribute plus a
    # `nativeAction(action` call site as reachable.
    sends_indirectly = "nativeAction(action" in html
    # Case labels can list several actions: `case "begin-connect", "refresh-read":`.
    # Matching only the first string after `case` invents missing handlers.
    case_labels = re.findall(r"case\s+((?:\s*\"[a-z-]+\"\s*,?)+):", swift)
    native_cases = {name for label in case_labels
                    for name in re.findall(r'"([a-z-]+)"', label)}

    dead = sorted(a for a in declared
                  if a not in handled_locally
                  and a not in sent_literally
                  and not sends_indirectly)
    if dead:
        fail("页面声明了但从不发送的死按钮：" + ", ".join(dead))
    else:
        print(f"  ✓ {len(declared)} 个动作都有去处（本地处理或发往原生）")

    # Native handlers are allowed to exist without a literal send (combined
    # `case "a", "b":` and indirect sends both hide the literal), so only report
    # an action the page *does* send and native never mentions at all.
    unhandled = sorted(a for a in sent_literally if a not in native_cases)
    if unhandled:
        # `modal-state` / `screen` / `select-vehicle` are deliberate no-ops.
        real = [a for a in unhandled if a not in {"modal-state", "screen", "select-vehicle"}]
        if real:
            fail("页面发了但原生没有分支：" + ", ".join(real))
        else:
            print("  ✓ 未接的动作都是有意忽略的展示类动作")
    else:
        print("  ✓ 页面发出的动作原生都有分支")

    # A modal the native side raises but the page has no entry for renders
    # nothing at all — the dialog is simply invisible, which is how a failure
    # notice once became a dead button.
    native_modals = set(re.findall(r'state\["modal"\] = "([a-z-]+)"', swift))
    page_modals = set(re.findall(r"'([a-z-]+)': \[", html))
    custom_modals = {"wake", "write-confirm", "write-gate", "dashboard-requirements",
                     "missing-vehicle", "license"}
    missing = sorted(native_modals - page_modals - custom_modals)
    if missing:
        fail("原生会弹出、但页面没有定义的弹窗：" + ", ".join(missing))
    else:
        print(f"  ✓ {len(native_modals)} 个原生弹窗在页面上都有定义")

    # A spent directive must be *removed*, not set to NSNull. Nulling it leaves
    # screen:null in every later payload; the page copies it into its own state
    # and its render switch falls through to the home template, so any
    # subsequent push drags the rider home. The interaction checks below cannot
    # see this, because they hand-write the payload the native side would send.
    if re.search(r"state\[key\]\s*=\s*NSNull\(\)", swift):
        fail("pushState() 把一次性指令置为 NSNull；残留的 screen:null 会把页面打回首页")
    elif "removeValue(forKey: key)" not in swift:
        fail("pushState() 未清除一次性指令")
    else:
        print("  ✓ 一次性指令发送后从状态中移除，不会残留 screen:null")

    # The click chain has to end in a fallback. Every modal button is generated
    # from the specs table, so its action never appears as a literal
    # data-action="..." and the checks above cannot see it. If the chain does not
    # list that action and has no fallback, the button is wired to nothing at
    # all: tapping it does nothing — no error, no navigation, no log line. That
    # is exactly how the read-only-serial confirmation shipped dead on real
    # hardware while its native handler sat waiting for a message that never came.
    fallback = "else { if (window.BfgNative) nativeAction(action); }"
    if fallback not in html:
        fail("点击链没有兜底分支：未列出的动作（例如模板生成的弹窗按钮）会变成死按钮")
    else:
        print("  ✓ 点击链有兜底分支，未列出的动作仍会发往原生")

    return not failures


PAGE_TEST = r"""
<script>
window.addEventListener('load', function () {
  const out = [];
  const ok = (n, c, x) => out.push((c ? 'PASS ' : 'FAIL ') + n + (x ? ' :: ' + x : ''));
  const ev = [];
  window.BfgNative = { action: (a, v) => ev.push([a, String(v)]) };
  const update = (o) => window.bfgNativeUpdate(JSON.stringify(o));
  const click = (sel) => { const el = document.querySelector(sel);
                           if (!el) throw new Error('缺 ' + sel);
                           if (el.disabled) el.disabled = false;
                           el.click(); };
  const last = (k) => { for (let i = ev.length - 1; i >= 0; i--) if (ev[i][0] === k) return ev[i][1]; return null; };
  const opens = () => ev.filter(e => e[0] === 'modal-state' && e[1] === 'open').length;
  const sent = (a) => ev.some(e => e[0] === a);

  try {
    // 失败落到结果页；用户返回设置后，原生的后续推送不得把他拽回去
    update({ screen: 'scan-result', errorMessage: '本机没有这辆车的配对凭据。', busyMessage: null });
    ok('失败落到扫描结果页', last('screen') === 'scan-result', last('screen'));
    click('[data-action="settings"]');
    ok('返回设置生效', last('screen') === 'settings', last('screen'));

    let mark = ev.length;
    update({ busyMessage: null });
    ok('原生后续推送不把用户拽回失败页',
       last('screen') === 'settings' && !ev.slice(mark).some(e => e[0] === 'screen'), last('screen'));
    click('[data-action="home"]');
    ok('首页可达（导航不再循环）', last('screen') === 'home', last('screen'));

    // 对照组：确实存在 screen 的推送会切换页面 —— 证明本测试抓得到该缺陷
    update({ screen: 'scan-result' });
    ok('（对照）带 screen 的推送会切换页面', last('screen') === 'scan-result', last('screen'));
    click('[data-action="settings"]');

    // 弹窗关闭后不得复活
    update({ modal: 'operation-failed', screen: 'settings', errorMessage: '未配对。' });
    ok('失败弹窗出现', last('modal-state') === 'open', String(last('modal-state')));
    const opened = opens();
    click('[data-action="close-modal"]');
    ok('弹窗可关闭', last('modal-state') === 'closed', String(last('modal-state')));
    update({ busyMessage: null });
    ok('关闭后不复活', last('modal-state') === 'closed' && opens() === opened,
       'opens=' + opens() + '/' + opened);

    // 曾经空接的按钮必须真的把动作发出去
    click('[data-action="dump-registers"]');
    ok('导出寄存器快照发往原生', sent('dump-registers'), '');
    ok('快照进入进度页', last('screen') === 'scan-progress', last('screen'));
    click('[data-action="cancel-scan"]');
    click('[data-action="compare-dump"]');
    ok('与上次快照对比发往原生', sent('compare-dump'), '');
    click('[data-action="restore-dis"]');
    ok('恢复首次仪表配置发往原生', sent('restore-dis'), '');
    click('[data-action="restore-first"]');
    ok('恢复首次原参数发往原生', sent('restore-first'), '');

    // 写入越界告警：文案要在，且首要动作是"导出快照"而不是"重试"
    update({ modal: 'write-collateral', screen: 'review',
             errorMessage: '⚠ 写入后检测到 2 处目标之外的寄存器变化。' });
    ok('越界告警弹窗出现', last('modal-state') === 'open', String(last('modal-state')));
    ok('越界告警不复用"写入成功"文案',
       document.body.innerText.indexOf('写入成功') === -1, '');
    ok('越界告警首要动作是导出快照',
       !!document.querySelector('.nb-modal [data-action="dump-registers"]'), '');
    click('[data-action="close-modal"]');
    window.bfgNativeGo('settings');   // 声明按钮在设置页，先回去

    // 声明弹窗打开时不改变当前页面，关闭后不复活
    click('[data-action="show-license"]');
    ok('关于声明发往原生', sent('show-license'), '');
    update({ modal: 'license', licenseText: 'x' });
    ok('声明弹窗出现且页面未被拽走', last('modal-state') === 'open' && last('screen') === 'settings',
       last('screen'));
    click('[data-action="close-modal"]');
    update({ busyMessage: null });
    ok('声明关闭后不复活', last('modal-state') === 'closed', String(last('modal-state')));

    // The exact shape the native side used to send once a directive was spent:
    // every one-shot key present and null. None of it is a navigation order, so
    // the page must stay where it is. Asserted against the rendered DOM rather
    // than the reported 'screen' events: a null screen navigates without
    // reporting, which is precisely how the defect stayed hidden.
    window.bfgNativeGo('settings');
    update({ screen: null, modal: null, errorMessage: null, result: null,
             writeGate: null, busyMessage: '正在连接车辆…' });
    ok('一次性指令被清空后的推送不把页面打回首页',
       document.body.innerText.indexOf('关于与使用声明') !== -1, '');
  } catch (e) { out.push('ERROR ' + e.message); }
  document.title = 'UICHECK|' + out.join('|');
});
</script>
"""


def part2_interaction(html):
    print("\n── 2. 页面交互（无头浏览器，走原生同一通道断言）")
    # CHROME may be a bare name to look up on PATH, or an absolute path to a
    # specific binary — Edge and Chrome-for-Testing on Windows have neither a
    # stable name nor a PATH entry.
    chrome = os.environ.get("CHROME", "google-chrome")
    if os.path.isabs(chrome):
        found = os.path.exists(chrome)
    else:
        found = any(os.path.exists(os.path.join(p, chrome))
                    for p in os.environ.get("PATH", "").split(os.pathsep))
    if not found:
        print("  ⚠ 未找到 chrome/chromium，跳过（渲染类检查在本机与 CI 都不做）")
        return

    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False,
                                     encoding="utf-8",
                                     dir=tempfile.gettempdir()) as handle:
        handle.write(html.replace("</body>", PAGE_TEST + "</body>"))
        path = handle.name

    # A dedicated profile keeps the run hermetic: without it the launcher hands
    # the URL to an already-running browser, exits immediately, and the captured
    # DOM comes back empty.
    profile = tempfile.mkdtemp(prefix="bfg-uicheck-profile-")
    try:
        result = subprocess.run(
            [chrome, "--headless=new", "--disable-gpu", "--no-sandbox",
             "--no-first-run", "--disable-extensions",
             f"--user-data-dir={profile}",
             "--virtual-time-budget=8000", "--window-size=390,844", "--dump-dom",
             pathlib.Path(path).as_uri()],
            capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        fail("无头浏览器超时未返回")
        return
    finally:
        shutil.rmtree(profile, ignore_errors=True)
        os.unlink(path)
    match = re.search(r"<title>UICHECK\|(.*?)</title>", result.stdout, re.S)
    if not match:
        fail("页面测试没有返回结果（chrome 未运行？）")
        return
    for line in match.group(1).split("|"):
        if line.startswith("PASS"):
            print("  ✓ " + line[5:])
        elif line.startswith("FAIL"):
            fail(line[5:])
        else:
            fail(line)


def main():
    html = open(HTML, encoding="utf-8").read()
    swift = open(SWIFT, encoding="utf-8").read()

    part1_contract_diff(html, swift)
    part2_interaction(html)

    print()
    if failures:
        print(f"未通过 {len(failures)} 项：")
        for item in failures:
            print("  · " + item)
        sys.exit(1)
    print("页面 ⇄ 原生契约检查通过")


if __name__ == "__main__":
    main()
