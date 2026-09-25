import { execFile } from 'node:child_process';
import type { Answer, Description, JevRequest, JevResponse, Question } from './types.js';
import { abortable, integer, json, record } from './util.js';

export type JevProvider = 'typesafe' | 'openrouter' | 'vercel';
const routes = {
  typesafe: {
    endpoint: 'https://api.typesafe.ai/v1/systemone',
    key: 'TYPESAFE_API_KEY',
    model: 'jev-latest',
  },
  openrouter: {
    endpoint: 'https://openrouter.ai/api/alpha/decisions',
    key: 'OPENROUTER_API_KEY',
    model: 'typesafe/jev-1.13',
  },
  vercel: {
    endpoint: 'https://ai-gateway.vercel.sh/typesafe/v1/systemone',
    key: 'AI_GATEWAY_API_KEY',
    model: 'typesafe-ai/jev',
  },
} as const;

const MAX_QUESTIONS = 128;
const MAX_NAME_LENGTH = 128;
const MAX_CHOICE_OPTIONS = 255;
const MAX_OPTION_KEY_LENGTH = 256;
const MIN_SCORE_LEVELS = 2;
const MAX_SCORE_LEVELS = 10;
const PROBABILITY_SUM_TOLERANCE = 0.02;
const MAX_RESPONSE_BYTES = 1048576;
const DEFAULT_TIMEOUT_MS = 15000;
const DEFAULT_MAX_EVALUATIONS = 100;
const DEFAULT_MAX_TOKENS = 100000;
const CREDENTIAL_TIMEOUT_MS = 5000;
const CREDENTIAL_MAX_OUTPUT_BYTES = 16384;

const REQUEST_KEYS = ['state', 'questions', 'model'];
const QUESTION_KEYS = ['type', 'instructions', 'criteria'];
const NOUL_CRITERIA_KEYS = ['true', 'false'];

type Usage = { input_tokens: number; output_tokens: number };
type ChoiceQuestion = Extract<Question, { type: 'choice' }>;
type ScoreQuestion = Extract<Question, { type: 'score' }>;

const description = (v: unknown): v is Description => typeof v === 'string' || Array.isArray(v) || record(v);
const probability = (v: unknown): v is number =>
  typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= 1;
const only = (v: Record<string, unknown>, keys: string[]) => Object.keys(v).every(k => keys.includes(k));
const isTokenCount = (v: unknown): v is number => Number.isSafeInteger(v) && (v as number) >= 0;
const totalTokens = (usage: Usage) => usage.input_tokens + usage.output_tokens;

function isModelName(model: unknown): model is string {
  return typeof model === 'string' && model.length > 0 && model.length <= MAX_NAME_LENGTH;
}

function hasValidQuestionCount(questions: Record<string, unknown>): boolean {
  const count = Object.keys(questions).length;
  return count >= 1 && count <= MAX_QUESTIONS;
}

function isRequestEnvelope(value: unknown): value is { questions: Record<string, unknown> } {
  return record(value)
    && only(value, REQUEST_KEYS)
    && description(value.state)
    && record(value.questions)
    && hasValidQuestionCount(value.questions)
    && (value.model === undefined || isModelName(value.model));
}

function isQuestionEnvelope(id: string, question: unknown): question is Record<string, unknown> {
  return id.length > 0
    && id.length <= MAX_NAME_LENGTH
    && record(question)
    && only(question, QUESTION_KEYS)
    && description(question.instructions);
}

function isChoiceOption([key, option]: [string, unknown]): boolean {
  return key.length > 0 && key.length <= MAX_OPTION_KEY_LENGTH && (option === null || description(option));
}

function isChoiceCriteria(criteria: unknown): boolean {
  if (!record(criteria)) return false;
  const options = Object.entries(criteria);
  return options.length >= 1 && options.length <= MAX_CHOICE_OPTIONS && options.every(isChoiceOption);
}

function isScoreCriteria(criteria: unknown): boolean {
  return Array.isArray(criteria)
    && criteria.length >= MIN_SCORE_LEVELS
    && criteria.length <= MAX_SCORE_LEVELS
    && criteria.every(description);
}

function isNoulCriteria(criteria: unknown): boolean {
  if (criteria === undefined) return true;
  return record(criteria) && only(criteria, NOUL_CRITERIA_KEYS) && Object.values(criteria).every(description);
}

function validateCriteria(question: Record<string, unknown>): void {
  if (question.type === 'choice') {
    if (!isChoiceCriteria(question.criteria)) throw new Error('Choice requires 1..255 described options');
  } else if (question.type === 'score') {
    if (!isScoreCriteria(question.criteria)) throw new Error('Score requires 2..10 ordered levels');
  } else if (question.type === 'noul') {
    if (!isNoulCriteria(question.criteria)) throw new Error('Invalid Noul criteria');
  } else {
    throw new Error('Jev supplies choice, noul, and score, not generated text');
  }
}

