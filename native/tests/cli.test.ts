import { test, expect, afterAll } from 'bun:test';
import { mkdtempSync, mkdirSync, rmSync, statSync, readdirSync } from 'node:fs';
import { resolve, join } from 'node:path';
import manifest from '../../package.json';
const base=resolve('.tmp');mkdirSync(base,{recursive:true});const root=mkdtempSync(join(base,'native-cli-'));const bin=resolve('build/jev-fabric');
afterAll(()=>rmSync(root,{recursive:true,force:true}));
async function run(args:string[],options:{input?:string,path?:string,home?:string}={}){
 const p=Bun.spawn([bin,'--',...args],{env:{PATH:options.path??process.env.PATH!,BEND_NO_TELEMETRY:'1',JEV_FABRIC_HOME:options.home??join(root,'jobs')},stdin:'pipe',stdout:'pipe',stderr:'pipe'});
 p.stdin.write(options.input??'');await p.stdin.end();
 const[out,err,code]=await Promise.all([new Response(p.stdout).text(),new Response(p.stderr).text(),p.exited]);return {out,err,code};
}
test('public native help registers execution, source, validation, Jev and job verbs',async()=>{
 const r=await run(['--help']);expect(r.code).toBe(0);for(const cmd of ['exec','run','validate','jev','start','status','events','wait','stop','watch'])expect(r.out).toContain(cmd);
 expect((await run(['--version'])).out).toContain('0.1.0-native');
 expect(manifest.bin['jev-fabric']).toBe('build/jev-fabric');expect(manifest.bin['jev-fabric-reference']).toBe('dist/src/cli.js');expect(manifest.scripts.demo).toContain('examples/native/pipeline.bend');
});
test('strict request file validation runs with no Node/Bun on PATH',async()=>{
 const r=await run(['validate','examples/native/request.json'],{path:'/nonexistent'});expect(r.code,r.out+r.err).toBe(0);expect(JSON.parse(r.out).questions.healthy.type).toBe('noul');
 const file=join(root,'invalid.json');await Bun.write(file,'{"state":"x","state":"y","questions":{}}');const bad=await run(['validate',file]);expect(bad.code).not.toBe(0);
 await Bun.write(file,new Uint8Array([0xff,0xfe]));expect((await run(['validate',file])).code).not.toBe(0);
 expect((await run(['validate',join(root,'absent')])).code).not.toBe(0);
});
test('compiled native program executes in a private directory with literal argv and inherited stdin',async()=>{
 const file=join(root,'echo.bend');await Bun.write(file,'import Base\nimport ../../native/Process.bend as Process\ndef main() -> IO(Unit):\n  do IO<Unit>:\n    args : List<String> <- IO.args()\n    IO.print(List.show(&1, String, text => text, args))\n    result : Process.Report <- Process.run_stdin(["/bin/cat"], 1000)\n    IO.print(Process.show(result))\n');
 const r=await run(['run','20000',file,'literal ; $(nope)'],{input:'native input 🙂\n'});expect(r.code,r.out+r.err).toBe(0);const receipt=JSON.parse(r.out);expect(receipt.stdout).toContain('literal ; $(nope)');expect(receipt.stdout).toContain('native input 🙂');
 const home=join(root,'jobs');expect(statSync(home).mode&0o777).toBe(0o700);for(const id of readdirSync(home))expect(statSync(join(home,id)).mode&0o777).toBe(0o700);
});
test('compiler failures and option injection fail closed; outside deadline bounds compile',async()=>{
 const file=join(root,'bad.bend');await Bun.write(file,'not a valid Bend program');const bad=await run(['run','5000',file]);expect(bad.code).not.toBe(0);
 for(const args of [['run','0',file],['run','2000','--evil.bend'],['run','2000','file.ts']])expect((await run(args)).code).not.toBe(0);
 const start=Date.now();const tiny=await run(['run','1','examples/native/pipeline.bend']);expect(tiny.code).toBe(124);expect(Date.now()-start).toBeLessThan(1500);
});
test('native source loop cannot suppress outside execution deadline',async()=>{
 const file=join(root,'spin.bend');await Bun.write(file,'import Base\n@unsafe def spin(n: U32) -> U32:\n  spin(U32.add(n, 1))\ndef main() -> IO(Unit):\n  do IO<Unit>:\n    args : List<String> <- IO.args()\n    IO.print("entered-runtime")\n    IO.print(U32.show(spin(U32.from_nat(List.length(&1, String, args)))))\n');
 const home=join(root,'spin-jobs');const start=Date.now();const r=await run(['run','6000',file],{home});expect(r.code,r.out+r.err).toBe(124);expect(Date.now()-start).toBeLessThan(8000);
 const program=join(home,readdirSync(home)[0]!,'program');expect(statSync(program).size).toBeGreaterThan(0);
 const compiled=await run(['exec','300',program,'--','dynamic']);expect(compiled.code,compiled.out+compiled.err).toBe(124);expect(JSON.parse(compiled.out).timedOut).toBe(true);
});
test('shipped executable owns background workers and private replay with no JS runtime',async()=>{
 const start=await run(['start','3000','/bin/sh','-c','printf "hello\\n"; sleep 0.2; printf "done\\n"'],{path:'/usr/bin:/bin'});expect(start.code,start.err).toBe(0);const{id}=JSON.parse(start.out);
 const waited=await run(['wait',id,'3000'],{path:'/nonexistent'});expect(JSON.parse(waited.out).state).toBe('exited');
 const events=await run(['events',id],{path:'/nonexistent'});const rows=events.out.trim().split('\n').map(x=>JSON.parse(x));expect(rows.some(x=>x.type==='process.output')).toBe(true);
 expect((await run(['stop',id],{path:'/nonexistent'})).code).toBe(0);expect((await run(['status','../escape'])).code).not.toBe(0);
});
