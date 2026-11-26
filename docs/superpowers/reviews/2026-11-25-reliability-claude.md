# 신뢰성 계획 Claude 재검토와 반영 판단

2026-11-25, 계획 `8d2141b`, 기준 구현 `7309923`. Claude Code CLI의 파일 수정·실행 도구를 끄고 원본 계획·설계·번호가 있는 코드/테스트 발췌를 전달했다. Claude 판정은 `revise`다. Cross Review 요청 ID는 `1a68f338-19fa-4d8f-a51b-cedbfb772c6c`다.

## 반영 판단

- pre-commit wrapper 바이트 보존, post-commit 추가, 고정 HEAD와 원본 훅의 종료값·입력 보존을 채택한다.
- 공통 커밋 builder와 활성·보관 전체 ID 중복 검사를 채택한다. 빈 커밋과 컨텍스트 전용 커밋도 기록하고 files에서 컨텍스트 경로를 제외한다.
- strict와 3초 잠금 변경은 첫 구현에서 보류한다. ctx의 모든 기록·snapshot 처리를 post-commit으로 옮긴다.
- CLI 언어 현행 유지, 명시 help/stdout과 오류/stderr, timeline 원값 보존과 안전한 타입 표시를 채택한다.
- F6의 정적 검사 불가능 표현은 도구 적용이 어렵다는 뜻으로 좁힌다. 기존 compile/exec 테스트와 P0의 내장 코드 추출 lint 계획을 근거로 한다.
- F8·R5·R9는 Claude가 발췌 부재로 보류했다. Codex가 기준 코드의 sync·export·generate와 `git tag --merged 7309923`을 확인한 정정을 유지한다.
- `--only`의 post-commit 환경은 macOS/Git 2.42에서 직접 재현했다. `GIT_INDEX_FILE=.git/index`였고, 제외된 다른 파일의 staged blob과 status를 확인했다.
- 현재 선행 변경을 포함한 수정 전 테스트는 351개 통과했다. Claude는 테스트를 실행하지 않았다.

## Claude 원문

# ctx-kit 결정 1·2에 대한 Codex 검토 의견 재검토

요청대로 파일 수정, 도구·스킬 호출, 실행은 하지 않았습니다. 근거는 요청에 포함된 발췌뿐입니다. `ctx.sh:N`, `tests/...:N`은 모두 기준 커밋 `7309923` 발췌의 행 번호입니다. 원본 계획은 행 번호 없이 전달되어 절과 항목 이름으로 가리킵니다.

---

## 1. 판정: **revise**

방향(C 변형, 언어 현행 유지)은 받아들입니다. 다만 아래 네 가지를 계획에 넣지 않으면 C를 구현할 때 기존 설치가 깨지거나 완료 기준끼리 충돌합니다.

1. **pre-commit wrapper 바이트를 한 글자도 바꾸면 안 됩니다. 기존 설치 전환이 실패합니다.** (사실, 코드 판독)
   - 설치기는 기존 훅이 ctx 관리 대상인지를 `content in (wrapper(True), wrapper(False))`로 바이트를 정확히 비교해 판정합니다(`ctx.sh:2124`).
   - 새 ctx.sh가 wrapper 바이트를 바꾸면 7309923 설치본은 관리 대상이 아니게 됩니다. 그 결과 원본 훅이 있던 설치는 `Hook backup already exists`(`ctx.sh:2130-2131`)로, 원본 훅이 없던 설치는 `Modified or unrecognized ctx hook`(`ctx.sh:2133-2136`)으로 **install과 uninstall이 모두 거부**됩니다.
   - 따라서 pre-commit wrapper는 바이트를 그대로 두고, 동작 변경은 wrapper가 호출하는 `_hook_run_pre_commit` 쪽에서 해야 합니다. 이렇게 하면 기존 설치 전환이 "post-commit 추가"만으로 끝납니다.
2. **post-commit 행과 backfill 행은 어느 writer가 먼저 쓰든 같은 내용이어야 합니다.** fullCommit 중복 제거 때문에 먼저 쓴 쪽만 남기 때문입니다.
   - 현재 pre-commit은 컨텍스트 경로를 제외합니다(`ctx.sh:2380-2382`). 컨텍스트 파일만 바뀐 커밋은 기록하지 않으며 이를 테스트로 고정했습니다(`tests/test_git_metadata.py:335-339`).
   - backfill은 컨텍스트 경로를 제외하지 않고 빈 커밋도 기록합니다(`ctx.sh:1725-1735`, `tests/test_git_metadata.py:297-303`).
   - Codex의 완료 기준 "성공 커밋당 자동 로그 1건"은 기존 테스트 339행과 정면으로 충돌합니다. 공통 builder 하나와 컨텍스트 경로 정책을 먼저 정해야 합니다.
