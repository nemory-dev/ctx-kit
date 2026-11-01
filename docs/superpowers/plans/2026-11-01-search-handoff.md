# 통합 검색과 근거 있는 인수인계 Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` after implementation is explicitly authorized. Steps use checkbox (`- [ ]`) syntax. 2026-11-01 사용자가 구현과 가능한 테스트를 승인했다. 기존 변경과 contracts를 보존하며 subagent·worktree·commit·push·PR·배포를 임의로 실행하지 않는다.

**Goal:** 기존 문서와 모든 로그 발생을 함께 검색하고, 근거·누락·미검증 상태를 명시한 인수인계를 CLI와 오프라인 HTML에서 제공한다.

**Architecture:** 기존 내장 reader를 공유해 같은 수집 바이트에서 출처·검색·인수인계를 파생한다. 검색은 Python/JS 공통 golden 계약, 인수인계는 Python 단일 builder를 사용한다. 기존 타임라인·export·원문 저장 형식을 유지한다.

**Tech Stack:** Bash 3.2, Python 3.7+ 표준 라이브러리, 인라인 CSS/일반 JS, unittest, 선택적 Node 검증. 새 패키지·DB·서버·AI 호출·CI 변경 없음.

---

## 1. 상태와 실행 전제

- 작성일: 2026-11-01, Asia/Seoul. 상태: 구현·자동 검증 완료. 실브라우저/사람 평가·Python3.7/Windows 실환경은 미실시. [실제 결과](../reports/2026-11-01-search-handoff-implementation.md).
- 기준: `codex/local-context-viewer`, HEAD `6c0eb86`.
- [조사](../research/2026-11-01-context-tools-benchmark.md), [규범 설계](../specs/2026-11-01-search-handoff-design.md), [Claude 검토·반영](../reviews/2026-11-01-search-handoff-claude.md).
- 보호 대상: 기존 계획 `2026-10-30-local-context-viewer.md`의 미커밋 검증 보완과 미추적 `contracts/`. 되돌리거나 스테이징하지 않는다. contracts는 수정·이동·삭제하지 않는다.
- 계획 작성 당시 신규 명령·함수·테스트는 미구현이었다. 아래는 승인 당시 체크리스트를 유지하며, 실제 구현·검증 상태는 8절과 결과 문서를 따른다.
- 저장소의 sample-context는 없다. 초기화하지 말고 BaseViewCase/합성 임시 프로젝트로 검증한다.
- 이전 검증은 전체 258개·뷰어 70개였다. [당시 결과와 미실시 항목](2026-10-30-local-context-viewer.md)은 역사적 결과로 유지한다.

## 2. 범위와 파일 책임

새 공개 인터페이스는 search/handoff CLI, 두 뷰어 탭, schemaVersion=1 응답이다. 기존 export/view/timeline 인자와 타임라인 hash는 유지한다. 새 기록 스키마·영구 ID·새 입력·지침 수집·템플릿 변경은 없다. 개인정보 마스킹·AI 요약·실제 테스트 검증을 제공한다고 표시하지 않는다.

| 파일 | 변경 책임 |
| --- | --- |
| `ctx.sh` | 공유 reader, 출처 manifest, 검색·섹션·인수인계 함수, CLI, HTML 탭, help/dispatch |
| `tests/context_read_support.py` 신규 | BaseViewCase 확장, stdout JSON/출처/행 범위 단언, golden 로딩 |
| `tests/test_context_reader.py` 신규 | 복사 설치, manifest, 공통 오류, 읽기 전용 계약 |
| `tests/test_context_search.py` 신규 | CLI 검색·정렬·Unicode·한도 |
| `tests/test_handoff.py` 신규 | 섹션·근거·반복 발생·Git 구분·출력 예산 |
| `tests/test_view_context.py` 신규 | 내장 JS 검색·hash·복사·예산 오류 표시 |
| `tests/fixtures/context-read/search-cases.json` 신규 | Python/JS 공통 입력·query·기대 결과 |
| `tests/fixtures/context-read/browser-harness.js` 신규 | 새 탭용 DOM 대역, 실제 내장 JS 실행 |
| `tests/fixtures/context-read/evaluation.md` 신규 | 20개 질문·검색어·필수 출처, 사람 평가 양식 |
| `README.md`, `README.ko.md` | 새 명령과 기존 명령의 관계 |
| `docs/en/workflows.md`, `docs/ko/workflows.md` | 검색·인수인계·원문 확인·누락·예산 |
| `docs/en/troubleshooting.md`, `docs/ko/troubleshooting.md` | 입력 오류·불완전 결과·예산·복사 실패 |

기존 tests/viewer_support.py API는 유지한다. AGENT_RULES.md, 내장 규칙·초기화 템플릿, 기본 설정, ctx.cmd, CI, contracts는 수정하지 않는다. 런타임 Python/JS를 별도 필수 파일로 분리하지 않는다.

