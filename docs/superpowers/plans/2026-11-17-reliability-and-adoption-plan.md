# 신뢰성·채택 리스크 개선 계획

> **상태:** 2026-11-25 Claude 재검토를 반영했다. 사용자가 검토 후 보완·작업을 요청한 범위에서 P1·P2 구현과 검증을 완료했다. 나머지 단계는 후속 계획이다. 체크박스는 실제 검증 후 갱신한다.
> 검토 기록: [Claude 재검토와 반영 판단](../reviews/2026-11-25-reliability-claude.md).

**Goal:** 처음 쓰는 사람이 ctx-kit을 설치해도 커밋이 막히거나, 기록이 오염되거나, 비공개 내용이 새거나, 지울 수 없게 되는 일이 없도록 한다. 그 뒤에 기능을 더한다.

**Architecture:** 배포물은 지금처럼 `ctx.sh`와 `ctx.config.json` 두 파일이다. 개발은 `src/`의 모듈에서 하고 빌드 스크립트가 `ctx.sh`를 생성한다. 설정 읽기와 경로 검증은 한 곳으로 모은다.

**Tech Stack:** Bash 3.2, Python 표준 라이브러리, unittest. 런타임 의존성·서버·DB·LLM 호출은 추가하지 않는다. 개발 도구로 ruff와 shellcheck를 CI에만 추가한다.

---

## 1. 기준과 근거

- 작성일: 2026-11-17. 기준: `main` `7309923`.
- 진단 근거: Linux 컨테이너(Bash 5.2, Python 3.13, Git 2.43)에서 전체 테스트 331개 통과(1개 skip)를 확인했고, 아래 F1~F5는 임시 프로젝트에서 직접 재현했다. F6~F8은 코드 판독과 측정이다.
- Windows, macOS, Python 3.7 실환경에서는 실행하지 않았다.
- 선행 문서: [유사 도구 조사](../research/2026-11-01-context-tools-benchmark.md). 이 계획은 그 조사의 "후속 범위"(진단, 유효성 표시)를 구체화하고, 조사에 없던 사용자 리스크를 더한다.

### 진단 요약

| ID | 문제 | 근거 |
| --- | --- | --- |
| F1 | pre-commit의 커밋 시도 관측이 성공 커밋과 연결되지 않고 `pending`으로 남는다. 중단된 시도도 보존되며, `backfill`은 성공 커밋을 별도 행으로 추가한다 | 재현. `ctx.sh` `_hook_run_pre_commit`. 문서에 한계로 명시돼 있음 |
| F2 | `auto_log`가 활성 타임라인을 읽는 staged 커밋은 손상된 JSONL 때문에 실패한다. 설정 읽기·잠금·archive 복구·컨텍스트 Git 실패는 staged 내용과 무관하게 차단할 수 있다 | 재현. 문서에 명시돼 있음 |
| F3 | `log --summary`, `timeline --limit`, `backfill --type`에 값이 없으면 메시지 없이 exit 1 | 재현. `shift 2`와 `set -e` |
| F4 | `timeline`이 자체 파서를 써서 손상된 줄·비문자열 필드에 traceback을 낸다. 오류 스트림이 명령마다 다르다. 기존 명령은 영어, `search`·`handoff` 사람용 출력과 handoff JSON의 안내·경고 샘플은 한국어다 | 재현 |
| F5 | `view`·`search`는 컨텍스트가 프로젝트 안인지 검사하지만 `init`·`generate`는 `../`를 허용한다. 에이전트 이름의 `\|`가 잘못 파싱된다 | 재현 |
| F6 | `ctx.sh` 4,911줄 중 약 2,650줄이 heredoc 안의 Python이라 모듈별 린트·정적 분석을 적용하기 어렵다. 일부 내장 함수는 추출 후 `compile`·`exec`하는 테스트 helper로 검사한다. 복잡도 최대 28 | ruff C901 측정 |
| F7 | CI가 Python 3.11만 실행한다. 문서상 최소 버전 3.7과 Windows는 검증이 없다 | `.github/workflows/ci.yml` |
| F8 | `sync`가 기존 `> Last Updated: ` 줄을 실행일로 바꾼다. 그 줄이 없어도 파일 교체를 수행한다 | 코드 판독, 실행 출력 |

