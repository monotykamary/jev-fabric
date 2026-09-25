// Browser bridge for examples/native/browse.bend.
//
// Owns one Chrome tab through browser-harness-js's guarded InteractionController
// (trusted input) and speaks JSON lines over stdio:
//   bridge -> orchestrator: {"step":n,"log":"...","request":{...Jev request...}} or {"done":{...}}
//   orchestrator -> bridge: the complete Jev evaluation ({"model":...,"answers":{...},...})
// Every model call happens in the Bend orchestrator; this process never touches the network
// except to drive the browser. Model output only ever selects observed candidate indexes or
// text spans copied from the goal: never selectors, coordinates or scripts.
import { spawn, type ChildProcess } from 'node:child_process';
import { appendFileSync, existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';

const SDK = resolve(process.env.BROWSER_HARNESS_SDK ?? '../browser-harness-js/skills/cdp/sdk');
const { Session } = await import(join(SDK, 'session.ts'));
const { InteractionController } = await import(join(SDK, 'interaction.ts'));

const START_URL = process.env.BROWSE_URL ?? 'https://en.wikipedia.org/wiki/Main_Page';
const GOAL = process.env.BROWSE_GOAL ?? "Find and open the Wikipedia article about Gödel's incompleteness theorems.";
const MAX_STEPS = Number(process.env.BROWSE_STEPS ?? '15');
const ORIGINS = [new URL(START_URL).origin, ...(process.env.BROWSE_ORIGINS ?? '').split(',').filter(Boolean)];
const SETTLE_MS = 1500;
// Optional JSONL trace of every request and answer (never credentials; page text only).
const TRACE = process.env.BROWSE_TRACE;
const trace = (entry: unknown) => { if (TRACE) appendFileSync(TRACE, JSON.stringify(entry) + '\n'); };

type Candidate = {
  id: string;
  role: string;
  label: string;
  operations: string[];
  value?: string;
  expanded?: boolean;
  checked?: boolean;
  selected?: boolean;
  context?: string;
};
type Observation = { observationId: string; revision: string; candidates: Candidate[]; url: string; title: string; scope: { sessionId: string } };

const emit = (message: unknown) => process.stdout.write(JSON.stringify(message) + '\n');
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

// ---- Chrome ---------------------------------------------------------------------------------

function chromePath(): string {
  const found = [
    process.env.CHROME_PATH,
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
  ].find(path => path && existsSync(path));
  if (!found) throw new Error('Chrome not found; set CHROME_PATH');
  return found;
}

async function launchChrome(): Promise<{ port: number; stop: () => Promise<void> }> {
  const profile = mkdtempSync(join(tmpdir(), 'jev-fabric-browse-'));
  const headless = process.env.BROWSE_VISIBLE === '1' ? [] : ['--headless=new'];
  const chrome: ChildProcess = spawn(chromePath(), [
    ...headless, '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--no-first-run',
    '--no-default-browser-check', '--window-size=1280,900', '--lang=en-US', 'about:blank',
  ], { stdio: 'ignore' });
  const portFile = join(profile, 'DevToolsActivePort');
  for (let i = 0; i < 100 && !existsSync(portFile); i++) await sleep(100);
  const port = Number(readFileSync(portFile, 'utf8').split('\n')[0]);
  const stop = async () => {
    if (chrome.exitCode === null) {
      const exited = new Promise(r => chrome.once('exit', r));
      chrome.kill();
      await exited;
    }
    rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  };
  return { port, stop };
}

// ---- Text the agent may type: word spans copied from the goal -------------------------------

function goalSpans(goal: string): string[] {
  const words = goal.split(/\s+/).map(word => word.replace(/^[("'“‘]+|[)"'”’.,;:!?]+$/g, '')).filter(Boolean);
  const spans = new Set<string>();
  for (let length = 1; length <= 6; length++) {
    for (let start = 0; start + length <= words.length; start++) spans.add(words.slice(start, start + length).join(' '));
  }
  return [...spans].filter(span => span.length <= 256).slice(0, 255);
}

// ---- One Jev request per step ---------------------------------------------------------------

function describe(c: Candidate): string {
  const parts = [`${c.role}: ${c.label || '(unlabelled)'}`];
  if (c.value) parts.push(`value "${c.value.slice(0, 80)}"`);
  if (c.expanded !== undefined) parts.push(c.expanded ? 'expanded' : 'collapsed');
  if (c.checked !== undefined) parts.push(c.checked ? 'checked' : 'unchecked');
  if (c.selected) parts.push('selected');
  if (c.context) parts.push(`in ${c.context}`);
  return parts.join(', ');
}

function targets(seen: Observation, ...operations: string[]): Record<string, string> {
  const out: Record<string, string> = {};
  seen.candidates.forEach((candidate, index) => {
    if (operations.some(op => candidate.operations.includes(op))) out[String(index + 1)] = describe(candidate);
  });
  return out;
}

function request(seen: Observation, history: string[], spans: string[]) {
  const clickable = targets(seen, 'click');
  const typable = targets(seen, 'type');
  const scrollable = targets(seen, 'scroll_down', 'scroll_up');
  const operations: Record<string, string> = {};
  if (Object.keys(clickable).length) operations.click = 'Click one of the listed elements.';
  if (Object.keys(typable).length) {
    operations.type = 'Replace the text in a field with text from the goal.';
    operations.press_enter = 'Press Enter in a field, for example to submit a search already typed.';
  }
  if (Object.keys(scrollable).length) {
    operations.scroll_down = 'Scroll the page or a list down to reveal more of it.';
    operations.scroll_up = 'Scroll the page or a list back up.';
  }
  operations.done = 'The current page already shows what the goal asks for.';
  operations.blocked = 'The goal cannot be completed from here.';
  const questions: Record<string, unknown> = {
    operation: {
      type: 'choice',
      instructions: 'Choose the next operation that makes the most progress toward the goal. Before submitting a form or ' +
        'choosing done, check that every detail the goal specifies (options, places, dates, counts) is already set ' +
        'on the page, and fix any that are not. Do not repeat an action that already failed.',
      criteria: operations,
    },
  };
  // Speculative targets: all heads are answered in the same round trip; only the one
  // matching the chosen operation is used.
  if (Object.keys(clickable).length) {
    questions.click_target = { type: 'choice', instructions: 'If the operation is click, which element?', criteria: clickable };
  }
  if (Object.keys(typable).length) {
    questions.type_target = { type: 'choice', instructions: 'If typing or pressing Enter, which field?', criteria: typable };
    questions.type_text = {
      type: 'choice',
      instructions: 'If typing, which exact text from the goal belongs in that field?',
      criteria: Object.fromEntries(spans.map(span => [span, null])),
    };
  }
  if (Object.keys(scrollable).length) {
    questions.scroll_target = { type: 'choice', instructions: 'If scrolling, what should scroll?', criteria: scrollable };
  }
  return {
    state: {
      goal: GOAL,
      page: { url: seen.url, title: seen.title },
      history: history.slice(-6),
      elements: seen.candidates.map((c, i) => `[${i + 1}] ${describe(c)}`),
    },
    questions,
  };
}

// ---- Driving the page -----------------------------------------------------------------------

async function observe(controller: any, scope: { sessionId: string }): Promise<Observation> {
  // Navigation invalidates observations mid-flight; retry briefly until the page settles.
  let lastError: unknown;
  for (let attempt = 0; attempt < 20; attempt++) {
    try {
      return await controller.observe({ scope, maxElements: 128 });
    } catch (error) {
      lastError = error;
      await sleep(150);
    }
  }
  throw lastError;
}

// Return as soon as the page's observable state changes (polled every 100 ms), or at `ms`.
async function settle(controller: any, scope: { sessionId: string }, revision: string, ms: number) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    await sleep(100);
    try {
      const seen = await controller.observe({ scope, maxElements: 128 });
      if (seen.revision !== revision) return;
    } catch {
      return; // navigating: the next observe retries until the new page settles
    }
  }
}

// Client-rendered apps paint after `load`: wait until there is something to act on and
// the observable state holds still for one poll (at most `ms`).
async function interactive(controller: any, scope: { sessionId: string }, ms: number): Promise<Observation> {
  const end = Date.now() + ms;
  let previous = await observe(controller, scope);
  while (Date.now() < end) {
    await sleep(150);
    const current = await observe(controller, scope);
    if (current.candidates.length > 0 && current.revision === previous.revision) return current;
    previous = current;
  }
  return previous;
}

function choice(answers: any, question: string): string | undefined {
  return answers?.[question]?.choice;
}

async function main() {
  const chrome = await launchChrome();
  const session = new Session();
  await session.connect({ port: chrome.port });
  const { targetId } = await session.domains.Target.createTarget({ url: START_URL });
  const { sessionId } = await session.domains.Target.attachToTarget({ targetId, flatten: true });
  await session._call('Page.enable', {}, { sessionId });
  await session._call('Runtime.evaluate', {
    expression: 'new Promise(r => document.readyState === "complete" ? r() : addEventListener("load", r))',
    awaitPromise: true,
  }, { sessionId });
  const scope = { sessionId };
  const controller = new InteractionController(session, { allowedOrigins: ORIGINS, input: 'trusted' });
  const input = createInterface({ input: process.stdin });
  const lines = input[Symbol.asyncIterator]();
  const spans = goalSpans(GOAL);
  const history: string[] = [];
  const started = Date.now();
  let log = `opened ${START_URL}`;
  let outcome = 'step limit reached';

  try {
    for (let step = 0; step < MAX_STEPS; step++) {
      const seen = await interactive(controller, scope, 5000);
      if (seen.candidates.length === 0) {
        outcome = 'nothing to interact with';
        break;
      }
      const asked = request(seen, history, spans);
      trace({ step, request: asked });
      emit({ step, log, request: asked });
      const next = await lines.next();
      if (next.done) {
        outcome = 'orchestrator closed';
        break;
      }
      const answers = JSON.parse(next.value).answers;
      trace({ step, answers });
      const operation = choice(answers, 'operation');
      const actOn = async (index: string | undefined, action: Record<string, unknown>) => {
        const candidate = seen.candidates[Number(index) - 1];
        if (!candidate) return 'no such element';
        const receipt = await controller.act({ scope, observationId: seen.observationId, action: { targetId: candidate.id, ...action } });
        return `${receipt.status}${receipt.reason ? ` (${receipt.reason})` : ''} on ${describe(candidate)}`;
      };
      if (operation === 'done' || operation === 'blocked') {
        outcome = operation;
        log = `${operation} at ${seen.title}`;
        break;
      }
      let result: string;
      if (operation === 'click') {
        result = await actOn(choice(answers, 'click_target'), { operation: 'click' });
      } else if (operation === 'type') {
        const text = choice(answers, 'type_text') ?? '';
        result = await actOn(choice(answers, 'type_target'), { operation: 'type', text });
        result = `typed "${text}": ${result}`;
      } else if (operation === 'scroll_down' || operation === 'scroll_up') {
        result = await actOn(choice(answers, 'scroll_target'), { operation });
      } else if (operation === 'press_enter') {
        result = await actOn(choice(answers, 'type_target'), { operation: 'press', key: 'Enter' });
      } else {
        result = `unknown operation ${operation}`;
      }
      log = `${operation}: ${result}`;
      history.push(log);
      await settle(controller, scope, seen.revision, operation === 'type' ? 600 : SETTLE_MS);
    }
    const final = await observe(controller, scope).catch(() => undefined);
    emit({ done: { outcome, url: final?.url, title: final?.title, elapsed_ms: Date.now() - started, log } });
  } finally {
    controller.close();
    session.close();
    await chrome.stop();
    input.close();
  }
}

main().catch(error => {
  emit({ error: String(error?.message ?? error) });
  process.exit(1);
});
