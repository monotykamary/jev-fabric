import { beforeAll, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';

const root = resolve(import.meta.dir, '../..');
const binary = resolve(root, 'build/test-codec-wire-probe');
function run(mode: string, ...args: string[]) {
  const p = spawnSync(binary, ['--', mode, ...args], { cwd: root, encoding: 'utf8', timeout: 15000, maxBuffer: 2 ** 21 });
  if (p.error) throw p.error;
  return { code: p.status, out: p.stdout.trim(), error: p.stderr.trim() };
}
function accepted(mode: string, ...args: string[]) {
  const r = run(mode, ...args);
  expect(r.code).toBe(0);
  return r.out;
}
function rejected(mode: string, ...args: string[]) {
  const r = run(mode, ...args);
  expect(r.code).toBe(1);
  expect(r.error).toContain('rejected');
}
const q = (type: string, criteria?: unknown) => ({ type, instructions: 'judge', ...(criteria === undefined ? {} : { criteria }) });
const request = (question: unknown = q('noul')) => ({ state: {}, questions: { q: question } });
const req = JSON.stringify(request());
const rawResponse = (n: string, input = '1', output = '2') => `{"model":"jev","answers":{"q":{"type":"noul","noul":${n}}},"usage":{"input_tokens":${input},"output_tokens":${output}}}`;

beforeAll(() => {
  if (process.env.JEV_NATIVE_PREBUILT === '1') return;
  for (const name of ['codec', 'codec-limits', 'wire', 'codec-wire-probe']) {
    const p = spawnSync(resolve(root, 'build/jev-fabric'), ['--', 'exec', '90000', 'bend', `native/tests/${name}.bend`, '-o', `build/test-${name}`], { cwd: root, encoding: 'utf8', timeout: 120000, env: { ...process.env, BEND_NO_TELEMETRY: '1' } });
    if (p.status !== 0) throw new Error(`${name}: ${p.error ?? ''}\n${p.stdout}\n${p.stderr}`);
  }
}, 360000);

describe('pure-native strict Codec', () => {
  test('resource limits and reusable public AST alias in compiled native code', () => {
    const p = spawnSync(resolve(root, 'build/test-codec-limits'), [], { encoding: 'utf8', timeout: 30000 });
    expect(p.status).toBe(0);
    expect(p.stdout).toContain('native codec resource assertions: 15');
  });
  test('native Unicode, UTF8, AST and exact-lexeme assertions', () => {
    const p = spawnSync(resolve(root, 'build/test-codec'), [], { encoding: 'utf8', timeout: 30000 });
    expect(p.status).toBe(0);
    expect(p.stdout).toContain('native codec assertions:');
  });
  test('rejects malformed syntax and Unicode in every token boundary', () => {
    const bad = ['', '+1', '.1', '00', '-01', '1.', '1e', '1e+', '[1.]', '[1.e2]', '[1e,2]', '[1e+ ]', '[- ]', '[,]', '{,}', '{"x":}', '{"x" 1}', '{"x":1 "y":2}', '[true false]', 'true null', 'undefined', 'NaN', 'Infinity', '"\n"', '"\\q"', '"\\uD800"', '"\\uDC00"', '"\\uD800x"', '"\\uD800\\n"', '"\\uD800\\uD800"', '"\\uD800\\u0000"', '"\\uFFFFz', '\uFEFF{}'];
    for (const text of bad) rejected('codec', text);
  });
  test('retains exact raw numbers and decodes escaped scalar pairs', () => {
    const raw = '[9007199254740993,-0,1E+004,0.00000000000000000000001,1e-1000]';
    expect(accepted('codec', raw)).toBe(raw);
    expect(JSON.parse(accepted('codec', '["\\u0000","\\ud83d\\ude42","é"]'))).toEqual(['\0', '🙂', 'é']);
    for (const value of [null, true, false, [], {}, { x: ['🙂', '\n\t"\\', 1.25] }]) {
      expect(JSON.parse(accepted('codec', JSON.stringify(value)))).toEqual(value);
    }
  });
  test('rejects duplicate decoded keys, including nested and prototype-like names', () => {
    for (const text of ['{"x":1,"x":2}', '{"x":1,"\\u0078":2}', '[{"__proto__":1,"__proto__":2}]', '{"":1,"":2}', '{"a":{"b":0,"b":1}}']) rejected('codec', text);
    expect(JSON.parse(accepted('codec', '{"__proto__":1,"constructor":2}'))).toEqual(JSON.parse('{"__proto__":1,"constructor":2}'));
  });
  test('bounds nesting, numeric tokens, node work, keys and comparison work', () => {
    accepted('codec', '['.repeat(64) + '0' + ']'.repeat(64));
    rejected('codec', '['.repeat(65) + '0' + ']'.repeat(65));
    rejected('codec', '1'.repeat(1025));
    rejected('codec', '[' + '0,'.repeat(16384) + '0]');
    rejected('codec', JSON.stringify({ ['k'.repeat(257)]: 0 }));
    rejected('codec', JSON.stringify(Object.fromEntries(Array.from({ length: 257 }, (_, i) => [`k${i}`, 0]))));
    rejected('codec', JSON.stringify(Object.fromEntries(Array.from({ length: 256 }, (_, i) => ['x'.repeat(250) + String(i), 0]))));
  });
});

describe('pure-native Jev wire contract', () => {
  test('native numeric-fidelity assertions', () => {
    const p = spawnSync(resolve(root, 'build/test-wire'), [], { encoding: 'utf8', timeout: 30000 });
    expect(p.status).toBe(0);
    expect(p.stdout).toContain('native wire assertions:');
  });
  test('choice 1..255, score 2..10, Noul and descriptions', () => {
    for (const n of [1, 255]) accepted('request', JSON.stringify(request(q('choice', Object.fromEntries(Array.from({ length: n }, (_, i) => [`k${i}`, null]))))));
    for (const n of [0, 256]) rejected('request', JSON.stringify(request(q('choice', Object.fromEntries(Array.from({ length: n }, (_, i) => [`k${i}`, null]))))));
    for (const n of [2, 10]) accepted('request', JSON.stringify(request(q('score', Array(n).fill('level')))));
    for (const n of [0, 1, 11]) rejected('request', JSON.stringify(request(q('score', Array(n).fill('level')))));
    for (const c of [undefined, {}, { true: [], false: {} }]) accepted('request', JSON.stringify(request(q('noul', c))));
    for (const c of [null, [], { true: null }, { false: 1 }, { unknown: 'x' }]) rejected('request', JSON.stringify(request(q('noul', c))));
    for (const state of ['', {}, []]) accepted('request', JSON.stringify({ ...request(), state }));
    for (const state of [null, false, 3]) rejected('request', JSON.stringify({ ...request(), state }));
    rejected('request', JSON.stringify(request(q('choice', { a: false }))));
    rejected('request', JSON.stringify(request(q('score', [null, 'yes']))));
  });
  test('strict keys, IDs, UTF16 lengths, model labels and defaults', () => {
    for (const value of [{ ...request(), extra: true }, { ...request(), model: 4 }, { ...request(), model: '' }, { ...request(), model: '🙂'.repeat(65) }, { ...request(), questions: {} }, request({ ...q('noul'), extra: 1 }), request(q('text')), request({ type: 'noul' }), { ...request(), questions: { '': q('noul') } }, { ...request(), questions: { ['🙂'.repeat(65)]: q('noul') } }]) rejected('request', JSON.stringify(value));
    accepted('request', JSON.stringify({ ...request(), model: '🙂'.repeat(64) }));
    expect(JSON.parse(accepted('body', req, 'default')).model).toBe('default');
    const specified = JSON.stringify({ ...request(), model: 'specific' });
    expect(JSON.parse(accepted('body', specified, '')).model).toBe('specific');
    rejected('body', req, '');
    rejected('body', req, 'm'.repeat(129));
    for (const n of [1, 128]) accepted('request', JSON.stringify({ state: '', questions: Object.fromEntries(Array.from({ length: n }, (_, i) => [`q${i}`, q('noul')])) }));
    rejected('request', JSON.stringify({ state: '', questions: Object.fromEntries(Array.from({ length: 129 }, (_, i) => [`q${i}`, q('noul')])) }));
  });
  test('no F32 rounding: tiny negatives, >1, and long valid decimals', () => {
    for (const n of ['-1e-1000', '1.0000000000000000000000000000001', '-0.00000000000000001', '1.00000001', '1e999', 'true', 'null', '"0.5"']) rejected('response', req, rawResponse(n));
    for (const n of ['0', '-0', '1', '1e0', '1000e-3', '-0e-1000', '1e-1000', '0.123456789012345678901234567890', '0.999999999999999999999999999999']) expect(accepted('response', req, rawResponse(n))).toContain(`"noul":${n}`);
    rejected('response', req, rawResponse('1e-4097'));
  });
  test('usage counts are exact integers with an explicit native range cap', () => {
    for (const n of ['0', '-0', '16777217', '16777217.000', '167772170e-1', '281474976710655']) expect(accepted('response', req, rawResponse('0.5', n))).toContain(`"input_tokens":${n}`);
    for (const n of ['-1', '-1e-1000', '1.000000000000000001', '16777217.00000001', '281474976710656', '9007199254740991', '9007199254740992', '1e999999999', 'true', 'null', '"1"']) rejected('response', req, rawResponse('0.5', n));
  });
  test('normalizes typed answers, regenerates score legend, strips all unknown fields', () => {
    const r = { state: [], questions: { c: q('choice', { a: null, b: 'B' }), s: q('score', ['low', { high: true }]), n: q('noul') } };
    const response = { model: 'jev', secret: 'discard', answers: { c: { type: 'choice', choice: 'b', confidence: 0.9, probabilities: { b: 0.75, a: 0.25 }, generated: 'discard' }, s: { type: 'score', score: 0.8, confidence: 0.7, probabilities: { '1': 0.8, '0': 0.2 }, legend: 'unsafe', extra: {} }, n: { type: 'noul', noul: 1, generated: 'discard' } }, usage: { input_tokens: 1, output_tokens: 2, secret: 'discard' } };
    const got = JSON.parse(accepted('response', JSON.stringify(r), JSON.stringify(response)));
    expect(got).toEqual({ model: 'jev', answers: { c: { type: 'choice', choice: 'b', confidence: 0.9, probabilities: { a: 0.25, b: 0.75 } }, s: { type: 'score', score: 0.8, confidence: 0.7, probabilities: { '0': 0.2, '1': 0.8 }, legend: { '0': 'low', '1': { high: true } } }, n: { type: 'noul', noul: 1 } }, usage: { input_tokens: 1, output_tokens: 2 } });
  });
  test('exact distribution coverage, sum tolerance and score bounds', () => {
    const r = JSON.stringify(request(q('choice', { a: null, b: null })));
    const response = (p: string, choice = 'a', confidence = '1') => `{"model":"jev","answers":{"q":{"type":"choice","choice":"${choice}","confidence":${confidence},"probabilities":${p}}},"usage":{"input_tokens":0,"output_tokens":0}}`;
    for (const p of ['{"a":0.48,"b":0.5}', '{"a":0.52,"b":0.5}', '{"a":0.123456789012345678901,"b":0.876543210987654321099}']) accepted('response', r, response(p));
    for (const p of ['{"a":0.479999999999999999999,"b":0.5}', '{"a":0.520000000000000000001,"b":0.5}', '{"a":1}', '{"a":0.5,"c":0.5}', '{"a":0.5,"b":0.5,"c":0}', '{"a":0.5,"a":0.5}', '{"a":1.000000000000001,"b":0}', '{"a":-1e-1000,"b":1}', '{"a":"0.5","b":0.5}']) rejected('response', r, response(p));
    rejected('response', r, response('{"a":0.5,"b":0.5}', 'missing'));
    rejected('response', r, response('{"a":0.5,"b":0.5}', 'a', '1.00000000000001'));
    const scoreReq = JSON.stringify(request(q('score', ['low', 'high'])));
    const score = (n: string) => `{"model":"jev","answers":{"q":{"type":"score","score":${n},"confidence":1,"probabilities":{"0":0.5,"1":0.5}}},"usage":{"input_tokens":0,"output_tokens":0}}`;
    accepted('response', scoreReq, score('0.1234567890123456789012345'));
    for (const n of ['-1e-1000', '1.00000000000000001', '2', '"0.5"']) rejected('response', scoreReq, score(n));
  });
  test('full 255-option distributions and ten-level scores', () => {
    const criteria = Object.fromEntries(Array.from({ length: 255 }, (_, i) => [`k${i}`, null]));
    const probabilities = Object.fromEntries(Array.from({ length: 255 }, (_, i) => [`k${i}`, 1 / 255]));
    const r = JSON.stringify(request(q('choice', criteria)));
    const value = { model: 'jev', answers: { q: { type: 'choice', choice: 'k254', confidence: 0.9, probabilities } }, usage: { input_tokens: 0, output_tokens: 0 } };
    accepted('response', r, JSON.stringify(value));
    delete probabilities.k128;
    rejected('response', r, JSON.stringify(value));
    const scoreReq = JSON.stringify(request(q('score', Array(10).fill('level'))));
    const score = { model: 'jev', answers: { q: { type: 'score', score: 9, confidence: 1, probabilities: Object.fromEntries(Array.from({ length: 10 }, (_, i) => [String(i), 0.1])) } }, usage: { input_tokens: 0, output_tokens: 0 } };
    accepted('response', scoreReq, JSON.stringify(score));
    score.answers.q.score = 9.00000001;
    rejected('response', scoreReq, JSON.stringify(score));
  });
  test('response envelopes reject wrong keys, types, usage and model labels', () => {
    const base = JSON.parse(rawResponse('0.5'));
    for (const model of ['', 1, null, {}, '🙂'.repeat(65)]) rejected('response', req, JSON.stringify({ ...base, model }));
    for (const answers of [{}, { wrong: base.answers.q }, { q: base.answers.q, extra: base.answers.q }, { q: { type: 'choice', noul: 1 } }, { q: null }]) rejected('response', req, JSON.stringify({ ...base, answers }));
    for (const usage of [{}, { input_tokens: 1 }, null, []]) rejected('response', req, JSON.stringify({ ...base, usage }));
  });
});
