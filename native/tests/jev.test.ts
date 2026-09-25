import { test, expect, beforeAll, afterAll } from 'bun:test';
import { mkdtempSync, mkdirSync, chmodSync, rmSync, readFileSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
const base=resolve('.tmp');mkdirSync(base,{recursive:true});const root=mkdtempSync(join(base,'native-jev-'));
const bin=join(root,'bin');mkdirSync(bin);const secret='SYNTHETIC_KEY_FOR_NATIVE_TESTS';
const request=JSON.stringify({state:'synthetic',questions:{ok:{type:'noul',instructions:'Is two plus two four?'}}});
const response={model:'jev-test',answers:{ok:{type:'noul',noul:0.99,debug:secret}},usage:{input_tokens:4,output_tokens:2},debug:secret};
beforeAll(async()=>{
 if(process.env.JEV_NATIVE_PREBUILT!=='1'){const p=Bun.spawnSync([resolve('build/jev-fabric'),'--','exec','90000','bend','native/tests/jev-client.bend','-o','build/test-jev-client'],{env:{...process.env,BEND_NO_TELEMETRY:'1'},stdout:'pipe',stderr:'pipe'});expect(p.exitCode,p.stdout.toString()+p.stderr.toString()).toBe(0);}
 await Bun.write(join(root,'curl.ts'),`import{appendFileSync}from'node:fs';const cfg=await Bun.stdin.text();const args=process.argv.slice(2);if(!cfg.includes('Authorization: Bearer ${secret}'))process.exit(9);if(args.some(x=>x.includes('${secret}')))process.exit(10);appendFileSync(process.env.CURL_RECORD!,JSON.stringify({args,model:cfg.includes('jev-test-model')})+'\\n');if(process.env.FAIL_CURL){process.stdout.write('${secret}');process.stderr.write('${secret}');process.exit(7)}if(process.env.INVALID_UTF8)process.stdout.write(new Uint8Array([255]));else process.stdout.write(process.env.FAKE_RESPONSE!);process.stdout.write('\\n'+(process.env.FAKE_STATUS??'200'));`);
 await Bun.write(join(bin,'curl'),`#!/bin/sh\nexec '${process.execPath}' '${join(root,'curl.ts')}' "$@"\n`);chmodSync(join(bin,'curl'),0o700);
 await Bun.write(join(root,'credential.sh'),`#!/bin/sh\nprintf x >> "$CREDENTIAL_RECORD"\nprintf '%s\\n' '${secret}'\n`);chmodSync(join(root,'credential.sh'),0o700);
 await Bun.write(join(root,'bad-credential.sh'),`#!/bin/sh\nprintf '${secret}\\n' >&2\nprintf '${secret}\\n'\nexit 1\n`);chmodSync(join(root,'bad-credential.sh'),0o700);
},100000);
afterAll(()=>rmSync(root,{recursive:true,force:true}));
let serial=0;
async function run(options:{calls?:number,tokens?:number,key?:string,command?:string,request?:string,response?:unknown,status?:string,fail?:boolean,provider?:string,invalidUtf8?:boolean}={}){
 const n=serial++;const log=join(root,`curl-${n}`),cred=join(root,`cred-${n}`);
 const p=Bun.spawn([resolve('build/test-jev-client'),'--',options.request??request,String(options.calls??2),String(options.tokens??100)],{env:{PATH:`${bin}:/usr/bin:/bin`,TYPESAFE_API_KEY:options.key??secret,JEV_PROVIDER:options.provider??'typesafe',JEV_MODEL:'jev-test-model',JEV_CREDENTIAL_COMMAND:options.command??'',CURL_RECORD:log,CREDENTIAL_RECORD:cred,FAKE_RESPONSE:JSON.stringify(options.response??response),FAKE_STATUS:options.status??'200',...(options.fail?{FAIL_CURL:'1'}:{}),...(options.invalidUtf8?{INVALID_UTF8:'1'}:{})},stdout:'pipe',stderr:'pipe'});
 const[out,err,code]=await Promise.all([new Response(p.stdout).text(),new Response(p.stderr).text(),p.exited]);expect(out+err).not.toContain(secret);
 const rows=existsSync(log)?readFileSync(log,'utf8').trim().split('\n').map(x=>JSON.parse(x)):[];
 return {out,err,code,rows,credentials:existsSync(cred)?readFileSync(cred,'utf8'):''};
}
test('native client normalizes typed replies and keeps secrets out of argv/output',async()=>{
 const r=await run();expect(r.code,r.err).toBe(0);expect(r.rows.length).toBe(2);expect(r.rows.every(x=>x.model)).toBe(true);
 for(const line of r.out.trim().split('\n')) expect(JSON.parse(line)).toEqual({model:'jev-test',answers:{ok:{type:'noul',noul:0.99}},usage:{input_tokens:4,output_tokens:2}});
 expect(r.rows[0].args[0]).toBe('--disable');expect(r.rows[0].args).toContain('=https');
});
test('credential argv resolves privately once then caches in threaded client',async()=>{
 const r=await run({key:'',command:JSON.stringify(['/bin/sh',join(root,'credential.sh')])});expect(r.code,r.err).toBe(0);expect(r.credentials).toBe('x');expect(r.rows.length).toBe(2);
});
test('invalid request, provider, credential config and multiline keys never dispatch',async()=>{
 for(const opts of [{request:'{}'},{key:'',command:'not-json'},{key:'x\ny'},{provider:'unknown'},{key:'',command:JSON.stringify(['/bin/sh',join(root,'bad-credential.sh')])}]){
  const r=await run(opts);expect(r.rows.length).toBe(0);expect(r.out+r.err).not.toContain(secret);
 }
});
test('reservation limits calls; failed HTTP has no retries or budget refund',async()=>{
 for(const opts of [{calls:1},{calls:1,status:'401'},{calls:1,fail:true}]){
  const r=await run(opts);expect(r.rows.length).toBe(1);expect(r.out).toContain('Jev budget exhausted');
 }
});
test('reported token overshoot disables later calls without Nat overflow',async()=>{
 for(const usage of [{input_tokens:4,output_tokens:2},{input_tokens:281474976710655,output_tokens:281474976710655}]){
  const r=await run({tokens:5,response:{...response,usage}});expect(r.rows.length).toBe(1);expect(r.out).toContain('reported-token budget exceeded');expect(r.out).toContain('Jev budget exhausted');
 }
});
test('credential deadline and output bounds fail privately before HTTP dispatch',async()=>{
 const start=Date.now();const slow=await run({key:'',command:JSON.stringify(['/bin/sh','-c','sleep 3; printf never'])});expect(slow.rows.length).toBe(0);expect(slow.out).toContain('Private credential command failed');expect(Date.now()-start).toBeLessThan(4300);
 const flood=await run({key:'',command:JSON.stringify(['/bin/sh','-c','head -c 20000 /dev/zero'])});expect(flood.rows.length).toBe(0);expect(flood.out).toContain('Private credential command failed');
 const zero=await run({tokens:0,key:'',command:JSON.stringify(['/bin/sh',join(root,'credential.sh')])});expect(zero.credentials).toBe('');expect(zero.rows.length).toBe(0);
});
test('zero budget blocks credential retrieval and malformed response is sanitized',async()=>{
 const zero=await run({calls:0,key:'',command:JSON.stringify(['/bin/sh',join(root,'credential.sh')])});expect(zero.credentials).toBe('');expect(zero.rows.length).toBe(0);
 const utf8=await run({calls:1,invalidUtf8:true});expect(utf8.rows.length).toBe(1);expect(utf8.out).toContain('Invalid UTF-8 Jev response');
 const bad=await run({calls:1,response:{secret}});expect(bad.rows.length).toBe(1);expect(bad.out).toContain('Invalid typed Jev response');expect(bad.out).toContain('Jev budget exhausted');
});
