import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { chromium } from 'playwright-core';

const jobsUrl = 'https://www.zhipin.com/web/geek/jobs?scale=301,302';
const profile = join(import.meta.dirname, '.chrome-boss');
const logs = join(import.meta.dirname, 'logs');
const waitMs = 10_000;
const clickGap = 2_000;
const jobGap = 3_000;
const selectors = {
  card: '.job-list-container .job-card-wrapper, .job-list-box .job-card-wrapper',
  cardTitle: '.job-name',
  company: '.company-name',
  detail: '.job-detail',
  detailTitle: '.job-detail-header .name h2, .job-detail-header .job-name, .job-detail-header h2',
  detailCompany: '.company-info .company-name, .company-info a[href*="/gongsi/"], .job-detail-header .company-name',
  dialog: '[role="dialog"], .boss-dialog, .dialog-wrap, .dialog-container, .boss-popup',
  loading: '[aria-busy="true"], .loading, .skeleton',
  end: ['没有更多了', '没有更多职位了', '暂无更多职位', '没有更多职位', '暂无职位'],
};

let browser;
let page;
let lastClick = -Infinity;
let lastJob = -Infinity;
let observation;
let interruption;
let step = '打开岗位页面';
let job;
let chatAttempted = false;
let count = 0;
const navigation = [];
process.once('SIGINT', () => { interruption = '用户请求停止'; });

async function launchChrome({ debug = false } = {}) {
  const executable = [process.env.BOSS_CHROME_PATH,
    join(process.env.ProgramFiles ?? 'C:/Program Files', 'Google/Chrome/Application/chrome.exe'),
    join(process.env['ProgramFiles(x86)'] ?? 'C:/Program Files (x86)', 'Google/Chrome/Application/chrome.exe'),
    join(process.env.LOCALAPPDATA ?? '', 'Google/Chrome/Application/chrome.exe'),
  ].find(path => path && existsSync(path));
  if (!executable) throw new Error('找不到 Chrome，请将 BOSS_CHROME_PATH 设为 chrome.exe 的完整路径');
  await mkdir(profile, { recursive: true });
  const chrome = spawn(executable, [
    `--user-data-dir=${profile}`, '--no-first-run', '--new-window',
    ...(debug ? ['--remote-debugging-port=0', 'about:blank'] : [jobsUrl]),
  ], { detached: true, stdio: 'ignore' });
  await new Promise((resolve, reject) => {
    chrome.once('spawn', resolve);
    chrome.once('error', reject);
  });
  chrome.unref();
}

async function connectChrome() {
  await launchChrome({ debug: true });

  const deadline = performance.now() + waitMs;
  while (performance.now() < deadline) {
    if (interruption) throw new Error(interruption);
    try {
      const [port, endpoint] = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).trim().split(/\r?\n/);
      if (/^\d+$/.test(port) && endpoint?.startsWith('/devtools/browser/')) {
        return await chromium.connectOverCDP(`ws://127.0.0.1:${port}${endpoint}`, {
          timeout: 500, noDefaults: true,
        });
      }
    } catch {
      // Chrome may still be creating its debugging endpoint.
    }
    await sleep(150);
  }
  throw new Error('10 秒内未能连接 Chrome。请先关闭脚本专用 Chrome 的所有窗口');
}

function inspectPage(s) {
  const visible = el => el.getClientRects().length > 0 && getComputedStyle(el).visibility === 'visible';
  const all = (root, selector) => [...root.querySelectorAll(selector)].filter(visible);
  const text = el => el?.innerText?.replace(/\s+/g, ' ').trim() ?? '';
  const point = el => {
    if (!el || el.closest(':disabled,[aria-disabled="true"],[inert]')) return null;
    const box = el.getBoundingClientRect();
    const left = Math.max(0, box.left);
    const right = Math.min(innerWidth, box.right);
    const top = Math.max(0, box.top);
    const bottom = Math.min(innerHeight, box.bottom);
    if (right <= left || bottom <= top) return null;
    const x = (left + right) / 2;
    const y = (top + bottom) / 2;
    return el.contains(document.elementFromPoint(x, y)) ? { x, y } : null;
  };
  const controls = (root, label) => all(root, 'button,a,[role="button"],.btn')
    .filter(el => text(el) === label)
    .filter((el, _, matches) => !matches.some(other => other !== el && other.contains(el)));
  const uniquePoint = elements => elements.length === 1 ? point(elements[0]) : null;
  const cards = all(document, s.card).map(el => {
    const title = all(el, s.cardTitle)[0];
    const link = el.querySelector('a[href*="/job_detail/"]');
    return {
      id: link?.pathname ?? el.getAttribute('data-jobid') ?? '',
      title: text(title), company: text(all(el, s.company)[0]), target: point(title),
    };
  });
  const firstCard = document.querySelector(s.card);
  let scrollArea = null;
  for (let el = firstCard?.parentElement; el && el !== document.body; el = el.parentElement) {
    if (/^(auto|scroll)$/.test(getComputedStyle(el).overflowY) && el.scrollHeight > el.clientHeight) {
      scrollArea = el;
      break;
    }
  }
  const scroller = scrollArea ?? document.scrollingElement;
  const scroll = {
    target: point(scrollArea ?? firstCard?.parentElement),
    top: scroller?.scrollTop ?? 0,
    delta: Math.max(80, Math.min(450, (scroller?.clientHeight ?? 300) * 0.6)),
  };
  const detailRoots = all(document, s.detail);
  const detail = detailRoots.length === 1 ? detailRoots[0] : null;
  const dialogs = all(document, s.dialog).filter((el, _, candidates) =>
    !candidates.some(other => other !== el && el.contains(other)));
  const stay = dialogs.length === 1 ? controls(dialogs[0], '留在此页') : [];
  const bodyText = text(document.body);
  return {
    cards, scroll,
    end: bodyText.split(/\s+/).some(line => s.end.includes(line)),
    challenge: /安全验证|请完成验证|请输入验证码|访问过于频繁|操作过于频繁|访问受限|操作受限|滑动滑块/.test(bodyText),
    dialogs: dialogs.map(el => text(el).slice(0, 300)),
    expectedDialog: dialogs.length === 1 && (stay.length > 0 || text(dialogs[0]).includes('留在此页')),
    stay: uniquePoint(stay),
    detail: detail && {
      title: text(all(detail, s.detailTitle)[0]),
      company: text(all(detail, s.detailCompany)[0]),
      loading: all(detail, s.loading).length > 0 || detail.getAttribute('aria-busy') === 'true',
      chat: uniquePoint(controls(detail, '立即沟通')),
      already: controls(detail, '继续沟通').length === 1,
    },
  };
}

