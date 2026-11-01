# 통합 검색·근거 있는 인수인계 코드 리뷰와 반영

2026-11-01. 사용자가 구현·테스트의 Claude 리뷰와 필요한 수정을 승인했다. [설계 검토](2026-11-01-search-handoff-claude.md)와 구분하는 실제 코드 리뷰 기록이다. 기존 변경과 contracts를 보존하며 커밋하지 않는다.

## 실제 요청과 범위

- 실제 Claude CLI 2.1.306, 도구/MCP/슬래시 명령/프로젝트 설정/세션 저장 비활성화, stdin으로 명시적 diff·신규 테스트 전문·공유 reader/lock 문맥·설계·실측·306개 결과를 전달했다. 파일 수정 권한을 주지 않았다.
- 응답 모델: claude-opus-5-5. CLI 종료0 / is_error=false / API 476.156초 / 1turn. 응답의 정적 분석과 Codex의 실행 증거를 구분한다.
- 최초 샌드박스 안의 auth status가 false였으나 macOS Keychain 접근이 가능한 실행에서는 로그인 정상으로 확인했다. Bridge 요청 400b9b1b-b4ae-4510-b064-02c75edd9a56은 context 크기 제한과 직접 CLI 전환으로 취소했다. 미완료 요청을 Claude 응답으로 표현하지 않았다.
- 1차 프롬프트 SHA-256: bb34ed9452bbae83d2c1f5bafc1fc24397d1336dbdfb84024769ae7bfb693a00, UTF-8 202635 bytes. contracts 내용이나 기존 수정 계획의 diff는 전송하지 않았다.
- Claude는 명령·브라우저·테스트를 실행하지 않았다. 아래 반영표의 재현/검증은 Codex가 합성 임시 프로젝트에서 수행한다.

## 1차 응답 원문

# 독립 리뷰: unified context search / grounded handoff

## 판정: **revise**

아래 판정은 제공된 diff, 테스트, 문서를 읽고 정적으로 분석한 결과입니다. 명령은 실행하지 않았습니다.

- 블로커는 2건입니다. P1 1건과, `set -e` 사용 여부에 따라 P1이 되는 조건부 1건입니다.
- 출처는 동일 bytes의 SHA-256으로 일관됩니다. 예산은 Markdown·JSON 형식별로 실제 출력 길이를 셉니다.
- 다만 섹션 경계를 잘못 판단하는 경로가 있습니다. CLI 계약 위반 1건과 텍스트 출력의 출처 위조 경로도 남아 있습니다.

---

## 블로커

### P1-1 리스트 안 코드 펜스를 "미종결 fence"로 오인해 다른 필수 섹션을 흡수함

**위치:** `scan_markdown_headings`, `extract_handoff_sections` (ctx.sh)

**재현:**
```markdown
## Next Actions
- ```bash
  make test
  ```
## Verification
Reported pass.
```

**원인:**
- 리스트 항목 줄(`- ```bash`)은 리스트 정규식에 걸려 fence 판정 전에 `continue`됩니다.
- 그래서 닫는 줄(`  ````, 2칸 들여쓰기)이 `( {0,3})```` 규칙에 맞아 새 fence를 여는 줄로 처리됩니다.
- 이후 `## Verification`이 EOF까지 코드로 취급됩니다.
- `unclosed_fence` 이벤트는 kind가 `"warning"`이라 `ambiguous`를 세우지 않습니다.

**영향:**
- `next_actions`가 `present`로 나오는데, 블록 텍스트에 `## Verification\nReported pass.`가 다음 행동으로 들어갑니다.
- `recorded_verification`은 `missing`이 됩니다.
- 따르는 섹션이 필수가 아니면(`## Notes` 등) status가 `complete`인 채로 오염된 본문이 인용됩니다.
- 경고는 `ambiguous_markdown` 샘플 하나뿐이고, 어느 블록이 오염됐는지는 알려주지 않습니다.
- `- ```` 형태는 실제 계획 문서에서 흔한 구문입니다.

**최소 수정:** 아래 둘 중 하나를 적용합니다.
1. 활성 필수 블록 안에서 시작한 미종결 fence는 kind를 `"ambiguous"`로 바꿉니다. 미종결 comment와 같은 처리입니다.
2. 리스트/인용 마커 뒤의 fence 시작(`[-+*] {1,4}```` 등)도 fence 상태로 추적합니다.

1번만으로도 오귀속이 "블록 제외"로 바뀌어 보수적인 계약을 지킵니다.

