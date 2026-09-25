import { beforeAll, afterAll, test, expect } from 'bun:test';
import { mkdtempSync, mkdirSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';
mkdirSync('.tmp',{recursive:true});const root=mkdtempSync(resolve('.tmp/session-test-'));
const bin=resolve('build/test-session');let serial=0;
beforeAll(()=>{if(process.env.JEV_NATIVE_PREBUILT==='1')return;const p=Bun.spawnSync([resolve('build/jev-fabric'),'--','exec','90000','bend','native/tests/session.bend','-o',bin],{env:{...process.env,BEND_NO_TELEMETRY:'1'},stdout:'pipe',stderr:'pipe'});expect(p.exitCode,p.stdout.toString()+p.stderr.toString()).toBe(0);},100000);
afterAll(()=>rmSync(root,{recursive:true,force:true}));
async function probe(mode:string){
 const cmd=mode==='failures'?['/bin/sh','-c','ulimit -n 64; exec "$@"','sh',bin,'--',mode]:[bin,'--',mode];
 const p=Bun.spawn([resolve('build/jev-fabric'),'--','exec','20000',...cmd],{env:{PATH:'/usr/bin:/bin',JEV_FABRIC_HOME:join(root,String(serial++))},stdout:'pipe',stderr:'pipe'});
 const[out,err,code]=await Promise.all([new Response(p.stdout).text(),new Response(p.stderr).text(),p.exited]);expect(code,out+err).toBe(0);const receipt=JSON.parse(out);expect(receipt.exitCode,receipt.stderr).toBe(0);return receipt.stdout as string;
}
test('native persistent JSONL handshake observes replies before EOF and preserves child state',async()=>{
 const out=await probe('handshake');expect(out).toContain('live:ready');expect(out).toContain('live:"count":1');expect(out).toContain('live:"count":2');const row=JSON.parse(out.trim().split('\n').at(-1)!);expect(row.exitCode).toBe(0);expect(row.stdout).toContain('{"count":2,"value":20}');expect(row.stdout).not.toContain('30');
});
test('96 invalid launches return EPIPE without leaking stdin descriptors under fd limit64',async()=>{expect(await probe('failures')).toContain('failure-cleanup:96');});
test('binary stderr is preserved; invalid read bounds preserve ownership',async()=>{expect(await probe('bytes')).toContain('"state"');});
test('blocked stdin write unblocks when the owned child deadline closes its reader',async()=>{const start=Date.now();const out=await probe('blocked');expect(JSON.parse(out).timedOut).toBe(true);expect(Date.now()-start).toBeLessThan(2000);});
test('first-byte spool cap and write bound remain explicit in the public session API',async()=>{const out=await probe('limits');expect(out).toContain('live:spool-cap');expect(out).toContain('bounded-tail:32768');});
test('two live sessions compose without consuming one another',async()=>{const out=await probe('two');const rows=out.trim().split('\n').filter(x=>x.startsWith('{')).map(x=>JSON.parse(x));expect(rows.length).toBe(2);expect(rows.every(x=>x.exitCode===0)).toBe(true);});
test('scope cancellation is explicit and stops both owned sessions',async()=>{const out=await probe('cancel');const rows=out.trim().split('\n').filter(x=>x.startsWith('{')).map(x=>JSON.parse(x));expect(rows.length).toBe(2);expect(rows.every(x=>x.cancelled)).toBe(true);});
