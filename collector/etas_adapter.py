"""Fail-closed DOM adapter. Live eTAS compatibility is NOT certified.
Profile selectors are optional overrides; exact visible labels are tried first.
No website writes: only query, report opening and downloads.
"""
import json,re,time
from pathlib import Path
from etas_dom import BUTTONS_SCRIPT

class ConnectionError(RuntimeError):pass
class ItemError(RuntimeError):pass
class Cancelled(RuntimeError):pass

def driver_label(text):
    match=re.fullmatch(r'\s*([^()]+?)\s*\(([^()]+)\)\s*',text)
    return (match[1].strip(),match[2].strip()) if match else None

def download_suffix(kind,filename):
    expected='.pdf' if kind=='pdf' else '.xls'
    actual=Path(filename).suffix.lower()
    if actual!=expected:raise ItemError(f'다운로드 형식 불일치: 기대 {expected}, 실제 {actual or "확장자 없음"}. 파일을 변환하거나 확장자만 바꾸지 않습니다.')
    return expected

def result_month_matches(text, month):
    y,m=month.split('-')
    return re.search(re.escape(y)+r'\s*년\s*0?'+str(int(m))+r'\s*월\s*(?:의\s*)?검색\s*결과',text) is not None

class EtasAdapter:
    def __init__(self,context,profile=None,progress=None,stop=None,timeout=300):
        self.context=context;self.profile=profile or {};self.page=context.pages[0] if context.pages else context.new_page();self.current=None
        self.progress=progress or (lambda msg:None);self.stop=stop;self.timeout=timeout
        self.viewer=None;self.active_task=None;self.owned=[];self.stage='준비'
        context.on('page',self.enlarge)
        self.enlarge(self.page)
    def status(self,message):
        self.stage=message;self.progress(message)
    def tick(self):
        if self.stop and self.stop.is_set():raise Cancelled('관리자 일시중지')
        pages=[p for p in self.context.pages if not p.is_closed()]
        if not pages:raise ConnectionError('공단 브라우저가 닫혔습니다.')
        pages[0].wait_for_timeout(200)
    def wait(self,probe,message,seconds=None):
        end=time.monotonic()+(self.timeout if seconds is None else seconds)
        while time.monotonic()<end:
            if self.stop and self.stop.is_set():raise Cancelled('관리자 일시중지')
            try:result=probe()
            except (ConnectionError,ItemError,Cancelled):raise
            except Exception:result=None  # Frame may be replaced while a query/popup loads.
            if result:return result
            self.tick()
        raise ConnectionError(message)
    def enlarge(self,page):
        session=None
        try:
            session=self.context.new_cdp_session(page)
            window=session.send('Browser.getWindowForTarget')
            session.send('Browser.setWindowBounds',{'windowId':window['windowId'],'bounds':{'windowState':'maximized'}})
        except Exception:
            pass  # Window managers can reject resizing; collection must still work.
        finally:
            if session:
                try:session.detach()
                except Exception:pass
    def use_query_page(self):
        candidates=[]
        for p in self.context.pages:
            if p.is_closed():continue
            for f in p.frames:
                try:
                    if f.get_by_text('개인별 종합진단표',exact=False).count() and f.locator('select:visible').count()>=2:
                        candidates.append(p);break
                except Exception:continue
        if len(candidates)!=1:
            raise RuntimeError('종합진단표 조회 화면을 하나만 열어주세요. 수집기가 연 브라우저에서 로그인 후 이동해야 합니다.')
        self.page=candidates[0]
        return self.page
    def open(self):self.page.goto('https://etas.kotsa.or.kr',wait_until='domcontentloaded')
    def matches(self,page,key):
        matches=[]
        for frame in page.frames:
            try:
                selectors=[self.profile[key]] if self.profile.get(key) else frame.evaluate(BUTTONS_SCRIPT,key)
                for selector in selectors:
                    for item in frame.locator(selector).all():
                        if item.is_visible():matches.append(item)
            except Exception as e:
                if 'selector' in str(e).lower():raise ConnectionError(f'{key}: 저장된 연결 설정을 다시 지정하세요.') from e
        return matches
    def one(self,page,key,pattern=None):
        def probe():
            found=self.matches(page,key)
            if len(found)>1:raise ConnectionError(f'{key}: 대상 {len(found)}개. 요소를 다시 지정하세요.')
            return found[0] if found else None
        return self.wait(probe,f'{key}: 버튼을 찾지 못했습니다. 화면에서 해당 요소를 지정하세요.',30)
    def select_month(self,month):
        self.close_report();self.current=None
        y,m=month.split('-');p=self.use_query_page();self.status(f'{month} 연도·월 선택 및 조회')
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
        self.one(p,'query','조회').click()
        # Wait for result month marker, not just the changed selector.
        def ready():
            for f in p.frames:
                try:
                    if result_month_matches(f.locator('body').inner_text(timeout=1000),month):return True
                except Exception:pass
        self.wait(ready,'조회 결과 분석월 확인 실패. 로그인 상태와 조회 연결을 확인하세요.')
        self.current=month
    def check_query(self,month):
        self.current=None
        self.select_month(month)
        return f'{month} 조회 결과 확인 완료. 기사 한 명의 PDF와 Excel을 먼저 시험하세요.'
    def region(self,key):
        found=[]
        for f in self.page.frames:
            if self.profile.get(key):loc=f.locator(self.profile[key])
            elif key=='driver_list':loc=f.locator('table').filter(has_text=re.compile(r'운전자\s*이름'))
            else:raise ConnectionError('기사 목록 아래 페이지 번호를 [페이지 영역]으로 먼저 지정하세요.')
            for x in loc.all():
                if x.is_visible():found.append(x)
        if len(found)!=1:raise ConnectionError(f'{key}: 영역 {len(found)}개. 첫 연결 도움에서 다시 지정하세요.')
        return found[0]
    def drivers(self):
        found=[]
        for link in self.region('driver_list').locator('a').all():
            if link.is_visible():
                label=driver_label(link.inner_text())
                if label:found.append((label,link))
        return found
    def signature(self):return tuple(sorted(label for label,_ in self.drivers()))
    def page_links(self):
        return [(int(x.inner_text().strip()),x) for x in self.region('pagination').locator('a').all()
                if x.is_visible() and re.fullmatch(r'\d+',x.inner_text().strip())]
    def page_numbers(self):
        return set(self.region('pagination').locator('a,span,strong,b,em').evaluate_all(
            "els=>els.filter(x=>!x.querySelector('a,span,strong,b,em') && /^\\d+$/.test(x.textContent.trim())).map(x=>Number(x.textContent.trim()))"))
    def next_page(self,visited):
        # Only page links inside the confirmed pager; never other numbers on the page.
        before=self.signature();candidates=[];links=self.page_links()
        # Current page is commonly a span/strong rather than a clickable anchor.
        shown=self.page_numbers()
        visited.update(shown-{n for n,_ in links})
        for n,link in links:
            parent=link.locator('..')
            active=(link.get_attribute('aria-current')=='page' or
                    parent.get_attribute('aria-current')=='page' or
                    any(c in ('on','active','current','selected') for c in
                        ((link.get_attribute('class') or '')+' '+(parent.get_attribute('class') or '')).split()))
            if active:visited.add(n)
            elif n not in visited:candidates.append((n,link))
        if not candidates:return False
        n,link=min(candidates,key=lambda item:item[0]);visited.add(n)
        self.status(f'기사 목록 {n}페이지 이동');link.click()
        def changed():
            try:
                current=self.signature()
                return current if current and current!=before else None
            except ConnectionError:return None
        self.wait(changed,
                  f'{n}페이지 클릭 후 기사 목록이 바뀌지 않았습니다. 페이지 영역 연결을 확인하세요.',30)
        return True
    def find_driver(self,name):
        self.status(f'{name}: 기사 목록 검색');visited=set();signatures=set()
        for _ in range(100):
            rows=self.drivers();sig=tuple(sorted(label for label,_ in rows))
            hits=[link for label,link in rows if label[0]==name]
            if len(hits)>1:raise ItemError('동일 기사명 링크 중복: 공단 아이디와 계정 연결을 확인하세요.')
            if hits:return hits[0]
            if sig in signatures:raise ConnectionError('기사 목록 페이지가 반복됩니다. 페이지 연결을 확인하세요.')
            signatures.add(sig)
            if not self.next_page(visited):raise ItemError('전체 연결 페이지에서 기사명을 찾지 못했습니다. 공단 자료 없음으로 자동 확정하지 않습니다.')
        raise ConnectionError('기사 페이지 탐색 한도 초과')
    def audit_pages(self,month):
        self.select_month(month);visited=set();signatures=set();names=set();pages=0
        while True:
            rows=self.drivers();sig=tuple(sorted(label for label,_ in rows))
            if not rows:raise ConnectionError('기사 목록이 비었거나 영역 연결이 잘못되었습니다.')
            if sig in signatures:raise ConnectionError('페이지 목록 반복 감지')
            signatures.add(sig);pages+=1;names.update(label for label,_ in rows)
            if not self.next_page(visited):break
            if pages>=100:raise ConnectionError('페이지 탐색 한도 초과')
        return {'month':month,'pages':pages,'drivers':[{'name':n,'source_id':i} for n,i in sorted(names)]}
    def close_report(self):
        for p in reversed(self.owned):
            try:
                if not p.is_closed():p.close()
            except Exception:pass
        self.owned=[];self.viewer=None;self.active_task=None
    def open_report(self,task):
        key=(task['driver_id'],task['name'],task['month'])
        if self.active_task==key and self.viewer and not self.viewer.is_closed():return
        self.close_report()
        if self.current!=task['month']:self.select_month(task['month'])
        link=self.find_driver(task['name']);before=list(self.context.pages)
        self.status(f"{task['name']}: 상세창 로딩 대기")
        link.click()
        def new_with_button(original,button_key):
            found=[]
            for page in self.context.pages:
                if page not in original and not page.is_closed():
                    if page not in self.owned:self.owned.append(page)
                    matches=self.matches(page,button_key)
                    if len(matches)>1:raise ConnectionError(f'{button_key}: 버튼 중복. 연결을 다시 지정하세요.')
                    if matches:found.append(page)
            if len(found)>1:raise ConnectionError('보고서 창이 여러 개입니다. 수동 보고서 창을 닫고 재시도하세요.')
            return found[0] if found else None
        detail=self.wait(lambda:new_with_button(before,'file_download'),
            '상세창이 준비되지 않았습니다(about:blank/로그인 만료/공단 오류 가능). 빈 창을 정상 보고서로 처리하지 않습니다.')
        # Only the actual report button is clicked, after it becomes visible.
        self.status(f"{task['name']}: 파일다운로드 클릭 → 보고서 창 대기")
        detail.bring_to_front();before_viewer=list(self.context.pages)
        self.one(detail,'file_download').click()
        viewer=self.wait(lambda:new_with_button(before_viewer,'pdf_download'),
            '파일다운로드 이후 PDF 버튼이 있는 새 보고서 창을 찾지 못했습니다. [PDF 직접 다운로드] 연결을 확인하세요.')
        self.one(viewer,'xls_download')
        self.viewer=viewer;self.active_task=key;viewer.bring_to_front()
    def collect(self,task,tempdir):
        self.open_report(task)
        key='pdf_download' if task['kind']=='pdf' else 'xls_download'
        self.status(f"{task['name']} {task['month']}: {'PDF' if task['kind']=='pdf' else 'XLS'} 직접 다운로드")
        downloads=[];hooked=[]
        def on_download(d):downloads.append(d)
        def attach(page):
            if page not in hooked:
                page.on('download',on_download);hooked.append(page)
        # Listen before clicking, including downloads emitted by an intermediate new tab.
        for p in self.context.pages:attach(p)
        self.context.on('page',attach)
        try:
            self.one(self.viewer,key).click()
            self.wait(lambda:downloads,'다운로드가 시작되지 않았습니다. 해당 형식 버튼과 공단 응답을 확인하세요.')
            if len(downloads)!=1:raise ConnectionError('여러 다운로드가 동시에 발생했습니다. 수집 중 다른 다운로드를 중지하세요.')
            d=downloads[0];ext=download_suffix(task['kind'],d.suggested_filename)
            self.status(f"{task['name']}: 파일 수신 완료 대기 (완료 후 중지 가능)")
            path=Path(tempdir)/f"{task['id']}{ext}"
            try:d.save_as(str(path))
            except Exception as e:raise ItemError(f'파일 수신 실패: {e}') from e
            if d.failure():raise ItemError('다운로드 실패: '+d.failure())
            if not path.is_file() or not path.stat().st_size:raise ItemError('빈 다운로드 파일: 관리자 확인 필요')
            self.status(f"{task['name']}: 기사명·분석월 검증 및 저장")
            return path
        finally:
            self.context.remove_listener('page',attach)
            for p in hooked:
                try:p.remove_listener('download',on_download)
                except Exception:pass