**테스트:**
- 위 문서로 `next_actions.status == "ambiguous"`인지, 또는 2번 적용 시 `recorded_verification == "present"`인지 확인합니다.
- 두 경우 모두 어떤 블록 텍스트에도 `## Verification`이 없어야 합니다.
- 리스트 fence가 column 0의 ```` ``` ````로 닫히는 변형도 함께 넣습니다.

### P1-2 (조건부) `resolve_view_context` 실패가 호출자로 전파되지 않음

**위치:** `cmd_view`, `cmd_context_read`

**원인:**
- 기존 코드의 `CONTEXT_DIR=$(...) || return $?`는 `cmd_view`에서 직접 반환했습니다.
- 함수로 추출한 뒤에는 `|| return $?`가 `resolve_view_context`만 종료시킵니다.
- 두 호출부 모두 `resolve_view_context`(또는 `>&2`) 뒤에 `|| return`이 없습니다.

**영향:**
- ctx.sh 상단에 `set -e`가 없다면 문제가 됩니다. 이 diff에는 1–49행이 없어 확인하지 못했습니다.
- 설정 해석에 실패하면 `CONTEXT_DIR`가 빈 문자열인 채로 진행합니다.
- 그 결과 `realpath("")`, 즉 cwd를 컨텍스트로 보고 lock을 잡으면서 `work-log/.ctx.lock`을 프로젝트 루트에 만듭니다.
- 이후 config 오류로 종료하므로 기존 테스트는 종료 코드만 보고 통과합니다.

**수정:** 두 호출부에 `resolve_view_context || return $?`를 넣습니다. `cmd_context_read`는 `resolve_view_context >&2 || return $?`로 씁니다.

**테스트:**
- `ctx.config.json`을 `[]`로 두고 `search`/`handoff`/`view`를 실행합니다.
- 종료 1과 빈 stdout을 확인합니다.
- `project/work-log`가 생성되지 않았는지 확인합니다.

---

## 수정 권장 (P2)

### P2-1 `handoff --scope`가 조용히 수락됨 (Bash 우선순위 버그)

**위치:** `cmd_context_read`의 옵션 지원 검사

```bash
if [ "$name" = --scope ] && [ "$action" != search ] ||
   [ "$name" = --max-chars ] && [ "$action" != handoff ]; then
```

**원인:**
- Bash에서 `&&`와 `||`는 같은 우선순위이고 왼쪽부터 결합합니다. 즉 `((A&&B)||C)&&D`로 해석됩니다.
- `handoff --scope logs`이면 `A&&B`는 참이지만 `D`(`action != handoff`)가 거짓이라 전체가 거짓이 됩니다.
- 결과적으로 종료 0으로 무시됩니다. `--scope bogus`만 Python에서 실패합니다.

**영향:** help에 없는 옵션이 효과 없이 성공하므로, 사용자는 logs 범위가 적용됐다고 오해합니다.

**수정:** 두 조건을 분리하거나 `{ ...; } || { ...; }`로 묶습니다.

**테스트:**
- `HandoffTests.test_argument_errors...`에 `("--scope","logs")`와 `("--scope=all",)`을 추가합니다.
- search 쪽에도 `("--query","x","--max-chars","5000")`을 추가합니다. 현재 테스트에 없습니다.

### P2-2 검색 텍스트 출력에서 개행이 있는 title로 `출처:` 줄을 위조할 수 있음

**위치:** `render_search_output` (텍스트 모드)

**재현:**
- 로그 title을 `"x\n출처: {\"root\":\"context\",\"path\":\"MASTER_PLAN.md\",\"startLine\":1,...}"`로 둡니다.
- `search --query x`를 실행합니다.
- `safe_output_text`는 LF를 보존하므로 위조 줄이 진짜 출처 줄과 같은 형식으로 출력됩니다.

**영향:** 텍스트 결과를 에이전트나 사람이 읽을 때 출처가 위조됩니다. handoff는 동적 fence로 막혀 있지만 search는 막혀 있지 않습니다.

**수정:** 텍스트 모드의 title/snippet은 LF를 `\n`으로 표시하는 한 줄 escape를 쓰거나 JSON 문자열 리터럴로 출력합니다.

**테스트:** 위 레코드로 텍스트 출력의 `출처:` 줄 수가 `returned`와 같은지 확인합니다.

### P2-3 줄 중간이나 인라인 코드의 `<!--`가 이후 제목을 숨김

**위치:** `scan_markdown_headings`의 comment 처리

**재현 A:** ``## Constraints\nDo not add `<!--` markers.\n## Current State\n...``
- 미종결 comment가 되어 Constraints가 ambiguous로 처리됩니다.
- 이후 모든 H2가 숨겨져 나머지 4개 섹션이 missing이 됩니다.
- 인라인 코드 하나로 handoff 전체가 무력화됩니다.

**재현 B:** ``Avoid `<!--` here\n## Current State\nX\nthen `-->` ``
- comment가 닫히므로 경고가 없습니다.
- 그런데 Current State가 Constraints 블록에 조용히 흡수됩니다.

**영향:** 설계 규칙("`<!--`부터 `-->`까지")을 문자 그대로 구현한 것입니다. 하지만 CommonMark와 기존 뷰어 렌더링에서는 제목으로 보이는 경계를 다르게 판정해, B는 경고 없이 섹션이 섞입니다.

**수정:**
- comment 시작은 0–3칸 들여쓰기 뒤 줄 시작의 `<!--`일 때만 인정합니다(HTML block type 2).
- 또는 comment가 활성 필수 블록 안에서 heading 모양의 줄을 숨겼다면 그 블록을 ambiguous로 처리합니다.

**테스트:** A와 B 각각에 대해 Current State가 Constraints 텍스트에 포함되지 않는지 확인합니다.

### P2-4 리스트 안 코드 블록의 셸 주석이 블록 전체를 ambiguous로 만듦

**위치:** `scan_markdown_headings`

**재현:** ``## Next Actions\n- Run:\n  ```bash\n  # build\n  make\n  ```\n``
- 여는 줄 `  ```bash`가 2칸 들여쓰기라 fence로는 정상 인식됩니다.
- 하지만 `- ```bash` 형태(P1-1)이거나 fence 없이 들여쓴 `  # note`가 있으면 `indented_atx`로 판정됩니다.
- 그 결과 블록 전체가 제외됩니다.

**영향:** 보수적인 실패이므로 오귀속은 아닙니다. 다만 실제 계획 문서에서 incomplete 비율을 높입니다.