3. **`git_sync.strict`는 첫 구현에서 빼는 것을 권합니다.** C에서는 커밋을 막는 경로에 ctx 작업이 남지 않습니다. strict를 살리려면 사전 검사를 새로 넣어야 하는데, 그 검사는 결국 F2(타임라인을 읽다 커밋 차단)를 다시 만듭니다.
4. **F2는 "과장"을 고치는 데서 멈추면 안 되고, 실제 전체 차단 경로로 다시 써야 합니다.** 손상된 타임라인은 staged 변경이 있을 때만 커밋을 막습니다(`ctx.sh:2385`). 반면 아래 경로는 staged 내용과 무관하게 모든 커밋을 막을 수 있습니다(코드 판독, 실행 미확인).
   - 설정 JSON 읽기 실패(`ctx.sh:2353-2358`)
   - 컨텍스트 `.git`이 있을 때마다 실행되는 `context_git_commit` → `context_python` 쓰기 모드 → 잠금 30초 대기와 `recover_archive` 실패(`ctx.sh:328-330`, `ctx.sh:2416-2421`)

---

## 2. 두 권장안의 오류·누락

### 권장안 1 (C 변형)

**Codex 근거 중 발췌로 확인한 사실**

- `append_jsonl`은 기존 행 전체를 다시 직렬화합니다(`ctx.sh:200-204`). 빈 줄 제거, 공백 정규화, `ensure_ascii=False` 재표현이 일어납니다.
- backfill은 `createdAt`으로 정렬한 뒤 전체 파일을 다시 씁니다(`ctx.sh:1767-1782`).
- 따라서 "byte-append-only가 아니다"는 맞습니다. snapshotId나 hash가 바뀐다는 점은 A를 반대할 근거가 되지 않는다는 Codex의 자기 정정도 맞습니다.
- writer는 잠금을 잡은 직후 `recover_archive`를 먼저 실행하고, 그다음 본문을 실행합니다(`ctx.sh:328-330`).
- 보관 digest는 `pending` 행의 커밋 태그를 생략합니다(`ctx.sh:2014`). 보관된 pending을 고치려면 digest까지 다시 만들어야 한다는 지적도 맞습니다.

| 구분 | 항목 | 근거 |
| --- | --- | --- |
| **반드시 반영** | 위 1번. pre-commit wrapper 바이트 불변. 7309923의 두 wrapper 바이트를 golden 테스트로 고정 | `ctx.sh:2061-2084`, `2124-2136` |
| **반드시 반영** | 위 2번. post-commit과 backfill이 커밋→행 변환 builder를 하나로 공유. 같은 커밋이면 title/summary/files/createdAt이 writer와 무관하게 같아야 함. 다를 수 있는 값은 branch와 dirty뿐이며 이를 명시 | `ctx.sh:1722-1760`, `2393-2408` |
| **반드시 반영** | 컨텍스트 경로 정책 결정. 권장안: builder가 컨텍스트 경로를 files에서 제외하고, 성공 커밋은 files가 비어도 기록. 그러지 않으면 기록되지 않은 컨텍스트 전용 커밋을 backfill이 나중에 컨텍스트 경로 이름과 함께 추가함. `test_git_metadata.py:338-339`의 기대값 변경 필요 | `ctx.sh:2380-2385`, `tests/test_git_metadata.py:316-339` |
| **반드시 반영** | 중복 규칙 구체화. 새 origin 필드 없이 해결 가능: "기계 writer(post-commit, backfill)는 활성·보관 어느 행이든 같은 fullCommit이 있으면 추가하지 않는다. 수동 `log`는 검사하지 않는다." 현재 backfill 규칙(`ctx.sh:1677-1688`)과 같은 규칙. 보관 파일을 읽지 못하면 중복 여부를 알 수 없으므로 쓰지 않고 경고 | `ctx.sh:1674-1707` |
| **반드시 반영** | post-commit wrapper는 원본 post-commit보다 **먼저** `HEAD`를 고정해야 함. 원본 훅이 amend 등으로 HEAD를 바꾸면 다른 커밋을 기록하게 됨. 원본 실패와 무관하게 ctx를 실행하고 종료 코드는 원본 값을 전달(pre-commit과 다른 의미이므로 명시) | 추론. 원본 체이닝 형식 `ctx.sh:2062-2075` |
| **반드시 반영** | 기존 설치 전환 시 새 `_hook_run_pre_commit`의 동작: pending을 쓰지 않음. post-commit이 미설치면 stderr 한 줄 안내(`hook install`, 누락분은 `backfill`)를 내고 **항상 exit 0**. `require_config`/`require_python` 실패도 exit 0으로 흡수 | `ctx.sh:2345-2424`. 현재는 이 함수의 실패가 곧 커밋 실패 |
| **반드시 반영** | 로컬 컨텍스트 snapshot(`context_git_commit`)을 pre-commit에서 post-commit의 기록 **뒤**로 이동. `test_hook_index.py:81-82`의 "저장된 컨텍스트 로그 = 현재 행" 단언을 유지하기 위함 | `ctx.sh:2416-2421`, `tests/test_hook_index.py:64-84` |
| **고려** | dirty의 의미: post-commit 시점에 `log`와 같은 status 인자(`ctx.sh:1475-1483`)로 관측하고 "커밋 직후 커밋에 포함되지 않은 변경 존재"로 정의. backfill의 `False`는 관측값이 아님을 문서화. `--only`/`add -p`에서 post-commit 시점의 `GIT_INDEX_FILE`이 실제 인덱스를 가리키는지는 **미검증**이라 구현 전에 확인 필요. `GIT_OPTIONAL_LOCKS=0` 권장 | 추론 |
| **고려** | createdAt 기준: backfill은 author date(`%ad`, `ctx.sh:1713`). amend/rebase 커밋은 과거 시각으로 정렬됨. 첫 구현은 backfill과 같게 두고 한계를 문서화 | `ctx.sh:1713`, `1739-1745` |
| **고려** | 훅 경로의 잠금 대기: post-commit은 커밋을 막지 못하지만 30초 대기는 커밋이 멈춘 것처럼 보임. 훅 경로만 짧은 deadline을 환경변수로 받는 방안 | `ctx.sh:307` |
| **고려** | `core.hooksPath`와 linked worktree: 설치 경로는 `$PROJECT_ROOT/.git/hooks` 고정(`ctx.sh:2044`). hooksPath가 있으면 두 훅 모두 실행되지 않고, `.git`이 파일이면 설치가 실패함. 첫 구현은 install/status에서 경고만 내고 설치 위치는 바꾸지 않음 | 추론 |
| **고려** | 컨텍스트 Git 재귀: ctx 블록은 cwd의 `ctx.sh`를 찾으므로(`ctx.sh:2055-2059`) 컨텍스트 repo 커밋에서는 보통 아무 일도 하지 않음. 전역 hooksPath나 템플릿 환경은 테스트 1건으로 확인 | 추론 |
| **보류** | rebase/cherry-pick/revert(sequencer)에서 post-commit이 호출되는지, 몇 번 호출되는지. 호출된다면 커밋마다 전체 보관 파일을 읽는 비용 측정. Git 버전별 동작은 **미검증** | 추론 |
| **보류** | 자동 merge 보완용 post-merge 훅. 첫 구현은 backfill로 보완(Codex 관측과 일치). 기본 `--limit 30`임을 문서에 명시 | `ctx.sh:1635`, `1709-1711` |
| **보류** | 기존 pending 행을 search/handoff에서 별도 표시. 첫 구현은 "커밋 시도 관측, 성공 여부 미확인"이라는 의미를 문서화하는 데서 그침 | — |

