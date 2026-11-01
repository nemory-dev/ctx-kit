"use strict";
const assert=require("node:assert/strict"),fs=require("node:fs"),vm=require("node:vm");
const input=JSON.parse(fs.readFileSync(0,"utf8"));
const elements = new Map();
class Element {
  constructor(tag) { this.tagName = tag.toUpperCase(); this.children = []; this.attributes = {}; this.events = {}; this.value = ""; this.hidden = false; this.disabled = false; this._text = ""; }
  set id(value) { this._id = value; elements.set(value, this); }
  get id() { return this._id; }
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this._text + this.children.map(c => c.textContent).join(""); }
  get firstChild() { return this.children[0] || null; }
  appendChild(child) { this.children.push(child); return child; }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); return child; }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  removeAttribute(name) { delete this.attributes[name]; }
  addEventListener(name, callback) { (this.events[name] || (this.events[name] = [])).push(callback); }
  fire(name, extra) { (this.events[name] || []).slice().forEach(callback => callback(Object.assign({preventDefault() {}}, extra || {}))); }
  scrollIntoView() { this.scrolled = true; }
  focus() { this.focused = true; }
  select() { this.selected = true; }
}
const ids = ["view-context-search", "nav-context-search", "view-handoff", "nav-handoff", "context-search-query", "context-search-scope", "context-search-results", "context-search-status", "context-search-previous", "context-search-next", "context-search-page", "handoff-text", "handoff-copy", "handoff-status", "skip-main", "main-content", "ctx-view-data", "view-overview", "view-timeline", "view-documents", "nav-overview", "nav-timeline", "nav-documents", "search", "type-filter", "date-from", "date-to", "file-filter", "entry-list", "entry-detail", "result-count", "unknown-dates", "page-status", "previous-page", "next-page", "document-select", "document-content", "current-state", "next-actions", "recent-entries", "git-content", "warnings", "warning-list", "warnings-details", "warnings-summary", "warnings-panel", "warning-previous-page", "warning-page-status", "warning-next-page", "project-name", "context-path", "generated-at", "snapshot-age", "open-plan-current", "open-plan-next", "clear-filters"];
ids.forEach(id => { const element = new Element("div"); element.id = id; });
const $ = id => elements.get(id);
$("ctx-view-data").textContent = JSON.stringify(input.model);
const windowEvents = {};
const location = {hash: ""};
let clipboardCalls = 0, clipboardMode = "success", timers = new Map(), timerId = 0;
const clipboard = {writeText: async value => { clipboardCalls++; assert.equal(value, input.model.handoff.text); if (clipboardMode === "reject") throw Error("Denied"); }};
const context = {
  document: {getElementById: $, createElement: tag => new Element(tag), createTextNode: value => { const n = new Element("#text"); n.textContent = value; return n; }},
  window: {addEventListener: (name, callback) => { windowEvents[name] = callback; }},
  location,
  navigator: {clipboard},
  setTimeout: callback => { timers.set(++timerId, callback); return timerId; }, clearTimeout: id => timers.delete(id),
  history: {pushState: (_, title, hash) => { location.hash = hash; }, replaceState: (_, title, hash) => { location.hash = hash; }},
  setInterval: () => 1, URLSearchParams, URL, console,
};
vm.runInNewContext(input.script.replace("  renderGit(); renderWarnings(); render();", "window.contextResults=()=>{const h=contextHits(state.sq,state.ss);return h.hits.slice((state.sp-1)*50,state.sp*50).map(hit=>contextResult(hit,h.terms));};  renderGit(); renderWarnings(); render();"), context, {timeout:5000});
const click=id=>$(id).fire("click");
const hash=value=>{location.hash=value; windowEvents.hashchange();};
const all=e=>[e].concat(e.children.flatMap(all));
const query=(q,scope="all")=>hash("#tab=context-search&sq="+encodeURIComponent(q)+"&ss="+scope);
(async()=>{
assert.equal(clipboardCalls,0);
for(const c of input.expected){
  query(c.query,c.scope);
  assert.match($("context-search-status").textContent,new RegExp("결과 "+c.data.total+"건"));
  const rows=$("context-search-results").children.filter(e=>e.tagName==="BUTTON");
  assert.equal(rows.length,c.data.returned,c.query);
  assert.deepEqual(JSON.parse(JSON.stringify(context.window.contextResults())),c.data.results,c.query);
  rows.forEach((r,i)=>assert.equal(r.children[0].textContent,(c.data.results[i].title || "제목 미기록").normalize("NFC"),"NFC title highlight"));
}
query("page","logs");
assert.equal($("context-search-results").children.length,50);
click("context-search-next"); assert.equal($("context-search-results").children.length,5);
assert.match(location.hash,/sp=2/);
query("ctxAttack");
assert.ok(all($("context-search-results")).some(e=>e.tagName==="MARK"));
assert.ok(!all($("context-search-results")).some(e=>e.tagName==="SCRIPT"));
query("TIMEOUT");
const searchHash=location.hash;
$("context-search-query").value="no-such-term"; $("context-search-query").fire("input");
assert.equal(timers.size,1);
$("context-search-results").children[0].fire("click");
assert.equal($("view-timeline").hidden,false);
assert.equal(timers.size,0,"result navigation must cancel pending search");
assert.match($("entry-detail").textContent,/TIMEOUT/);
assert.match(location.hash,/sq=TIMEOUT/);
location.hash=searchHash; windowEvents.popstate();
assert.equal($("view-context-search").hidden,false);
query("Cache","documents");
$("context-search-results").children[0].fire("click");
assert.equal($("document-select").value,"plan");
assert.match(location.hash,/anchor=current-state/);
query("cache");
$("context-search-query").fire("compositionstart");
$("context-search-query").value="no-such-term"; $("context-search-query").fire("input",{isComposing:true});
assert.match($("context-search-status").textContent,/결과 3건/);
$("context-search-query").fire("compositionend"); assert.match($("context-search-status").textContent,/결과 0건/);
$("context-search-query").value="cache"; $("context-search-query").fire("input");
assert.equal(timers.size,1); assert.match($("context-search-status").textContent,/결과 0건/);
$("context-search-query").fire("keydown",{key:"Enter"}); assert.equal(timers.size,0);
$("context-search-query").value="page"; $("context-search-query").fire("input");
assert.equal(timers.size,1);
const scheduled=timers.values().next().value;timers.clear();scheduled();
assert.match($("context-search-status").textContent,/결과 55건/);
assert.match(location.hash,/sq=page/);
hash("#tab=context-search&sq=page&ss=bad&sp=-2&q=old&unknown=discard");
assert.equal($("context-search-scope").value,"all");
click("context-search-next"); assert.match(location.hash,/q=old/); assert.ok(!location.hash.includes("unknown"));
query("x".repeat(257)); assert.match($("context-search-status").textContent,/256/);
hash("#tab=context-search&sq=%E0%A4%A"); assert.equal($("view-overview").hidden,false);
click("nav-handoff"); assert.equal($("handoff-text").value,input.model.handoff.text);
assert.equal($("handoff-text").readOnly,true); assert.equal(clipboardCalls,0);
click("handoff-copy"); await new Promise(setImmediate); assert.equal(clipboardCalls,1);
assert.match($("handoff-status").textContent,/복사했/);
clipboardMode="reject"; click("handoff-copy"); await new Promise(setImmediate);
assert.ok($("handoff-text").selected); assert.match($("handoff-status").textContent,/수동/);
delete context.navigator.clipboard; click("handoff-copy"); assert.match($("handoff-status").textContent,/수동/);
console.log("context behavior passed");
})().catch(e=>{console.error(e);process.exitCode=1;});