**수정:** P1-1의 컨테이너 인식과 함께, 리스트 항목 연속 영역 안의 1–3칸 `#`는 heading 후보에서 제외합니다.

**테스트:** 위 형태에서 `next_actions == "present"`인지 확인합니다.

### P2-5 닫는 `#` 제거 정규식의 이차 백트래킹 (시간 상한 위반, view에도 영향)

**위치:** `scan_markdown_headings`의 `re.sub(r"[ \t]+#+[ \t]*$", "", heading.group(3))`

**재현:**
- MASTER_PLAN에 `"## a" + " " * 200000 + "b"`처럼 긴 공백이 들어간 heading 한 줄을 둡니다.
- 공백 run 안의 각 시작 위치에서 `[ \t]+`가 후퇴하므로 O(n²)입니다. 수십 초에서 수 시간이 걸립니다.

**영향:**
- `handoff`가 멈춥니다.
- `run_view`도 항상 `build_handoff`를 호출하므로 기존 `view`까지 멈춥니다(회귀).
- lock은 이미 해제된 뒤라 다른 writer를 막지는 않습니다.

**수정:** 선형 문자열 처리로 바꿉니다. `t = title.rstrip(" \t")`로 끝 공백을 지우고, 끝의 연속 `#`가 공백/탭 뒤에 있을 때만 잘라낸 뒤 다시 rstrip합니다.

**테스트:** 위 입력으로 `view`/`handoff`가 짧은 timeout(예: 5초) 안에 끝나는지 확인합니다.

### P2-6 handoff의 Git 조회는 "읽기 전용 / 코드 미실행"이 아님 (기존 코드를 새 명령으로 노출)

**위치:** `collect_git_snapshot`

**동작:**
- `git status`는 stat이 바뀐 추적 파일에 대해 `.gitattributes` 및 설정의 clean filter를 실행합니다.
  - 예: 전역 `filter.lfs.clean/process`. git-lfs는 `.git/lfs/objects`에 기록합니다.
- 기존 `-c safe.directory=*`는 다른 사용자 소유 상위 저장소의 설정도 신뢰하게 만듭니다.
- 이번 diff는 fsmonitor만 막았습니다.

**영향:**
- "Git nonmutating reads"와 "read-only 명령"이라는 주장보다 실제 보장이 약합니다.
- 공유 상위 디렉터리 시나리오에서는 임의 명령이 실행될 수 있습니다.

**최소 수정:**
- 문서에 "status가 설정된 clean filter를 실행할 수 있음"을 명시합니다.
- 가능하면 새 handoff 경로에서는 `safe.directory=*`를 넘기지 않습니다(owner 검사 유지).

**테스트:** 저장소 설정에 `filter.x.clean`을 marker 생성 스크립트로 두고, `.gitattributes`와 stat이 바뀐 파일을 준비합니다. 이를 handoff 실행 시 실행 여부를 확인하는 문서화된 기대값 테스트로 남깁니다.

### P2-7 JS 정규식 lookbehind 때문에 구형 Safari에서 뷰어 전체가 파싱 실패 가능

**위치:** VIEW_JS `contextTerms`: `/(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u`

**영향:**
- lookbehind는 Safari 16.4 미만에서 정규식 리터럴 SyntaxError를 냅니다.
- 이는 스크립트 전체의 early error이므로 기존 개요·타임라인·문서 탭까지 동작하지 않습니다(회귀).
- 지원 브라우저 기준에 Safari 16.4 미만이 포함되면 P1입니다. 이번 검토에서는 브라우저로 검증하지 않았습니다.

**수정:** 단독 surrogate 검사는 `try { encodeURIComponent(query) } catch { 거부 }`로 대체합니다. 범용 지원되며 lookbehind가 필요 없습니다.

**테스트:**
- harness에서 lone surrogate 거부를 확인합니다.
- 내장 JS에 `(?<`가 없는지 정적으로 검사합니다.

---

## 경미 (P3)