## 3. 함수와 데이터 계약

구현·테스트·JS에서 다음 이름을 일관되게 사용한다.

```python
HANDOFF_KEYS = ("constraints", "current_state", "next_actions",
                "recorded_verification", "recorded_unverified")

collect_snapshot(project_root, context_dir, config_path, output_path=None)
build_source_manifest(config_bytes, source_bytes)
snapshot_id(manifest)
source_ref(snapshot, path, start_line, end_line)
ordered_snapshot_entries(snapshot)
build_search_units(snapshot)
search_terms(query)
search_units(units, terms, scope)
make_search_result(snapshot, hit, terms)
render_search_output(snapshot, hits, options)
scan_markdown_headings(text)
extract_handoff_sections(plan_document, snapshot)
build_handoff(snapshot, git_snapshot, options)
render_handoff(model, format_name)
fit_handoff(model, format_name, max_chars)
safe_output_text(value)
emit_stdout(value)
```

manifest/출처/인자/응답의 규범 계약은 설계 3~5절에 있다. source_ref는 수집된 manifest만 참조하고 파일을 다시 읽지 않는다. source 없는 missing에 가짜 digest나 행을 붙이지 않는다.

### 검색 정규화와 점수 기준

```python
import re
import unicodedata

ASCII_LOWER = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")

def search_fold(value):
    return unicodedata.normalize("NFC", value).translate(ASCII_LOWER)

def search_terms(query):
    if not isinstance(query, str) or "\0" in query or len(query) > 256:
        raise ValueError("query must contain 1..256 Unicode code points")
    try:
        query.encode("utf-8", errors="strict")
    except UnicodeEncodeError as error:
        raise ValueError("query must contain valid UTF-8 text") from error
    terms = [p for p in re.split(r"[ \t\r\n\f\v]+", search_fold(query)) if p]
    if not terms or len(terms) > 16:
        raise ValueError("query must contain 1..16 terms")
    return list(dict.fromkeys(terms))

def search_units(units, terms, scope):
    wanted = {"all": None, "documents": "document", "logs": "work_log"}[scope]
    hits = []
    for unit in units:
        if wanted is not None and unit["kind"] != wanted:
            continue
        title = search_fold(unit["title"]) if unit["kind"] == "work_log" else ""
        paths = [search_fold(path) for path in unit["paths"]]
        body = search_fold(unit["body"])
        combined = "\n".join([title, body] + paths)
        if all(term in combined for term in terms):
            score = sum(4 * (term in title) + 2 * any(term in path for path in paths) + (term in body)
                        for term in terms)
            hits.append({"unit": unit, "score": score})
    return sorted(hits, key=lambda hit: (-hit["score"], hit["unit"]["order"]))
```

문서 title은 표시용 path이며 title 가중치는 없다. 로그 title 누락은 공개 null/표시 ‘제목 미기록’/검색용 빈 문자열이다. order는 기존 정렬 위치이고 JS도 같은 모델 배열 순서를 따른다. search_terms에서 strict UTF-8 encode 검사를 더해 원시 query surrogate도 거부한다.

snippet의 표시 문자열만 NFC로 만들며 원문과 hash는 바꾸지 않는다. 첫 일치 앞 40 code points부터 본문 최대 158 code points를 취하고 앞뒤 생략 시 각각 `…`를 붙여 최대 160으로 제한한다. JS는 일치 위치에서 surrogate pair 단위로 전후를 걸어 큰 문서 전체를 Array.from으로 펼치지 않는다. 경로에만 일치하면 path를 발췌하고 문서 본문 행을 지어내지 않는다.

### 공유 reader 기준

cmd_view의 Python heredoc을 `context_reader_python()` Bash 함수로 한 번만 옮긴다. 기존 함수명과 CTX_VIEW_IMPLEMENTATION_START/END 마커를 유지한다. Python 실행 본체는 `run_view()`/`run_search()`/`run_handoff()`로 나누고 환경변수의 action enum으로 호출한다.

```python
action = os.environ["CTX_READER_ACTION"]
if action not in ("view", "search", "handoff"):
    raise ValueError("Unknown context reader action")
```

output_path=None이면 collector의 출력 경로 abspath/realpath 계산만 건너뛰고 lock 제외는 유지한다. search는 Git을 조회하지 않는다. handoff는 기존 Git 함수에 빈 commit_refs를 넘긴다. view의 출력 사전검사·동시 변경 검사·보호 쓰기·선택적 열기는 run_view 안에서 기존 순서를 유지한다.

## 4. 구현 작업: 조사 → 수정 → 검증 → 정리

각 새 테스트의 실패 원인을 확인한 뒤 최소 구현하고 대상 테스트를 통과시킨다. 코드 이동 회귀와 기능 구현을 분리한다. Task 1~3은 검색, 4~5는 인수인계, 6~7은 HTML이다. 커밋은 사용자 지시 때만 한다.

