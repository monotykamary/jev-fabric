import { execFile } from 'node:child_process';
import type { Answer, Description, JevRequest, JevResponse, Question } from './types.js';
import { abortable, integer, json, record } from './util.js';

export type JevProvider = 'typesafe' | 'openrouter' | 'vercel';
const routes = {
  typesafe: { endpoint: 'https://api.typesafe.ai/v1/systemone', key: 'TYPESAFE_API_KEY', model: 'jev-latest' },
  openrouter: { endpoint: 'https://openrouter.ai/api/alpha/decisions', key: 'OPENROUTER_API_KEY', model: 'typesafe/jev-1.13' },
  vercel: { endpoint: 'https://ai-gateway.vercel.sh/typesafe/v1/systemone', key: 'AI_GATEWAY_API_KEY', model: 'typesafe-ai/jev' },
} as const;
const description = (v: unknown): v is Description => typeof v === 'string' || Array.isArray(v) || record(v);
const probability = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= 1;
const only = (v: Record<string, unknown>, keys: string[]) => Object.keys(v).every(k => keys.includes(k));

export function validateRequest(value: unknown): asserts value is JevRequest {
  json(value);
  if (!record(value) || !only(value, ['state', 'questions', 'model']) || !description(value.state) || !record(value.questions) ||
      Object.keys(value.questions).length < 1 || Object.keys(value.questions).length > 128 ||
      (value.model !== undefined && (typeof value.model !== 'string' || !value.model || value.model.length > 128))) throw new Error('Invalid Jev request');
  for (const [id, q] of Object.entries(value.questions)) {
    if (!id || id.length > 128 || !record(q) || !only(q, ['type', 'instructions', 'criteria']) || !description(q.instructions)) throw new Error('Invalid Jev question');
    if (q.type === 'choice') {
      if (!record(q.criteria) || !Object.keys(q.criteria).length || Object.keys(q.criteria).length > 255 ||
          !Object.entries(q.criteria).every(([k, v]) => k.length > 0 && k.length <= 256 && (v === null || description(v)))) throw new Error('Choice requires 1..255 described options');
    } else if (q.type === 'score') {
      if (!Array.isArray(q.criteria) || q.criteria.length < 2 || q.criteria.length > 10 || !q.criteria.every(description)) throw new Error('Score requires 2..10 ordered levels');
    } else if (q.type === 'noul') {
      if (q.criteria !== undefined && (!record(q.criteria) || !only(q.criteria, ['true', 'false']) || !Object.values(q.criteria).every(description))) throw new Error('Invalid Noul criteria');
    } else throw new Error('Jev supplies choice, noul, and score, not generated text');
  }
}

export function validateResponse(value: unknown, request: JevRequest): JevResponse {
  const invalid = (): never => { throw new Error('Invalid typed Jev response'); };
  if (!record(value) || typeof value.model !== 'string' || !value.model || value.model.length > 128 || !record(value.answers) || !record(value.usage)) return invalid();
  if (![value.usage.input_tokens, value.usage.output_tokens].every(v => Number.isSafeInteger(v) && (v as number) >= 0)) return invalid();
  if (Object.keys(value.answers).length !== Object.keys(request.questions).length) return invalid();
  const answers: [string, Answer][] = [];
  for (const [id, q] of Object.entries(request.questions)) {
    const a = Object.hasOwn(value.answers, id) ? value.answers[id] : null;
    if (!record(a) || a.type !== q.type) return invalid();
    if (q.type === 'noul') {
      if (!probability(a.noul)) return invalid();
      answers.push([id, { type: 'noul', noul: a.noul }]); continue;
    }
    const keys = q.type === 'choice' ? Object.keys(q.criteria) : q.criteria.map((_, i) => String(i));
    const p = a.probabilities;
    if (!record(p) || !probability(a.confidence) || Object.keys(p).length !== keys.length || !keys.every(k => Object.hasOwn(p, k) && probability(p[k])) ||
        Math.abs(Object.values(p).reduce<number>((sum, n) => sum + (n as number), 0) - 1) > 0.02) return invalid();
    const probabilities = Object.fromEntries(keys.map(k => [k, p[k] as number]));
    if (q.type === 'choice') {
      if (typeof a.choice !== 'string' || !Object.hasOwn(q.criteria, a.choice)) return invalid();
      answers.push([id, { type: 'choice', choice: a.choice, confidence: a.confidence, probabilities }]);
    } else {
      if (typeof a.score !== 'number' || !Number.isFinite(a.score) || a.score < 0 || a.score > keys.length - 1) return invalid();
      answers.push([id, { type: 'score', score: a.score, confidence: a.confidence, probabilities, legend: Object.fromEntries(q.criteria.map((x, i) => [String(i), x])) }]);
    }
  }
  return { model: value.model, answers: Object.fromEntries(answers), usage: { input_tokens: value.usage.input_tokens as number, output_tokens: value.usage.output_tokens as number } };
}

