# ctx-kit 유사 도구 조사와 고도화 판단

- 조사일: 2026-11-01, Asia/Seoul.
- 대상: `codex/local-context-viewer`, HEAD `6c0eb86` 및 기존 뷰어 검증 문서의 미커밋 보완.
- 사용자 요청: 유사 서비스 조사, 벤치마킹, 통합 검색·근거 있는 인수인계 우선 고도화 계획, Claude 검토.
- 방법: 공식 문서·공개 저장소·논문을 읽고 로컬 구현과 대조했다. 타 제품 설치·실행·가격 비교·동일 조건 성능 비교는 하지 않았다. 제품 설명, 구현 사실, 제안을 구분한다.
- 연결: [설계](../specs/2026-11-01-search-handoff-design.md), [구현 계획](../plans/2026-11-01-search-handoff.md), [Claude 검토와 반영](../reviews/2026-11-01-search-handoff-claude.md).

## 1. 현재 기능과 차별화 가설

ctx-kit은 Bash 3.2/Python 3.7 이상 표준 라이브러리로 동작하며, `ctx.sh`와 설정 두 파일 복사 설치를 유지한다. Markdown·JSONL을 정본으로 두고 로컬 작업 기록, 규칙 링크, 보관, 내보내기, 단일 오프라인 HTML을 제공한다.

`ctx.sh`에서 확인한 사실:

| 코드 위치 (6c0eb86 기준) | 현재 동작 | 고도화 기회 |
| --- | --- | --- |
| `cmd_export`, 약 1125행 | 고정 문서와 최근 작업 10건, `--all`로 보관 이력 추가 | 목적별 선별과 출력 예산 |
| `collect_snapshot`, 약 2616행 | 허용 문서·JSONL 수집, 잠금·손상·archive 검사, 원문 보존 | 같은 수집 결과에서 검색과 인수인계 파생 |
| 항목 키, 약 2676행 | `sourcePath:sourceLine` | 스냅샷 안의 발생 참조로 사용. 영구 ID로 오표시하지 않기 |
| `searchValues`, 약 3392행 | 로그 제목·요약·파일명 검색 | 허용 문서 본문까지 통합 검색 |
| `renderDetail`, 약 3650행 | 문서·당시 보고·생성 시점 Git을 구분 | 인수인계에도 같은 근거 수준 유지 |

차별화 가설은 **여러 에이전트 사이에서 사람이 확인 가능한 근거·제약·미검증 사항을 작게 전달하는 로컬 재개 도구**다. 단일 HTML 자체의 독창성이나 시장 수요를 입증한 것은 아니다.

## 2. 비교 대상