### Task 0: 상태와 기준선

대상: 읽기 전용 ctx.sh/tests/기존 계획.

- [ ] git status/diff로 보호 범위와 기준 커밋을 확인한다.
- [ ] 아래 검사를 한 번 실행해 실제 건수·시간을 기록한다. 기존 실패는 본건에 섞어 고치지 않는다.

```bash
/bin/bash -n ctx.sh
python3 -B -m unittest discover -s tests -v
git diff --check
```

기대: 각 명령 0, unittest 성공. 컨텍스트를 초기화하지 않는다.

### Task 1: 공유 reader와 복사 설치

수정: ctx.sh의 cmd_view/Python heredoc. 생성: context_read_support.py, test_context_reader.py.

- [ ] ContextReadCase를 BaseViewCase에서 상속하고 read_stdout_json(result), assert_sources_unchanged(before)를 제공한다. stdout 파싱 실패와 종료 코드는 테스트 실패로 남긴다.
- [ ] 3절의 공유 reader로 기존 코드를 이동한다. 엄격한 CONTEXT_DIR 해석을 resolve_view_context에 추출한다. view는 같은 환경변수에 action=view를 더해 호출한다.
- [ ] 이 단계는 동작을 바꾸지 않는 코드 이동이므로 기존 view 70개와 Bash 구문으로 회귀를 확인한다. 새 search 테스트는 Task3에서 추가해 중간 단계에 의도적인 실패를 남기지 않는다.

```bash
python3 -B -m unittest discover -s tests -p 'test_view*.py' -v
/bin/bash -n ctx.sh
```

### Task 2: manifest와 출처

수정: ctx.sh의 collect_snapshot/build_view_model. 테스트: test_context_reader.py.

- [ ] test_manifest_uses_collected_bytes, test_manifest_missing_vs_empty, test_snapshot_id_ignores_time_and_output, test_source_counts_lf_only, test_identical_rows_have_distinct_refs를 추가한다.
- [ ] 수집 뒤 원문 변경 fault injection으로 hash가 수집 바이트를 가리키는지 실패를 확인한다. 기존 재수집 로직은 유지한다.
- [ ] 설정·허용 입력을 각각 한 번 hash하고 missing 항목을 포함한다. 다음 canonical 계산을 사용한다.

```python
def snapshot_id(manifest):
    ordered = sorted(manifest, key=lambda row: (row["root"], row["path"]))
    packed = json.dumps(ordered, ensure_ascii=True, sort_keys=True,
                        separators=(",", ":")).encode("ascii")
    return "sha256:" + hashlib.sha256(packed).hexdigest()
```

- [ ] source_ref는 manifest의 실제 입력에 한해서 root/path/range/hash를 만든다. 내부 viewer model에 sourceManifest/snapshotId를 선택적으로 추가하고 viewModelVersion=1은 유지한다.
- [ ] 대상 테스트와 기존 수집·출력 안전성 테스트를 실행한다.

```bash
python3 -B -m unittest discover -s tests -p 'test_context_reader.py' -v
python3 -B -m unittest discover -s tests -p 'test_view_data.py' -v
python3 -B -m unittest discover -s tests -p 'test_view_safety.py' -v
```

### Task 3: CLI 통합 검색

수정: ctx.sh의 cmd_search/run_search/help/dispatch/검색 함수. 생성: test_context_search.py와 공통 search-cases.json.

- [ ] query 누락·공백·257자·17개 검색어, 중복 옵션, 잘못된 scope, limit 0/51, 알 수 없는 인자, help의 Python 불필요를 테스트한다.
- [ ] CLI 복사 설치의 새 계약도 여기서 추가하고 unknown command로 실패하는 것을 확인한다.

```python
from context_read_support import ContextReadCase

class ContextSearchTests(ContextReadCase):
    def test_search_copy_preserves_sources(self):
        before = self.source_snapshot()
        result = self.run_ctx("search", "--query", "Ready", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_stdout_json(result)["total"], 1)
        self.assertEqual(self.source_snapshot(), before)
        self.assertFalse(self.output.exists())
```

- [ ] 다음 테스트가 실패하는 것을 확인한다.

```python
def test_document_body_and_log_are_searchable(self):
    (self.context / "decisions.md").write_text("# 선택\ntimeout cache 채택\n", encoding="utf-8")
    self.write_jsonl("work-log/timeline.jsonl", [
        {"title": "timeout", "summary": "cache checked", "files": []}])
    result = self.run_ctx("search", "--query", "TIMEOUT cache", "--json")
    data = self.read_stdout_json(result)
    self.assertEqual(data["total"], 2)
    self.assertEqual({r["kind"] for r in data["results"]}, {"document", "work_log"})
    self.assertTrue(all(r["source"]["sha256"] for r in data["results"]))
```

