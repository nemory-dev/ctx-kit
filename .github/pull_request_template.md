## Problem and resulting behavior / 문제와 변경 후 동작

Explain why the change is needed and what a user will observe.

## Changes / 주요 변경

List the focused changes and any compatibility or storage-format impact.

## Validation / 검증

Record exact commands and results. Mark checks that were not run and explain why. For browser checks, include OS/browser, tested commit, steps, and results.

- `bash -n ctx.sh`:
- `python3 -B -m unittest discover -s tests -v`:
- `git diff --check`:
- Other checks or remaining limitations:

## Contribution checklist / 기여 확인

- [ ] The diff contains only the intended change, with no credentials, personal contact details, private paths, or real project context.
- [ ] Relevant English/Korean documentation is updated, or the reason it is unchanged is explained.
- [ ] Behavioral fixes include a meaningful regression test, or the reason one is not applicable is explained.
- [ ] The reported validation reflects what actually ran; untested platforms and manual checks remain explicit.

Security vulnerabilities should use [SECURITY.md](https://github.com/nemory-dev/ctx-kit/blob/main/SECURITY.md), not a public PR with sensitive details.
