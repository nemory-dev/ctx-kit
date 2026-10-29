# 로컬 컨텍스트 뷰어: 새 세션 병렬 실행 가이드

- 사용자 승인: 2026-10-30, “새 세션에서 병렬로 작업 가능한 부분을 정리하고 작업을 시작하자”.
- 설계: [상세 계획](2026-10-30-local-context-viewer.md).
- 검토: [Claude 제안 검토 원문](../reviews/2026-10-30-local-viewer-claude.md). 제안문 검토이며 코드 리뷰와 구분한다.
- 새 사용자 세션 하나를 통합 담당으로 시작하고 그 안에서 최대 세 하위 에이전트를 병렬 실행한다. 구현·검증은 승인됐으며 commit·push·PR·배포는 승인되지 않았다.

## 1. 시작 상태와 보호 범위

- 저장소: `/Users/hyun/dev/ctx-kit`, 준비 시점 HEAD `537e1a3`, 브랜치 `codex/git-log-metadata`. 추적 파일 변경 없음.
- 인계 전 검증: `bash -n ctx.sh` 성공, `python3 -B -m unittest discover -s tests` 188개 통과(93.027초), 계획 문서 링크·코드 펜스·공백 검사와 `git diff --check` 통과. 이후 파일 변경이 있으면 새 세션에서 해당 검사를 다시 실행한다.
- `contracts/`는 기존 타 작업으로 수정·이동·삭제·스테이징하지 않는다.
- 계획·실행 가이드·Claude 검토 문서는 미추적 상태로 현재 폴더에 있다. 별도 checkout을 사용한다면 이 세 파일을 명시적으로 복사해야 한다.
- 새 세션은 현재 로컬 checkout에서 상태를 다시 확인하고 `codex/local-context-viewer` 또는 충돌하지 않는 같은 prefix의 기능 브랜치를 만든다. 기존 브랜치가 있으면 상태를 확인하며 reset·강제 재사용하지 않는다.
- 새 worktree는 요청되지 않았으므로 추가 사용자 세션을 worktree에 자동 생성하지 않는다. 기능 브랜치와 파일 소유권으로 작업을 분리한다.

## 2. 의존 관계와 병렬 단위

| 단계 | 담당·실행 | 완료 조건 |
|---|---|---|
| S0. 상태·회귀 확인 | 통합, 순차 | diff 보호 범위·기존 검사·기능 브랜치 확인 |
| S1. 계약·fixture 준비 | 통합, 순차 | 아래 인터페이스·공통 helper를 확인하고 공유 |
| P-A. 수집·모델·Git | 에이전트 A, 병렬 | 독립 Python 조각·데이터 테스트 |
| P-B. HTML·문서·검색 | 에이전트 B, 병렬 | 렌더러·CSS·JS·HTML 테스트 |
| P-C. 저장·실행·안내 | 에이전트 C, 병렬 | 출력·브라우저 조각·장애 테스트·문서 |
| S2. 내장·CLI 통합 | 통합, 순차 | A/B/C 코드를 `ctx.sh`에 내장하고 두 파일 설치 유지 |
| S3. 리뷰·최종 검증 | 통합·읽기 전용 reviewer | 명세·품질·회귀·실브라우저·성능 확인 |

P-A/B/C는 S1 뒤 함께 시작한다. 최종 CLI 테스트는 S2에 의존한다. 미통합 실패를 정상 통과로 보고하지 않는다. 임시 조각 검증은 함수 수준 결과이며 배포 CLI의 성공 증거와 구분한다.

## 3. 파일 소유권