export interface JevOptions {
  provider?: JevProvider; model?: string; apiKey?: string; fetch?: typeof fetch; signal?: AbortSignal;
  credentialCommand?: readonly string[];
  timeoutMs?: number; maxEvaluations?: number; maxTokens?: number;
  onUsage?: (stats: { evaluations: number; usage: { input_tokens: number; output_tokens: number } }) => void;
}
export class JevClient {
  evaluations = 0;
  readonly usage = { input_tokens: 0, output_tokens: 0 };
  private active = false;
  #commandKey: string | undefined;
  private readonly route;
  constructor(private readonly options: JevOptions = {}) {
    const provider = options.provider ?? process.env.JEV_PROVIDER ?? 'typesafe';
    if (!Object.hasOwn(routes, provider)) throw new Error('JEV_PROVIDER must be typesafe, openrouter, or vercel');
    this.route = routes[provider as JevProvider];
    integer(options.timeoutMs ?? 15000, 'request timeout');
    integer(options.maxEvaluations ?? 100, 'evaluation budget');
    integer(options.maxTokens ?? 100000, 'token budget');
  }
  private async credential(signal: AbortSignal): Promise<string> {
    const direct = this.options.apiKey ?? process.env[this.route.key];
    if (direct?.trim()) return direct.trim();
    if (this.#commandKey) return this.#commandKey;
    let command: unknown = this.options.credentialCommand;
    if (!command && process.env.JEV_CREDENTIAL_COMMAND) {
      try { command = JSON.parse(process.env.JEV_CREDENTIAL_COMMAND); } catch { throw new Error('JEV_CREDENTIAL_COMMAND must be a JSON argv array'); }
    }
    if (!command) throw new Error(`Missing ${this.route.key}; optionally configure JEV_CREDENTIAL_COMMAND`);
    if (!Array.isArray(command) || !command.length || !command.every(x => typeof x === 'string' && !x.includes('\0')) || !command[0]) throw new Error('Credential command must be a nonempty argv array');
    const key = await new Promise<string>((resolveKey, reject) => {
      execFile(command[0], command.slice(1), { encoding: 'utf8', timeout: 5000, maxBuffer: 16384, signal }, (error, stdout) => {
        // Subprocess errors can contain secrets in stdout/stderr: never propagate them.
        if (error) reject(new Error('Private credential command failed')); else resolveKey(stdout.trim());
      });
    });
    signal.throwIfAborted();
    if (!key || /[\r\n]/.test(key)) throw new Error('Private credential command returned an invalid key');
    this.#commandKey = key;
    return key;
  }
  async evaluate<const Q extends Record<string, Question>>(request: JevRequest<Q>): Promise<JevResponse<Q>> {
    validateRequest(request);
    request = structuredClone(request);
    if (this.active) throw new Error('One evaluation in flight per client; batch independent questions');
    this.options.signal?.throwIfAborted();
    if (this.evaluations >= (this.options.maxEvaluations ?? 100) || this.usage.input_tokens + this.usage.output_tokens >= (this.options.maxTokens ?? 100000)) throw new Error('Jev budget exhausted');
    const signal = AbortSignal.any([AbortSignal.timeout(this.options.timeoutMs ?? 15000), ...(this.options.signal ? [this.options.signal] : [])]);
    const body = json({ ...request, model: request.model ?? this.options.model ?? process.env.JEV_MODEL ?? this.route.model });
    this.active = true;
    let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
    try {
      const key = await abortable(signal, this.credential(signal));
      signal.throwIfAborted();
      this.evaluations++;
      this.options.onUsage?.({ evaluations: this.evaluations, usage: { ...this.usage } });
      let response: Response;
      try {
        response = await abortable(signal, (this.options.fetch ?? fetch)(this.route.endpoint, {
          method: 'POST', redirect: 'error', signal, headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` }, body,
        }));
      } catch { throw new Error(signal.aborted ? 'Jev request cancelled or timed out' : 'Jev network request failed'); }
      if (!response.ok) {
        void response.body?.cancel().catch(() => {});
        throw new Error(`Jev HTTP ${response.status}; no automatic retry`);
      }
      reader = response.body?.getReader();
      if (!reader) throw new Error('Empty Jev response');
      const chunks: Uint8Array[] = [];
      let size = 0;
      for (;;) {
        const part = await abortable(signal, reader.read());
        if (part.done) break;
        size += part.value.byteLength;
        if (size > 1048576) throw new Error('Jev response exceeds 1 MiB');
        chunks.push(part.value);
      }
      let parsed: unknown;
      try { parsed = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw new Error('Invalid Jev JSON response'); }
      const result = validateResponse(parsed, request);
      this.usage.input_tokens += result.usage.input_tokens;
      this.usage.output_tokens += result.usage.output_tokens;
      this.options.onUsage?.({ evaluations: this.evaluations, usage: { ...this.usage } });
      if (this.usage.input_tokens + this.usage.output_tokens > (this.options.maxTokens ?? 100000)) throw new Error('Jev reported-token budget exceeded; final request may still be billed');
      return result as JevResponse<Q>;
    } finally { this.active = false; void reader?.cancel().catch(() => {}); }
  }
}
