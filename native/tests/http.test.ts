import { test, expect, beforeAll, afterAll } from 'bun:test';
import { mkdtempSync, mkdirSync, rmSync } from 'node:fs';
import { resolve, join } from 'node:path';
const root=resolve('.tmp'); mkdirSync(root,{recursive:true});
const dir=mkdtempSync(join(root,'native-tls-'));
let server: ReturnType<typeof Bun.serve>;
const requests: {path:string,auth:string|null,body:string}[]=[];
const body=JSON.stringify({state:'quotes " slashes \\ newline\n tab\t emoji 🙂; \\nurl = https://invalid.test/'});
beforeAll(()=>{
 const p=Bun.spawnSync(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',join(dir,'key.pem'),'-out',join(dir,'cert.pem'),'-days','1','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost'],{stdout:'ignore',stderr:'pipe'});
 expect(p.exitCode, p.stderr.toString()).toBe(0);
 if(process.env.JEV_NATIVE_PREBUILT!=='1'){const build=Bun.spawnSync([resolve('build/jev-fabric'),'--','exec','90000','bend','native/tests/http.bend','-o','build/test-http'],{env:{...process.env,BEND_NO_TELEMETRY:'1'},stdout:'pipe',stderr:'pipe'});
 expect(build.exitCode,build.stdout.toString()+build.stderr.toString()).toBe(0);}
 server=Bun.serve({hostname:'127.0.0.1',port:0,tls:{key:Bun.file(join(dir,'key.pem')),cert:Bun.file(join(dir,'cert.pem'))},async fetch(req){
  const path=new URL(req.url).pathname;
  requests.push({path,auth:req.headers.get('authorization'),body:await req.text()});
  if(path==='/redirect') return new Response('',{status:302,headers:{location:`https://localhost:${server.port}/unexpected`}});
  if(path==='/huge') return new Response('x'.repeat(1048577));
  if(path==='/error') return new Response('SYNTHETIC_NOT_A_SECRET',{status:401});
  if(path==='/slow') await Bun.sleep(2500);
  return new Response('ok');
 }});
},100000);
afterAll(()=>{server?.stop(true);rmSync(dir,{recursive:true,force:true});});
async function run(path:string,trust=true,host='localhost',input=body){
 const p=Bun.spawn([resolve('build/test-http'),'--',`https://${host}:${server.port}${path}`,input],{env:{PATH:'/usr/bin:/bin',...(trust?{CURL_CA_BUNDLE:join(dir,'cert.pem')}:{}),HTTPS_PROXY:'http://127.0.0.1:1',ALL_PROXY:'http://127.0.0.1:1'},stdout:'pipe',stderr:'pipe'});
 const [out,err,code]=await Promise.all([new Response(p.stdout).text(),new Response(p.stderr).text(),p.exited]);
 expect(code,err).toBe(0);expect(out+err).not.toContain('SYNTHETIC_NOT_A_SECRET');return out.trim();
}
test('native HTTPS verifies trusted TLS and preserves private config/body literally',async()=>{
 expect(await run('/ok')).toBe('ok:2');const req=requests.at(-1)!;expect(req.auth).toBe('Bearer SYNTHETIC_NOT_A_SECRET');expect(req.body).toBe(body);
});
test('unknown CA and wrong hostname fail closed',async()=>{
 const n=requests.length;expect(await run('/untrusted',false)).toBe('error');expect(await run('/mismatch',true,'127.0.0.1')).toBe('error');expect(requests.length).toBe(n);
});
test('redirect is not followed and status errors never expose body',async()=>{
 expect(await run('/redirect')).toBe('error');expect(requests.some(r=>r.path==='/unexpected')).toBe(false);expect(await run('/error')).toBe('error');
});
test('body bounds and network deadline are enforced',async()=>{
 expect(await run('/huge')).toBe('error');const start=Date.now();expect(await run('/slow')).toBe('error');expect(Date.now()-start).toBeLessThan(2300);
});
test('curl data-file syntax rejected before network',async()=>{
 const n=requests.length;expect(await run('/file',true,'localhost','@/etc/passwd')).toBe('error');expect(requests.length).toBe(n);
});
