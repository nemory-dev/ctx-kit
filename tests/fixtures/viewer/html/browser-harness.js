/* Test-only DOM adapter: executes the exact inline viewer script without a runtime dependency. */
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const input = JSON.parse(fs.readFileSync(0, "utf8"));
input.model.warnings = Array.from({length: 40000}, (_, index) => ({code:"legacy", message:"Warning " + index, source:"timeline.jsonl"}));
input.model.documents.find(doc => doc.key === "plan").text = input.model.documents.find(doc => doc.key === "plan").text.replace("Ready to resume.", "Ready to resume.\n\n" + ">".repeat(5000) + " quote");
input.model.documents.find(doc => doc.key === "plan").text += "\n\n# " + "#".repeat(100000) + "x\n\n" + "[".repeat(100000) + "\n\n" + "[x](".repeat(30000) + "\n\ninline " + "`".repeat(100000);
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
}
const ids = ["view-context-search", "nav-context-search", "view-handoff", "nav-handoff", "context-search-query", "context-search-scope", "context-search-results", "context-search-status", "context-search-previous", "context-search-next", "context-search-page", "handoff-text", "handoff-copy", "handoff-status", "skip-main", "main-content", "ctx-view-data", "view-overview", "view-timeline", "view-documents", "nav-overview", "nav-timeline", "nav-documents", "search", "type-filter", "date-from", "date-to", "file-filter", "entry-list", "entry-detail", "result-count", "unknown-dates", "page-status", "previous-page", "next-page", "document-select", "document-content", "current-state", "next-actions", "recent-entries", "git-content", "warnings", "warning-list", "warnings-details", "warnings-summary", "warnings-panel", "warning-previous-page", "warning-page-status", "warning-next-page", "project-name", "context-path", "generated-at", "snapshot-age", "open-plan-current", "open-plan-next", "clear-filters"];
ids.forEach(id => { const element = new Element("div"); element.id = id; });
const $ = id => elements.get(id);
$("ctx-view-data").textContent = JSON.stringify(input.model);
const windowEvents = {};
const location = {hash: ""};
const context = {
  document: {getElementById: $, createElement: tag => new Element(tag), createTextNode: value => { const n = new Element("#text"); n.textContent = value; return n; }},
  window: {addEventListener: (name, callback) => { windowEvents[name] = callback; }},
  location,
  history: {replaceState: (_, title, hash) => { location.hash = hash; }},
  setInterval: () => 1, URLSearchParams, URL, console,
};
vm.runInNewContext(input.script, context, {timeout: 5000});
const click = id => $(id).fire("click");
const change = (id, value) => { $(id).value = value; $(id).fire("change"); };
const query = value => { $("search").value = value; $("search").fire("input"); };
const all = element => [element].concat(element.children.flatMap(all));
const hash = value => { location.hash = value; windowEvents.hashchange(); };
assert.equal($("warning-list").children.length, 0, "Warnings must stay collapsed and avoid initial DOM growth");
assert.match($("warnings-summary").textContent, /40000/);
$("warnings-details").open = true; $("warnings-details").fire("toggle");
assert.equal($("warning-list").children.length, 50);
assert.match($("warning-page-status").textContent, /1 \/ 800/);
click("warning-next-page");
assert.equal($("warning-list").children.length, 50);
assert.match($("warning-list").children[0].textContent, /Warning 50/);
click("warning-previous-page");
assert.match($("warning-list").children[0].textContent, /Warning 0/);
$("warnings-details").open = false; $("warnings-details").fire("toggle");
assert.equal($("warning-list").children.length, 0);
assert.match($("current-state").textContent, /Ready to resume/);
assert.ok(all($("current-state")).filter(n => n.tagName === "BLOCKQUOTE").length <= 32);
assert.ok(all($("current-state")).some(n => n.tagName === "PRE" && n.textContent.startsWith(">".repeat(4968)) && n.textContent.includes("quote")), "Deep quote remainder must stay readable as raw source");
assert.match($("next-actions").textContent, /Review the next task/);
assert.ok(!$("next-actions").textContent.includes("still code"), "Code fence text must not become an overview section");
assert.equal($("recent-entries").children.length, 5);
click("nav-timeline");
const timelineHash = location.hash; click("skip-main");
assert.ok($("main-content").focused, "Skip link must focus the current main content");
assert.equal(location.hash, timelineHash, "Skip link must preserve viewer route state");
assert.equal($("entry-list").children.length, 50);
assert.match($("result-count").textContent, /결과 56건/);
click("next-page");
assert.equal($("entry-list").children.length, 6);
assert.match($("page-status").textContent, /^2 \/ 2/);
query("Task 001");
assert.equal($("entry-list").children.length, 1);
assert.match($("page-status").textContent, /^1 \/ 1/);
assert.match(location.hash, /q=Task/);
query("한글");
assert.match($("result-count").textContent, /결과 55건/);
change("file-filter", "한글.kt");
assert.match($("result-count").textContent, /결과 27건/);
change("file-filter", "한글.kt");
assert.match($("result-count").textContent, /결과 28건/);
click("clear-filters");
change("type-filter", "custom");
assert.match($("result-count").textContent, /결과 1건/);
click("clear-filters");
change("date-from", "2000-01-01");
assert.match($("result-count").textContent, /결과 55건/);
assert.match($("unknown-dates").textContent, /시각 미확인 1건 · 날짜 필터에서 제외/);
click("clear-filters");
$("search").fire("compositionstart");
$("search").value = "Task 001"; $("search").fire("input", {isComposing:true});
assert.match($("result-count").textContent, /결과 56건/);
$("search").fire("compositionend");
assert.match($("result-count").textContent, /결과 1건/);
query("no matching phrase"); assert.match($("result-count").textContent, /결과 0건/);
click("clear-filters");
$("entry-list").children[0].fire("click");
const firstHash = location.hash;
assert.match($("entry-detail").textContent, /기록 당시 로그/);
assert.match($("entry-detail").textContent, /9007199254740993/, "Raw JSON integers must retain their source digits");
assert.match($("entry-detail").textContent, /조회한 커밋 참조/);
assert.match($("entry-detail").textContent, /aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/);
$("entry-list").children[1].fire("click");
assert.notEqual(location.hash, firstHash, "Colliding record ids must remain independently selectable");
const entry = input.model.entries[0];
hash("#tab=timeline&q=Task+001&page=9999999&entry=" + encodeURIComponent(entry.key));
assert.match($("result-count").textContent, /결과 1건/);
assert.match($("page-status").textContent, /^1 \/ 1/);
hash("#tab=garbage&from=2026-99-99&file=missing&page=-1");
assert.equal($("view-overview").hidden, false);
hash("#tab=timeline&q=%E0%A4%A");
assert.equal($("view-overview").hidden, false);
click("nav-documents");
assert.match($("document-content").textContent, /MASTER_PLAN/);
const doc = input.model.documents.find(doc => doc.key === "plan");
if (doc.text.includes("MARKDOWN_TEST")) {
  const nodes = all($("document-content"));
  assert.ok(nodes.some(n => n.tagName === "H2"));
  assert.ok(nodes.some(n => n.tagName === "H2" && n.textContent === "C#"), "Literal trailing # in a heading must remain");
  assert.ok(nodes.some(n => n.tagName === "H2" && n.textContent === "Title"), "Spaced closing heading markers must be removed");
  assert.ok(nodes.some(n => n.tagName === "OL"));
  assert.ok(nodes.some(n => n.tagName === "UL"));
  assert.ok(nodes.some(n => n.tagName === "BLOCKQUOTE"));
  assert.ok(nodes.some(n => n.tagName === "CODE"));
  assert.ok(nodes.some(n => n.tagName === "PRE" && n.textContent.includes("| column |")));
  assert.ok(nodes.some(n => n.tagName === "A" && n.href === "https://example.invalid/docs" && n.rel === "noopener noreferrer"));
  assert.ok(!nodes.some(n => n.tagName === "IMG" || n.tagName === "SCRIPT"));
  assert.ok(!nodes.some(n => n.tagName === "A" && /javascript:/.test(n.href)));
  assert.match($("document-content").textContent, /\[bad\]\(javascript:alert\(1\)\)/);
  assert.match($("document-content").textContent, /<img src=/);
  assert.ok(!nodes.some(n => n.tagName === "A" && (n.textContent === "outside" || n.textContent === "missing")));
  const internal = nodes.find(n => n.tagName === "A" && n.textContent === "internal");
  assert.ok(internal); internal.fire("click");
  assert.match(location.hash, /anchor=current-state/);
  assert.ok($("doc-plan-current-state").scrolled);
  const decisionLink = all($("document-content")).find(n => n.tagName === "A" && n.textContent === "decisions");
  assert.ok(decisionLink); decisionLink.fire("click");
  assert.equal($("document-select").value, "decisions");
  assert.match($("document-content").textContent, /Explicit decision text/);
  assert.ok($("doc-decisions-decision").scrolled);
}
console.log("viewer behavior passed");
