import { test, expect } from 'bun:test';
import { resolve } from 'node:path';
import { auditSources, acceptVerdict, type Manifest } from '../../scripts/check-native-safety.ts';

function fixture(pure = 'import Base\ndef value() -> Nat:\n  0n\n') {
  const manifest: Manifest = { schemaVersion: 1, compiler: 'bend 2.0.27', pure: ['native/Pure.bend'], proofs: [], drivers: ['native/Driver.bend'], foreign: { 'native/Driver.bend': { 'Effect.call': 'native/bridge.c' } } };
  const sources = new Map([
    ['native/Pure.bend', pure],
    ['native/Driver.bend', 'import Base\ndef Effect.call() -> IO(Unit):\n  import "./bridge.c"\n'],
  ]);
  return { manifest, sources };
}
function rejected(source: string, message: RegExp) {
  const f = fixture(source);
  expect(() => auditSources(f.sources, f.manifest)).toThrow(message);
}

test('safe core accepts trusted driver segregation and ignores quoted/commented syntax', () => {
  const f = fixture('# @unsafe ?TODO\nimport Base\ndef value() -> String:\n  "@unsafe ?TODO def fake?() import IO"\n');
  expect(auditSources(f.sources, f.manifest).foreign).toBe(1);
});
test('unsafe decorator, def sugar, and named/TODO proof holes fail closed', () => {
  for (const source of ['@unsafe\ndef f() -> Nat:\n  0n', 'def f?() -> Nat:\n  0n', 'def f() -> Nat:\n  ?TODO', 'def f() -> Nat:\n  ?unfinished']) rejected(source, /unsafe definition or proof hole/);
});
test('unfilled laws are not accepted as proofs', () => rejected('law fabricated: Empty', /unimplemented law/));
test('pure modules cannot depend on drivers, even through unused imports', () => rejected('import ./Driver.bend as Driver\ndef value() -> Nat:\n  0n', /pure closure reaches/));
test('Base IO capabilities, including qualified aliases, are forbidden in the pure closure', () => {
  rejected('import Base\ndef f() -> IO(Unit):\n  IO.print("x")', /effect capability/);
  rejected('import Base as Trusted\ndef f() -> Trusted.IO(Unit):\n  Trusted.IO.print("x")', /effect capability/);
});
test('unapproved foreign entrypoints cannot hide in tests or pure modules', () => rejected('def Bad() -> IO(Unit):\n  import "./bridge.c"', /unapproved foreign effect/));
test('out-of-tree imports, missing files and new unclassified modules fail closed', () => {
  rejected('import ../../elsewhere.bend as Hidden', /escaping import/);
  rejected('import ./Missing.bend as Hidden', /unresolved import/);
  const f = fixture(); f.sources.set('native/New.bend', 'import Base');
  expect(() => auditSources(f.sources, f.manifest)).toThrow(/unclassified/);
});
test('transitive helper contamination is rejected rather than just scanning roots', () => {
  const f = fixture('import ./Helper.bend as H');
  f.sources.set('native/Helper.bend', 'import ./Driver.bend as D'); f.manifest.pure.push('native/Helper.bend');
  expect(() => auditSources(f.sources, f.manifest)).toThrow(/pure closure reaches/);
});
test('native safe encoder fuel and pure effect gates execute as specified', () => {
  if (process.env.JEV_NATIVE_PREBUILT !== '1') {
    const build = Bun.spawnSync([resolve('build/jev-fabric'), '--', 'exec', '90000', 'bend', 'native/tests/policy-core.bend', '-o', 'build/test-policy-core'], { stdout: 'pipe', stderr: 'pipe' });
    expect(build.exitCode, build.stdout.toString() + build.stderr.toString()).toBe(0);
  }
  const result = Bun.spawnSync([resolve('build/test-policy-core')], { stdout: 'pipe', stderr: 'pipe' });
  expect(result.exitCode, result.stderr.toString()).toBe(0);
  expect(result.stdout.toString()).toContain('native safe policy assertions: 10');
}, 100000);

test('compiler trust warnings and incomplete verdicts fail in the pure proof closure', () => {
  acceptVerdict('pure', 'All terms check.\n', true);
  const warning = 'All terms check, but 1 def relies on unsafe or foreign code:\n- run\n';
  expect(() => acceptVerdict('pure', warning, true)).toThrow(/trust verdict/);
  acceptVerdict('driver', warning, false);
  expect(() => acceptVerdict('pure', 'All terms check, but incomplete.', true)).toThrow(/trust verdict/);
});