- [ ] active/archive의 동일 내용 3발생, 시차/시각 미확인, 큰 정수, 잘못된 선택 필드, U+2028, NFC/NFD, emoji, 경로만 일치, 검색어가 다른 레코드에 흩어진 비일치를 golden에 추가한다.
- [ ] 3절의 search_fold/search_terms/search_units와 기존 모델을 참조하는 build_search_units를 구현한다. 문서 원문·recordText를 결과마다 복제하지 않는다.
- [ ] Bash wrapper는 옵션을 중복 검사하고 값은 환경변수로 전달한다. eval·명령 문자열 합성을 사용하지 않는다. 정수 옵션은 십진 숫자만 허용한다. run_search는 Git/HTML/브라우저를 호출하지 않는다.
- [ ] 전체 응답 확정 뒤 stdout으로 한 번 출력한다. --json은 ANSI/성공 안내가 없는 object 하나이며, source·점수·정렬·scope·limit·총수·생략수를 단언한다.

```bash
python3 -B -m unittest discover -s tests -p 'test_context_search.py' -v
python3 -B -m unittest discover -s tests -p 'test_context_reader.py' -v
```

### Task 4: 명시적 섹션과 인수인계 후보

수정: ctx.sh의 scan_markdown_headings/extract_handoff_sections/build_handoff. 생성: test_handoff.py.

- [ ] 펜스 속 가짜 제목, H2 종료 경계, H3 포함, 반복 제목 전체 보존, 빈/누락 섹션, 한영 제목, CRLF/U+2028 행 구분을 실패 테스트로 고정한다.
- [ ] 로그의 성공 보고로 검증 섹션을 채우지 않는 계약을 다음처럼 고정한다.

```python
def test_missing_verification_is_not_inferred_from_log(self):
    self.write_jsonl("work-log/timeline.jsonl", [{
        "title": "all tests passed", "summary": "success", "files": [],
        "commit": "pending", "dirty": False}])
    result = self.run_ctx("handoff", "--json", "--max-chars", "20000")
    data = self.read_stdout_json(result)
    verification = next(s for s in data["mandatory"] if s["key"] == "recorded_verification")
    self.assertEqual(verification["status"], "missing")
    self.assertEqual(data["status"], "incomplete")
```

- [ ] 설계9절의 별도 엄격 scanner를 구현한다. unindented ATX H2만 채택하며 HTML comment/들여쓰기/인용/목록 속 제목을 제외한다. setext가 필수 블록에 있으면 ambiguous로 제외한다. BOM/CRLF/닫는#/미종결 fence/유사 제목/반복을 검사한다. 기존 renderer 파서는 유지한다.
- [ ] 3절의 HANDOFF_KEYS를 유일한 정본 순서로 사용해 후보·JSON·Markdown·HTML을 구성한다. 설계5절 표와 같은지 순서 단언을 둔다.
- [ ] Git은 collect_git_snapshot(root, exclusions, [])의 관측값만 요약한다. pending/dirty를 현재 성공·작업 트리 증거로 쓰지 않는다. Git 없음/실패도 문서를 출력한다.
- [ ] query가 없으면 기존 UTC 순서, 있으면 logs 검색 순서로 후보를 선택한다. limit=0도 available/omittedByLimit이 정확해야 한다.

```bash
python3 -B -m unittest discover -s tests -p 'test_handoff.py' -v
```

### Task 5: 예산·원문·CLI 출력

수정: ctx.sh의 render_handoff/fit_handoff/safe_output_text/cmd_handoff/help/dispatch. 테스트: test_handoff.py와 test_context_reader.py.

- [ ] 필수만으로 예산 초과→stdout 비움/종료1, 정확히 N자 성공/N-1자 실패, missing은 경고 성공0, 동일 발생 보존, 큰 정수 자릿수, code fence 공격, 단독 surrogate를 테스트한다.
- [ ] JSON/Markdown 모두 최종 LF·출처·안내·생략 건수를 포함한 실제 출력 길이를 단언한다.
- [ ] 원문 표시와 UTF-8 출력은 다음 기준으로 구현한다.

```python
def safe_output_text(value):
    value = value.replace("\r\n", "\n")
    def escape(char):
        if char == "\\":
            return "\\\\"
        point = ord(char)
        control = point < 32 and char not in "\n\t" or 127 <= point <= 159
        bidi = point in (0x061C, 0x200E, 0x200F) or 0x202A <= point <= 0x202E or 0x2066 <= point <= 0x2069
        surrogate = 0xD800 <= point <= 0xDFFF
        return "\\u%04x" % point if control or bidi or surrogate else char
    return "".join(escape(char) for char in value)

def literal_block(text):
    text = safe_output_text(text)
    longest = max((len(m.group(0)) for m in re.finditer(r"~+", text)), default=0)
    fence = "~" * max(3, longest + 1)
    return fence + "text\n" + text + "\n" + fence + "\n"
```

