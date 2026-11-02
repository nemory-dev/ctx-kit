# 회사 PC에서 검색·인수인계 확인하기

이 폴더의 [demo.html](demo.html)은 공개용 합성 데이터로 만든 오프라인 뷰어입니다. 회사 PC에 Git·Python·Bash를 설치하지 않고 브라우저로 확인할 수 있습니다. 실제 프로젝트나 개인 작업 기록은 포함하지 않습니다.

자동 검증의 범위와 수치는 [검증 보고서](../../superpowers/reports/2026-11-02-browser-qa-readiness.md)와 [데모 검증 결과](automated-results.json)에 기록했습니다. 자동 검증 통과를 실제 브라우저 확인 완료로 표시하지 않습니다.

## 파일을 받아서 열기

1. GitHub에서 [demo.html](demo.html) 파일 페이지를 엽니다.
2. 파일의 **Download raw file** 버튼으로 `demo.html`을 저장합니다. GitHub의 소스 미리보기에서는 뷰어가 실행되지 않습니다.
3. 저장한 파일을 Chrome·Edge·Safari 중 사용 가능한 브라우저로 엽니다. 파일을 수정하거나 로컬 서버를 실행할 필요는 없습니다.

파일 하나를 받기 어렵다면 이 문서가 포함된 브랜치의 저장소 페이지에서 **Code → Download ZIP**으로 내려받아 압축을 풀고 `docs/qa/search-handoff/demo.html`을 엽니다. 이 절차는 Windows에서 HTML을 여는 방법이며, Windows의 CLI 실행 호환성을 검증한 것은 아닙니다.

## 우선 확인할 네 가지

사용 가능한 브라우저 하나에서 먼저 확인합니다. Chrome·Edge·Safari를 모두 사용할 필요는 없습니다. 아직 아래 항목의 사람 확인 결과는 기록되지 않았습니다.

| 항목 | 할 일 | 기대 결과 |
| --- | --- | --- |
| 화면 열기 | 파일을 열고 개요·작업 기록·문서·통합 검색·인수인계 탭을 눌러 봅니다. | 프로젝트명은 `ctx-kit-qa-demo`. 작업 기록 61건이 보입니다. Git 관리 밖 표시는 합성 데이터의 정상 상태입니다. |
| 검색과 출처 | 통합 검색에서 `timeout cache`, `한글.kt`, `no-such-term`을 순서대로 입력합니다. 결과를 눌러 원문을 열고 브라우저 뒤로가기를 합니다. | 각각 2건, 1건, 0건. 원문 문서 또는 작업 상세로 이동하고, 뒤로가기로 검색 결과가 복원됩니다. |
| 페이지와 입력 | 통합 검색에서 `page`를 입력하고 다음·이전 페이지를 누릅니다. 한글 입력과 Tab/Enter 조작, 좁은 창에서도 확인합니다. | 55건이 첫 페이지 50건·다음 페이지 5건으로 나뉩니다. 한글 조합과 키보드 조작이 가능하고 버튼·본문이 가려지지 않아야 합니다. |
| 인수인계 복사 | 인수인계 탭에서 복사 버튼을 누르고 빈 텍스트 편집기에 붙여 넣습니다. | 필수 섹션 기재 안내와 원문 출처, 생략 안내가 보입니다. 자동 복사가 불가능하면 선택된 본문을 수동 복사할 수 있어야 합니다. |

`complete`는 필수 섹션이 문서에 기재됐다는 뜻입니다. 데모의 검증·미검증 문구와 작업 완료 기록은 모두 합성 예시이며 실제 테스트 성공이나 실행·변경 승인을 뜻하지 않습니다. 파일을 다시 열어도 최신 저장소나 실제 프로젝트 상태를 자동으로 읽지 않습니다.

다음 양식만 채워 전달해도 됩니다. 이름·회사명·개인 파일 경로는 적지 않습니다.