| 담당 | 수정 허용 | 동시 수정 금지 |
|---|---|---|
| 통합 | `ctx.sh`, `tests/viewer_support.py`, `tests/test_view.py`, 계획 체크 | 다른 담당의 테스트·문서 |
| A 데이터 | 임시 `data.py`, `tests/test_view_data.py`, `tests/fixtures/viewer/data/` | `ctx.sh`, 공통 helper, B/C 파일 |
| B 화면 | 임시 `render.py`·`viewer.css`·`viewer.js`, `tests/test_view_html.py`, `tests/fixtures/viewer/html/` | `ctx.sh`, 공통 helper, A/C 파일 |
| C 저장 | 임시 `output.py`, `tests/test_view_safety.py`, 한국어·영문 README/이용 흐름/문제 해결 문서 | `ctx.sh`, 공통 helper, A/B 파일 |

- 통합 담당이 `tempfile.mkdtemp(prefix="ctx-kit-viewer-")`로 공통 임시 폴더를 만들고 담당별 하위 경로를 전달한다. 고정 `/tmp` 파일을 공유·덮어쓰지 않는다.
- 임시 조각은 병렬 구현용이며 런타임 의존성이 아니다. 최종 `ctx.sh`는 두 파일 복사만으로 실행되어야 한다. 임시 조각을 import하거나 절대 임시 경로를 참조하지 않는다.
- 각 담당은 코드·테스트·실행 결과·통합 의존성을 보고한다. 타 파일 변경을 발견하면 덮어쓰지 않고 통합 담당에게 알린다.
- 한영 문서는 C만 수정한다. 최종 동작과 다른 부분은 통합 담당이 C에게 수정 요청한다.
- 통합 후 소유한 임시 파일만 정리한다. 프로젝트나 다른 작업에 대한 광범위한 삭제는 하지 않는다.

## 4. 먼저 고정할 함수 계약

Python 3.7 호환. 아래는 새 함수의 계획상 계약이며 현재 구현된 API가 아니다. 변경은 통합 담당과 의존 담당에게 알린 뒤 함께 반영한다.

```python
# A: 기존 context_lock 등 helper의 globals 제공 여부는 통합 담당과 확인
collect_snapshot(project_root, context_dir, config_path, output_path)
# -> 문서·행별 레코드·수집시각·보호할 입력 경로 dict
collect_git_snapshot(project_root, excluded_paths, commit_refs)
# -> status, observedAt, branch, head, changes, commitObjects, warnings dict
build_view_model(snapshot, git_snapshot, generated_at)
# -> 상세 계획 5.2 모델, generated_at은 UTC offset 포함 문자열

# B: 외부 I/O 없이 모델만으로 HTML 생성
render_view_html(model)
# -> str; CSS/JS는 고정 상수로 내장

# C: 출력 보호와 원자적 저장
write_view_html(output_path, html_text, project_root, protected_inputs)
# -> None; 실패는 OSError/ValueError
open_view(output_path)
# -> bool; 예외는 CLI 경계에서 설명
```

- 통합 담당은 옵션·환경 전달·호출 순서·오류·종료 코드·help·dispatch를 소유한다.
- 순서: 인자/경로 확인 → snapshot → Git → model → render → write → 선택적 open.
- A는 수집 중에만 lock을 보유하며 journal을 복구하지 않는다.
- B는 record와 문서 원문을 표시하며 없는 필드를 추론으로 채우지 않는다.
- C는 프로젝트 설정·hook·외부 서비스를 변경하지 않는다.

## 5. 데이터 계약