- [ ] 필수 원문만으로 초과하면 렌더 전 실패한다. 나머지는 k=0부터 실제 선정·생략 수로 렌더하고 처음 초과한 직전 결과를 고른다. 9↔10/99↔100 경계와 available=selected+omittedByLimit+omittedByBudget을 검사한다. 조각은 한 번 직렬화해 재사용한다.
- [ ] 손상/journal/동시 변경/잘못된 설정에서 부분 출력하지 않고 원본·기존 HTML을 보존하는지 확인한다. --open/--output은 거부한다.

```bash
python3 -B -m unittest discover -s tests -p 'test_handoff.py' -v
python3 -B -m unittest discover -s tests -p 'test_context_reader.py' -v
```

### Task 6: HTML 통합 검색과 Python/JS 일치

수정: ctx.sh의 VIEW_JS/VIEW_HTML/VIEW_CSS. 생성: test_view_context.py와 새 browser-harness.js.

- [ ] 새 tab DOM 부재, 같은 golden query에 대한 순서·점수·source·snippet 불일치를 먼저 실패로 확인한다.
- [ ] view-context-search, nav-context-search, context-search-query, context-search-scope, context-search-results, context-search-status와 이전/다음 버튼을 추가한다. 기존 id를 재사용하지 않는다.
- [ ] 기존 model에서 units를 만들고 3절의 정규화·AND·점수·order·snippet 계약을 구현한다. 새 데이터 script나 원문 복제 배열을 만들지 않는다.
- [ ] tab=context-search와 sq/ss/sp를 hash에 추가한다. 기존 hash는 같은 상태로 복원하고 잘못된 escape/scope/page는 안전한 기본값으로 처리한다.
- [ ] IME 조합 완료까지 기다리고 최대50행 DOM을 만든다. 문서는 직전 제목, 로그는 기존 상세로 이동한다. mark 요소와 textContent만으로 강조한다.
- [ ] Node가 없으면 skip 이유를 남긴다. 실제 내장 JS에 timeout을 걸어 공격 문자열/위험URL/외부 이미지/대수/빈 결과/페이지/hash 복원을 실행한다.

```bash
python3 -B -m unittest discover -s tests -p 'test_view_context.py' -v
python3 -B -m unittest discover -s tests -p 'test_view_html.py' -v
```

### Task 7: 같은 builder의 인수인계 탭과 복사

수정: ctx.sh의 run_view/VIEW_JS/VIEW_HTML/VIEW_CSS. 테스트: test_view_context.py와 새 harness.

- [ ] 생성 시각을 고정해 같은 snapshot으로 만든 CLI builder 본문과 HTML 본문이 같은지, 예산 초과에도 view가 성공하는지 실패 테스트를 만든다.
- [ ] nav-handoff/view-handoff/handoff-text/handoff-copy/handoff-status를 추가한다. Python 기본 handoff를 textContent/readOnly textarea로 표시한다.
- [ ] 버튼 미조작 시 clipboard 호출0, writeText 성공/거부/API 없음의 세 경로를 검증한다. 실패 시 focus/select와 수동 복사 안내를 제공한다.
- [ ] tab=handoff hash, complete/incomplete/budget_exceeded를 표시한다. complete는 필수 섹션 기재 여부이며 진행 승인과 무관하다. HTML은 query 재선정·독자적 요약·예산 계산을 하지 않는다.
- [ ] 기존 CSP의 JS/CSS hash, script/style 수, 외부 리소스 없음 검증을 다시 실행한다.

```bash
python3 -B -m unittest discover -s tests -p 'test_view_context.py' -v
python3 -B -m unittest discover -s tests -p 'test_view*.py' -v
```

### Task 8: 한영 안내와 평가 fixture

수정: 2절의 README/workflows/troubleshooting 한영 문서. 생성: evaluation.md.

- [ ] 구현된 CLI 계약과 ASCII 대소문자 처리, 문서 단위 AND, 당시 보고/현재 검증의 차이, 제약의 완전 자동 추출을 하지 않는다는 점을 한영으로 맞춘다.
- [ ] 권장 H2 이름은 안내만 하고 기존 MASTER_PLAN·템플릿을 자동 변경하지 않는다. missing은 사용자가 원문을 확인해 기재하는 절차로 설명한다.
- [ ] scope별 예, 예산 초과, 복사 실패, 공유 범위, 스냅샷 한정 참조를 문서화한다.
- [ ] evaluation.md의 20개 질문과 검색어·필수 출처를 6절 표대로 고정한다. 사람 평가 시간·정답 칸은 미실시로 둔다.

### Task 9: 성능·호환성·사람 평가