**Codex 근거 중 고칠 표현**

- "A를 복구보다 앞에 두면"은 가정형입니다. 실제 writer 구조에서 본문은 항상 복구 뒤에 실행됩니다(`ctx.sh:329-330`).
- A를 반대하는 결정적 근거는 세 가지면 충분합니다.
  - 같은 tree를 가진 여러 커밋에 오연결될 수 있음
  - 시도 당시의 원문이 사라짐
  - 보관 파일·digest에 걸친 여러 파일 트랜잭션이 필요함

### 권장안 2 (언어 현행 유지)

| 구분 | 항목 | 근거 |
| --- | --- | --- |
| **반드시 반영** | 현행 출력 언어는 이미 혼재 상태임을 사실로 적고, "통일하지 않음"을 결정으로 기록. 기존 명령은 영어(`ctx.sh:1437`, `1540`, `1570`, `1764`, `2144-2171`), search/handoff 사람용 출력은 한국어(`ctx.sh:3144-3150`, `3429-3453`) | 발췌 확인 |
| **반드시 반영** | handoff JSON에도 고정 한국어 값이 있음: `notice`(`ctx.sh:3370`), warnings 샘플(`3356`, `3358`, `3408-3411`). "JSON 키는 영어라 영향 없음"은 handoff에 대해 틀림. search JSON은 발췌 범위(`3136-3143`)에서 고정 한국어 값을 확인하지 못함(`make_search_result`는 미열람) | 발췌 확인 |
| **반드시 반영** | 스트림 정정 대상을 구체화: 사용법 오류가 stdout으로 나가는 `ctx.sh:1449`(log, exit 1), `1560`(timeline), `1645`(backfill), `2186`(hook). 명시적 `--help`는 stdout/exit 0을 유지(`1436-1438`, `1556-1558`, `1641-1643`) | 발췌 확인 |
| **반드시 반영** | timeline은 `ctx_python`과 자체 파서를 씀(`ctx.sh:1574`, `1584-1589`). `read_jsonl`은 `context_python` 전문(prelude)에만 있으므로 `context_python --read-only`(`ctx.sh:325-326`)로 바꿔야 함. 그래야 `read_jsonl`과 `Error:` 형식 처리(`331-333`)를 함께 얻고 잠금·복구를 하지 않음. 비문자열 처리 지점은 `1594`, `1614`, `1618`, `1622` | 발췌 확인 |
| **고려** | 예산 영향의 방향: JSON은 `ensure_ascii=True`라 한글 1자가 6자(`\uXXXX`)가 됨. 영어로 번역하면 JSON 예산이 오히려 여유로워짐. Markdown은 문구 길이에 비례. 현행 유지이므로 첫 구현에는 영향 없음 | `ctx.sh:3427-3428`, 설계 §5 |
| **보류** | `--lang ko\|en`. 도입하더라도 JSON 키, 경고 code, `grantsAuthority`, 입력 H2 한영 별칭(`ctx.sh:2950-2956`)은 언어와 무관하게 고정 | — |
| **보류** | `need_value`가 다음 인자가 `--`로 시작하면 값 누락으로 볼지 여부. search 설계 §9는 그렇게 정했음. 기존 명령에는 인자 개수만 검사해 동작 변경을 최소화하는 쪽을 권장 | 설계 §9 |