| 위치 | 문제 / 재현 | 수정 / 테스트 |
|---|---|---|
| `extract_handoff_sections.finish` | 파일이 LF로 끝나면 마지막 섹션의 `endLine`이 `split("\n")`의 빈 꼬리 세그먼트를 가리킵니다. `## Constraints\nKeep.\n`이면 `endLine=3`인데 실제 줄은 2개입니다. 테스트는 `lines[s-1:e]` 슬라이싱이 초과 인덱스를 허용해 이를 가립니다. | 꼬리 `""`이면 `endLine=end-1`로 하거나 정의를 문서화합니다. `assert_source`에 `endLine <= LF 기준 줄 수` 검사를 추가합니다. |
| `fit_handoff` 사전검사 | `required`가 원문 길이(CR 포함)로 계산됩니다. Markdown은 CRLF를 LF로 줄이므로 실제로는 들어가는 출력을 거부할 수 있습니다. stderr의 "needs at least N"도 사실과 다릅니다. | Markdown은 `replace("\r\n","\n")` 기준 하한을 씁니다. CRLF 다량 MASTER_PLAN으로 N/N-1 테스트를 추가합니다. |
| `make_search_result` vs JS | Python `rstrip("\r")`은 CR을 모두 지우고, JS `/\r$/`와 설계("CR 하나")는 하나만 지웁니다. `"abc\r\r\n"`에서 snippet이 불일치합니다. | `content[:-1] if content.endswith("\r")`로 바꾸고 golden에 케이스를 추가합니다. |
| `scan_markdown_headings` | setext `--`/`==`(1–2자)와 빈 `##` 줄을 경계로 보지 않아 다음 본문이 앞 섹션에 붙습니다. | `-{1,}`/`={1,}`, `#{1,6}(?:[ \t]+.*)?$`로 바꾸고 해당 케이스를 테스트합니다. |
| `scan_markdown_headings` | `lstrip("\ufeff")`가 BOM 여러 개를 제거합니다. 설계는 맨 앞 하나입니다. | `line[1:] if line.startswith("\ufeff")`로 바꿉니다. |
| `_handoff_packet` | bidi 문자가 `terminal_controls`와 `bidi_controls`에 이중 집계되어 `warnings.total`이 부풀려집니다. title과 recordText 중복도 함께 집계됩니다. | 의도라면 문서화하고, 아니면 bidi를 terminal에서 제외합니다. |
| `make_search_result`, JS `contextResult` | 줄마다 검색어 수만큼 NFC를 반복합니다. 최대 16×이며 20 MiB 문서의 늦은 일치에서 비용이 큽니다. | 줄당 fold를 1회만 수행합니다. |
| JS `goContextResult` | 대기 중인 debounce 타이머를 지우지 않아, 이동 직후 이전 입력이 `setState`로 적용됩니다. | `restoreHash`와 같은 clear를 넣고 harness에서 타이머 콜백을 실제로 실행합니다. |
| JS `writeHash` | `ss=all`이 모든 탭의 hash에 항상 붙습니다(기본값 직렬화). 기존 hash 상태의 외형이 바뀝니다. | 기본값이면 생략합니다. |
| JS `renderContextSearch` | 탭을 처음 열면 빈 검색어가 오류 문구로 표시됩니다. | 빈 sq는 안내 상태로 분기합니다. |
| `search_units` / JS `includes` | Python 3.7–3.9의 fastsearch는 최악 O(n·m)입니다(20 MiB × 256). 자기 데이터라 위험도는 낮습니다. | 한계로 문서화합니다. |

---

## 테스트가 실패를 가릴 수 있는 지점

1. **`test_help_without_config_or_python`:** `PATH=/usr/bin:/bin`이지만 macOS에는 `/usr/bin/python3` shim이 있어 "Python 없이"를 증명하지 못합니다. python 실행 파일이 없는 임시 PATH(bash와 coreutils만 링크)로 바꿔야 합니다.
2. **`test_git_fsmonitor_is_not_executed`:** 커밋이 없는 새 저장소에서는 fix가 없어도 hook이 호출되지 않을 수 있습니다. 같은 설정에서 `git status`를 직접 실행해 marker가 생성되는지 양성 대조를 먼저 확인해야 합니다.
3. **`test_complete_sections...`:** 슬라이스가 초과 인덱스를 허용해 endLine 오류를 가립니다(위 P3).
4. **browser-harness:**
   - debounce 타이머 콜백을 한 번도 실행하지 않습니다(`timers.size`만 확인).
   - `files:[42]`나 `files`가 문자열인 경우의 parity 질의("42")가 없습니다. 기존 `filesOf`가 강제로 문자열화하면 CLI와 어긋납니다.
5. **Node 부재 시 parity 테스트 2개 skip:** Linux 증거에서 실제로 skip됐습니다. Node가 없는 CI에서는 JS 회귀가 보이지 않습니다.
6. **누락된 음성 테스트:**
   - `handoff --scope`
   - `search --max-chars`
   - `-h` 단독/혼합
   - 텍스트 모드 search의 개행 title
   - P1-1/P2-3 문서들

---

## 문서화된 의도적 한계 (결함으로 보지 않음)

- Unicode 11 이후 문자의 NFC parity는 보장하지 않습니다. ASCII만 case fold합니다.
- 예산 선정은 첫 초과에서 멈추는 접두 정책이며, 최대 수록량을 찾지 않습니다.
- 출력 I/O 실패 시 부분 stdout이 남을 수 있습니다.
- HTML은 handoff를 다시 만들지 않습니다.
- Git 관측 시점은 스냅샷과 다릅니다.
- 읽기 명령도 `.ctx.lock`을 생성합니다.
- 미종결 fence는 EOF까지 코드로 처리합니다(규칙 자체). P1-1은 닫힌 fence를 미종결로 오판하는 별개 문제입니다.

---

## 잔여 위험 / 미검증

