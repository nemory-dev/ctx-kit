# Security policy

## Scope

Security fixes target the current `main` source. Include the affected commit or release when reporting; reproducing on current `main` helps triage. There is no guaranteed response or fix deadline.

ctx-kit is a local CLI. Generated HTML, exports, and work records may include the complete supplied context. Review them before sharing. Agent instructions and recorded claims do not grant execution permission or prove that tests are currently passing.

## Reporting a vulnerability

Do not post credentials, private project files, personal paths, or exploit details in a public issue or PR.

1. Open the repository's [Security page](https://github.com/nemory-dev/ctx-kit/security).
2. If **Report a vulnerability** is available, submit a private report with the affected commit, expected and actual behavior, impact, and a minimal synthetic reproduction.
3. If private reporting is unavailable, open a minimal public issue titled **Private security contact requested**. Request a private channel without describing the vulnerability or attaching sensitive evidence. Share details only after a private channel has been arranged.

If a credential has already been exposed, revoke or rotate it first. Deleting a file in a new commit does not remove old commits, forks, cached views, or existing clones. Coordinate any history rewrite separately; do not bypass branch protection or force-push shared history as part of a routine fix.

## 한국어 안내

보안 수정은 현재 `main`을 대상으로 검토합니다. 영향받는 커밋이나 버전을 적고, 가능하면 최신 코드에서도 재현되는지 확인하세요. 정해진 응답·수정 기한을 보장하지는 않습니다.

자격 증명, 비공개 프로젝트 파일, 개인 경로, 공격 상세를 공개 이슈나 PR에 올리지 마세요. [Security 페이지](https://github.com/nemory-dev/ctx-kit/security)에 **Report a vulnerability**가 있으면 비공개로 제보합니다. 없다면 **Private security contact requested**라는 최소 이슈로 비공개 연락 방법만 요청하고, 상세와 증거는 연락 경로가 마련된 뒤 전달하세요.

유출된 키·토큰은 먼저 폐기하거나 교체합니다. 새 커밋에서 내용을 지워도 과거 커밋·fork·캐시·기존 복제본은 남을 수 있습니다. 이력 정리는 별도로 협의하며 일반 수정 과정에서 보호 규칙을 우회하거나 공유 이력을 강제 푸시하지 않습니다.