### 추가 사실 정정에 대한 판단

| 항목 | 판단 | 근거 |
| --- | --- | --- |
| F2 과장 | **동의하되 보강**. 위 1-4번의 전체 차단 경로를 함께 적어야 함 | `ctx.sh:2353`, `2385`, `2416-2421`, `328-330` |
| F3 | 동의. 대상 옵션을 전부 나열: log `--summary/--title/--commit/--files/--type`, timeline `--limit/--commit`, backfill `--limit/--type` | `ctx.sh:1432-1435`, `1553-1554`, `1638-1640` |
| F6 | 동의. 내장 Python을 exec하는 helper가 있음(`tests/test_handoff.py:202`의 `self.helpers()`). "린트·타입 검사 불가"만 남겨야 함 | 발췌 확인 |
| F8, R5, R9 | 판단 보류. sync, export/generate 코드, 태그 목록이 발췌에 없음 | 미검증 |

---

## 3. 원본 계획 수정안

### 문장 교체

- **§1 F1**
  > pre-commit 자동 로그는 커밋 *시도*의 관측이다. 이후 훅(prepare-commit-msg/commit-msg) 실패나 중단에도 남고, 성공 커밋과 연결되지 않아 `pending`으로 계속 남으며, `backfill`은 같은 커밋을 별도 행으로 추가한다. 근거: 재현, `_hook_run_pre_commit`, backfill 중복 판정은 `pending` 행을 어떤 커밋에도 대응시키지 않음.
- **§1 F2**
  > auto_log 사용 중 컨텍스트 밖 staged 변경이 있으면 `timeline.jsonl` 손상 줄 하나로 커밋이 실패한다(빈 커밋은 통과, 재현). git_sync가 켜져 있으면 설정 읽기 실패, 잠금 timeout, 복구할 수 없는 archive 저널, 컨텍스트 Git 커밋 실패가 staged 내용과 무관하게 커밋을 막을 수 있다(코드 판독).
- **§1 F4 끝 문장**
  > 사용법·오류 스트림은 명령마다 다르다. 출력 언어는 기존 명령이 영어, search/handoff 사람용 출력과 handoff JSON의 notice·warnings 샘플이 한국어다.
- **§1 F6**: "직접 단위 테스트"를 삭제하고 "(일부 함수는 내장 코드를 exec하는 테스트 helper로 단위 검사 중)"을 추가합니다.
- **§3 R1 해결**
  > ctx 기록은 post-commit으로 옮겨 커밋 차단 경로에서 뺀다. 원본 pre-commit의 실패 전파는 유지한다.
- **§3 R2 해결**
  > 성공 커밋은 post-commit에서 확정된 커밋 객체로 1건 기록하고, backfill과는 fullCommit 기준으로 중복을 막는다. 기존 pending은 시도 관측으로 보존한다.
- **P1 마지막 항목**
  > 출력 언어는 현행을 유지한다(기존 명령 영어, search/handoff 한국어). 명시적 help는 stdout/exit 0, 사용법 오류와 실행 오류는 stderr/exit 1로 통일한다. 영어 인수인계 수요가 확인되면 CLI와 HTML이 공유하는 `--lang`을 별도 결정한다. 이때 handoff JSON의 notice·warnings 샘플과 형식별 예산 변화를 함께 다룬다.
  - "영향: search·handoff 문구 변경" 문단은 삭제합니다.
- **P1 완료 기준**에 추가
  > timeline은 손상되거나 객체가 아닌 줄에서 traceback 없이 행 번호를 포함한 stderr 오류와 exit 1을 낸다. 비문자열 필드는 텍스트 표시에서 JSON 표기로 보여 주고, `--commit` 필터는 문자열 필드만 비교하며, `--json`은 원래 값을 보존한다.
- **P2 "커밋을 막지 않는다"**: strict와 3초 항목을 삭제하고 아래로 교체합니다.
  > ctx 기록과 컨텍스트 snapshot은 post-commit에서만 실행한다. 실패하면 stderr에 원인 한 줄과 `bash ctx.sh backfill` 복구 안내를 낸다. 기존 pre-commit wrapper는 바이트를 바꾸지 않으며, `_hook_run_pre_commit`은 기록하지 않고 항상 exit 0이다.
- **P2 "pending 연결" 절 전체, 설계 근거, 사전 검증, 결정 필요**: 아래 "C 실행 순서"와 "기존 설치 전환" 요약으로 교체합니다. `write-tree` 관련 문장은 모두 삭제합니다.
- **P2 완료 기준**
  > 성공 커밋당 자동 로그 1건(fullCommit=커밋 ID), 실패하거나 중단된 커밋은 0건, post-commit 재실행과 backfill 순서에 상관없이 중복 0건, 손상된 타임라인에서도 커밋 성공 + 경고, 7309923 설치본이 `hook install` 한 번으로 전환됨.
- **§6 훅 행**
  > 실제 `git commit`으로 성공 1건·실패 0건·중복 0건, 원본 pre-commit 실패 전파, 원본 post-commit의 실행·인자·stdin·interpreter 보존, 7309923 wrapper 전환을 확인한다.