```text
OS / 브라우저 버전:
파일 열기: 성공 / 불가
검색·출처 이동·뒤로가기: 성공 / 실패
페이지·한글 입력·키보드: 성공 / 실패
복사: 자동 성공 / 수동 성공 / 실패
문제가 있다면 재현 순서와 화면에 나온 오류:
```

## 추가로 확인할 수 있다면

- `occurrence` 검색은 출처가 서로 다른 동일 기록 2건을 유지해야 합니다.
- `ctxAttack` 검색 결과는 시험용 공격 문자열을 텍스트로 보여야 하며 script 실행·알림창이 발생해서는 안 됩니다.
- 문서의 `decisions.md`에서 HTTPS 예제 링크는 명시적으로 클릭할 때만 열려야 합니다.
- 개발자 도구를 사용할 수 있다면, 새로고침·검색·문서 이동만으로 자동 HTTP(S) 요청이 발생하지 않고 예상하지 못한 Console 오류도 없는지 확인합니다.

회사 PC에서 파일 열기나 개발자 도구 사용이 불가능한 항목은 미실시로 남깁니다. 다른 브라우저에서 확인하지 않은 결과를 확대해서 기록하지 않습니다.

이 확인은 브라우저 기능 QA입니다. 처음 보는 사람이 60초 안에 상태·다음 행동·제약·미검증 사항을 이해하는지 평가하는 작업은 [별도의 평가 절차](../../../tests/fixtures/context-read/evaluation.md)를 따릅니다. 위 검색어와 정답을 읽은 뒤 수행한 QA를 처음 보는 사람의 재개 시간으로 집계하지 않습니다.

## 데이터와 재생성

기본 입력은 [평가 corpus](../../../tests/fixtures/context-read/evaluation-corpus.json)입니다. 페이지 이동을 확인하기 위한 합성 로그 55건과 명시적 HTTPS 클릭 확인용 `https://example.com/` 링크만 추가했습니다. 원래 평가 질문의 출처 행은 유지합니다. 데모의 인수인계는 필수 H2 다섯 개가 갖춰져 있으며 기본 5건 외 로그의 생략을 표시합니다.

아래 명령은 개발자가 저장소 루트에서 실행하는 재생성 절차입니다. 회사 PC에서 데모를 열 때는 실행하지 않습니다. 현재 checkout의 `ctx.sh`를 사용하므로 다른 코드 버전으로 재생성하면 HTML과 측정값이 달라질 수 있습니다.

```bash
python3 -B - <<'PY'
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path.cwd()
corpus = json.loads((repo / "tests/fixtures/context-read/evaluation-corpus.json").read_text(encoding="utf-8"))
with tempfile.TemporaryDirectory(prefix="ctx-qa-demo-") as temporary:
    project = Path(temporary) / "ctx-kit-qa-demo"
    project.mkdir()
    shutil.copy2(repo / "ctx.sh", project / "ctx.sh")
    (project / "ctx.config.json").write_text(json.dumps({
        "source": "context/AGENT_RULES.md", "git_sync": {"enabled": False}
    }), encoding="utf-8")
    for name, text in corpus["documents"].items():
        if name == "decisions.md":
            text += "\n[HTTPS example](https://example.com/)\n"
        path = project / "context" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    for name, rows in corpus["logs"].items():
        rows = list(rows)
        if name == "work-log/timeline.jsonl":
            rows += [{"title": "page %03d" % i, "summary": "Synthetic pagination record.",
                      "createdAt": "2026-10-29T00:00:00Z", "type": "work", "files": [],
                      "commit": "pending", "branch": "synthetic", "dirty": False}
                     for i in range(55)]
        path = project / "context" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows), encoding="utf-8")
    result = subprocess.run(["bash", str(project / "ctx.sh"), "view"], cwd=project,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
    if result.returncode:
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace"))
    output = repo / "docs/qa/search-handoff/demo.html"
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(project / "context/generated/view.html", output)
print("docs/qa/search-handoff/demo.html")
PY
```