export function validateRequest(value: unknown): asserts value is JevRequest {
  json(value);
  if (!isRequestEnvelope(value)) throw new Error('Invalid Jev request');
  for (const [id, question] of Object.entries(value.questions)) {
    if (!isQuestionEnvelope(id, question)) throw new Error('Invalid Jev question');
    validateCriteria(question);
  }
}

const invalidResponse = (): never => {
  throw new Error('Invalid typed Jev response');
};

function isResponseEnvelope(value: unknown): value is {
  model: string;
  answers: Record<string, unknown>;
  usage: Usage;
} {
  return record(value)
    && isModelName(value.model)
    && record(value.answers)
    && record(value.usage)
    && isTokenCount(value.usage.input_tokens)
    && isTokenCount(value.usage.output_tokens);
}

/** Choice answers are keyed by option name; score answers by level index. */
function optionKeys(question: ChoiceQuestion | ScoreQuestion): string[] {
  if (question.type === 'choice') return Object.keys(question.criteria);
  return question.criteria.map((_, index) => String(index));
}

function sum(values: unknown[]): number {
  return values.reduce<number>((total, n) => total + (n as number), 0);
}

function isDistributionOver(distribution: unknown, keys: string[]): distribution is Record<string, number> {
  return record(distribution)
    && Object.keys(distribution).length === keys.length
    && keys.every(key => Object.hasOwn(distribution, key) && probability(distribution[key]))
    && Math.abs(sum(Object.values(distribution)) - 1) <= PROBABILITY_SUM_TOLERANCE;
}

function isScoreWithin(score: unknown, levels: number): score is number {
  return typeof score === 'number' && Number.isFinite(score) && score >= 0 && score <= levels - 1;
}

function scoreLegend(levels: Description[]) {
  return Object.fromEntries(levels.map((level, index) => [String(index), level]));
}

function parseAnswer(question: Question, answer: unknown): Answer {
  if (!record(answer) || answer.type !== question.type) return invalidResponse();
  if (question.type === 'noul') {
    if (!probability(answer.noul)) return invalidResponse();
    return { type: 'noul', noul: answer.noul };
  }
  const keys = optionKeys(question);
  const distribution = answer.probabilities;
  if (!probability(answer.confidence) || !isDistributionOver(distribution, keys)) return invalidResponse();
  const confidence = answer.confidence;
  const probabilities = Object.fromEntries(keys.map(key => [key, distribution[key] as number]));
  if (question.type === 'choice') {
    const choice = answer.choice;
    if (typeof choice !== 'string' || !Object.hasOwn(question.criteria, choice)) return invalidResponse();
    return { type: 'choice', choice, confidence, probabilities };
  }
  if (!isScoreWithin(answer.score, keys.length)) return invalidResponse();
  const legend = scoreLegend(question.criteria);
  return { type: 'score', score: answer.score, confidence, probabilities, legend };
}

export function validateResponse(value: unknown, request: JevRequest): JevResponse {
  if (!isResponseEnvelope(value)) return invalidResponse();
  if (Object.keys(value.answers).length !== Object.keys(request.questions).length) return invalidResponse();
  const answers: [string, Answer][] = [];
  for (const [id, question] of Object.entries(request.questions)) {
    const answer = Object.hasOwn(value.answers, id) ? value.answers[id] : null;
    answers.push([id, parseAnswer(question, answer)]);
  }
  const usage = { input_tokens: value.usage.input_tokens, output_tokens: value.usage.output_tokens };
  return { model: value.model, answers: Object.fromEntries(answers), usage };
}

function parseCredentialCommandEnv(): unknown {
  try {
    return JSON.parse(process.env.JEV_CREDENTIAL_COMMAND!);
  } catch {
    throw new Error('JEV_CREDENTIAL_COMMAND must be a JSON argv array');
  }
}

function isArgv(command: unknown): command is [string, ...string[]] {
  return Array.isArray(command)
    && command.length > 0
    && command.every(arg => typeof arg === 'string' && !arg.includes('\0'))
    && Boolean(command[0]);
}