- **§7**: "pending 연결이 잘못된 커밋과 맞는다" 행을 아래로 교체합니다.
  > post-commit이 설치되지 않았거나 실패하면 기록이 빠진다 → 안내를 출력하고, backfill로 누락 커밋을 복구하고, doctor로 상태를 확인한다.
  - "엄격 모드를 남긴다"는 삭제합니다.
- **§8 결정 1**
  > post-commit 훅을 추가하고 기존 설치를 전환하는 것을 승인할지. 함께 정할 것: 컨텍스트 경로 제외와 빈 커밋 기록, dirty의 의미, strict 보류.
- **§8 결정 2**
  > 출력 언어 현행 유지와 스트림 통일을 승인할지. `--lang`은 보류.

### C의 실행 순서 (제안)

**post-commit wrapper** (`#!/bin/sh`, 원본 백업은 `post-commit.ctx-kit-original`)

1. `ctx_head=$(git rev-parse --verify HEAD)`로 HEAD를 고정합니다. 실패하면 이 값을 비워 둡니다.
2. 원본 백업이 있어야 하는데 없으면 pre-commit과 같은 오류를 내고 exit 1로 끝납니다. 커밋 결과에는 영향이 없습니다.
3. 원본 훅이 실행 가능하면 `"$ctx_original_hook" "$@"`로 실행하고(stdin 상속) 종료 상태를 저장합니다. **실패해도 다음 단계로 진행합니다.**
4. `bash ctx.sh _hook_run_post_commit "$ctx_head"`를 실행합니다. 종료 상태는 무시합니다.
5. 3단계에서 저장한 원본 종료 상태로 끝냅니다.

**`_hook_run_post_commit <id>`** (모든 실패는 경고 + backfill 안내 후 exit 0)

1. 설정을 읽습니다. `enabled`가 아니면 종료합니다.
2. `git cat-file -e <id>^{commit}`으로 커밋 객체를 확인합니다.
3. 잠금 밖에서 고정 객체를 조회합니다: `git log -1 -z <backfill과 같은 format> --name-only <id>`. 공통 builder로 행을 만들고, 컨텍스트 경로를 제외하고, branch와 status(dirty)를 관측합니다.
4. `context_python`(잠금 → `recover_archive`) 안에서 활성 파일과 보관 파일을 모두 읽습니다. 같은 fullCommit이 있으면 건너뛰고, 없으면 `append_jsonl`로 추가합니다. 읽기나 복구에 실패하면 쓰지 않고 경고합니다.
5. 컨텍스트 `.git`이 있으면 `context_git_commit`으로 snapshot을 만듭니다. 이 snapshot에는 방금 추가한 행이 포함됩니다.

### 기존 훅 이전 방법

1. `_manage_pre_commit_hook`을 훅 이름을 인자로 받도록 일반화합니다. pre-commit의 wrapper 바이트, 백업 이름, 메시지는 그대로 둡니다.
2. `hook install`
   - 두 훅 모두 `check-install`을 먼저 통과해야 합니다. 이 단계에서는 아무것도 쓰지 않습니다.
   - 그다음 post-commit을 설치하고 pre-commit을 설치합니다. pre-commit이 이미 관리 대상이면 "already installed"만 출력합니다.
   - post-commit만 설치된 뒤 중단되더라도, pre-commit이 새 `_hook_run_pre_commit`을 호출해 아무 일도 하지 않으므로 안전합니다.
3. `hook uninstall`: 두 훅을 모두 검사한 뒤 각자의 원본을 복원하고, 마지막에 `enabled=false`로 바꿉니다. 검사에서 실패하면 설정을 바꾸지 않는 기존 계약(`tests/test_hook_chain.py:247-281`)을 유지합니다.
4. `init`의 기본 훅 설치와 `hook status`도 두 훅을 함께 다룹니다. status는 `core.hooksPath`가 있거나 `.git`이 디렉터리가 아니면 경고합니다.
5. 업그레이드 안내: ctx.sh 교체 → `bash ctx.sh hook install` → `bash ctx.sh backfill`(전환 전에 빠진 커밋 복구).

---

## 4. 첫 구현의 최소 범위와 회귀 검증

**PR-A (P1 최소)**
- 값 누락 검사
- 사용법 오류를 stderr로 이동(`1449`, `1560`, `1645`, `2186`)
- timeline을 `context_python --read-only`와 `read_jsonl`로 전환하고 비문자열 표시 규칙 적용
- 언어 변경 없음

**PR-B (P2-C 최소)**
- post-commit wrapper와 설치기 일반화
- 공통 builder(backfill도 사용, 컨텍스트 경로 제외)
- 중복 검사
- `_hook_run_pre_commit`을 항상 exit 0으로 바꾸고 안내만 출력
- snapshot 이동

**제외**: strict, 3초 잠금, doctor, `--lang`, tree, 기존 pending 이관, post-merge, hooksPath 설치 지원.

**회귀 검증 (실제 실패를 잡는 순서)**