async function readState(dialogAllowed = false, deadline = performance.now() + waitMs) {
  if (interruption) throw new Error(interruption);
  const url = new URL(page.url());
  if (url.origin !== 'https://www.zhipin.com' || url.pathname !== '/web/geek/jobs') {
    throw new Error('页面已离开岗位列表，请检查登录或页面跳转');
  }
  const timeout = new AbortController();
  try {
    observation = await Promise.race([
      page.evaluate(inspectPage, selectors),
      sleep(Math.max(0, deadline - performance.now()), undefined, { signal: timeout.signal })
        .then(() => { throw new Error(`${step}：10 秒内未能读取页面状态`); }),
    ]);
  } catch (error) {
    if (interruption) throw new Error(interruption, { cause: error });
    if (/Execution context was destroyed|Cannot find context with specified id/i.test(error.message)) {
      throw new Error('页面在读取期间发生导航，已停止。可用 npm run open 检查普通 Chrome 是否也会跳转', { cause: error });
    }
    throw error;
  } finally {
    timeout.abort();
  }
  if (interruption) throw new Error(interruption);
  if (observation.challenge) throw new Error('检测到验证码或平台限制提示');
  if (observation.dialogs.length && (!dialogAllowed || !observation.expectedDialog)) {
    throw new Error('检测到流程外弹窗');
  }
  return observation;
}

async function waitFor(predicate, { dialogAllowed = false, tick } = {}) {
  const deadline = performance.now() + waitMs;
  while (performance.now() < deadline) {
    const state = await readState(dialogAllowed, deadline);
    if (performance.now() >= deadline) break;
    const result = predicate(state);
    if (result) return result;
    if (tick) await tick(state);
    await sleep(Math.min(150, Math.max(0, deadline - performance.now())));
  }
  throw new Error(`${step}：10 秒内未满足页面条件`);
}

async function click(target, { dialogAllowed = false, selecting = false, chatting = false } = {}) {
  const until = Math.max(lastClick + clickGap, selecting ? lastJob + jobGap : -Infinity);
  while (performance.now() < until) {
    await readState(dialogAllowed);
    await sleep(Math.min(150, Math.max(0, until - performance.now())));
  }
  const position = target(await readState(dialogAllowed));
  if (!position) throw new Error(`${step}：点击前目标发生变化或不可点击`);
  await page.mouse.move(position.x, position.y, { steps: 8 });
  const confirmed = target(await readState(dialogAllowed));
  if (!confirmed || confirmed.x !== position.x || confirmed.y !== position.y) {
    throw new Error(`${step}：鼠标移动后目标发生变化`);
  }
  if (chatting) chatAttempted = true;
  await page.mouse.click(position.x, position.y);
  lastClick = performance.now();
}

function cardKey(card) {
  return card.id || (card.title && card.company && JSON.stringify([card.title, card.company]));
}

