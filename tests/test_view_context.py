"""The actual embedded JS shares search contracts with the Python CLI."""
import json
from pathlib import Path
import shutil
import subprocess

from context_read_support import ContextReadCase
from test_view_html import ViewerHTMLParser

FIXTURES = Path(__file__).parent / 'fixtures/context-read'


class ViewContextTests(ContextReadCase):
    def test_search_parity_navigation_ime_paging_and_clipboard(self):
        if not shutil.which('node'):
            self.skipTest('Node unavailable; embedded JS not executed')
        cases = json.loads((FIXTURES / 'search-cases.json').read_text())
        self.complete_plan()
        (self.context / 'decisions.md').write_text('# Choice\nalpha\u2028beta\n' + '😀' * 200 + 'NEEDLE 끝' + 'x' * 200)
        (self.context / 'backlog.md').write_bytes(b'# Backlog\ncontrolmatch\r\r\n')
        records = cases['records'] + [{'title': 'page %d' % i} for i in range(55)]
        self.write_jsonl('work-log/timeline.jsonl', records)
        self.write_jsonl('archive/timeline-colon:name.jsonl', [records[0]])
        expected = [dict(query=c['query'], scope=c['scope'], data=self.search(c['query'], '--scope', c['scope'], '--limit', '50')) for c in cases['queries']]
        self.assertEqual(self.run_ctx('view').returncode, 0)
        parser = ViewerHTMLParser()
        parser.feed(self.output.read_text())
        ids = {a.get('id') for _, a in parser.tags}
        self.assertTrue({'nav-context-search', 'view-context-search', 'context-search-query', 'handoff-copy', 'handoff-text'}.issubset(ids))
        script = next(t for a, t in parser.scripts if a.get('id') != 'ctx-view-data')
        result = subprocess.run(['node', str(FIXTURES / 'browser-harness.js')], input=json.dumps(dict(model=self.read_view_model(), script=script, expected=expected)), stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('context behavior passed', result.stdout)

    def test_view_uses_same_builder_without_second_git_observation(self):
        self.complete_plan()
        self.write_jsonl('work-log/timeline.jsonl', [{'title': 'cache'}])
        self.assertEqual(self.run_ctx('view').returncode, 0)
        model = self.read_view_model()
        ns = self.helpers()
        snapshot = dict(documents=model['documents'], entries=model['entries'], snapshotId=model['snapshotId'],
                        sourceLookup={r['path']: r for r in model['sourceManifest'] if r['root'] == 'context'}, collectionFinishedAt=model['collectionFinishedAt'])
        _, expected = ns['fit_handoff'](ns['build_handoff'](snapshot, model['git'], dict(query=None, limit=5)), 'markdown', 12000)
        self.assertEqual(model['handoff']['text'], expected)

    def browser_probe(self, model, probe):
        if not shutil.which('node'):
            self.skipTest('Node unavailable; embedded JS not executed')
        adapter = (FIXTURES / 'browser-harness.js').read_text().split('vm.runInNewContext', 1)[0]
        program = adapter + '''
vm.runInNewContext(input.script.replace("  renderGit(); renderWarnings(); render();",
  "window.review={setState,contextHits,contextResult,contextTerms};"), context, {timeout:5000});
''' + probe
        result = subprocess.run(['node', '--max-old-space-size=128', '-e', program],
                                input=json.dumps(dict(model=model, script=self.helpers()['VIEW_JS'])),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                universal_newlines=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_repetitive_long_title_has_bounded_preview_and_highlight_dom(self):
        title = 'x ' * 16384
        model = dict(project={}, documents=[], warnings=[], git={}, generatedAt='',
                     sourceManifest=[dict(root='context', path='work-log/timeline.jsonl', sha256='a' * 64)],
                     entries=[dict(key='work-log/timeline.jsonl:1', sourcePath='work-log/timeline.jsonl',
                                   sourceLine=1, record=dict(title=title), recordText='{}')])
        self.browser_probe(model, '''
context.window.review.setState({tab:"context-search",sq:"x",ss:"logs",sp:1});
const row=$("context-search-results").children[0];
assert.ok(Array.from(row.children[0].textContent).length<=160,"long title preview must be bounded");
const descendants=e=>1+e.children.reduce((n,c)=>n+descendants(c),0);
assert.ok(descendants(row)<500,"repetitive titles must not create unbounded marks");
const h=context.window.review.contextHits("x","logs");
assert.equal(context.window.review.contextResult(h.hits[0],h.terms).title,input.model.entries[0].record.title,"raw title stays intact");
''')

    def test_query_validation_avoids_lookbehind_and_rejects_lone_surrogates(self):
        self.browser_probe(dict(project={}, documents=[], entries=[], warnings=[], git={}, generatedAt=''), '''
assert.ok(!input.script.includes("(?<"),"legacy browsers must not encounter lookbehind literals");
for(const value of [String.fromCharCode(0xd800),String.fromCharCode(0xdfff),"x".repeat(257)]) {
  assert.throws(()=>context.window.review.contextTerms(value));
}
assert.equal(context.window.review.contextTerms("😀".repeat(256)).length,1);
''')

    def test_empty_search_tab_explains_how_to_start(self):
        self.browser_probe(dict(project={}, documents=[], entries=[], warnings=[], git={}, generatedAt=''), '''
context.window.review.setState({tab:"context-search",sq:"",ss:"all",sp:1});
assert.match($("context-search-status").textContent,/검색어를 입력/);
assert.equal($("context-search-previous").disabled,true);
assert.equal($("context-search-next").disabled,true);
''')