1. 7309923 wrapper 두 종류(원본 있음/없음)가 golden 바이트로 관리 대상으로 인식되는지. install 후 pre-commit 바이트 불변, post-commit 추가, uninstall 시 원본 바이트와 mode 복원.
2. 손상된 `timeline.jsonl`에서 staged 커밋 성공, stderr 경고, 파일 바이트 불변. 복구 후 backfill로 1건만 추가.
3. commit-msg exit 1 → 새 행 0건. 원본 pre-commit 실패 → 0건(기존 `test_hook_chain.py:85-99`).
4. 같은 tree를 가진 commit/revert/allow-empty → 서로 다른 fullCommit 3건.
5. post-commit → backfill 순서와 backfill → `_hook_run_post_commit HEAD` 순서에서 중복 0건. archive 후 재실행 시 중복 0건.
6. `--amend` → 2건, `--no-verify` → 1건, `--only`에서 다른 staged blob 보존(기존 `test_hook_index.py:94-107`), `merge --no-commit` 후 commit → 1건, 자동 merge → 0건이고 backfill로 1건.
7. 원본 post-commit: 실행·인자·stdin·interpreter 보존. 실패해도 ctx 행 기록. 원본이 HEAD를 바꿔도 고정한 ID를 기록.
8. post-commit만 미설치(새 ctx.sh + 기존 pre-commit): 커밋 성공, pending 0건, 안내 1줄.
9. 특수 파일 이름(`test_git_metadata.py:305`)과 컨텍스트 경로 강제 stage(`316-339`, 결정한 정책으로 기대값 갱신).
10. 명시적 `--git-dir` 커밋에서 컨텍스트 Git 격리, snapshot에 새 행 포함(`test_hook_index.py:109-119`).
11. post-commit 중 Git 조회 실패: 커밋 성공, 행 없음, 경고. `test_git_metadata.py:341-352`를 대체.
12. P1: 값이 필요한 옵션 9종(`--name` 단독)에 대해 stderr, exit 1, 빈 stdout. 손상·비객체·비문자열 타임라인에서 traceback 0건.
13. `bash -n`과 Bash 3.2에서 전체 unittest.

**바뀌는 기존 단언**
- `test_hook_index.py:72`(`pending`)
- `test_git_metadata.py:313-314`
- `test_hook_chain.py:320-333`: wrapper를 직접 실행하면 행이 0건이 됨
- `test_git_metadata.py:338-339`, `341-352`

---

## 5. 확인한 것과 추론·미검증의 구분

- **발췌를 직접 읽어 확인**: 위 표에서 "발췌 확인"으로 표시하고 행 번호를 붙인 항목 전부입니다. 디스크의 파일은 열지 않았습니다. 지시에 따라 도구를 쓰지 않았고, 요청 본문의 발췌만 읽었습니다.
- **코드 판독에 근거한 추론**
  - wrapper 바이트를 바꾸면 전환이 거부된다는 점
  - F2의 다른 전체 차단 경로
  - 컨텍스트 Git 재귀가 일어나지 않는 이유
  - hooksPath/linked worktree에서 훅이 실행되지 않거나 설치가 실패한다는 점
- **Git 동작에 대한 추론 (미검증)**
  - post-commit 시점의 `GIT_INDEX_FILE`과 인덱스 상태
  - sequencer(rebase/cherry-pick/revert)의 post-commit 호출 여부
  - stash가 훅을 호출하지 않는다는 점
- **확인하지 못한 것**
  - `make_search_result`의 고정 문구
  - `browser-harness.js`의 한국어 단언
  - sync/export/generate 코드(F8, R5), v0.1.0 태그(R9), CI 설정
  - `require_python`의 본문
- **실행하지 않은 것**: 어떤 테스트나 명령도 실행하지 않았습니다. Codex의 실행 결과(331개 통과, 각 재현 결과)는 독립적으로 확인하지 않았습니다.

## 구현 diff 재검토와 반영 판단

Claude에 이번 작업 전 백업과 구현 후 diff를 전달해 추가 검토를 받았다. 아래는 실제 코드·Git 실험과 대조한 반영 판단이다.

- 짧은 legacy ID의 모호성이 관련 없는 새 커밋까지 막는 지적을 반영했다. post-commit은 후보와 접두사가 겹치는 참조만 Git 객체로 해석한다. 후보와 관련된 참조가 모호하면 기록을 중단한다. backfill은 기존 전체 검사 계약을 유지한다. 실제 충돌 커밋 객체를 만든 회귀 테스트로 세 경우를 확인한다.
- 접두사 일치만으로 중복을 확정하자는 제안은 채택하지 않았다. 다른 객체와 충돌한 짧은 ID를 특정 커밋으로 간주해 자동 기록을 누락할 수 있기 때문이다.
- post-commit은 40/64자리 전체 16진 ID를 검증한 뒤 `cat-file -t`로 commit 객체인지 확인한다. 새 경로에서 `rev-parse --end-of-options`에 의존하지 않도록 보완했다.
- 업그레이드 안내에 post-commit 설치 전에는 자동 기록과 자동 컨텍스트 snapshot이 함께 대기함을 명시했다.
- dirty에서 컨텍스트 전체를 제외하자는 제안은 채택하지 않았다. dirty는 기존 수동 log와 같은 프로젝트 전체 status 관측값이다. 이미 추적한 컨텍스트의 변경도 실제 미커밋 변경이며 제외하면 이를 숨긴다. 설치 후 컨텍스트 로그를 강제 추적한 임시 프로젝트에서 저장한 dirty와 Git status가 일치함을 확인했고 사용 안내에 포함했다.
- Claude가 제시한 설치 전 추적 시나리오는 기존 ignore 검사에서 설치가 거부됐다. 강제 추적을 설치 후 수행한 경로로 바꿔 위 실험을 확인했다.