function runCredentialCommand(command: [string, ...string[]], signal: AbortSignal): Promise<string> {
  const options = {
    encoding: 'utf8' as const,
    timeout: CREDENTIAL_TIMEOUT_MS,
    maxBuffer: CREDENTIAL_MAX_OUTPUT_BYTES,
    signal,
  };
  return new Promise<string>((resolveKey, reject) => {
    execFile(command[0], command.slice(1), options, (error, stdout) => {
      // Subprocess errors can contain secrets in stdout/stderr: never propagate them.
      if (error) reject(new Error('Private credential command failed'));
      else resolveKey(stdout.trim());
    });
  });
}

async function readBoundedBody(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  signal: AbortSignal,
): Promise<Buffer> {
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const part = await abortable(signal, reader.read());
    if (part.done) break;
    size += part.value.byteLength;
    if (size > MAX_RESPONSE_BYTES) throw new Error('Jev response exceeds 1 MiB');
    chunks.push(part.value);
  }
  return Buffer.concat(chunks);
}

function parseResponseJson(body: Buffer): unknown {
  try {
    return JSON.parse(body.toString('utf8'));
  } catch {
    throw new Error('Invalid Jev JSON response');
  }
}

export interface JevOptions {
  provider?: JevProvider;
  model?: string;
  apiKey?: string;
  fetch?: typeof fetch;
  signal?: AbortSignal;
  credentialCommand?: readonly string[];
  timeoutMs?: number;
  maxEvaluations?: number;
  maxTokens?: number;
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
    if (!Object.hasOwn(routes, provider)) {
      throw new Error('JEV_PROVIDER must be typesafe, openrouter, or vercel');
    }
    this.route = routes[provider as JevProvider];
    integer(options.timeoutMs ?? DEFAULT_TIMEOUT_MS, 'request timeout');
    integer(options.maxEvaluations ?? DEFAULT_MAX_EVALUATIONS, 'evaluation budget');
    integer(options.maxTokens ?? DEFAULT_MAX_TOKENS, 'token budget');
  }
  private async credential(signal: AbortSignal): Promise<string> {
    const direct = this.options.apiKey ?? process.env[this.route.key];
    if (direct?.trim()) return direct.trim();
    if (this.#commandKey) return this.#commandKey;
    let command: unknown = this.options.credentialCommand;
    if (!command && process.env.JEV_CREDENTIAL_COMMAND) command = parseCredentialCommandEnv();
    if (!command) throw new Error(`Missing ${this.route.key}; optionally configure JEV_CREDENTIAL_COMMAND`);
    if (!isArgv(command)) throw new Error('Credential command must be a nonempty argv array');
    const key = await runCredentialCommand(command, signal);
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
    const maxEvaluations = this.options.maxEvaluations ?? DEFAULT_MAX_EVALUATIONS;
    const maxTokens = this.options.maxTokens ?? DEFAULT_MAX_TOKENS;
    if (this.evaluations >= maxEvaluations || totalTokens(this.usage) >= maxTokens) {
      throw new Error('Jev budget exhausted');
    }
    const signal = AbortSignal.any([
      AbortSignal.timeout(this.options.timeoutMs ?? DEFAULT_TIMEOUT_MS),
      ...(this.options.signal ? [this.options.signal] : []),
    ]);
    const model = request.model ?? this.options.model ?? process.env.JEV_MODEL ?? this.route.model;
    const body = json({ ...request, model });
    this.active = true;
    let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
    try {
      const key = await abortable(signal, this.credential(signal));
      signal.throwIfAborted();
      this.evaluations++;
      this.options.onUsage?.({ evaluations: this.evaluations, usage: { ...this.usage } });
      let response: Response;
      try {
        const fetcher = this.options.fetch ?? fetch;
        response = await abortable(signal, fetcher(this.route.endpoint, {
          method: 'POST',
          redirect: 'error',
          signal,
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
          body,
        }));
      } catch {
        throw new Error(signal.aborted ? 'Jev request cancelled or timed out' : 'Jev network request failed');
      }
      if (!response.ok) {
        void response.body?.cancel().catch(() => {});
        throw new Error(`Jev HTTP ${response.status}; no automatic retry`);
      }
      reader = response.body?.getReader();
      if (!reader) throw new Error('Empty Jev response');
      const parsed = parseResponseJson(await readBoundedBody(reader, signal));
      const result = validateResponse(parsed, request);
      this.usage.input_tokens += result.usage.input_tokens;
      this.usage.output_tokens += result.usage.output_tokens;
      this.options.onUsage?.({ evaluations: this.evaluations, usage: { ...this.usage } });
      if (totalTokens(this.usage) > (this.options.maxTokens ?? DEFAULT_MAX_TOKENS)) {
        throw new Error('Jev reported-token budget exceeded; final request may still be billed');
      }
      return result as JevResponse<Q>;
    } finally {
      this.active = false;
      void reader?.cancel().catch(() => {});
    }
  }
}
