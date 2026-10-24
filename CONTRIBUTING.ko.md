# ctx-kit에 기여하는 방법

[English](CONTRIBUTING.md) · [README](README.ko.md) · [CLI 사용 흐름](docs/ko/workflows.md) · [문제 해결](docs/ko/troubleshooting.md)

ctx-kit 저장소를 수정하고 검증한 뒤 PR과 머지를 거치는 절차입니다. 다른 프로젝트에 ctx-kit을 설치하려면 [시작하기](docs/ko/getting-started.md)를 참고하세요.

## 준비 사항

- Bash, 기본 Unix 도구, Git. 아래 절차는 macOS 또는 Linux에서 실행합니다.
- CI와 맞춘 Python **3.11**. 테스트는 표준 라이브러리만 사용합니다.
- GitHub 계정. PR·검사·머지에 GitHub 웹 UI를 사용하면 [GitHub CLI](https://cli.github.com/manual/)는 선택 사항입니다. CLI 예시는 `gh auth status`가 성공한 상태를 가정합니다.

명령은 저장소 루트에서 실행합니다. 테스트가 임시 프로젝트를 만들므로 이 체크아웃에서 `ctx.sh init`을 실행할 필요는 없습니다.

## CI와 main 보호 정책

[CI 설정](.github/workflows/ci.yml)은 PR 생성·다시 열기·새 커밋 푸시와 `main` 푸시에서 실행됩니다. 문서 변경도 CI를 실행합니다. 각 작업은 Python 3.11로 `bash -n ctx.sh` 다음 전체 unittest를 실행합니다.

| 실행 환경 | 필수 검사 이름 |
| --- | --- |
| `ubuntu-latest` | `Regression tests (ubuntu-latest)` |
| `macos-latest` | `Regression tests (macos-latest)` |

두 작업이 모두 성공해야 합니다. 한 작업이 실패해도 다른 작업은 취소되지 않으며, 각 작업의 제한 시간은 10분입니다. 로그에 도구 버전이 표시되고 `-latest` 실행 환경 이미지는 바뀔 수 있습니다. Windows는 이 CI 매트릭스에 포함되지 않습니다.

**2026-10-25**에 확인한 원본 저장소의 `main` 정책은 다음과 같습니다.

- 관리자 변경을 포함한 모든 변경은 PR을 거칩니다. PR 우회 예외는 설정되어 있지 않습니다.
- GitHub Actions가 제공하는 위 두 검사가 모두 필수이며, 머지 전에 최신 `main` 변경을 반영해야 합니다.
- **필수 리뷰 승인 인원은 0명**입니다. 형식적인 승인은 필수가 아니지만 PR과 CI 조건은 그대로 적용됩니다. 머지 전에 리뷰 의견을 처리하세요.
- `main` 강제 푸시와 삭제를 허용하지 않습니다.

브랜치 보호는 워크플로 YAML과 별개인 [GitHub 저장소 설정](https://github.com/nemory-dev/ctx-kit/settings/branches)입니다. 워크플로를 다른 저장소에 복사해도 해당 저장소의 보호 정책은 설정되지 않습니다. CI 작업 이름을 바꾸는 관리자는 필수 검사 이름도 일치시켜야 합니다. GitHub의 [보호 브랜치 문서](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)를 참고하세요.

## 1. 작업 브랜치 만들기

쓰기 권한이 있다면 새 디렉터리에 원본 저장소를 복제합니다.

```bash
git clone https://github.com/nemory-dev/ctx-kit.git
cd ctx-kit
```

쓰기 권한이 없다면 GitHub에서 fork를 만든 뒤 자신의 fork를 복제합니다. GitHub CLI를 사용한다면 `ctx-kit` 디렉터리가 없는 상위 디렉터리에서 다음을 실행합니다.

```bash
gh repo fork nemory-dev/ctx-kit --clone
cd ctx-kit
git remote -v
```

fork를 사용하면 `origin`이 자신의 fork를, `upstream`이 `nemory-dev/ctx-kit`을 가리키는지 확인하세요. `upstream`이 없다면 `git remote add upstream https://github.com/nemory-dev/ctx-kit.git`으로 추가합니다. 아래 블록의 `BASE_REMOTE`는 fork일 때 `upstream`, 그 외에는 `origin`으로 지정합니다. 이미 체크아웃이 있다면 여기부터 시작하되 브랜치 전환 전에 기존 변경을 확인하세요. 예시 대신 고유한 브랜치 이름을 정하고 가이드 전체에서 사용합니다.

```bash
BASE_REMOTE=origin
git status --short
git fetch "$BASE_REMOTE"
git switch main
git merge --ff-only "${BASE_REMOTE}/main"
git switch -c codex/my-change
```

전환이나 fast-forward가 실패하면 표시된 로컬 작업 또는 갈라진 이력을 확인한 뒤 진행하세요. 기존 파일과 미완료 작업을 보존합니다.

## 2. 수정하고 로컬 검증하기

변경을 필요한 범위로 제한하고 기존 패턴을 따릅니다. 버그 수정에는 수정 전 실패하는 회귀 테스트를 포함하세요. 한글·영문 문서는 함께 맞춥니다. 에이전트 규칙을 바꾸면 루트 `AGENT_RULES.md`와 `ctx.sh`의 내장 템플릿을 모두 수정하세요. 초기화 테스트가 두 내용을 비교합니다.

```bash
bash -n ctx.sh
python3 -B -m unittest discover -s tests -v
git diff --check
```

모든 명령이 성공하고 테스트 요약이 `OK`로 끝나야 합니다. 실패 원인을 확인하고 수정한 뒤 푸시하세요. 테스트는 중단된 쓰기와 동시 쓰기를 포함한 CLI 동작을 검증하며, AI가 지침을 준수한다는 것을 증명하지는 않습니다.

## 3. 검토한 파일만 커밋·푸시하기

diff와 새 파일을 편집기에서 확인합니다. 관련 없는 로컬 파일과 개인 컨텍스트가 커밋에 들어가지 않도록 파일 경로를 명시해 스테이징하세요. 문서 수정 예시는 다음과 같습니다.

```bash
git add -- README.md README.ko.md CONTRIBUTING.md CONTRIBUTING.ko.md
git diff --cached --check
git diff --cached
git commit -m "docs: clarify the contribution workflow"
git push -u origin HEAD
```

파일 목록과 메시지는 실제 변경에 맞게 바꿉니다. 커밋 전에 스테이징된 diff를 확인하고, `main` 대신 작업 브랜치를 푸시하세요. fork에서는 `BASE_REMOTE`가 `upstream`이어도 `origin`은 자신의 fork입니다.

## 4. main 대상 PR 만들기

`git push`가 출력한 링크를 열거나 [GitHub CLI로 PR을 생성](https://cli.github.com/manual/gh_pr_create)합니다.

```bash
PR_SOURCE=codex/my-change
gh pr create --repo nemory-dev/ctx-kit --base main --head "$PR_SOURCE"
```

fork라면 `PR_SOURCE`를 `YOUR_LOGIN:codex/my-change`로 지정하고, `YOUR_LOGIN`은 fork 소유자의 GitHub 로그인으로 바꾸세요. 명령이 제목·본문을 입력받고 PR URL을 출력합니다. 해결할 문제, 바뀐 동작, 수행한 검증, 남은 제약을 적습니다.

## 5. PR 검사와 최신 main 반영하기

`123`을 생성한 PR 번호로 바꿉니다. PR의 head 커밋을 저장하고 [필수 검사를 기다립니다](https://cli.github.com/manual/gh_pr_checks).

```bash
PR_NUMBER=123
PR_HEAD=$(gh pr view "$PR_NUMBER" --repo nemory-dev/ctx-kit --json headRefOid --jq .headRefOid)
gh pr checks "$PR_NUMBER" --repo nemory-dev/ctx-kit --required --watch --fail-fast
```

GitHub에서 현재 PR 커밋의 두 필수 검사 이름이 모두 성공인지 확인합니다. 대기 중인 작업, 없는 검사, 로컬 테스트 결과는 PR 검사 통과가 아닙니다. 새 댓글을 읽고 필요한 피드백을 반영하세요. 새 커밋을 푸시했다면 `PR_HEAD`를 다시 저장하고 새 결과를 기다립니다.

GitHub에서 `main`보다 뒤처졌다고 표시하면 작업 브랜치에 머문 채 최신 기준 브랜치를 머지합니다.

```bash
git fetch "$BASE_REMOTE"
git merge --no-edit "${BASE_REMOTE}/main"
```

충돌이 생기면 해결한 파일만 스테이징하고 머지 커밋을 완료한 뒤 계속합니다. 2단계의 로컬 검증 명령 세 개를 다시 실행하고, `git push origin HEAD`로 작업 브랜치를 푸시한 뒤 PR 검사 블록을 반복하세요. 보호 정책은 갱신된 결과를 요구하므로 우회하지 않습니다.

## 6. 검증한 PR 머지하기

머지 권한이 있는 관리자는 최종 diff·리뷰 의견·현재 CI 두 결과를 확인한 뒤 GitHub 머지 버튼이나 다음 명령을 사용합니다.

```bash
gh pr merge "$PR_NUMBER" --repo nemory-dev/ctx-kit --merge --match-head-commit "$PR_HEAD"
gh pr view "$PR_NUMBER" --repo nemory-dev/ctx-kit --json state,mergedAt,mergeCommit
```

5단계에서 검증한 `PR_HEAD`를 유지하세요. [head 일치 옵션](https://cli.github.com/manual/gh_pr_merge)은 PR이 바뀌면 머지를 거부합니다. 새 커밋을 검토하고 검증을 반복하세요. PR 상태가 `MERGED`일 때만 계속하고, 머지 명령이 오류를 보고하면 다른 시도 전에 PR 상태를 조회하세요. `--admin`을 사용하거나 보호 설정을 꺼서 조건을 건너뛰지 않습니다. 머지 권한이 없는 기여자는 관리자의 처리를 기다립니다.

## 7. main 푸시 CI 확인하기

머지하면 `main`의 머지 커밋을 대상으로 별도의 CI가 시작됩니다. PR CI 성공만으로 이후 실행을 검증한 것은 아닙니다. 머지 SHA·브랜치·이벤트로 실행을 찾습니다.

```bash
MERGE_SHA=$(gh pr view "$PR_NUMBER" --repo nemory-dev/ctx-kit --json mergeCommit --jq .mergeCommit.oid)
gh run list --repo nemory-dev/ctx-kit --workflow ci.yml --branch main --event push --commit "$MERGE_SHA" --json databaseId,status,conclusion,url
```

목록이 비어 있으면 잠시 기다린 뒤 다시 조회합니다. 아래 `456`은 반환된 `databaseId`로 바꾸세요. PR 번호가 아니라 워크플로 실행 ID입니다.

```bash
RUN_ID=456
gh run watch "$RUN_ID" --repo nemory-dev/ctx-kit --exit-status --interval 10
```

전체 실행과 두 OS 작업이 성공하고 **Check Bash syntax**·**Run regression tests** 단계가 모두 통과했는지 확인합니다. 브라우저에서는 [Actions](https://github.com/nemory-dev/ctx-kit/actions/workflows/ci.yml)의 해당 실행을 확인하세요. 실패하면 실패 단계의 로그를 읽고 새 PR로 수정합니다.

## 8. 로컬 main 최신화와 브랜치 정리하기

PR이 머지되고 `main` 푸시 CI도 성공하면 작업 트리의 변경을 검토한 뒤 다음을 실행합니다.

```bash
git fetch "$BASE_REMOTE"
git switch main
git merge --ff-only "${BASE_REMOTE}/main"
git branch -d codex/my-change
git push origin --delete codex/my-change
git status --short
```

실제 작업 브랜치 이름을 사용하고, 원격 브랜치가 이미 삭제되었다면 원격 삭제는 건너뜁니다. 예시의 머지 방식은 `git branch -d`가 확인하는 조상 관계를 유지합니다. 삭제가 거부되면 강제하지 말고 이력을 확인하세요. 관련 없는 미추적 파일과 개인 컨텍스트는 그대로 둡니다.

## 문제 해결

| 증상 | 다음 행동 |
| --- | --- |
| `main` 직접 푸시 거부 | 작업 브랜치를 푸시하고 PR을 만드세요. 정상적인 보호 동작입니다. |
| 필수 검사 대기 또는 누락 | PR의 Actions 실행에서 정확한 두 검사 이름을 기다립니다. 관리자는 fork 실행 승인 여부와 저장소 Actions 설정도 확인합니다. |
| 필수 검사 실패 | 실패 단계 로그를 읽고 로컬 명령으로 재현한 뒤 원인을 수정해 새 커밋을 푸시합니다. |
| PR이 최신 main을 반영하지 않음 | 5단계에서 충돌을 해결하고 새 CI 결과를 기다립니다. |
| head가 바뀌어 머지 실패 | 새 변경을 검토하고 head를 다시 저장한 뒤 PR 검사를 반복합니다. |
| CLI로 검사 조회·실행 감시 불가 | `gh auth status`와 저장소 접근 권한을 확인하거나 GitHub 웹 UI에서 PR·Actions 실행을 봅니다. |
| 머지 후 main 푸시 CI 실패 | 해당 push 실행 로그를 확인하고 실패를 공유한 뒤 새 PR로 수정합니다. |

ctx-kit 컨텍스트 저장과 규칙 링크 문제는 [CLI 문제 해결 가이드](docs/ko/troubleshooting.md)를 참고하세요.