### 구현 diff에 대한 Claude 원문

# 리뷰 결과

실행 가능한 문제 3건(중간 2, 조건부 낮음 1)과 문서 불일치 1건을 찾았습니다.

## 1. [중간] `dirty`가 ctx 자신의 쓰기 때문에 계속 `true`가 됨

**위치:** `ctx.sh` `_hook_run_post_commit`의 Python 블록, `status_args` 구성 부분

**원인:** `git status` pathspec은 `work-log/.ctx.lock`만 제외하고 컨텍스트 디렉터리 전체는 제외하지 않습니다. 반면 `files`는 `git_commit_entries`에서 컨텍스트 경로를 제외합니다. 문서가 지원 대상으로 명시한 "이미 추적 중인 컨텍스트 파일"이 있으면 둘이 어긋납니다.

**재현:**
1. `init`을 hook 없이 실행합니다.
2. `git add -A && git commit`을 실행합니다. 이때 `sample-context/work-log/timeline.jsonl`이 추적 대상이 됩니다.
3. `hook install`을 실행합니다. ignore 규칙은 추가되지만 추적은 그대로 유지됩니다.
4. 커밋 C1 → post-commit이 추적 중인 `timeline.jsonl`에 행을 추가합니다.
5. 이후 컨텍스트와 무관한 커밋 C2를 만듭니다.

**결과:** C2에서 `status`가 C1 때 ctx가 추가한 `timeline.jsonl` 변경을 보고 `dirty: true`가 됩니다. 이후 모든 커밋이 영구히 `dirty: true`입니다. `files`에서는 컨텍스트가 빠져 있어 원인도 보이지 않습니다. 에이전트가 `backlog.md` 등을 수정해도 마찬가지입니다.

**수정 제안:** 컨텍스트가 root 내부이면 `":(exclude,literal)<context_path>/"`를 status pathspec에 추가합니다. 이렇게 하면 lock 제외는 이 규칙에 포함됩니다.

## 2. [중간] 모호한 legacy 짧은 참조 하나가 이후 모든 post-commit 기록을 막음

**위치:** `ctx.sh` 공유 preamble `existing_commit_refs`, 호출처 `_hook_run_post_commit`

**원인:** `cat-file --batch-check`는 커밋이 아닌 blob·tree와 prefix가 겹쳐도 `ambiguous`를 반환합니다. 이 경우 `ValueError`가 발생합니다. 지금까지는 사용자가 명시적으로 실행하는 backfill만 멈췄지만, 이제는 매 커밋의 자동 기록이 멈춥니다. 또한 저장소에 객체가 늘면서 예전에 유일하던 참조가 나중에 모호해질 수 있습니다. 기록 중인 그 커밋이 모호함을 만들 수도 있습니다.

**재현:** active 또는 archive에 `{"commit":"abcd"}`(fullCommit 없음, 4~7자리)가 있는 상태에서 `abcd`로 시작하는 객체가 2개 이상 생기면 됩니다. 4자리라면 객체 수만 개 규모에서 사실상 확정적으로 발생합니다.

**결과:**
- 이후 모든 커밋이 경고만 내고 행을 추가하지 않습니다.
- 안내된 복구 수단인 `backfill`도 같은 오류로 실패합니다.

**수정 제안:** post-commit에는 cat-file 해석이 필요 없습니다. "이 `full_commit`이 대표되는가"만 판정하면 됩니다.
- `full_commit`이 `fullCommit` 집합에 있는지 확인합니다.
- 또는 `full_commit.lower().startswith(ref.lower())`를 만족하는 legacy 참조가 있는지 확인합니다.

이 방식으로 분리하면 모호성 중단은 backfill에만 남습니다.

## 3. [낮음·조건부] `rev-parse --end-of-options`는 Git 2.30 이상이 필요함

**위치:** `ctx.sh` `_hook_run_post_commit`, `["rev-parse", "--verify", "--end-of-options", reference + "^{commit}"]`

**원인:** `rev-parse`가 `--end-of-options`를 인식한 것은 Git 2.30부터로 알고 있습니다.

**재현:** 지원 범위에 Git 2.25(Ubuntu 20.04) 같은 버전이 포함된 경우입니다.

**결과:** 해당 버전에서는 이 호출이 실패합니다. 그러면 모든 커밋이 경고만 내고 기록되지 않습니다.

ctx.sh가 이미 다른 곳에서 2.30 이상을 요구한다면 무시해도 됩니다. 그렇지 않다면 captured ID를 40/64자리 hex로 검증하고 옵션을 빼는 편이 안전합니다.

## 4. [문서] 업그레이드 안내가 snapshot 중단을 누락함

**위치:** `docs/en/workflows.md`, `docs/ko/workflows.md`의 "Upgrade an existing installation" 첫 문단