- 최상위: `viewModelVersion=1`, `generatedAt`, `project`, `documents`, `entries`, `git`, `warnings`.
- `project`: `name`, 프로젝트 상대 `contextPath`.
- `documents`: `{key, path, sourceKind:"document", status:"present"|"missing", text}`. key는 `plan`, `decisions`, `backlog`, `digest`, `completed`, `deprecated`.
- `entries`: `{key, sourceKind:"work_log", sourcePath, sourceLine, record, recordText, timestampUtc, commitObjectRef, commitObjectStatus}`.
- `recordText`: 원래 JSONL 행을 문자열로 보존하여 큰 정수·소수·공백의 원문 표시를 보장한다.
- `commitObjectRef`: 조회한 명시 참조 또는 null. `commit` 누락/null/빈 문자열일 때만 `fullCommit`을 사용하며 pending/uncommitted를 보정하지 않는다.
- `timestampUtc`: offset을 해석한 epoch 초 숫자 또는 null. 원래 시각은 `record.createdAt`에 보존.
- `commitObjectStatus`: `not_recorded`, `verified`, `unavailable`. 확인 불가 이유는 warnings와 기록 참조로 남긴다.
- `git.status`: `available`, `not_repository`, `unavailable`. unborn HEAD·detached는 `head`/`branch`의 null 및 경고로 표시한다.
- `git.changes`: `{path, status, previousPath}`. 이전 경로가 없으면 null.
- `git.commitObjects`: 참조 문자열에서 `{status, objectId}`로 가는 내부 사전. 모델 생성 시 기록별 상태에 반영.
- `warnings`: `{code, message, source}`. source는 상대 경로나 null. 메시지는 텍스트로만 표시.
- 누락한 목록은 빈 배열, 미확인 scalar는 null. 원래 record의 타입을 신뢰하지 않는다.
- 같은 로그 ID·내용을 합치지 않는다. NFC는 검색에만 적용하며 원문 경로·ID를 보존한다.

## 6. 공통 테스트 fixture

통합 담당이 `tests/viewer_support.py`에 `BaseViewCase(unittest.TestCase)`를 먼저 제공한다. 각 테스트는 `from viewer_support import BaseViewCase`를 사용한다.

- 속성: 절대 Path인 `project`, `script`, `context`, `output`; subprocess 환경 사전 `env`.
- `run_ctx(*args)`: 실제 복사한 Bash CLI 실행의 CompletedProcess 반환. 성공을 미리 단언하지 않는다.
- `write_jsonl(relative_path, entries)`: 컨텍스트 아래 상대 경로에 fixture 작성.
- `read_view_model(output=None)`: HTMLParser로 고정 ID `ctx-view-data`의 JSON 데이터 블록 추출.
- `source_snapshot()`: 문서·로그·설정의 바이트 사전. 생성물·lock·임시 파일 제외.
- `git(*args)`: 테스트 작성자 환경을 사용한 프로젝트 Git 실행 helper.
- 최소 설정·문서·context만 준비하며 실제 init·hook에 의존하지 않는다.
- 대상 테스트 명령: `python3 -B -m unittest discover -s tests -p 'test_view*.py' -v`.

## 7. 통합과 검증

1. 코드와 실제 테스트 출력을 확인하고 보고만으로 통과 처리하지 않는다.
2. 통합 담당만 조각을 기존 Python 실행 문맥에 내장하며 이름 충돌·누락 import를 확인한다.
3. 소유권을 유지하며 테스트 실패를 담당자에게 전달하고 통합 문제는 직접 해결한다.
4. 명세 준수와 코드 품질 검토를 나눈다. 완료된 작업자를 읽기 전용 reviewer로 재사용할 수 있다.
5. 전체 unittest·Bash 구문·diff 검사 후 생성 파일로 실브라우저·공격 입력·반응형·성능을 확인한다.
6. 미검증 항목은 이유와 재현 명령을 남긴다. 구현·검증·commit·merge 상태를 구분한다.
7. 결과는 변경 요약·수정 파일·검증·남은 행동 순으로 한국어로 보고한다. commit·push·PR은 하지 않는다.

## 8. 새 세션의 작업 지시

상세 계획과 이 가이드, Claude 검토를 읽고 구현을 시작한다. 실제 막힘이 없다면 단계별 재승인을 요청하지 않는다. 사용자에게 하위 에이전트를 직접 관리하도록 넘기지 않고 통합 담당이 끝까지 조정한다. 원래 세션은 새 세션의 작업 착수를 확인한 뒤 소스 파일 편집을 하지 않는다.
