# Architecture

```text
[배차표 XLS] ──웹 관리자 업로드──┐
                                 │
[eTAS XLS] ───웹 관리자 업로드──┼──> [Supabase]
                                 │       ├─ users/sessions
                                 │       ├─ dispatch
                                 │       ├─ official eTAS scores
                                 │       ├─ CDT candidates
                                 │       ├─ vehicle change events
                                 │       └─ acknowledgements/audit
                                 │
[E:\...\Data\*.CDT] -> [Windows Collector]
                           │
[TAGO BIS realtime] --------┘

[Netlify Static Web]
  ├─ 관리자: 업로드/모니터링/확인현황
  └─ 기사: 본인 분석/확인
```

## 데이터 신뢰도 계층

1. **공단 eTAS 리포트**: 외부 공식 리포트 원문/점수 보존
2. **CDT 후보 이벤트**: 회사 내부 개선·코칭용 상세 후보
3. **BIS 차량변경**: 공개 실시간 위치 기반 후보, 신뢰도 저장
4. **배차표**: 기사-차량-노선-회차 연결 기준정보

서로 다른 데이터의 의미를 합쳐서 하나의 '공식 점수'로 재산정하지 않습니다.