- 실브라우저(file://), Python 3.7 실런타임, Windows, 사람 60초 평가는 미검증입니다. 이번 검토에서도 실행하지 않았습니다.
- 성능 수치는 단일 샘플입니다. DOM 대역 기준이며 마지막 두 수정 전 값입니다. 브라우저 paint와 peak heap은 측정하지 않았습니다.
- `_view_timestamp`의 `fromisoformat` 허용 범위는 Python 3.7과 3.11+에서 다릅니다. 따라서 handoff/search 순서와 `unknown_timestamp` 수가 런타임에 따라 달라질 수 있습니다(기존 코드).
- P2-6 Git filter 실행과 P2-7 구형 Safari 파싱은 환경에 따라 심각도가 달라집니다.

## 검토·반영 결정

| 지적 | 결정·근거 | 반영/검증 |
| --- | --- | --- |
| P1-1 목록 펜스 오귀속 | 채택. 1차의 EOF 검사만으로는 뒤에서 다시 닫히는 변형을 막지 못함 | 무시하는 컨테이너/들여쓰기 펜스 자체를 ambiguous로 격리. 두 닫힘 형태와 뒤에서 재종결하는 반례 실패→수정→통과 |
| P1-2 resolver 오류 전파 | 조건 불성립. 실제 line9의 set -e가 이미 호출을 중단 | []/source42/손상 JSON × 3명령에서 stdout0·종료1·lock 디렉터리 미생성 확인. 2차 Claude도 해소 인정 |
| P2-1 Bash 옵션 우선순위 | 채택 | 두 AND 조건을 명시적 그룹으로 묶음. handoff scope 값/등호와 search max-chars 거부 |
| P2-2 텍스트 검색 출처 위조 | 채택 | 제목/스니펫 고정 라벨과 한 줄 escape. LF/TAB/U+2028/2029, C0/C1/bidi/백슬래시를 구분. JSON 원값 보존. 출처 줄 수 단언 |
| P2-3 inline-code 주석 | 채택 | 같은 행의 정확한 backtick 길이를 array/bisect로 탐색. 이스케이프 여는 tick 홀짝/남은 길이 구분. 여러 줄 해석 위험은 ambiguous로 제외 |
| P2-4 컨테이너 안 셸 주석 | 부분 채택/기존 보수 정책 유지 | 정상 `- Run:` + 들여쓴 fenced block은 이미 present. 전체 CommonMark 컨테이너 파서는 추가하지 않고 모호한 목록 펜스는 격리. 펜스 밖 1~3칸 ATX는 기존 설계대로 ambiguous |
| P2-5 닫는 # 정규식 | 채택 | rstrip + 뒤쪽 # 선형 스캔. 20만 공백 제목의 handoff/view가 각 5초 안에 성공 |
| P2-6 Git 필터/소유권 | 최소 수정 채택, 한계 명시 | shared collector만 safe.directory=* 제거. 동일 크기 추적 파일 변경에서 clean filter 실행을 실제 재현. 신뢰하는 Git 설정의 외부 필터 부수효과를 차단한다고 주장하지 않음. 필터를 임의로 끄면 status가 왜곡될 수 있어 하지 않음 |
| P2-7 lookbehind | 채택 | encodeURIComponent로 단독 surrogate 거부. 정적 lookbehind 부재 및 256 emoji/잘못된 scalar 테스트. 실제 구형 Safari 검증은 아님 |
| P3-1 EOF 출처 | 채택 | 마지막 LF 뒤 split 빈 세그먼트 제외. 실제 LF 행 수 상한을 assert_source에 추가 |
| P3-2 CRLF 예산 하한 | 채택 | Markdown 사전 하한은 CRLF→LF 길이. 다량 CRLF의 실제 N/N-1 경계 검증 |
| P3-3 extra CR parity | 채택, 호스트도 독립 재현 | Python에서 CR 하나만 제거. `CR CR LF`를 공통 golden에 추가 |
| P3-4 short setext/빈 ATX | 채택 | 1~2자 밑줄과 빈 H1/H2도 경계 또는 모호 처리. 빈 H3만으로 본문을 채우지 않음 |
| P3-5 다중 BOM | 채택 | 맨 앞 BOM 하나만 제거 |
| P3-6 경고 중복 | 의미 유지/문서화 | total은 코드별 발생 합계. bidi의 두 코드·다른 선택 필드 중복은 의도된 집계. schema/의미를 바꾸지 않음 |
| P3-7 중복 fold | 채택 | 필드/행당 fold 1회 재사용. 기존 CLI/JS golden 유지 |
| P3-8 debounce | 채택 | 결과 이동 시 취소. 실제 예약 callback 실행과 취소를 harness에서 검증 |
| P3-9 ss=all | 미채택(외형 선호) | 기본값 직렬화의 의미·복원은 동일. 알려진 상태 전체 보존 정책 유지 |
| P3-10 빈 검색 탭 | 채택 | 최초 진입은 오류 대신 입력 안내/비활성 페이지 버튼 |
| P3-11 구 Python 문자열 탐색 | 한계 명시 | 새 검색 라이브러리/런타임 변경 없음. 20MiB 모든 패턴에 지연시간을 보장하지 않음 |
| 테스트 약점 | 채택 | Python 없는 PATH, fsmonitor 양성 대조+index 불변, 실제 source 행 상한, debounce callback, files42/string/혼합 help/실제 제어문자 추가 |
| 호스트 발견: 긴 제목 | 채택 | 160자 미리보기와 DOM 상한. 262144자 반복 제목 probe에서 기존 Node heap 약98MiB→수정 후 약5.90MiB, 표시159자. 원문 모델/JSON은 유지. 실브라우저 peak 측정 아님 |

2차 잔존 P1(재종결 목록 펜스)·P2(여러 줄 code/comment)는 각각 추가 실패 테스트로 재현했다. 컨테이너/들여쓰기 펜스를 처음 무시하는 시점에 ambiguous를 기록하고, 같은 문단 미해결 backtick과 주석의 조합도 격리한다. 기존 확실한 fence/comment 속 가짜 제목 테스트는 유지했다. 원문이 다른 필수 섹션으로 조용히 승격되면 안 된다는 기준을 적용했다.

2차의 실제 NEL/VT/FF/ESC/bidi/Unicode 줄 구분자 테스트를 추가했다. 빈 closing #/빈 subheading 판정을 수정했고, clean-filter 테스트는 향후 Git의 더 강한 보호를 실패로 보지 않도록 handoff의 필터 실행을 강제하지 않고 원문 불변을 확인한다. 실제 실행 가능성은 별도 재현과 [Git 필터 공식 문서](https://git-scm.com/docs/gitattributes#_filter)에 근거한다. 공유 조회 소유권 우회 제거는 [Git safe.directory 공식 문서](https://git-scm.com/docs/git-config#Documentation/git-config.txt-safedirectory)와 대조했다.

CLI 텍스트 검색의 라벨/escape 형식은 이번 코드 리뷰에서 변경됐다. JSON schemaVersion과 입력/로그 저장 스키마는 바꾸지 않았다. 실제 브라우저·Python3.7·Windows·사람 평가를 수행한 것으로 표시하지 않는다.


## 2차 응답 원문

실제 CLI 종료0 / is_error=false / effort medium / API 106.727초. 수정 diff와 재현 결과를 전달했으며 명령 실행은 없었다.

# 독립 재검토 (코드 정독과 손 추적만 수행, 실행 없음)

## 해소 확인
- **resolver 조건부 P1**: line 9에 `set -e`가 있고, 잘못된 config 3종 × 명령 3종 테스트로 해소된 것으로 봅니다.
- **해소된 P2**:
  - Bash `&&`/`||` 우선순위가 `{ ; }`로 묶였습니다.
  - plain 출력이 한 줄 escape와 `제목:`/`스니펫:` 접두로 바뀌어 출처 행 위조가 막혔습니다.
  - closing `#` 처리가 선형이 되었습니다.
  - lookbehind가 제거되었습니다.
  - `safe.directory=*`가 제거되었습니다.
  - Git filter는 문서화된 신뢰 경계로 수용합니다.
- **inline-code 탐색 자원**: `array`+`bisect` 구조이고 매 반복마다 index가 marker 끝 이후로 전진하므로, 줄 길이에 대해 대략 O(n log n)입니다. 주석이 줄 중간에서 닫혀도 bisect가 `start` 이후만 보므로 오귀속은 없습니다.
- 제목 미리보기 상한, debounce 취소, 빈 탭 안내 모두 diff상 타당합니다.

## P1 (잔존): 목록 펜스가 뒤 섹션을 조용히 흡수
EOF까지 미종결인 경우만 막혔고, **뒤에 닫는 펜스가 있으면 여전히 흡수**됩니다.

재현 (손 추적):
````
## Next Actions
- ```bash
  make test
  ```
## Verification
Reported pass.
```sh
echo hi
```
````
추적 결과:
1. 2행은 list 줄이라 skip되고, fence 상태가 열리지 않습니다.
2. 4행 `  ```` 이 새 펜스를 엽니다.
3. 5~8행은 펜스 내부로 처리되어 `## Verification`이 무시됩니다. ```` ```sh ```` 는 닫는 조건에 맞지 않습니다.
4. 9행 ```` ``` ```` 이 펜스를 닫습니다.
5. ambiguous 이벤트가 하나도 생기지 않아 `next_actions`는 `present`가 되고, 그 텍스트에 `## Verification`이 포함됩니다. `recorded_verification`은 `missing`이 됩니다.

추가된 테스트 두 케이스는 모두 EOF 미종결 경로라 이 경우를 잡지 못합니다.

최소 수정:
1. list/quote 줄을 skip할 때, marker 뒤가 `` `{3,}|~{3,} ``로 시작하면 `fence=(char, len, number)`로 설정합니다. 그러면 `  ```` 가 그 펜스를 닫습니다.
2. 안전망으로, fence나 comment 내부에서 ` {0,3}#{1,2}[ \t]+<alias>` 줄을 만나면 ambiguous 이벤트(`masked_heading`)를 냅니다. alias 일치일 때만 내므로 셸 주석 `## build` 같은 오탐은 생기지 않습니다.
3. 위 재현을 회귀 테스트로 추가합니다.

## P2
1. **줄을 넘는 code span이 가짜 주석을 엽니다.** 재현:
   ```
   ## Constraints
   Use `x
   <!--` literally.
   ## Current State
   S.
   See `-->`.
   ```
   - 3행에서 주석이 열리고 6행에서 닫히므로 Current State가 Constraints 블록으로 흡수되고 `complete` 판정이 납니다.
   - same-line 한정은 문서화되어 있지만, 결과가 경고 없는 흡수라 P2로 봅니다.
   - 수정: P1의 `masked_heading` 안전망으로 함께 해소됩니다.
2. **plain escape 범위 확인 필요.** `safe_output_text`가 U+0085(NEL), VT/FF, C1 제어문자까지 escape하는지 diff로는 확인할 수 없습니다.
   - 위조 테스트 제목의 `r'\u202e'`는 실제 bidi 문자가 아니라 리터럴 6자라 bidi 경로를 검증하지 못합니다.
   - 수정: 실제 `\u202e`, `\x85`, `\x0b`를 넣은 케이스를 추가합니다.

## P3
- `## ###`의 제목이 빈 값이 아니라 `###`이 됩니다. `end==0`일 때도 제거해야 합니다.
- `finish`의 has_body 판정에서 공백 없는 `###` 줄을 본문으로 계산합니다.
- clean-filter 테스트가 실행 발생을 `assertTrue`로 **요구**하므로, 향후 강화하거나 Git 동작이 바뀌면 테스트가 실패합니다. marker 존재 여부와 무관하게 source 불변만 단언하는 편이 낫습니다.
- plain 출력의 라벨 추가는 출력 형식 변경이므로 "계약 변경 없음" 기술과 맞는지 확인이 필요합니다.

## 미검증
실제 브라우저, Python 3.7, Windows, 전체 회귀 재실행은 주장된 대로 미검증 상태이며, 저도 실행하지 않았습니다.

**판정: revise** (P1 목록 펜스 재종결 흡수)

## 3차 응답 원문

실제 CLI 종료0 / is_error=false / effort medium / API 51.785초. 직전 지적의 수정 조건과 scanner를 한정 확인했다. 저장소 명령/테스트를 실행하지 않았다.

# 최종 재검토 (실행 없이 코드 정독만으로 판단)

## 남은 P1 1건: 줄 중간 `<!--`가 이후 실제 heading을 흡수함

**원인:** CommonMark에서 여러 줄에 걸치는 주석은 HTML block뿐입니다. HTML block은 줄 시작(들여쓰기 0~3칸)의 `<!--`로만 열립니다. 줄 중간의 `<!--`는 inline raw HTML이므로 문단 경계를 넘지 못합니다. ATX heading, fence, 빈 줄이 오면 문단이 끝나고, 그 `<!--`는 리터럴 텍스트가 됩니다. 현재 스캐너는 줄 중간 opener도 block 주석처럼 `comment` 상태로 이어갑니다.

**Repro:**
```
## Constraints
Note <!-- todo
## Verification
Fake report.
-->
```
- 실제 렌더링: `## Verification`은 진짜 heading입니다.
- 현재 결과: Verification은 `missing`, Constraints는 `present`입니다. Constraints block 텍스트에 `## Verification\nFake report.\n-->`가 그대로 들어갑니다.
- 이는 "불확실하면 incomplete, 조용한 오귀속 금지" 정책에 정면으로 위배됩니다.
- `\<!--`(백슬래시로 escape된 `<`)도 같은 방식으로 흡수됩니다.
- 기존 escape 테스트의 `\`` 와 `\\``` 케이스는 이 흡수를 기대값(`missing`)으로 고정하고 있습니다. 다만 Constraints가 오염되는지는 검사하지 않습니다.

**최소 수정:** opener를 찾은 직후 block-start 여부를 판정합니다.
```python
block_start = index == 0 and not line[:start].strip(" ") and start <= 3
```
`not block_start`이고 같은 줄에서 `-->`가 닫히지 않으면 `{"kind":"ambiguous","reason":"inline_comment_span"}` 이벤트를 추가합니다. 기존 숨김 동작은 그대로 유지해도 되며, 이 이벤트로 해당 block이 제외됩니다.

테스트 보강: 위 repro와 escape 4케이스에 `mandatory[0]['status'] == 'ambiguous'` 단언을 추가합니다. Verification의 `missing` 기대는 유지 가능합니다.

## 확인 결과 문제없음
- **list/quote 줄의 `<!--`를 스킵하는 동작:** 컨테이너 안의 HTML block은 lazy continuation이 없습니다. 따라서 다음 줄의 col-0 heading은 실제 heading이고, 현재 동작이 맞습니다.
- **줄 시작 `<!--` + pending inline risk → ambiguous:** HTML block이 문단을 interrupt하므로 사실상 주석이 맞습니다. 보수적인 과잉 처리이지만 허용 범위입니다.
- **리소스:** run 조회가 bisect이고, marker 진행이 단조 증가하며, heading 끝의 `#` 제거가 선형입니다. 백트래킹 위험은 보이지 않습니다.
- **escape 홀짝 처리와 exact-run 조회:** 로직상 정합합니다.

## 판정
위 P1을 수정하고 테스트를 보강하는 조건으로 수용합니다.

**명시할 한계:**
- 컨테이너/들여쓰기 fence는 즉시 ambiguous로 처리하며, 컨테이너 파서는 없습니다.
- 다중 행 inline 조합은 보수적으로 제외합니다.
- `has_body`의 주석 제거 정규식은 inline code 안의 `<!--`를 과하게 제거할 수 있습니다(P3).
- trusted repo filter가 실행될 수 있습니다(문서화 완료).

최종 full regression은 아직 미실행 상태로 기록해야 합니다.

## 4차 응답 원문

실제 CLI 종료0 / is_error=false / effort medium / API 33.491초. 직전 지적의 수정 조건과 scanner를 한정 확인했다. 저장소 명령/테스트를 실행하지 않았다.

**판정: revise**

요청하신 조건 자체는 충족됩니다. `Note <!--`, `\<!--`, ``Note <!--` `` 세 경우 모두 `block_start=False`이고 같은 줄에 `-->`가 없어 `inline_span` 이벤트가 생깁니다. 활성 Constraints 블록은 ambiguous가 되고 블록도 비워집니다. 백틱 fence info 가드도 정상입니다.

**남은 unsafe attribution (이 가드의 같은 줄 닫힘 판정)**

`find("-->", start + 4)`는 `<!-->`와 `<!--->`를 놓칩니다. CommonMark에서는 둘 다 그 줄에서 끝나는 주석/HTML 블록입니다. 문제가 되는 예는 다음과 같습니다.

```
## Constraints
Keep X.
<!-->
## Verification
Reported pass.
-->
```

`<!-->`가 줄 시작에 있으면 `block_start=True`라서 ambiguous 이벤트가 생기지 않습니다. 이 상태로 주석이 열리면 실제 Verification 헤딩이 가려집니다. 결과적으로 Constraints는 present가 되고, 그 source 범위가 `Reported pass.`까지 포함합니다. 결국 Verification 내용이 Constraints 출처로 귀속됩니다.

**수정 제안**

- 열기 직후 닫힘 검사와 `inline_span`에서 `line.find("-->", start + 2)`를 사용하세요.
- `finish`의 정규식도 `<!--(?:-?>|.*?(?:-->|$))`로 맞추세요.
- 위 입력을 테스트에 추가하세요.

## 마지막 경계 조건 반영

3차의 줄 중간 여러 줄 주석은 inline_comment_span으로 affected block을 제외한다. Note/escaped < 표식/주석 뒤 backtick 반례를 추가했다. 잘못된 backtick fence-info도 별도 ambiguous 이벤트로 격리한다.

4차의 `<!-->`/`<!--->` 반례도 재현했다. 닫힘 검색을 opener start+2부터 수행하고 겹치는 same-line 종료를 즉시 소비한다. 본문 존재 검사도 같은 짧은 주석 규칙을 사용해, 뒤의 정상 본문/Verification이 사라지지 않게 했다. [CommonMark HTML block 규칙](https://spec.commonmark.org/0.31.2/#html-blocks)의 시작/종료가 같은 행에 있을 때를 대조했다. 이 수정은 전체 CommonMark 지원을 뜻하지 않는다.

## 5차 조건 확인 원문

실제 CLI 종료0 / is_error=false / effort medium / API 15.251초. 4차에서 남긴 겹치는 주석 종료 조건만 확인했고 테스트를 실행하지 않았다.

**검증 결과: 지적한 조건은 해결됨**

- `find("-->", start + 2)`에서 start+2에 매칭되면 `<!-->`, start+3이면 `<!--->`가 됩니다. 정확히 HTML의 abrupt-closing 두 형태만 추가로 잡고, 일반 `<!-- … -->`의 동작은 바뀌지 않습니다.
- `inline_span`과 소비 경로가 같은 `same_line_end`를 공유합니다. 그래서 겹친 close가 즉시 소비되고 multi-line 상태로 들어가지 않습니다. 공백 폭(`same_line_end + 3 - start`)도 맞습니다.
- finish 정규식의 첫 대안 `-?>`가 두 marker를 먼저 처리하므로 visible 경로와 일치합니다.
- 테스트 세 가지가 해당 조건을 직접 겨냥합니다. 실행 여부는 확인하지 않았습니다.

**accept**

## 최종 검토 상태

1차 전체 diff/테스트/설계 리뷰와 후속 4회 수정 조건 검토를 수행했다. 마지막 응답은 해당 주석 종료 조건에 대해 accept였다. 이를 전체 저장소 무결성 보증이나 실브라우저 검증으로 확대하지 않는다. 식별한 오귀속·출처·CLI·예산·성능 결함은 재현 테스트로 수정했고, 새로운 전체 CommonMark 파서·Git 필터 차단·런타임 교체는 추가하지 않았다.

완전한 CommonMark 지원을 제공하지 않는다. 컨테이너/들여쓰기 펜스·불확실한 여러 줄 인라인/주석·잘못된 펜스 info는 해당 필수 블록을 ambiguous로 제외한다. JSON 원문과 source hash는 보존하고, missing/ambiguous를 완료나 허가로 해석하지 않는다. Git 필터와 미실시 플랫폼/사람 평가의 제한은 유지한다.

최종 실행 증거는 아래에 기록한다.

## 최종 실행 검증 (2026-11-01)

최종 ctx.sh SHA-256: `60b389235fb2d5ee2c6e84d837683968be311d29c8946d69c77f5b0262b2bdb2`. 플랫폼 검증 복사본과 동일하다.

| 검증 | 실제 결과 |
| --- | --- |
| macOS Bash3.2 / Python3.11.8 전체 | `python3 -B -m unittest discover -s tests -v`: **331개 / 117.194초 / OK**, skip 없음 |
| macOS Python3.9.6 | reader/search32 + handoff36 + HTML5 = **73개 통과** |
| macOS Python3.13.3 | 같은 **73개 통과** |
| Linux arm64 Python3.11.15 / Bash5.2 / Git2.39 | 대상143개 중 **138개 통과, Node 부재로5개 skip** |
| Linux Python3.11.16 / Node20.20.2 | Linux에서 CLI/HTML 생성부터 실제 내장 JS의 **5개 통과** |
| 문법/정적 | Bash 문법, Python3.7 AST(내장5블록+신규 Python), Node harness 문법, diff 공백 검사 |

리뷰 전 306개에서 **25개 회귀 테스트를 추가**했다. 실패를 관찰한 뒤 수정한 사례와 기존 동작 확인을 구분했다. 전체/대상 테스트는 최종 코드로 실행했다. Linux의 두 이미지 모두 기존 로컬 이미지를 사용했고 network none / read-only root+source / 임시 tmpfs로 실행했다. 새 이미지·패키지 다운로드나 CI 변경은 없다.

실제 브라우저의 file:// 화면·키보드·클립보드 권한/paint, Python3.7 실런타임, Windows, 사람60초 평가는 계속 미실시다. 초기 자동 file:// 거부를 우회하지 않았다. Node 대역이나 Claude의 정적 accept를 이 검증으로 표현하지 않는다. Linux에서 skip된 기존 브라우저 harness 하나는 macOS 전체 테스트의 Node에서 통과했으며 Linux 실브라우저 검증은 아니다.

기존 수정 계획의 SHA-256 `8ecd05c687658bfe659da7fa184addb5875be7de32850c6dd5270a75de7319fd` 동일. contracts 미수정/미이동/미삭제/미스테이징, HEAD `6c0eb861c31c64f593cc66c25ad37a88a6b289bf` 유지, staged diff 없음. 원본 프로젝트의 init/commit/push/PR은 하지 않았다.