**문제:** 문서는 "스크립트만 교체하면 committed logging만 대기 상태"라고 설명합니다. 그러나 구 pre-commit wrapper가 호출하는 `_hook_run_pre_commit`은 이제 경고만 하고 반환합니다. 따라서 post-commit을 설치하기 전까지는 독립 컨텍스트 저장소의 자동 snapshot도 중단됩니다.

**재현:** 스크립트만 교체하고 커밋하면, `timeline.jsonl` 외의 컨텍스트 변경도 로컬 Git에 커밋되지 않습니다.

**수정 제안:** 문서에 "자동 기록과 컨텍스트 snapshot이 모두 중단된다"고 명시합니다.

## 집중 확인 항목 중 문제를 찾지 못한 부분

- **pre-commit wrapper 바이트:** 변경이 없고 golden fixture로 검증됩니다.
- **HEAD 선확보와 원본 종료값:** HEAD를 원본 실행 전에 확보하고, 원본의 인자·입력을 전달하며, 원본 종료값을 반환합니다.
- **set -e 오류 전파:** `local` 선언과 할당이 분리되어 있어 실패가 wrapper 경고로 이어집니다.
- **동시 실행 중복 방지:** `fullCommit` 중복 검사와 append가 한 lock 안에서 이루어집니다.
- **`--only` 인덱스 격리:** post-commit 시점의 실제 index를 쓰고, `GIT_OPTIONAL_LOCKS=0`이 적용되며, snapshot 쪽 env는 제거됩니다.
- **timeline JSONL:** 손상 시 오류 보고가 동작하고 비문자열 필드를 처리합니다.

diff에 포함되지 않은 `previous`/`with_original` 본문, `context_python --read-only`, `config_python` preamble의 동작은 테스트 통과를 근거로 전제했습니다.

## 선행 작업을 포함한 작업 트리 검증

2026-11-25, macOS arm64. 검토된 P1·P2를 현재 작업 트리의 선행 변경 위에 적용했다. 작업 브랜치는 `codex/reliability-claude-reviewed`다.

- 수정 전 `python3 -B -m unittest discover -s tests`는 351개 통과했다.
- 최종 같은 명령은 371개, 140.855초, OK다. 테스트 시작 시 저장한 코드·fixture·테스트 SHA-256과 종료 후 값을 대조해 검증 중 변경이 없음을 확인했다.
- `bash -n ctx.sh`와 `git diff --check`가 통과했다.
- 40자리 SHA-1과 별도 SHA-256 저장소의 64자리 커밋을 기록하고 backfill과 중복되지 않음을 확인했다.
- 컨텍스트 저장소의 post-commit이 부모 ctx를 다시 호출하는 실험에서 교착·추가 부모 로그 없이 독립 snapshot이 생성됐다.
- `--only`에서 실제 다른 staged blob과 dirty 관측, 부분 스테이징 뒤 남은 작업 트리, 원본 훅 실패·HEAD 변경·인자·stdin·interpreter, 옛 wrapper 두 종류, legacy pending 보존, 같은 시각 ID, 빈 커밋·amend·revert·merge와 동시 재시도를 검사했다.
- 선행 변경의 AGENT_RULES, init/search/doctor/baseline 테스트, 평가 자료와 reader의 doctor·규칙/계획 템플릿 본문을 백업과 대조해 보존을 확인했다.
- Windows, Python 3.7, 오래된 Git의 실환경 검증은 수행하지 않았다. 연결 worktree·사용자 hooksPath 설치, strict·언어 선택·post-merge 훅은 이번 구현 범위에 포함하지 않았다.

최종 ctx.sh SHA-256은 `3bba6b3d609a84b62e5ce180c4663594f096090fec30947ee6a86e6ac40c2fb6`다.

## P1·P2 PR 분리 검증

2026-11-25, `main` `7309923`에서 이번 P1·P2만 분리해 검사했다. 위 351→371 검증은 선행 작업까지 포함한 작업 트리의 기록이다. 이 PR의 기준 테스트는 main의 331개이며, P1·P2 반영 후 351개다.

- 수정 전 백업과 현재 파일의 차이만 추출해 19개 수정 파일과 4개 새 문서·fixture를 구성했다. 기존 사용자 변경을 다시 합쳤을 때 현재 작업 트리와 바이트가 일치하는지 확인했다.
- 기존 규칙·템플릿 축소, doctor, handoff baseline 코드·테스트는 커밋 범위에서 제외했다.
- `bash -n ctx.sh`와 stage 대상 diff 검사가 통과했다.
- `python3 -B -m unittest discover -s tests -v`는 분리본에서 Python 3.11.8의 351개/147.097초, Python 3.13.3의 351개/171.574초 모두 OK다.
- Python 3.13이 2,000단계 중첩 JSON을 정상 처리해, 오류 검증 입력을 실제로 거부되는 20,000단계로 바꿨다. 두 Python에서 해당 회귀와 전체 검사를 확인했다.
- Windows·Python 3.7은 미검증이다.

분리본 ctx.sh SHA-256은 `5e66a36d2669ade3c29f6c937e5cde825bc65ff4ee99df33e37aa003cef24acd`다.