- [ ] 55/5천/2만 건, 설정 포함20 MiB 문서, 한 줄의 큰 문서, 경고4만 fixture를 임시 프로젝트에 만든다. 기존 계획14.2절 재현 절차에 필수 H2 합성 입력을 더한다.
- [ ] 입력 bytes/생성 시간/HTML bytes/검색 초기화·동기 처리/DOM/예산 계산을 측정한다. 5천 건 생성3초·검색200ms와 2만 건 조작 가능/최대50행을 평가한다. Node 동기 시간과 브라우저 그리기를 구분한다.
- [ ] macOS Bash3.2와 사용 가능한 Python, 기존 Linux runtime에서 대상 검증을 실행한다. Python3.7/Windows 실환경이 없으면 미실시로 남기고 설치·이미지 다운로드·CI 변경을 추가하지 않는다.
- [ ] Chrome/Safari의 사람에 의한 file://검색·키보드·복사 성공/거부·HTTPS 명시 클릭·자동 외부 요청0을 기록한다. 기존 자동 접근 거부를 우회하지 않는다.
- [ ] 처음 보는 사람이 상태·다음 행동·제약·미검증을 설명하기까지 Markdown 직접 열람과 비교한다. 60초라도 오답이면 미달성. 두 번째 열람의 학습 효과를 분리한다.
- [ ] 새 대상 검증이 성공하면 전체 회귀를 한 번 실행한다. 변경·실패가 없으면 반복하지 않는다.

```bash
/bin/bash -n ctx.sh
python3 -B -m unittest discover -s tests -v
git diff --check
```

### Task 10: 결과 정리와 인계

- [ ] 설계 각 조건에 구현·검증 근거를 연결하고 새 기능/기존 회귀/플랫폼·사람 미실시를 구분한다.
- [ ] 최종 출력에서 source hash/행 범위, 반복 발생, 예산 생략, 권한을 부여하지 않는 안내문을 확인한다.
- [ ] AGENT_RULES·설정·CI·contracts와 불필요한 임시 파일이 변경되지 않았는지 확인한다. 자기 임시 fixture만 정리한다.
- [ ] 변경 요약/수정 파일/실제 검증/남은 항목 순서로 보고한다. 승인 없는 commit/push/PR은 하지 않는다.

### 단계별 추가 필수 검증 (Claude 1차 검토 반영)

다음 조건은 선택 개선이 아니며 해당 Task의 완료 조건이다. 상세 동작은 설계9절을 따른다.

| Task | 추가 작업·실패 테스트 |
| --- | --- |
| 1 | wrapper가 모든 전달 환경변수를 매번 설정. 상속 CTX_VIEW_OUTPUT/OPEN/ACTION이 search/handoff의 쓰기를 유발하지 않음. work-log/lock 생성·fsync 범위, 잠금 권한 부족·timeout1, Bash3.2 stdout LF 보존 |
| 3 | query=UTF-8/원시256cp/분리 전16어, 숫자ASCII만, --query=--flag, --name=value, 단독--거부/help 단독. VT/FF/U+001C/U+0085/NBSP/U+3000/U+2028/U+2029/İ/Kelvin/emoji, 파일명콜론, 경로만일치행null, 한줄1MiB 후반snippet |
| 4 | comment/들여쓰기/인용/목록/setext/미종결fence/중복제목. complete=기재 여부, grantsAuthority=false, missing≠없음. 필수순서 constraints/current_state/next_actions/recorded_verification/recorded_unverified |
| 4 | 필수블록 안의1~3칸 들여쓴ATX는 해당블록ambiguous, 미종결comment는EOF까지이며 영향블록ambiguous. HANDOFF_KEYS 하나를 JSON/Markdown/HTML 순서의 정본으로 사용 |
| 4 | 기존 GIT_OPTIONAL_LOCKS=0/환경정리/lock제외/timeout/상태구분 유지. GIT_TERMINAL_PROMPT=0과 core.fsmonitor=false 추가. sentinel fsmonitor 미실행/index 불변. 미커밋 수를 검증 이후 변경으로 추정하지 않음 |
| 5 | 고정8종 경고/각2개·160자 샘플/전체·생략수. 4만 경고의 전체배열을 인수인계에 넣지 않음. OSC52/ESC/CR/bidi, title의 가짜Constraints, path/branch/경고 문자열 모두 격리 |
| 5 | Markdown 표시이스케이프와 JSON ensure_ascii=True 값보존 분리. 실제 형식별최종LF 예산/자릿수경계. emit_stdout은 bytes 확정 후 부분write 처리, BrokenPipe1/traceback없음, 입력오류0bytes와 출력I/O 일부전달 구분 |
| 5 | CRLF→LF 표시는 terminal_controls로 경고하지 않음. 원래백슬래시→두개표시, 실제제어문자와 구분. 선택원문필드의 CRLF/백슬래시/제어문자 변환수를 displayStats에 포함. JSON 원값은 그대로 |
| 6 | 150ms debounce/compositionend·Enter즉시, 검색캐시와20MiB heap 측정. 알려진hash필드 일괄보존, 결과이동 pushState와 popstate로 이전 검색·필터 복귀. 임의 unknown hash를 보존하지 않음 |
| 7 | 기존 Git 관측 재사용. 알려진 budget/구조불명만 탭안에 표시. 예상밖 builder 오류는 실패·기존결과보존으로 남겨 숨기지 않음 |
| 8~9 | Unicode11 이후 NFC parity 미보장, 인수인계에 결정문서 전문/자유형식 제약 자동포함 안함, 최소필요문자수·기본예산 성공률을 문서화/측정 |