## 2. 경쟁 구도에서 본 위치

기존 조사의 비교표는 유지한다. 이번에 추가로 확인한 사실과 그 의미만 적는다.

| 관찰 | 출처와 확인 수준 | ctx-kit에 주는 의미 |
| --- | --- | --- |
| Claude Code는 CLAUDE.md에서 `@경로` import를 지원하고, Windows에서는 symlink 대신 `@AGENTS.md` import를 권장한다 | [공식 문서](https://code.claude.com/docs/en/claude-md) | symlink만 지원하는 현재 방식은 Windows 기본 설정에서 막힌다. import·복사 모드가 필요하다(P5) |
| Git for Windows는 symlink가 기본으로 꺼져 있고, Developer Mode나 관리자 권한이 필요하다 | [Git for Windows 문서](https://gitforwindows.org/symbolic-links) | 커밋된 링크를 Windows에서 받으면 대상 경로만 적힌 일반 파일이 될 수 있다. 진단 명령이 이를 잡아야 한다(P4) |
| Claude Code에 자동 메모리가 있고, Codex CLI에도 Memories 기능이 보고된다 | Claude: [공식 문서](https://code.claude.com/docs/en/memory). Codex: 제3자 글만 확인, 미검증 | "기억" 자체는 내장 기능과 경쟁하지 않는다. 도구 간 이동성과 사람이 검증 가능한 출처로 차별화해야 한다 |
| claude-mem 사용자들은 worker 포트 충돌로 훅이 모든 프롬프트를 막았다고 보고했다 | GitHub 이슈 [#2899](https://github.com/thedotmack/claude-mem/issues/2899), [#2996](https://github.com/thedotmack/claude-mem/issues/2996). 사용자 보고, 미검증 | 보조 도구가 본 작업을 막으면 사용자는 도구를 지운다. F2와 같은 유형이다(P2) |
| 코드가 바뀌면 메모리가 조용히 낡고, 낡은 기록도 확신 있게 제시된다는 지적이 반복된다 | 실무자 글과 [사전 공개 논문](https://arxiv.org/pdf/2609.05510). 통제된 연구는 찾지 못함 | 기록이 낡았다는 신호를 결정적으로 보여 줘야 한다. F8은 반대로 낡음을 숨긴다(P5) |

**포지셔닝:** 상주 프로세스·DB·모델 호출 없이, 여러 에이전트 사이에서 사람이 확인할 수 있는 근거를 전달하는 로컬 도구. 경쟁 도구의 기능을 따라가지 않고, 그 도구들에서 사용자가 겪는 문제(훅 차단, 상주 프로세스 장애, 낡은 기억, 의도하지 않은 업로드)를 구조적으로 갖지 않는 쪽을 강점으로 삼는다.

## 3. 사용자가 느낄 리스크와 해결

| ID | 사용자가 겪는 상황 | 현재 동작 | 해결 | 단계 |
| --- | --- | --- | --- | --- |
| R1 | 설치했더니 커밋이 안 된다 | 로그 파일 손상·잠금 timeout·Git 조회 오류가 커밋을 막는다 | 기록과 컨텍스트 snapshot을 post-commit으로 옮긴다. 원본 pre-commit의 실패는 전파한다 | P2 |
| R2 | 기록이 믿을 수 없다 | `pending`·유령·중복 기록이 쌓여 검색과 인수인계에 섞인다 | 확정된 전체 커밋 ID로 기록하고 `backfill`과 중복을 막는다. 기존 pending은 당시 관측으로 보존한다 | P2 |
| R3 | 잘못 입력했는데 아무 말이 없다 | 값 누락 시 무메시지 종료, 일부 명령은 traceback | 공통 인자 검증과 공통 JSONL 읽기 | P1 |
| R4 | Windows에서 링크가 안 만들어진다 | symlink만 지원 | 규칙 파일 연결 모드에 import·복사 추가 | P5 |
| R5 | 비공개 컨텍스트가 push되거나 공유된다 | `--no-hook`이면 ignore 설정도 건너뛴다. `view`는 허용된 문서·로그 전체, 기본 `export`는 최근 활성 로그 10건과 문서, `export --all`은 보관 상세도 포함한다. `generate`는 설정된 glob을 따른다 | 진단에서 ignore 누락을 경고. 공유 전 검사 옵션. 과장된 문구 수정 | P4, P5 |
| R6 | 계획 문서가 낡았는데 최신처럼 보인다 | `sync`가 날짜를 무조건 갱신 | 자동 날짜 갱신을 없애고, 계획 수정 이후 커밋 수를 표시 | P5 |
| R7 | 에이전트가 규칙을 읽었는지 알 수 없다 | 링크 존재만 표시 | 진단에서 파일 형식·크기·링크 해석을 확인. 준수 여부는 보증하지 않는다고 명시 | P4 |
| R8 | 지우고 싶은데 뭘 지워야 할지 모른다 | 훅 제거만 있고 링크·ignore 항목은 수동 | `uninstall --dry-run`으로 제거 대상을 먼저 보여 준다 | P4 |
| R9 | 새 버전에서 뭐가 바뀌었는지 모른다 | `v0.1.0` 태그는 있으나 릴리스별 변경 기록과 복사 설치의 갱신 안내가 부족하다 | 태그, CHANGELOG, 업그레이드 안내 | P6 |
| R10 | 규칙 파일이 토큰을 얼마나 쓰는지 모른다 | 표시 없음 | `status`에 규칙·계획 파일 크기와 대략적 토큰 추정을 표시(추정임을 명시) | P5 |

## 4. 원칙과 비범위

- 사용자 데이터 보존이 기능보다 우선이다. 기존의 "충돌 시 거부" 동작은 유지한다.
- 보조 도구는 본 작업(커밋, 편집)을 막지 않는다. ctx 처리는 성공 커밋 이후 실행한다. 원본 pre-commit 검사의 차단 의미는 보존한다.
- 문서의 지원 범위는 CI가 실제로 실행하는 범위와 같게 한다.
- 동작을 바꾸는 변경과 구조만 바꾸는 변경은 같은 PR에 넣지 않는다.
- 비범위: MCP 서버, 임베딩·의미 검색, LLM 요약, 대화 전문 수집, 팀 동기화, 호스팅. 필요성은 P6의 사람 평가 결과로 다시 판단한다.

## 5. 단계별 계획

이번 회차는 수정 전 351개 회귀와 재현 테스트로 P1·P2를 보호하며 구현한다. P0의 CI·지원 버전·테스트 헬퍼 정리는 후속 단계로 남긴다. P1·P2는 작고 사용자 체감이 크므로 먼저 한다. 구조 분리(P3)는 새 기능(P4·P5)보다 앞에 둔다. 지금 구조에 기능을 더하면 분리 비용이 계속 커진다.

### P0. 안전망 (선행)

이후 변경을 보호할 검사를 먼저 넣는다. 코드 동작은 바꾸지 않는다.

- [ ] CI에 `shellcheck ctx.sh` 추가. 기존 경고는 한 번에 고치지 않고 기준선 파일로 고정한다.
- [ ] 내장 Python을 추출해 `ruff check`(F, E9 규칙)로 문법·미정의 이름을 검사하는 스크립트를 추가한다. P3 이후에는 `src/`를 직접 검사한다.
- [ ] Python 매트릭스에 최신 버전과 최저 버전을 추가한다. `setup-python`이 3.7을 제공하는 러너가 없으면, 문서의 최소 버전을 실제로 실행하는 최저 버전으로 올린다.
- [ ] 테스트 헬퍼 `run_ctx`·`git`(14개 파일에 중복)을 `tests/support.py`로 모은다.

완료 기준: 기존 331개 테스트가 그대로 통과하고, 새 검사가 PR에서 실행된다.

### P1. CLI 일관성 (F3, F4 → R3)

- [x] log·timeline·backfill에서 값이 필요한 옵션에 공통 값 개수 검사를 적용한다. archive·view·search·handoff의 기존 추가 검사는 유지한다. doctor는 P4의 후속 범위다.

  ```bash
  need_value() {  # need_value <option> <남은 인자 수>
    if [ "$2" -lt 2 ]; then
      echo "Error: $1 requires a value." >&2
      return 1
    fi
  }
  # --summary|-s) need_value "$1" "$#" || return 1; SUMMARY="$2"; shift 2 ;;
  ```

- [x] `timeline`은 `context_python --read-only`의 `read_jsonl`과 공통 오류 처리를 사용한다. 잠금·archive 복구는 수행하지 않는다. `--json`은 원값을 보존하고, 텍스트에서 비문자열 값은 JSON 표기로 표시한다. 커밋 필터는 문자열 필드만 비교한다.
- [x] 정상 결과와 명시적 `--help`는 stdout, 잘못된 호출의 사용법·실행 오류는 stderr로 보낸다.
- [x] 출력 언어는 현행을 유지한다. `--lang`은 후속 결정이다. 도입 시 handoff JSON의 `notice`·경고 샘플과 Markdown·JSON별 실제 출력 예산도 검증한다.
- [x] 기존 `log --summary "--literal summary"` 입력을 허용한다. 기존 옵션의 값 검사는 남은 인자 수를 기준으로 한다.

완료 기준: 값이 필요한 옵션 전부에 대해 "값 누락 → stderr 메시지와 exit 1" 테스트가 있고, 손상된 타임라인에서 어떤 읽기 명령도 traceback을 내지 않는다.

영향: 잘못된 호출의 출력 스트림과 `timeline`의 손상·비문자열 처리만 변경한다. 검색·인수인계의 문구·golden 검색 결과는 유지한다.

### P2. 훅 신뢰성 (F1, F2 → R1, R2)

**성공한 커밋을 직접 기록한다.**

- [x] 기존 pre-commit wrapper 두 종류의 바이트·백업 이름·원본 종료 동작을 보존한다. `_hook_run_pre_commit`은 새 pending을 쓰지 않고 항상 성공한다. post-commit 미설치 시 `hook install`과 `backfill` 안내를 stderr로 보낸다.
- [x] post-commit wrapper가 원본 훅 실행 전에 HEAD를 고정한다. 원본 post-commit을 같은 interpreter·인자·stdin으로 실행하고 종료값을 보관한다. 실패해도 고정한 커밋의 ctx 기록을 시도한 뒤 원본 종료값을 반환한다.
- [x] ctx 기록 실패는 원인과 복구 안내를 stderr에 표시한다. 커밋 이후에 실행하므로 프로젝트 커밋의 성공을 취소하지 않는다. `git_sync.strict`와 추가 사전 검사는 이번 구현에 넣지 않는다.
- [x] `backfill`과 post-commit은 공통 커밋→행 builder를 사용한다. 전체 커밋 ID·author date·제목·본문·파일 목록·ID 생성 규칙을 공유한다. 파일 목록에서 컨텍스트 경로는 문자 그대로 제외하고, 빈 커밋과 컨텍스트 전용 커밋도 빈 파일 목록으로 기록한다. 메시지는 기존 backfill의 제목·본문 조합과 바깥쪽 공백 정리 규칙을 따른다.
- [x] post-commit의 `branch`·`dirty`는 기록 시점의 프로젝트 관측값이다. `--only`·부분 스테이징 이후 남은 변경과 이미 추적 중인 컨텍스트 변경도 포함한다. backfill의 빈 branch·`dirty=false`는 과거 커밋의 기본 메타데이터이며 당시 작업 트리를 관측했다는 뜻을 부여하지 않는다. `createdAt`은 공통 author date라 amend 등에서는 과거 시각일 수 있다.
- [x] 기계 writer는 공통 잠금 → archive 복구 → 활성·모든 보관 로그 검사 순서를 사용하고, 어느 행이든 같은 전체 커밋 ID가 있으면 새 행을 추가하지 않는다. 기존 짧은 ID 판별도 재사용하되 post-commit은 새 커밋과 접두사가 겹치는 참조만 해석한다. 관련된 참조가 모호하면 기록을 중단한다. backfill의 전체 모호성 검사는 유지한다. 수동 `log`의 반복 발생은 허용한다.
- [x] 자동 로그를 추가한 뒤 독립 컨텍스트 Git snapshot을 만든다. 재실행은 기존 로그를 보존하며, 이전에 실패한 snapshot도 다시 시도할 수 있다.
- [x] install은 두 훅을 쓰기 전에 모두 검사하고 post-commit부터 설치한다. uninstall도 두 훅을 검사한 뒤 각각 원본을 복원한다. 백업 충돌·사용자 수정 훅은 보존하고 명시적으로 실패한다. `hook status`는 두 훅과 비표준 hooksPath/worktree 상태를 알린다.

기존 설치 전환은 `ctx.sh` 교체 → `bash ctx.sh hook install` → `bash ctx.sh backfill` 순서다. 기본 backfill은 최근 30개를 검사하며 필요한 경우 `--all`을 사용한다. 기존 pending 행은 성공 여부가 확인되지 않은 시도 관측으로 보존한다.

설계 근거는 tree가 콘텐츠를 식별해도 커밋 시도와 성공의 대응을 증명하지 못한다는 점이다. 새 기록은 확정된 커밋 객체에서 생성한다. reader의 원문·반복 발생·snapshot hash 계약은 기존처럼 적용한다.

완료 기준은 성공 커밋의 자동 로그 1건, 실패한 시도의 새 자동 로그 0건, 재실행·backfill·archive 이후 중복 0건, 손상 타임라인에서도 프로젝트 커밋 성공과 경고, 7309923 설치본의 재설치·제거, `--only`의 다른 staged 변경 보존이다. 자동 merge의 보완은 backfill로 한다. post-merge 훅·기존 pending 이관·`--lang`·strict·잠금 시간 변경은 후속 범위다.

### P3. 구조 분리 (F6)

동작은 바꾸지 않는다. 전체 테스트가 수정 없이 통과하는 것이 유일한 합격 조건이다.

```text
src/
  cli.sh                 인자 파싱과 분기
  ctx/storage.py         잠금, 원자적 쓰기, archive 저널
  ctx/config.py          설정 읽기 (P4에서 검증 추가)
  ctx/gitio.py           Git 호출
  ctx/worklog.py         log, timeline, backfill
  ctx/archive.py
  ctx/hooks.py
  ctx/reader.py          snapshot 수집
  ctx/search.py, handoff.py, view.py
  view/view.css, view.js, view.html
  templates/             AGENT_RULES.md 등 (정본 하나)
tools/build.py           src → ctx.sh
```

- [ ] `tools/build.py`가 모듈을 정해진 순서로 이어 붙여 하나의 Python 프로그램으로 만들고 `ctx.sh`에 넣는다. 압축·인코딩 없이 평문으로 넣어 사용자가 설치 전에 읽을 수 있게 한다.
- [ ] `python3 tools/build.py --check`가 커밋된 `ctx.sh`와 빌드 결과가 다르면 실패한다. CI에 추가한다.
- [ ] 루트 `AGENT_RULES.md`와 내장 템플릿의 이중 관리를 없앤다. 정본은 `src/templates/` 하나다.
- [ ] `src/ctx` 모듈을 직접 import하는 단위 테스트를 추가한다. 기존 블랙박스 테스트는 빌드된 `ctx.sh`를 대상으로 그대로 둔다.
- [ ] 복잡도가 높은 함수(`collect_git_snapshot` 28, `scan_markdown_headings` 25, `collect_snapshot` 20)는 분리 PR이 끝난 뒤 별도 PR에서 쪼갠다.

주의할 제약:

- Python 프로그램은 지금처럼 stdin heredoc으로 전달한다. `-c` 인자는 Linux에서 인자 하나당 약 128KB 제한이 있어 전체 프로그램을 담을 수 없다.
- 그래서 stdin을 쓰는 기존 경로(템플릿 heredoc)는 Python 안으로 옮겨야 한다.
- 명령마다 전체 프로그램을 컴파일하게 된다. 분리 전후의 `status`·`log` 실행 시간을 측정해 기록하고, 눈에 띄게 느려지면 명령별로 필요한 모듈만 넣는 방식으로 바꾼다.

완료 기준: 331개 테스트 무수정 통과, `--check` 통과, 실행 시간 측정값 기록.

### P4. 설정 단일화와 진단 (F5 → R5, R7, R8)

- [ ] `config.py`의 `load_config()` 하나가 스키마와 경로를 검증하고 모든 명령이 이를 쓴다. 지금은 같은 JSON을 6곳에서 따로 읽는다.
- [ ] 경로 규칙: `source`, `generate.*.output`, `agent_rules[].path`는 프로젝트 루트 안이어야 한다. 절대 경로와 `..` 이탈은 거부한다. `collect`도 기본은 루트 안만 허용한다.
- [ ] `status`·`sync`·`list`의 에이전트 순회를 Python으로 옮겨 `|` 구분 텍스트 파싱을 없앤다.
- [ ] `ctx.sh doctor` 추가. 읽기 전용이며 다음을 확인한다.
  - Python·Git·Bash 버전과 선택된 Python 경로
  - 규칙 파일: 링크 해석 여부, 대상 경로만 적힌 일반 파일(Windows symlink 미지원 흔적), 크기
  - 컨텍스트 디렉터리의 ignore 여부와 이미 추적 중인 컨텍스트 파일
  - 훅 상태, `core.hooksPath`, worktree 여부
  - 타임라인 유효성, 연결되지 않은 pending 개수, 미완료 archive 저널
  - 각 항목에 통과·경고·실패와 다음에 실행할 명령 하나
- [ ] `ctx.sh uninstall --dry-run`은 제거할 훅·링크·ignore 항목을 나열만 한다. `--dry-run` 없이 실행하면 그 목록을 제거하고, 컨텍스트 디렉터리는 건드리지 않는다.
- [ ] `hook status`의 "safe from remote push" 문구를 "Git이 무시함"으로 고친다. ignore는 push 안전을 보장하지 않는다.

영향: 루트 밖 경로를 쓰던 설정은 오류가 된다. 변경 기록에 호환성 주의로 적고, 오류 메시지에 고칠 방법을 넣는다.

완료 기준: 이탈 경로 3종(source, output, agent path)이 모든 명령에서 같은 메시지로 거부되고, `doctor`가 위 항목마다 테스트를 가진다.

### P5. 채택 리스크 해소 (R4, R5, R6, R10)

**규칙 파일 연결 모드 (R4).**

- [ ] `agent_rules[].mode`: `symlink`(기본), `import`, `copy`.
  - `import`: `@<정본 경로>` 한 줄을 담은 일반 파일을 만든다. Claude Code용이다.
  - `copy`: 정본의 사본에 생성 표식과 정본 해시를 넣는다. `sync`가 다시 만들고, 사용자가 사본을 고쳤으면 덮어쓰지 않고 거부한다.
- [ ] symlink 생성이 실패하면 조용히 다른 모드로 바꾸지 않는다. 원인과 `mode` 설정 방법을 알리고 멈춘다.
- [ ] 열린 질문: Cursor `.mdc`는 frontmatter가 있어 생성 표식의 위치를 따로 정해야 한다. Codex·Cursor가 import 문법을 지원하는지는 공식 문서로 확인한 뒤 모드 허용 범위를 정한다.

**낡음 표시 (R6, F8).**

- [ ] `sync`의 무조건적인 `Last Updated` 갱신을 없앤다.
- [ ] `status`와 `handoff`에 "계획 문서 최종 수정 시각"과 "그 뒤의 프로젝트 커밋 수"를 표시한다. 낡았다고 판정하지 않고 숫자만 보여 준다.
- [ ] 결정 필요: 날짜 줄을 그대로 두고 갱신만 멈출지, 템플릿에서 줄 자체를 뺄지. 권장은 갱신만 멈추는 쪽이다. 기존 사용자의 파일을 바꾸지 않는다.

**공유 전 검사 (R5).**

- [ ] `export`·`view`·`generate`에 `--check`를 추가한다. 표준 라이브러리 정규식으로 확신도 높은 패턴(개인 키 헤더, 널리 알려진 토큰 접두사)만 찾아 파일과 줄을 경고한다.
- [ ] 출력에 "이 검사는 일부 패턴만 찾으며 통과가 안전을 뜻하지 않는다"를 항상 붙인다.
- [ ] `generate`에 `respect_gitignore` 옵션을 추가한다. 결정 필요: 새 설정의 기본값을 `true`로 할지. 권장은 `true`이고, 기존 설정 파일은 키가 없으면 지금 동작을 유지한다.

**크기 표시 (R10).**

- [ ] `status`에 규칙·계획·결정·백로그 파일의 바이트 수와 문자 수 기반 토큰 추정을 표시한다. 추정임을 표기한다.

완료 기준: 각 모드·옵션에 테스트가 있고, Windows 스모크(아래 P6)가 `copy` 모드로 통과한다.

### P6. 릴리스와 평가 (R9, F7)

- [ ] `windows-latest` 스모크 작업을 추가한다. Git Bash에서 `init --no-hook`, `log`, `timeline`, `search`, `view`를 `copy` 모드로 실행한다. 처음에는 필수 검사로 지정하지 않는다.
- [ ] `CHANGELOG.md`를 만들고 릴리스마다 태그를 붙인다. 동작이 바뀐 항목(P1 문구, P2 훅 기본값, P4 경로 거부, P5 날짜 갱신)은 호환성 주의로 표시한다.
- [ ] 업그레이드 안내: `ctx.sh` 교체 후 `doctor` 실행.
- [ ] 기존 계획에서 미실시로 남은 사람 평가(처음 보는 사람의 60초 재개)를 실시하고 결과를 기록한다. MCP·관계 모델 같은 후속 기능은 이 결과를 보고 결정한다.

## 6. 검증 방법

| 대상 | 방법 |
| --- | --- |
| 회귀 | 모든 PR에서 전체 unittest. P3는 테스트 수정 없이 통과해야 한다 |
| 재현 사례 | F1~F5 각각을 실패하는 테스트로 먼저 추가하고, 수정 뒤 통과를 확인한다 |
| 훅 | 실제 커밋의 성공 1건·실패 0건·재실행 중복 0건, 원본 훅 계약, 구 wrapper 재설치, index 격리와 snapshot을 확인한다 |
| 성능 | P3 전후로 `status`, `log`, `search`(5천 건) 실행 시간을 같은 환경에서 측정한다 |
| Windows | 스모크 작업 결과만 근거로 삼는다. 통과 전에는 문서에 미검증으로 둔다 |

## 7. 이 계획의 리스크

| 리스크 | 대응 |
| --- | --- |
| P3 분리 중 미묘한 동작 변화 | 동작 변경 PR과 분리하고, 블랙박스 테스트를 수정 없이 통과시킨다 |
| 훅을 통과시키면 기록 누락을 모르고 지나간다 | stderr 경고와 `hook status`의 두 훅 상태를 확인하고 backfill로 누락된 확정 커밋을 복구한다 |
| post-commit 미설치·실패·자동 merge로 기록이 빠진다 | 훅 상태·복구 명령을 안내하고 backfill로 확정된 커밋을 수집한다 |
| 경로 거부로 기존 설정이 깨진다 | 호환성 주의로 알리고, 오류 메시지에 수정 방법을 넣는다 |
| 범위가 커져 끝나지 않는다 | 단계마다 독립 PR로 머지한다. P2까지만 해도 R1~R3이 해소된다 |

## 8. 결정이 필요한 항목

1. 결정 반영 — post-commit에서 확정 커밋 기록. 기존 pending 보존, 빈 커밋 기록, 컨텍스트 파일 경로 제외. strict는 보류한다(P2).
2. 결정 반영 — 출력 언어 현행 유지. 정상 help/stdout과 오류/stderr를 구분한다. `--lang`은 보류한다(P1).
3. 문서의 최소 Python 버전을 CI 최저 버전에 맞춰 올릴지(P0).
4. `Last Updated` 줄을 유지하고 갱신만 멈출지(P5).
5. 새 설정에서 `respect_gitignore` 기본값을 `true`로 할지(P5).

## 9. 이번 실행 순서

1. 조사 — Claude의 판독과 현재 호출 경로를 대조한다. 선행 변경을 포함한 기존 351개 테스트를 기준선으로 삼는다.
2. 수정 — P1의 값 누락·stream·timeline 회귀부터 고치고 P2의 post-commit 전환을 이어서 구현한다. 기존 기능의 변경 이유와 원본 wrapper golden을 테스트로 남긴다.
3. 검증 — 관련 CLI·훅·Git 메타데이터·저장소 테스트, 실제 `--only`/실패/중복/이전 설치 시나리오, `bash -n ctx.sh`, 전체 unittest를 실행한다.
4. 정리 — 검토 반영과 실행 결과를 기록하고 실제 변경 파일을 정리한다.

## 10. PR 분리 검증

선행 사용자 작업을 제외한 main 7309923 + P1·P2 분리본의 전체 테스트 351개가 Python 3.11.8·3.13.3에서 각각 통과했다. 기존 작업을 포함한 371개 결과와 구분한다. 분리본에는 규칙·템플릿 축소, doctor, handoff baseline 구현을 포함하지 않는다.
