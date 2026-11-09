"""Fail-closed DOM adapter. Live eTAS compatibility is NOT certified.
Profile selectors are optional overrides; exact visible labels are tried first.
No website writes: only query, report opening and downloads.
"""
import json,re,time
from pathlib import Path

class EtasAdapter:
    def __init__(self,context,profile=None):self.context=context;self.profile=profile or {};self.page=context.pages[0] if context.pages else context.new_page();self.current=None
    def open(self):self.page.goto('https://etas.kotsa.or.kr',wait_until='domcontentloaded')
    def one(self,page,key,pattern=None):
        matches=[]
        for frame in page.frames:
            loc=frame.locator(self.profile[key]) if self.profile.get(key) else frame.get_by_text(pattern,exact=True)
            for i in range(loc.count()):
                item=loc.nth(i)
                if item.is_visible():matches.append(item)
        if len(matches)!=1:raise RuntimeError(f'{key}: 화면 연결을 확인하세요. 일치하는 요소 {len(matches)}개 (관리자/개발자 연결 설정 필요)')
        return matches[0]
    def select_month(self,month):
        y,m=month.split('-');p=self.page
        # Never assume selector positions. Infer from full option sets or explicit profile.
        for key,value,kind in [('year',y,'year'),('month',m,'month')]:
            candidates=[]
            for f in p.frames:
                loc=f.locator(self.profile[key]) if self.profile.get(key) else f.locator('select')
                for i in range(loc.count()):
                    s=loc.nth(i)
                    if not s.is_visible():continue
                    options=s.locator('option').evaluate_all('(els)=>els.map(x=>({label:x.textContent.trim(),value:x.value}))')
                    nums=[re.sub(r'\D','',o['label']) for o in options]
                    valid=any(n==y for n in nums) if kind=='year' else set(nums)>=set(f'{n:02}' for n in range(1,13)) or set(nums)>=set(str(n) for n in range(1,13))
                    if valid:
                        found=[o for o,n in zip(options,nums) if n and int(n)==int(value)]
                        if len(found)==1:candidates.append((s,found[0]['value']))
            if len(candidates)!=1:raise RuntimeError(f'{key}: 조회연도/월 선택 요소를 특정하지 못했습니다.')
            candidates[0][0].select_option(candidates[0][1])
        self.one(p,'query','조회').click();p.wait_for_timeout(1000)
        # Wait for result month marker, not just the changed selector.
        marker=re.compile(re.escape(y)+r'년\s*0?'+str(int(m))+r'월.*검색 결과')
        deadline=time.time()+60
        while time.time()<deadline:
            if any(marker.search(f.locator('body').inner_text()) for f in p.frames):self.current=month;return
            p.wait_for_timeout(500)
        raise RuntimeError('조회 결과의 분석월 확인 실패 또는 로그인 만료')
    def find_driver(self,name):
        pattern=re.compile('^'+re.escape(name)+r'\s*\([^()]+\)$');p=self.page
        seen=set()
        for _ in range(100):
            for f in p.frames:
                loc=f.get_by_role('link',name=pattern)
                if loc.count()==1:return loc
                if loc.count()>1:raise RuntimeError('동일 기사 링크 중복: 관리자 확인 필요')
            # Numeric pagination only; do not navigate by guessed URL.
            nums=[]
            for f in p.frames:
                for link in f.get_by_role('link',name=re.compile(r'^\d+$')).all():
                    label=link.inner_text().strip()
                    if link.is_visible() and label not in seen:nums.append((int(label),link))
            if not nums:break
            n,link=sorted(nums,key=lambda x:x[0])[0];seen.add(str(n));link.click();p.wait_for_timeout(1000)
        raise RuntimeError('선택 월 기사 링크를 찾지 못했습니다. 자료 없음/명단/페이지 연결을 관리자에게 확인하세요.')
    def collect(self,task,tempdir):
        if self.current!=task['month']:self.select_month(task['month'])
        link=self.find_driver(task['name']);original=list(self.context.pages)
        detail=None;viewer=None
        try:
            with self.context.expect_page(timeout=30000) as popup:link.click()
            detail=popup.value;detail.wait_for_load_state('domcontentloaded');detail.wait_for_timeout(1000)
            button=self.one(detail,'file_download','파일다운로드')
            button.click();detail.wait_for_timeout(1500)
            candidates=[p for p in self.context.pages if p not in original and p!=detail]
            viewer=candidates[-1] if candidates else detail
            viewer.wait_for_load_state('domcontentloaded')
            if self.profile.get('export_open'):self.one(viewer,'export_open').click()
            else:
                found=[]
                for f in viewer.frames:
                    for x in f.get_by_role('button',name=re.compile(r'^(저장|파일 저장|Save)$',re.I)).all():
                        if x.is_visible():found.append(x)
                if len(found)!=1:raise RuntimeError('보고서 저장 아이콘 연결 설정(export_open)이 필요합니다. 수동 등록은 사용할 수 있습니다.')
                found[0].click()
            target='pdf' if task['kind']=='pdf' else 'xlsx';selects=[]
            for f in viewer.frames:
                loc=f.locator(self.profile['format']) if self.profile.get('format') else f.locator('select')
                for s in loc.all():
                    if not s.is_visible():continue
                    options=s.locator('option').evaluate_all('(es)=>es.map(x=>({t:x.textContent,v:x.value}))')
                    options=[o for o in options if ('*.'+target) in o['t'].lower()]
                    if len(options)==1:selects.append((s,options[0]['v']))
            if len(selects)!=1:raise RuntimeError('저장 형식 선택 확인 필요')
            selects[0][0].select_option(selects[0][1])
            # Set filename only where default report is present or selector explicitly configured.
            for f in viewer.frames:
                loc=f.locator(self.profile['filename']) if self.profile.get('filename') else f.locator('input:visible')
                for x in loc.all():
                    try:
                        if self.profile.get('filename') or x.input_value()=='report':x.fill(f"{task['name']}({task['month']})");break
                    except Exception:pass
            self.one(viewer,'all_pages','전체 페이지').click()
            with viewer.expect_download(timeout=180000) as downloaded:self.one(viewer,'save','저장').click()
            d=downloaded.value
            if d.failure():raise RuntimeError('다운로드 실패: '+d.failure())
            path=Path(tempdir)/f"{task['id']}.{target}";d.save_as(str(path));return path
        finally:
            for p in list(self.context.pages):
                if p not in original:p.close()
