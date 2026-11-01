/* Optional synthetic synchronous benchmark; not a browser painting measurement. */
'use strict';
const fs=require('node:fs'),vm=require('node:vm'),{performance}=require('node:perf_hooks');
const input=JSON.parse(fs.readFileSync(0,'utf8'));
const adapter=fs.readFileSync(__dirname+'/browser-harness.js','utf8');
const start=adapter.indexOf('const elements ='),end=adapter.indexOf('vm.runInNewContext');
// Reuse only the test DOM adapter, with no behavioral assertions or production hooks.
const make=new Function('input','assert',adapter.slice(start,end)+'return {context,$};');
const {context,$}=make(input,require('node:assert/strict'));
const before=process.memoryUsage().heapUsed;
const script=input.script.replace('  renderGit(); renderWarnings(); render();',
  'window.runSearch=(q)=>{state.tab="context-search";state.sq=q;state.ss="all";state.sp=1;render();}; window.nextSearch=()=>{state.sp=2;render();}; renderGit(); renderWarnings(); render();');
let startTime=performance.now();vm.runInNewContext(script,context,{timeout:15000});const startupMs=performance.now()-startTime;
startTime=performance.now();context.window.runSearch('timeout');const firstMs=performance.now()-startTime;
const rows=$('context-search-results').children.length;
startTime=performance.now();context.window.runSearch('cache');const subsequentMs=performance.now()-startTime;
startTime=performance.now();context.window.nextSearch();const cachedPageMs=performance.now()-startTime;
console.log(JSON.stringify({startupMs,firstMs,subsequentMs,cachedPageMs,rows,heapDeltaMiB:(process.memoryUsage().heapUsed-before)/1048576}));
