import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { main, parseArgs, USAGE } from './reachout.mjs';

test('help and invalid schemas list every kind/reason pair and safe examples without sender access',async()=>{
  const expected=['need: decision|hands|stuck','ready-to-try: install|build','urgent-call: decision|goal-risk'];
  const help=await main(['--help']);
  for(const text of expected)assert.ok(help.help.includes(text));
  assert.equal((USAGE.match(/--dry-run\n/g)||[]).length,3);
  assert.ok(USAGE.includes('UNIQUE_CALL_ID'));
  const args=['send','--kind','urgent-call','--reason','hands','--session','ses_A','--id','example','--title','Test','--body','Test'];
  assert.throws(()=>parseArgs(args),error=>expected.every(v=>error.message.includes(v))&&error.message.includes('Examples'));
  const executable=fileURLToPath(new URL('./reachout.mjs',import.meta.url));
  const shown=spawnSync(process.execPath,[executable,'--help'],{encoding:'utf8'});
  assert.equal(shown.status,0);for(const text of expected)assert.ok(shown.stdout.includes(text));
  const refused=spawnSync(process.execPath,[executable,...args],{encoding:'utf8'});
  assert.equal(refused.status,1);const value=JSON.parse(refused.stdout);
  for(const text of expected)assert.ok(value.error.includes(text));
});
