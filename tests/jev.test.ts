import test from 'node:test';
import assert from 'node:assert/strict';
import { JevClient, validateRequest, validateResponse } from '../src/index.js';

const request = {
  state: { message: 'Build failed; dependency missing.' },
  questions: {
    route: { type: 'choice' as const, instructions: 'Choose the relevant category.', criteria: { build: 'Build failure', other: 'Other' } },
    failed: { type: 'noul' as const, instructions: 'Did the build fail?' },
    severity: { type: 'score' as const, instructions: 'Rate severity.', criteria: ['low', 'high'] },
  },
};
function response() {
  return { model: 'jev-latest', answers: {
    route: { type: 'choice', choice: 'build', confidence: 0.9, probabilities: { build: 0.95, other: 0.05 } },
    failed: { type: 'noul', noul: 0.99 },
    severity: { type: 'score', score: 0.8, confidence: 0.7, probabilities: { '0': 0.2, '1': 0.8 } },
  }, usage: { input_tokens: 30, output_tokens: 0 } };
}
const mock = (value: unknown): typeof fetch => async () => new Response(JSON.stringify(value));

test('all three primitives validate and preserve typed answers', async () => {
  const client = new JevClient({ provider: 'typesafe', apiKey: 'fixture-key', fetch: mock(response()) });
  const result = await client.evaluate(request);
  assert.equal(result.answers.route.choice, 'build');
  assert.equal(result.answers.failed.noul, 0.99);
  assert.equal(result.answers.severity.score, 0.8);
  assert.deepEqual(result.answers.severity.legend, { '0': 'low', '1': 'high' });
  assert.equal(client.evaluations, 1);
});

test('malformed questions, non-finite data and partial/invalid answers fail closed', () => {
  assert.throws(() => validateRequest({ ...request, state: { n: Infinity } }));
  assert.throws(() => validateRequest({ state: '', questions: {} }));
  assert.throws(() => validateRequest({ ...request, questions: { q: { type: 'text', instructions: 'write code' } } }));
  const wrongChoice = response(); wrongChoice.answers.route.choice = 'unobserved';
  const wrongMass = response(); wrongMass.answers.route.probabilities.build = 0;
  const wrongNoul = response(); wrongNoul.answers.failed.noul = 1.5;
  const wrongScore = response(); wrongScore.answers.severity.score = 10;
  const wrongConfidence = response(); wrongConfidence.answers.route.confidence = -1;
  for (const bad of [wrongChoice, wrongMass, wrongNoul, wrongScore, wrongConfidence, { ...response(), answers: {} }]) assert.throws(() => validateResponse(bad, request), /Invalid typed/);
});

test('fixed upstream routes, redirect rejection, and secret-free errors', async () => {
  const endpoints = { typesafe: 'https://api.typesafe.ai/v1/systemone', openrouter: 'https://openrouter.ai/api/alpha/decisions', vercel: 'https://ai-gateway.vercel.sh/typesafe/v1/systemone' } as const;
  for (const [provider, endpoint] of Object.entries(endpoints)) {
    const client = new JevClient({ provider: provider as keyof typeof endpoints, apiKey: 'fixture-secret', fetch: async (url, init) => {
      assert.equal(url, endpoint); assert.equal(init?.redirect, 'error');
      assert.equal(new Headers(init?.headers).get('Authorization'), 'Bearer fixture-secret');
      assert.ok(!String(init?.body).includes('fixture-secret'));
      return new Response('fixture-secret in private response', { status: 429 });
    } });
    await assert.rejects(client.evaluate(request), error => /HTTP 429/.test(String(error)) && !String(error).includes('fixture-secret'));
    assert.equal(client.evaluations, 1);
  }
});

test('evaluation and reported-token budgets reject further work', async () => {
  const client = new JevClient({ apiKey: 'fixture', fetch: mock(response()), maxEvaluations: 1 });
  await client.evaluate(request);
  await assert.rejects(client.evaluate(request), /budget exhausted/);
  const tokens = new JevClient({ apiKey: 'fixture', fetch: mock(response()), maxTokens: 1 });
  await assert.rejects(tokens.evaluate(request), /may still be billed/);
  assert.equal(tokens.usage.input_tokens, 30);
});

test('in-flight exclusivity and cancellation do not depend on the fetcher honoring abort', async () => {
  const controller = new AbortController();
  const client = new JevClient({ apiKey: 'fixture', signal: controller.signal, fetch: () => new Promise(() => {}) });
  const pending = client.evaluate(request);
  await assert.rejects(client.evaluate(request), /One evaluation/);
  controller.abort(new Error('test cancellation'));
  await assert.rejects(pending);
});

test('oversized response and malformed JSON are rejected', async () => {
  const large = new JevClient({ apiKey: 'fixture', fetch: async () => new Response('x'.repeat(1048577)) });
  await assert.rejects(large.evaluate(request), /1 MiB/);
  const bad = new JevClient({ apiKey: 'fixture', fetch: async () => new Response('{private-invalid') });
  await assert.rejects(bad.evaluate(request), error => String(error).includes('Invalid Jev JSON') && !String(error).includes('private-invalid'));
});

test('request identity is snapshotted before asynchronous work', async () => {
  let release!: (response: Response) => void;
  const client = new JevClient({ apiKey: 'fixture', fetch: () => new Promise(resolve => { release = resolve; }) });
  const mutable = structuredClone(request);
  const pending = client.evaluate(mutable);
  await new Promise(resolve => setImmediate(resolve));
  mutable.questions.route.criteria = { fake: 'Fake' } as never;
  release(new Response(JSON.stringify(response())));
  assert.equal((await pending).answers.route.choice, 'build');
});

test('credential command uses bounded private stdout, caching, and sanitized failure', async () => {
  const previous = process.env.TYPESAFE_API_KEY;
  delete process.env.TYPESAFE_API_KEY;
  try {
    const client = new JevClient({ provider: 'typesafe', credentialCommand: [process.execPath, '-e', "process.stdout.write('fixture-command-key')"], fetch: async (_url, init) => {
      assert.equal(new Headers(init?.headers).get('Authorization'), 'Bearer fixture-command-key');
      return new Response(JSON.stringify(response()));
    } });
    await client.evaluate(request); await client.evaluate(request);
    const bad = new JevClient({ provider: 'typesafe', credentialCommand: [process.execPath, '-e', "console.error('fixture-private-failure'); process.exit(1)"], fetch: mock(response()) });
    await assert.rejects(bad.evaluate(request), error => String(error).includes('Private credential command failed') && !String(error).includes('fixture-private-failure'));
  } finally { if (previous === undefined) delete process.env.TYPESAFE_API_KEY; else process.env.TYPESAFE_API_KEY = previous; }
});