예산 측정은 JSON/Markdown을 나누며 JSON ASCII escape에 따른 한글 분량 증가를 기록한다. 첫 초과에서 멈추는 접두 정책은 최대 수록량 최적화가 아니다. 이 제한을 설명하고, 뒤쪽 k가 더 작다는 이유로 앞 기록을 건너뛰지 않는 회귀 테스트를 둔다.

실제 코드 수정이 시작되면 이 표의 항목도 독립적인 작은 테스트로 실패→최소수정→통과 순서로 진행한다. 새 테스트명을 의미에 맞춰 부여하되 기존 테스트를 삭제해 수를 맞추지 않는다.

## 5. 요구사항·검증 연결

| 요구 | 구현 | 최소 검증 |
| --- | --- | --- |
| 두 파일/원문/lock/명시 실패 | Task1~2 | copy/scripts/custom context, journal, 동시 변경 |
| 수집 바이트 출처와 snapshot | Task2 | missing/empty, 시간 불변, 수집 후 변경, LF |
| 문서·모든 발생 검색 | Task3/6 | AND/scope/점수/order, Unicode parity, 최대50 DOM |
| 명시 섹션·근거·누락 | Task4 | fence/반복/빈 섹션, 로그의 성공 보고 비승격 |
| 엄격한 형식별 예산 | Task5 | N/N-1, 필수 초과, raw 숫자, 접두 선정 |
| 공통 builder·복사 대안 | Task7 | 고정 snapshot 본문 일치, 거부/미지원, view 성공 |
| 문서·성능·사용성 | Task8~9 | 한영, 20개 질문, 부하, 사람 체크 |
| 보호 범위·커밋 경계 | Task0/10 | 작업 전후 status/diff |

## 6. 검색·재개 평가 20개 질문

합성 문서와 로그의 아래 키워드를 실제로 넣고 source 경로·행을 정답으로 기록한다. 단위 Unicode/오류 테스트와 별도 자료다. 질문은 사람이 확인할 목적이고 검색어는 지원하는 키워드 AND 입력이다.

| 확인할 질문 | 검색어 | 필수 합성 출처 |
| --- | --- | --- |
| 현재 상태는? | cache | MASTER_PLAN Current State |
| 다음 검증은? | timeout | MASTER_PLAN Next Actions |
| 수정 제약은? | protected | MASTER_PLAN Constraints |
| 미실시 OS는? | Windows | MASTER_PLAN Unverified |
| 실행했다고 기록한 검증은? | unittest | MASTER_PLAN Verification |
| 서버를 두지 않은 이유는? | offline | decisions |
| 다음 개선 아이디어는? | reranking | backlog |
| 과거 주요 단계는? | milestone | timeline-digest |
| 보관된 완료 작업은? | completed | completed-tasks |
| 대체된 결정은? | superseded | decisions-deprecated |
| 재시도 관련 제목은? | retry | 로그 title |
| 지연 관련 보고는? | backoff | 로그 summary |
| 해당 파일 작업은? | Retry.kt | 로그 files |
| 한글 경로 작업은? | 한글.kt | NFD files 로그 |
| 대문자 검색도 같은가? | TIMEOUT | timeout 로그 |
| 두 키워드의 공통 작업은? | timeout cache | 두 단어를 같은 unit에 가진 기록 |
| 반복된 동일 작업은? | occurrence | active/archive 각각 |
| 시각 불명 기록은? | legacy | timezone 없는 로그 |
| 공격 문자열 원문은? | ctxAttack | 비실행 공격 로그 |
| 없는 내용은? | no-such-term | 0건 |

## 7. Claude 검토 이후 결정

1차 검토의 P1-1~10/P2/P3를 설계9절과 단계별 추가 필수 검증에 연결했다. 코드에서 이미 있는 optional lock/lock 제외/실패구분은 재구현하지 않고 fsmonitor·prompt 차단만 추가한다. 기존 renderer 전체 교체, arbitrary unknown hash 보존, 예상외 오류를 숨기는 포괄처리, 검증 이후 변경 추정은 채택하지 않았다. 정확한 이유와 실제 Claude 원문은 리뷰 문서에 있다. 계획 검토를 구현 테스트나 브라우저 검증으로 표현하지 않는다.