| 도구 | 공식 자료에서 확인한 기능 | 가져올 설계 | 도입 비용·차이 |
| --- | --- | --- | --- |
| [projectmem](https://github.com/riponcm/projectmem) | 이슈·시도·수정·결정 JSONL, 요약, HTML 시각화, MCP, 파일별 과거 실패 안내 | 실패 이력 연결, 간결한 재개 문서, 사전 주의사항 | 가장 가까운 비교 대상. 훅·watcher·MCP가 범위에 포함됨 |
| [SpecStory](https://docs.specstory.com/) | 여러 에이전트의 세션을 로컬 Markdown으로 저장, 과거 세션 변환·검색·재개, 클라우드 공유 | 에이전트·세션 출처, 수집 어댑터, 이전 맥락 찾기 | 대화 전문의 크기·민감정보·형식 변화 관리 |
| [Claude-Mem](https://docs.claude-mem.ai/architecture/overview) | 활동 수집, 모델 처리, worker, SQLite/FTS5, 선택적 Chroma, 웹 UI | 검색 목록 → 주변 타임라인 → 선택 상세 | 상주 프로세스와 모델 처리 경로가 추가됨 |
| [Basic Memory](https://docs.basicmemory.com/start-here/what-is-basic-memory) | Markdown 정본, 검색 인덱스, 관계 그래프, MCP | 편집 가능한 원본과 파생 검색 계층 분리 | 파일·인덱스 일관성 관리 |
| [Beads](https://github.com/gastownhall/beads) | 의존성, `ready`, 작업 선점, 구조화된 작업 기억. 현재 Dolt 기반 | 막힌 작업과 시작 가능한 작업 구분 | 작업 관리 스키마와 저장 계층 확장 |
| [Entire](https://github.com/entireio/cli) | 커밋에 연결된 세션 checkpoint, Trails의 의도·리뷰·CI·승인 | 명시적인 변경 이유·세션·커밋 연결 | Git 훅·checkpoint·동기화·호스팅 기능 |
| [Rulesync](https://github.com/dyoshikawa/rulesync), [Ruler](https://github.com/intellectronica/ruler) | 공통 규칙을 도구별 설정으로 생성·배포, 기능·경로 차이 관리 | 호환성 표, 적용 전 진단, 생성물 출처 | 링크 존재·형식 적합·실제 로딩을 구분해야 함 |
| [Repomix](https://repomix.com/guide/) | 수집 범위, Git 제외 규칙, 토큰 수, 보안 검사 | 선별 내보내기, 크기 표시, 공유 전 검사 | 저장소 패키징 중심 |
| [OpenMemory](https://mem0.ai/openmemory) | 프로젝트별 기억, 종류·가시성·접근 기록 | 기억을 누가 언제 사용했는지 관측 | 추가 서비스·연동·권한 관리 |
| [Hindsight](https://hindsight.vectorize.io/) | retain/recall/reflect, 메모리 저장·검색·추론 분리 | 원본·검색·AI 해석의 책임 분리 | 모델·저장소·서버 또는 임베디드 런타임 |
| [Graphiti/Zep](https://www.getzep.com/platform/graphiti/) | 사실의 유효 시점·출처·대체 이력, 하이브리드 검색 | 오래된 결정과 재검증 필요 표시 | 그래프·모델·검색 운영 |
| [Serena](https://github.com/oraios/serena) | 심볼·참조 기반 코드 도구, 장기 작업 메모리 | 코드 이해가 필요할 때 연동 검토 | 언어 서버·IDE 연동. 이번 우선 범위 밖 |

Claude Code 자체에도 지침 파일과 자동 메모리가 있다. 별도 도구 채택 이유는 도구 간 이동성·확인 가능한 출처·인수인계 품질에서 검증해야 한다. [공식 메모리 문서](https://code.claude.com/docs/en/memory)

## 3. 벤치마킹 판단

### 이번 우선 범위

1. 통합 검색: 기존 허용 문서와 모든 작업 발생을 함께 검색하고 근거 위치로 이동.
2. 근거 있는 인수인계: 현재 상태·다음 행동·명시된 제약·검증/미검증 기재·선별 기록에 출처를 부착.
3. 필요한 정보만 제공: 전체 이력은 보존하되 선택 수·예산에 따른 생략을 명시.

### 후속 범위

- 읽기 전용 진단: 버전, 경로, 규칙 충돌, 훅·worktree 상태를 진단. 실제 에이전트 준수를 보증하지 않음.
- 결정·실패 관계: 명시적 연결, 선택적 신규 필드와 안정적인 발생 ID를 별도 설계.
- 유효성 표시: 관련 파일 변경을 `재확인 필요`로 표시. 의미상 오류를 자동 판정하지 않음.
- 선택적 MCP: 핵심 CLI와 분리한 읽기 전용 어댑터.
- 수집 연동: 이미 있는 수집 도구의 결과를 명시적으로 가져오기. 사용자 홈의 세션을 자동 수집하지 않음.

### 이번에 추가하지 않는 것

서버, DB, LLM 요약, 임베딩·RAG, 코드 분석, watcher, 기록 편집, 작업 실행, 규칙 자동 변경, 팀 동기화, 대화 전문 수집, 새로운 런타임 의존성. 이 조사에서 다룬 제품 전체를 재구현하지 않는다.

## 4. 근거 수준과 보안에서 배울 점

- Claude-Mem의 [단계적 조회](https://docs.claude-mem.ai/usage/search-tools)는 인덱스·주변 맥락·상세를 나눠 읽게 한다. 문서의 토큰 절감 수치를 ctx-kit의 실측으로 사용하지 않는다.
- PROJECTMEM 최신 논문 v2는 저자 실행 연구와 지연 측정을 보고하며, 실패 이력의 존재가 실패 예방 효과의 증거는 아니라고 구분한다. [논문 v2](https://arxiv.org/abs/2606.12329v2). 구 버전 검색 요약의 207건 수치를 최신 결과로 재사용하지 않는다.
- SpecStory는 로그인 상태에서 클라우드 동기화가 활성화될 수 있다. [CLI 기본 동작](https://docs.specstory.com/integrations/terminal-coding-agents/usage).
- Entire는 checkpoint가 Git 원격에 업로드되는 경로와 best-effort 비밀정보 제거의 한계를 설명한다. [보안·개인정보](https://github.com/entireio/cli#security--privacy).
- Repomix의 Secretlint 검사는 참고 대상이지만, ctx-kit이 같은 검사를 제공한다고 표시하지 않는다. [보안 검사](https://repomix.com/guide/security).
- 가져온 기록·요약은 권한을 부여하는 지침이 아니다. 출처·검토 상태·검색 범위와 실행 승인을 분리한다. [메모리 오염 방어](https://www.getzep.com/blog/defending-agent-memory-poisoning/).

공유용 결과에는 제외 데이터를 처음부터 넣지 않아야 한다. HTML에서 접거나 숨긴 데이터도 파일에 들어 있으면 공유된다. 이번 인수인계 출력은 선택적 파생물이며 개인정보 마스킹 도구가 아니다. 기존 전체 뷰어의 포함 범위를 조용히 바꾸지 않는다.

## 5. 평가 계획

| 항목 | 평가 방법 | 성격 |
| --- | --- | --- |
| 사람의 재개 시간 | 처음 보는 사람이 상태·다음 행동·미검증 사항을 정확히 설명할 때까지 측정, 60초 목표 | 아직 사람 평가 미실시 |
| 검색 품질 | 질문·필수 출처 20개, 상위 5개 결과 근거 포함률 | 제안 목표 18/20 이상 |
| 인수인계 누락 | 지원하는 명시적 섹션의 제약·미검증 항목이 예산 때문에 잘리지 않는지 | 자동 fixture + 사람 검토 |
| 잘못된 확신 | pending·당시 성공 보고·문서 기재를 현재 검증으로 승격하는 사례 0 | 회귀 계약 |
| 참조 | 반복 발생 구분, 스냅샷·파일 hash·행 범위로 원문 검증 | archive 이후 영구 ID 보장과 구분 |
| 성능 | 5천/2만 건, 최대 20 MiB, 생성·검색·DOM·HTML 크기 | 생성 3초/5천 건 검색 200ms 잠정 목표 |
| 보호 | 실패 시 원본·기존 출력 보존, 생성·열람 중 자동 외부 요청 0 | 기존 계약 유지 |

같은 자료의 Markdown/JSONL과 HTML을 비교하되 첫 노출과 두 번째 열람의 학습 효과를 구분한다. 도구의 공식 기능 설명을 실행 성능·보안 완전성 검증으로 표현하지 않는다.

## 6. 채택 방향

로컬 재개·인수인계 기능을 먼저 개선하고 실제 재개 시간과 누락률을 측정한다. 공통 수집·출처 모델 위에 CLI와 HTML을 제공한다. MCP·관계 모델·의미 검색은 이 결과에서 필요성이 확인되면 별도 계획으로 진행한다.

이번 문서는 조사 기록이다. 구현 완료·사람 평가 완료·외부 서비스 도입 승인을 뜻하지 않는다.
