"""Optional offline synthetic benchmark: python3 -B tests/fixtures/context-read/measure.py.

Uses copied two-file installs in temporary directories; never initializes this repo.
Node measurements cover synchronous JS with a DOM adapter, not browser paint.
"""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import sys

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'tests'))
from test_view_html import ViewerHTMLParser

PLAN = '# Plan\n## Constraints\nPreserve protected files.\n## Current State\nCache ready.\n## Next Actions\nTest timeout.\n## Verification\nReported unittest.\n## Unverified\nWindows not run.\n'


def measure(name, count, large=0, legacy=False):
    with tempfile.TemporaryDirectory(prefix='ctx-context-measure-') as temporary:
        root = Path(temporary)
        shutil.copy2(REPO / 'ctx.sh', root / 'ctx.sh')
        context = root / 'context'
        (context / 'work-log').mkdir(parents=True)
        (root / 'ctx.config.json').write_text(json.dumps({'source': 'context/AGENT_RULES.md'}))
        (context / 'MASTER_PLAN.md').write_text(PLAN)
        record = {} if legacy else dict(title='timeout cache', summary='backoff ' + 'x' * 100,
            files=['src/Retry.kt'], type='work', commit='pending', branch='fixture', dirty=False, createdAt='2026-10-30T12:00:00Z')
        (context / 'work-log/timeline.jsonl').write_text((json.dumps(record) + '\n') * count)
        if large:
            used = sum(p.stat().st_size for p in root.rglob('*') if p.is_file() and p.name != 'ctx.sh')
            size = large - used if name == '20MiB' else large
            suffix = ' timeout cache' if name == 'one-line-1MiB' else '\ntimeout cache'
            (context / 'decisions.md').write_text('x' * (size - len(suffix)) + suffix)
        input_bytes = sum(p.stat().st_size for p in root.rglob('*') if p.is_file() and p.name != 'ctx.sh')
        times = {}
        outputs = {}
        for command, flags in [('view', []), ('search', ['--query', 'timeout', '--json']),
                               ('handoff_md', ['--max-chars', '12000']), ('handoff_json', ['--json', '--max-chars', '12000'])]:
            started = time.perf_counter()
            result = subprocess.run(['/bin/bash', str(root / 'ctx.sh'), 'handoff' if command.startswith('handoff') else command] + flags,
                                    cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90)
            times[command] = round(time.perf_counter() - started, 4)
            if result.returncode:
                raise RuntimeError(name + ' ' + command + ': ' + result.stderr.decode())
            outputs[command] = result.stdout.decode()
        html = context / 'generated/view.html'
        parser = ViewerHTMLParser(); parser.feed(html.read_text())
        model = json.loads(next(t for a,t in parser.scripts if a.get('id') == 'ctx-view-data'))
        js = next(t for a,t in parser.scripts if a.get('id') != 'ctx-view-data')
        node = None
        if shutil.which('node'):
            result = subprocess.run(['node', str(Path(__file__).with_suffix('.js'))], input=json.dumps(dict(model=model, script=js)),
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=60)
            if result.returncode:
                raise RuntimeError(result.stderr)
            node = json.loads(result.stdout)
        return dict(name=name, records=count, inputBytes=input_bytes, htmlBytes=html.stat().st_size,
                    seconds=times, handoffChars={k:len(v) for k,v in outputs.items() if k.startswith('handoff')},
                    handoffSelected=json.loads(outputs['handoff_json'])['selection']['selected'],
                    viewWarnings=len(model['warnings']), node=node)


if __name__ == '__main__':
    for args in [('55',55), ('5000',5000), ('20000',20000), ('20MiB',0,20*1024*1024),
                 ('one-line-1MiB',0,1024*1024), ('40000-warnings',20000,0,True)]:
        print(json.dumps(measure(*args), ensure_ascii=True), flush=True)