2차의 CRLF 표시·들여쓴ATX 경계·필수순서 P1 3건과 escape/예산 P2를 반영했다. 3차는 P0/P1 없음·accept(계획 Task4 순서 동기화 확인 조건)였다. Codex가 HANDOFF_KEYS/Task4/설계표의 같은 순서를 확인해 조건을 닫았다. 3차 선택 의견도 들여쓴제목 경고·미변환 문자 범위·CRLF 표시 한계로 설계9절과 테스트 목록에 반영했다.

문서의 로컬 링크·펜스·예제 Python3.7 AST를 검사하고 순수 함수 예제(검색정규화/인자/점수/hash/CRLF/제어문자/fence)를 실행해 확인했다. 이는 제품 코드·신규 테스트·브라우저의 검증 결과가 아니다.

## 8. 구현 결과 기록

2026-11-01 사용자의 구현 승인 후 기존 체크아웃에서 순차 실행했다. [구현 결과·검증·성능·미실시](../reports/2026-11-01-search-handoff-implementation.md)에 실제 증거를 정리했다. 위 체크리스트는 승인 당시 상세 기준이며 전부 완료했다고 일괄 표시하지 않는다.

| Task | 실제 상태 |
| --- | --- |
| 0 보호·기준 | 기존 변경 기록, baseline 258개 통과. 기존 뷰어 계획의 SHA-256 동일. contracts 미수정 |
| 1~2 공유 reader/출처 | 구현. 기존 뷰어 70개 및 신규 reader 계약 검증. 두 파일 복사/ scripts 설치 유지 |
| 3 CLI 검색 | 구현. Unicode/AND/점수/동점/발생/한도/원문 출처 및 20문항 자동 확인 |
| 4~5 인수인계 | 구현. 엄격 섹션·누락·원문·표시 변환·경고·형식별 N/N-1 예산·접두 선정 확인 |
| 6~7 HTML | 구현. CLI/JS golden 일치·페이지/IME/hash/뒤로가기·복사 대안·동일 builder 확인. 실제 브라우저는 미실시 |
| 8 문서/평가 fixture | 한영 사용/복구 안내, 20문항 합성 정답/사람 기록 양식, 재현 가능한 측정 스크립트 추가 |
| 9 성능·호환성 | 6개 합성 부하 실측. macOS Python3.9/3.11/3.13, Linux Python3.11/Node20 확인. 나머지 사람/브라우저/3.7/Windows는 미실시 |
| 10 정리 | 전체 306개 통과, diff/문법/로컬 문서 링크 확인. 커밋·push·PR 없음 |

주요 구현 선택: search/handoff Bash 파서는 공통 cmd_context_read로 묶었다. 인수인계 기본 limit=5는 설계5절을 따른다. JSON notice는 권한 안내를 명시하는 추가 필드다. 기존 구 browser-harness의 테스트 단언은 유지하고 새 DOM id만 추가했다. 검색 source 원문은 중복 저장하지 않으며 lazy 정규화와 query/scope/result 캐시를 사용한다. 원래 Markdown/JSONL·기존 계획·설정·템플릿은 수정하지 않는다.

검증 명령: `/bin/bash -n ctx.sh`, `python3 -B -m unittest discover -s tests -v`, `git diff --check`. 최종 전체 실행은 306개/117.259초/OK였다. 자세한 환경별 결과와 Node 대역의 한계는 결과 문서에 있다. 사람 평가를 통과한 것으로 표시하지 않는다.

## 9. 구현 코드 Claude 리뷰 후 갱신

사용자 요청으로 실제 Claude CLI의 1차 코드·테스트 리뷰와 후속4회 조건 확인을 수행했다. [리뷰 원문·지적별 결정·최종 증거](../reviews/2026-11-01-search-handoff-code-claude.md), [구현 결과의 후속 수정](../reports/2026-11-01-search-handoff-implementation.md)을 따른다. 8절의 306개는 리뷰 전 역사적 실행이며, **최종331개 / 117.194초 / OK**로 갱신한다. 리뷰 회귀25개를 추가했다. Python3.9/3.13 각73개, Linux Python 대상143개(5skip)와 Linux Node5개도 확인했다. Bash/Python3.7 문법/Node 문법/diff 검사를 통과했다.

마지막 accept는 주석 종료 조건의 수정 확인이다. 실제 브라우저·Python3.7 실환경·Windows·사람 평가의 미실시를 해제하지 않는다. 기존 수정 계획/ contracts를 보존하고 commit/push/PR은 하지 않았다. 불확실한 Markdown의 보수적 제외와 Git 필터 신뢰 경계는 설계10절에 기록했다.