async function chooseNext(previous, processed) {
  let lastScroll = -Infinity;
  const next = state => {
    if (!previous) return state.cards[0];
    const index = state.cards.findIndex(card => cardKey(card) === previous);
    if (index < 0) throw new Error('列表发生变化，无法确认下一条岗位');
    return state.cards[index + 1];
  };
  return waitFor(state => {
    const candidate = next(state);
    if (candidate) {
      const key = cardKey(candidate);
      if (!key || !candidate.title || !candidate.company || processed.has(key) ||
          state.cards.filter(card => cardKey(card) === key).length !== 1 ||
          state.cards.filter(card => card.title === candidate.title && card.company === candidate.company).length !== 1) {
        throw new Error('无法唯一确认下一条岗位');
      }
      return candidate.target ? candidate : null;
    }
    return state.end ? { end: true } : null;
  }, { tick: async state => {
    if (state.scroll.target && performance.now() - lastScroll >= 500) {
      const { x, y } = state.scroll.target;
      await page.mouse.move(x, y);
      await page.mouse.wheel(0, state.scroll.delta);
      lastScroll = performance.now();
    }
  } });
}

function matchingDetail(state) {
  const detail = state.detail;
  return detail && !detail.loading && detail.title === job.title && detail.company === job.company
    ? detail : null;
}

async function run() {
  const processed = new Set();
  let previous;
  for (;;) {
    step = previous ? '确认下一条岗位' : '确认第一条岗位';
    job = undefined;
    chatAttempted = false;
    const next = await chooseNext(previous, processed);
    if (next.end) return;
    job = next;
    const key = cardKey(job);
    step = '点击岗位';
    await click(state => {
      const index = previous ? state.cards.findIndex(card => cardKey(card) === previous) + 1 : 0;
      if (previous && index === 0) return null;
      const card = state.cards[index];
      return card && cardKey(card) === key && card.title === job.title && card.company === job.company &&
        state.cards.filter(item => item.title === job.title && item.company === job.company).length === 1
        ? card.target : null;
    }, { selecting: true });

    step = '等待当前岗位详情及沟通按钮';
    const detail = await waitFor(state => {
      const current = matchingDetail(state);
      return current && Boolean(current.chat) !== current.already ? current : null;
    });
    if (detail.already) {
      console.log(`已跳过「继续沟通」 ${job.title} / ${job.company}`);
    } else {
      step = '点击立即沟通';
      await click(state => {
        const current = matchingDetail(state);
        return current && !current.already ? current.chat : null;
      }, { chatting: true });

      step = '等待沟通弹窗及留在此页';
      await waitFor(state => state.stay, { dialogAllowed: true });
      step = '点击留在此页';
      await click(state => state.stay, { dialogAllowed: true });
      step = '确认弹窗关闭并返回岗位列表';
      await waitFor(state => !state.dialogs.length && state.cards.some(card => cardKey(card) === key),
        { dialogAllowed: true });
      count += 1;
      console.log(`已完成沟通点击流程 ${job.title} / ${job.company}`);
    }
    lastJob = performance.now();
    processed.add(key);
    previous = key;
  }
}

async function saveFailure(error) {
  await mkdir(logs, { recursive: true });
  const base = join(logs, `${new Date().toISOString().replaceAll(':', '-')}-${process.pid}`);
  const report = {
    time: new Date().toISOString(), url: page?.url(), step,
    job: job && { id: job.id, title: job.title, company: job.company },
    reason: error.message, chatAttempted, completed: count, observation, navigation,
  };
  if (page && !page.isClosed()) {
    try {
      await page.screenshot({ path: `${base}.png`, timeout: 2000 });
    } catch (screenshotError) {
      report.screenshotError = screenshotError.message;
    }
  }
  await writeFile(`${base}.json`, JSON.stringify(report, null, 2), 'utf8');
  console.error(`脚本已退出：${error.message}\n异常记录：${base}.json`);
}

try {
  if (process.argv.includes('--login') || process.argv.includes('--open')) {
    await launchChrome();
    console.log('已请求用普通 Chrome 打开岗位页。请先关闭之前由脚本启动的专用 Chrome 窗口，再使用此模式核对页面。');
  } else {
    browser = await connectChrome();
    const context = browser.contexts()[0];
    page = context.pages().find(tab => tab.url() === 'about:blank') ?? await context.newPage();
    page.on('popup', () => { interruption ??= '页面打开了流程外的新窗口'; });
    page.on('dialog', () => { interruption ??= '检测到流程外的浏览器原生弹窗'; });
    let loaded = false;
    page.on('framenavigated', frame => {
      if (frame !== page.mainFrame()) return;
      const url = new URL(frame.url());
      navigation.push({ time: new Date().toISOString(), page: url.origin + url.pathname });
      if (navigation.length > 20) navigation.shift();
      if (loaded || url.origin !== 'https://www.zhipin.com' || url.pathname !== '/web/geek/jobs') {
        interruption ??= '页面发生流程外导航，已停止。可用 npm run open 检查普通 Chrome 是否也会跳转';
      }
    });
    await page.goto(jobsUrl, { waitUntil: 'domcontentloaded', timeout: waitMs });
    loaded = true;
    await run();
    console.log(`列表处理结束，完成 ${count} 次沟通点击流程。`);
  }
} catch (error) {
  process.exitCode = 1;
  try {
    await saveFailure(error);
  } catch (logError) {
    console.error(`脚本已退出：${error.message}\n日志保存失败：${logError.message}`);
  }
} finally {
  await browser?.close();
}
