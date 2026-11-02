# 검색·재개 평가 fixture

합성 데이터이며 사람 평가 결과가 아니다. 자동 테스트는 20개 검색어의 필수 출처를 검사한다. 60초 재개 이해도, 실제 브라우저 사용성·그리기·클립보드는 **미실시**다.

회사 PC에서 개발 도구 없이 확인하려면 [다운로드용 HTML 데모와 짧은 확인표](../../../docs/qa/search-handoff/README.md)를 사용한다. 데모에는 페이지 이동용 합성 기록이 추가되어 있으며, 기본 corpus의 출처 행은 유지한다.

## 임시 프로젝트 준비

저장소 루트에서 실행하면 새 임시 디렉터리에 두 파일 설치와 합성 문서/로그를 만든다. 기존 프로젝트를 변경하지 않는다.

```bash
python3 -B - <<'PY'
import json, shutil, tempfile
from pathlib import Path
root = Path(tempfile.mkdtemp(prefix="ctx-evaluation-"))
shutil.copy2("ctx.sh", root / "ctx.sh")
(root / "ctx.config.json").write_text(json.dumps({"source":"context/AGENT_RULES.md"}))
corpus = json.loads(Path("tests/fixtures/context-read/evaluation-corpus.json").read_text())
for name, text in corpus["documents"].items():
    path = root / "context" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
for name, rows in corpus["logs"].items():
    path = root / "context" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row,ensure_ascii=False)+"\n" for row in rows),encoding="utf-8")
print(root)
PY
```

표시된 경로에서 `bash ctx.sh view --open`, `bash ctx.sh search --query "timeout cache" --json`, `bash ctx.sh handoff`를 실행한다. 합성 공격 문자열은 원문으로만 표시되어야 한다.

## 정답과 기록 양식

한 사람에게 Markdown 직접 열람 또는 새 UI 중 하나를 먼저 배정한다. 상태·다음 행동·제약·미검증을 자신의 말로 설명하는 시간과 근거를 기록한다. 60초 이내라도 오답이면 미달성이다. 같은 사람의 두 번째 열람은 학습 효과가 있으므로 따로 표시하고 첫 열람 비교와 합치지 않는다.

| 번호 | 질문 | 검색어 | 필수 출처 (1부터 LF 행) | 사람 시간 | 사람 정답 |
| --- | --- | --- | --- | --- | --- |
| 1 | 현재 상태는? | `cache` | MASTER_PLAN.md:5 | 미실시 | 미실시 |
| 2 | 다음 검증은? | `timeout` | MASTER_PLAN.md:7 | 미실시 | 미실시 |
| 3 | 수정 제약은? | `protected` | MASTER_PLAN.md:3 | 미실시 | 미실시 |
| 4 | 미실시 OS는? | `Windows` | MASTER_PLAN.md:11 | 미실시 | 미실시 |
| 5 | 실행했다고 기록한 검증은? | `unittest` | MASTER_PLAN.md:9 | 미실시 | 미실시 |
| 6 | 서버를 두지 않은 이유는? | `offline` | decisions.md:2 | 미실시 | 미실시 |
| 7 | 다음 개선 아이디어는? | `reranking` | backlog.md:2 | 미실시 | 미실시 |
| 8 | 과거 주요 단계는? | `milestone` | work-log/timeline-digest.md:2 | 미실시 | 미실시 |
| 9 | 보관된 완료 작업은? | `completed` | archive/completed-tasks.md:2 | 미실시 | 미실시 |
| 10 | 대체된 결정은? | `superseded` | archive/decisions-deprecated.md:2 | 미실시 | 미실시 |
| 11 | 재시도 관련 제목은? | `retry` | work-log/timeline.jsonl:1 | 미실시 | 미실시 |
| 12 | 지연 관련 보고는? | `backoff` | work-log/timeline.jsonl:1 | 미실시 | 미실시 |
| 13 | 해당 파일 작업은? | `Retry.kt` | work-log/timeline.jsonl:1 | 미실시 | 미실시 |
| 14 | 한글 경로 작업은? | `한글.kt` | work-log/timeline.jsonl:2 | 미실시 | 미실시 |
| 15 | 대문자 검색도 같은가? | `TIMEOUT` | work-log/timeline.jsonl:1 | 미실시 | 미실시 |
| 16 | 두 키워드의 공통 작업은? | `timeout cache` | work-log/timeline.jsonl:1 | 미실시 | 미실시 |
| 17 | 반복된 동일 작업은? | `occurrence` | work-log/timeline.jsonl:3, archive/timeline-old.jsonl:1 | 미실시 | 미실시 |
| 18 | 시각 불명 기록은? | `legacy` | work-log/timeline.jsonl:4 | 미실시 | 미실시 |
| 19 | 공격 문자열 원문은? | `ctxAttack` | work-log/timeline.jsonl:5 | 미실시 | 미실시 |
| 20 | 없는 내용은? | `no-such-term` | 0건 | 미실시 | 미실시 |

## 실제 브라우저 확인 (미실시)

- Chrome/Safari file://에서 검색·IME·키보드 focus·이전/다음·뒤로가기를 확인한다.
- 복사 성공, 권한 거부, API 없음에서 선택/수동 복사가 되는지 확인한다.
- 자동 외부 요청이 없고 HTTP(S) 명시 클릭만 이동하는지 확인한다.
- 기본 12,000자 예산의 Markdown/JSON 성공 여부와 최소 필요 문자를 각각 기록한다.

Node DOM 대역은 브라우저 권한·접근성·그리기를 검증하지 않는다.

## 성능 재현

```bash
python3 -B tests/fixtures/context-read/measure.py
```

55/5천/2만 건, 설정 포함 정확히 20 MiB, 한 줄 1 MiB, 기존 경고 4만 개를 합성 임시 프로젝트로 측정한다. Node가 있으면 내장 JS 초기화/최초 검색/다음 검색/캐시 페이지의 동기 시간과 GC를 강제하지 않은 heap 변화량을 표시한다. 실브라우저 peak heap·paint와 구분한다. 이미지 다운로드·네트워크·패키지 설치는 없다. 실측과 호환성 결과는 구현 결과 문서를 참고한다.
