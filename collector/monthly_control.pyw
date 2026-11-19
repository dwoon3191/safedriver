import json,os,queue,sys,tempfile,threading,traceback,time,shutil
from pathlib import Path
import tkinter as tk
from tkinter import ttk,filedialog,messagebox
from monthly_core import Queue,months

DATA=Path(os.environ.get('LOCALAPPDATA',str(Path.home())))/'DaewoonMonthly'
DATA.mkdir(parents=True,exist_ok=True)
# Enforce one writer/process; the browser profile and queue must not be shared concurrently.
lock=open(DATA/'collector.lock','a+b');lock.write(b'0');lock.flush();lock.seek(0)
try:
    if os.name=='nt':
        import msvcrt;msvcrt.locking(lock.fileno(),msvcrt.LK_NBLCK,1)
    else:
        import fcntl;fcntl.flock(lock.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
except OSError:
    messagebox.showerror('이미 실행 중','공단 수집기가 이미 실행 중입니다. 기존 창을 사용하세요.');sys.exit(1)

class App:
    def __init__(self,root):
        self.root=root;root.title('대운교통 공단 보고서 수집기 v2.0.4 PDF·XLS 수집기');root.geometry('1150x760')
        self.q=Queue(DATA/'queue.sqlite');self.events=queue.Queue();self.commands=queue.Queue();self.stop=threading.Event();self.busy=False;self.roster=[]
        self.config={}
        try:self.config=json.loads((DATA/'settings.json').read_text('utf-8'))
        except Exception:pass
        self.start=tk.StringVar(value=self.config.get('start','2026-01'));self.end=tk.StringVar(value=self.config.get('end','2026-01'));self.folder=tk.StringVar(value=self.config.get('folder',''))
        self.browser=tk.StringVar(value=self.config.get('browser','웨일'))
        self.banner=tk.StringVar(value='자동 다운로드는 현장 연결 시험 필요 · 수동 파일 등록 사용 가능 · 문자 발송 없음')
        ttk.Label(root,textvariable=self.banner,wraplength=1100).pack(fill='x',padx=12,pady=8)
        form=ttk.Frame(root);form.pack(fill='x',padx=12)
        for label,var in [('시작월 YYYY-MM',self.start),('종료월 YYYY-MM',self.end)]:ttk.Label(form,text=label).pack(side='left');ttk.Entry(form,textvariable=var,width=12).pack(side='left',padx=6)
        ttk.Button(form,text='기사명부 불러오기',command=self.load_roster).pack(side='left',padx=4)
        ttk.Button(form,text='① 기간별 작업 생성',command=self.plan).pack(side='left',padx=4)
        pathrow=ttk.Frame(root);pathrow.pack(fill='x',padx=12,pady=8)
        ttk.Entry(pathrow,textvariable=self.folder).pack(side='left',fill='x',expand=True)
        ttk.Button(pathrow,text='저장 루트 선택(G: 가능)',command=self.choose_folder).pack(side='left')
        browserrow=ttk.Frame(root);browserrow.pack(fill='x',padx=12,pady=4)
        ttk.Label(browserrow,text='실행 브라우저:').pack(side='left')
        ttk.Combobox(browserrow,textvariable=self.browser,values=['웨일','Chromium'],state='readonly',width=12).pack(side='left')
        ttk.Button(browserrow,text='웨일 실행파일 선택',command=self.choose_whale).pack(side='left',padx=4)
        ttk.Button(browserrow,text='진행기록 열기',command=self.open_log).pack(side='left',padx=4)
        ttk.Label(browserrow,text='수집 전용 창에서 로그인 · 파일명 자동 저장 · XLS 원본 보관').pack(side='left')
        buttons=ttk.Frame(root);buttons.pack(fill='x',padx=12)
        for n,(text,cmd) in enumerate([('② 공단 사이트 열기',lambda:self.command('open')),('③ 선택 작업 수집/재수집',self.collect),('일시중지',self.stop.set),('미완료 대기 건 선택',self.select_pending),('실패·확인필요 건 선택',self.select_errors),('연결 설정 파일 선택',self.profile)]):ttk.Button(buttons,text=text,command=cmd).grid(row=n//4,column=n%4,padx=2,pady=2,sticky='w')
        mapping=ttk.Frame(root);mapping.pack(fill='x',padx=12,pady=5)
        ttk.Label(mapping,text='첫 연결 도움:').pack(side='left')
        self.map_label=tk.StringVar(value='조회 연도')
        self.map_keys={'① 조회 연도':'year','② 조회 월':'month','③ 조회 버튼':'query','④ 기사 목록(이름 클릭)':'driver_list','⑤ 페이지 영역(번호 클릭)':'pagination','⑥ 상세창 파일다운로드':'file_download','⑦ PDF 직접 다운로드':'pdf_download','⑧ XLS 직접 다운로드':'xls_download'}
        self.map_label.set(next(iter(self.map_keys)))
        ttk.Combobox(mapping,textvariable=self.map_label,values=list(self.map_keys),state='readonly',width=23).pack(side='left')
        ttk.Button(mapping,text='화면에서 해당 요소 지정',command=self.pick).pack(side='left',padx=6)
        ttk.Label(mapping,text='대상 화면을 먼저 연 뒤 지정 (120초)').pack(side='left')
        checks=ttk.Frame(root);checks.pack(fill='x',padx=12)
        ttk.Button(checks,text='연결 순서 안내',command=self.mapping_help).pack(side='left')
        ttk.Button(checks,text='조회 연결 시험(시작월)',command=self.check_query).pack(side='left',padx=4)
        ttk.Button(checks,text='전체 페이지·기사 점검',command=self.audit).pack(side='left',padx=4)
        ttk.Button(checks,text='공단 창 크게 보기',command=lambda:self.command('enlarge')).pack(side='left',padx=4)
        ttk.Button(checks,text='요소 지정 취소',command=self.stop.set).pack(side='left',padx=4)
        ttk.Label(root,text='Ctrl/Shift로 여러 항목 선택 → 재직상태 확인 → 선택 수집. 휴직·퇴사자는 자동 제외하지 않습니다. 보류·제외는 자동 재선택하지 않습니다.').pack(fill='x',padx=12,pady=8)
        frame=ttk.Frame(root);frame.pack(fill='both',expand=True,padx=12)
        self.tree=ttk.Treeview(frame,columns=('name','month','kind','employment','status','reason'),show='headings',selectmode='extended')
        for key,label,width in [('name','기사',120),('month','분석월',85),('kind','형식',60),('employment','재직',60),('status','상태',100),('reason','사유',520)]:self.tree.heading(key,text=label);self.tree.column(key,width=width)
        scroll=ttk.Scrollbar(frame,command=self.tree.yview);self.tree.configure(yscrollcommand=scroll.set);self.tree.pack(side='left',fill='both',expand=True);scroll.pack(side='right',fill='y')
        self.tree.bind('<Double-1>',self.show_reason)
        lower=ttk.Frame(root);lower.pack(fill='x',padx=12,pady=8)
        for n,(text,cmd) in enumerate([('수동 다운로드 파일 연결',self.manual),('선택 건 보류',lambda:self.mark('보류')),('이번 수집 제외',lambda:self.mark('제외')),('공단 자료 없음 확인',lambda:self.mark('자료 없음')),('선택 건 대기로 되돌리기',lambda:self.mark('대기')),('결과 CSV 내보내기',self.export),('저장 폴더 열기',self.open_folder)]):ttk.Button(lower,text=text,command=cmd).grid(row=n//4,column=n%4,padx=2,pady=2,sticky='w')
        ttk.Label(root,text='웹 등록은 기존 웹앱 → 수집·등록 → 파일 검사·계정 연결 → 웹 등록 → 월별 보고서 검증 → 게시 순서로 진행하세요.').pack(fill='x',padx=12,pady=6)
        self.refresh();threading.Thread(target=self.worker,daemon=True).start();self.poll();root.protocol('WM_DELETE_WINDOW',self.close)
    def persist(self):
        self.config.update(start=self.start.get(),end=self.end.get(),folder=self.folder.get(),browser=self.browser.get());(DATA/'settings.json').write_text(json.dumps(self.config,ensure_ascii=False,indent=2),'utf-8')
    def show_reason(self,event=None):
        ids=self.tree.selection()
        if ids:
            t=self.q.get(int(ids[0]));messagebox.showinfo('작업 상세',f"{t['name']} / {t['month']} / {t['kind']}\n{t['status']}\n{t['reason']}\n{t['path'] or ''}")
    def choose_folder(self):
        p=filedialog.askdirectory()
        if p:self.folder.set(p);self.persist()
    def load_roster(self):
        p=filedialog.askopenfilename(filetypes=[('웹앱에서 내보낸 기사명부','*.json')])
        if p:
            try:
                self.roster=json.loads(Path(p).read_text('utf-8-sig'))
                if not isinstance(self.roster,list):raise ValueError('명부 형식 오류')
                self.banner.set(f'기사명부 {len(self.roster)}명 불러옴 · 기간별 작업 생성 버튼을 누르세요.')
            except Exception as e:messagebox.showerror('명부 오류',str(e))
    def plan(self):
        if self.busy:return
        try:
            if not self.roster:raise ValueError('웹앱 기사 계정에서 공단 이름 연결 후 수집·등록 메뉴에서 명부를 내보내세요.')
            self.q.plan(self.roster,self.start.get(),self.end.get());self.persist();self.refresh()
        except Exception as e:messagebox.showerror('작업 생성',str(e))
    def visible(self):return [t for t in self.q.rows() if self.start.get()<=t['month']<=self.end.get()]
    def refresh(self):
        selected=self.tree.selection();self.tree.delete(*self.tree.get_children())
        for t in self.visible():self.tree.insert('',tk.END,iid=str(t['id']),values=[t[k] for k in ('name','month','kind','employment','status','reason')])
        self.tree.selection_set([i for i in selected if self.tree.exists(i)])
    def select_pending(self):self.tree.selection_set([str(t['id']) for t in self.visible() if t['status'] in ('대기','진행 중')])
    def select_errors(self):self.tree.selection_set([str(t['id']) for t in self.visible() if t['status'] in ('실패','확인 필요')])
    def command(self,cmd):
        if self.busy:return
        self.stop.clear();self.persist();self.busy=True;self.commands.put((cmd,None));self.banner.set('요청 처리 중입니다.')
    def check_query(self):
        if self.busy:return
        try:months(self.start.get(),self.start.get())
        except Exception as e:return messagebox.showerror('조회월',str(e))
        self.stop.clear();self.busy=True;self.commands.put(('check',self.start.get()))
        self.banner.set('시작월 조회 연결 시험 중입니다. 파일은 다운로드하지 않습니다.')
    def choose_whale(self):
        if self.busy:return
        p=filedialog.askopenfilename(title='웨일 실행 파일 whale.exe 선택',filetypes=[('웨일 실행 파일','whale.exe')])
        if p:self.config['whale_path']=p;self.persist()
    def open_log(self):
        p=DATA/'collector.log'
        if os.name=='nt' and p.exists():os.startfile(p)
        else:messagebox.showinfo('진행기록',str(p))
    def audit(self):
        if self.busy:return
        try:months(self.start.get(),self.start.get())
        except Exception as e:return messagebox.showerror('조회월',str(e))
        self.stop.clear();self.busy=True;self.commands.put(('audit',self.start.get()))
    def mapping_help(self):
        messagebox.showinfo('첫 연결 및 수집 순서',
            '1. 웨일 선택 → 공단 사이트 열기 → 전용 브라우저에서 로그인 → 종합진단표.\n'
            '2. 조회 연도·월·조회 버튼을 각각 지정합니다.\n'
            '3. 기사 목록은 이름 하나를 클릭해 지정합니다. 페이지 영역은 아래 숫자 2를 클릭해 지정합니다.\n'
            '4. 조회 연결 시험 → 전체 페이지·기사 점검을 실행합니다.\n'
            '5. 기사 이름을 직접 클릭하여 상세창을 먼저 엽니다. 파일다운로드를 지정한 뒤 다시 클릭합니다.\n'
            '6. 새 보고서 창에서 PDF 직접 다운로드와 XLS 직접 다운로드를 각각 지정합니다.\n'
            '7. 수동 보고서 창을 닫고 기사 한 명의 PDF·Excel 두 작업을 선택해 시험 수집합니다.\n'
            '8. 파일 내용과 G: 저장을 확인한 뒤 전체 수집합니다.\n\n'
            '지정용 클릭은 실제 실행하지 않습니다. 저장된 위치는 다음 실행에도 사용합니다.\n'
            '화면 이동에는 같은 버튼을 다시 누르세요. 파일명 입력·다른 이름으로 저장은 필요 없습니다.\n'
            '연결/로그인 오류는 중단, 기사 누락/내용 불일치는 확인필요로 남기고 다음 작업을 진행합니다.\n'
            '일시중지는 대기 중 취소하며, 파일 수신·검증·저장 중에는 해당 처리가 끝난 뒤 멈춥니다.')
    def collect(self):
        if self.busy:return
        ids=[int(i) for i in self.tree.selection()]
        if not ids:return messagebox.showinfo('선택 필요','수집할 작업을 선택하세요.')
        if not Path(self.folder.get()).is_dir():return messagebox.showerror('저장 위치','접근 가능한 저장 루트를 선택하세요.')
        ids.sort(key=lambda i:(self.q.get(i)['month'],self.q.get(i)['name'],0 if self.q.get(i)['kind']=='pdf' else 1))
        selected=[self.q.get(i) for i in ids];special=[t for t in selected if t['employment']!='재직']
        text=f'{len(ids)}개 파일을 처리합니다. 완료 파일은 다시 받지 않습니다.'
        if special:text+='\n휴직·퇴사 항목 '+str(len(special))+'건이 포함되어 있습니다. 해당 분석월 수집이 필요한지 확인하세요.'
        if not messagebox.askyesno('대상 확인',text):return
        self.persist();self.stop.clear();self.busy=True;self.commands.put(('collect',(ids,self.folder.get())))
    def mark(self,status):
        if self.busy:return
        from tkinter.simpledialog import askstring
        ids=self.tree.selection()
        if not ids:return
        reason=askstring('관리자 확인',status+' 처리 사유를 입력하세요. 자료 없음은 공단 화면에서 확인한 경우만 선택하세요.')
        if not reason:return
        for i in ids:self.q.mark(int(i),status,reason)
        self.refresh()
    def manual(self):
        if self.busy:return
        ids=self.tree.selection()
        if len(ids)!=1:return messagebox.showinfo('선택','파일을 연결할 작업 한 개를 선택하세요.')
        p=filedialog.askopenfilename(filetypes=[('보고서','*.pdf *.xls *.xlsx')])
        if not p:return
        try:self.q.store(int(ids[0]),p,self.folder.get());self.refresh()
        except Exception as e:
            self.q.mark(int(ids[0]),'확인 필요',str(e));self.refresh()
            # No bypass for structural/identity validation: use web manual review for exceptional PDFs.
            messagebox.showerror('검증 필요',str(e)+'\n원본을 직접 열어 확인하세요. 텍스트 추출 불가 파일은 웹앱 수동 등록 후 대조할 수 있습니다.')
    def export(self):
        p=filedialog.asksaveasfilename(defaultextension='.csv',initialfile='공단수집_관리자확인.csv')
        if p:self.q.export(p)
    def open_folder(self):
        if os.name=='nt' and Path(self.folder.get()).is_dir():os.startfile(self.folder.get())
    def profile(self):
        p=filedialog.askopenfilename(filetypes=[('현장 확인한 연결 설정','*.json')])
        if p:self.config['profile']=p;self.persist();messagebox.showinfo('연결 설정','다음 공단 사이트 열기부터 반영됩니다. 브라우저를 열고 다시 로그인하세요.')
    def pick(self):
        if self.busy:return
        self.stop.clear();self.busy=True;self.commands.put(('pick',self.map_keys[self.map_label.get()]));self.banner.set('공단 브라우저에서 '+self.map_label.get()+' 요소를 한 번 클릭하세요. 지정용 클릭은 실제 실행되지 않습니다.')
    def worker(self):
        from playwright.sync_api import sync_playwright
        from etas_adapter import EtasAdapter,ConnectionError,ItemError,Cancelled
        from etas_dom import PICK_SCRIPT,CLEAR_PICK
        from monthly_browser import launch_browser
        with sync_playwright() as pw:
            context=None;adapter=None
            while True:
                cmd,arg=self.commands.get()
                try:
                    if cmd=='close':
                        if context:context.close()
                        return
                    if cmd=='open':
                        if context:context.close()
                        context=None;adapter=None
                        context=launch_browser(pw,DATA,self.config.get('browser','웨일'),self.config.get('whale_path',''))
                        context.set_default_timeout(15000)
                        profile={}
                        if self.config.get('profile'):profile=json.loads(Path(self.config['profile']).read_text('utf-8'))
                        adapter=EtasAdapter(context,profile,progress=lambda msg:self.events.put(('info',msg)),stop=self.stop);adapter.open();self.events.put(('done','공단 로그인 후 종합진단표 화면을 여세요. 연결 순서 안내를 참고하세요.'))
                    if cmd=='enlarge':
                        if not adapter:raise RuntimeError('먼저 공단 사이트 열기를 실행하세요.')
                        for p in context.pages:adapter.enlarge(p)
                        self.events.put(('done','창 확대를 요청했습니다. 확대되지 않으면 해당 창 제목 표시줄을 두 번 클릭하세요.'))
                    if cmd=='check':
                        if not adapter:raise RuntimeError('먼저 공단 사이트 열기를 실행하세요.')
                        self.events.put(('done',adapter.check_query(arg)))
                    if cmd=='audit':
                        if not adapter:raise RuntimeError('먼저 공단 사이트 열기를 실행하세요.')
                        result=adapter.audit_pages(arg)
                        pp=DATA/'page_audit.json';pp.write_text(json.dumps(result,ensure_ascii=False,indent=2),'utf-8')
                        self.events.put(('audit',result))
                        self.events.put(('done',f"페이지 점검 완료: {result['pages']}개 목록, {len(result['drivers'])}명. 수집대상 누락 결과를 확인하세요."))
                    if cmd=='pick':
                        if not adapter:raise RuntimeError('먼저 공단 사이트 열기를 실행하세요.')
                        script=PICK_SCRIPT
                        frames=[];chosen=None;deadline=time.time()+120
                        while time.time()<deadline and not chosen and not self.stop.is_set():
                            frames=[f for p in context.pages for f in p.frames]
                            for f in frames:
                                try:
                                    # Re-arm after navigation and include newly opened popup frames.
                                    if not f.evaluate('Boolean(window.__dw_handler)'):f.evaluate(script,arg)
                                    error=f.evaluate('window.__dw_error')
                                    if error:
                                        self.events.put(('info',error));f.evaluate('window.__dw_error=null')
                                    chosen=f.evaluate('window.__dw_pick')
                                    if chosen:break
                                except Exception:pass
                            if not chosen:context.pages[0].wait_for_timeout(200)
                        for f in frames:
                            try:f.evaluate(CLEAR_PICK)
                            except Exception:pass
                        if self.stop.is_set():raise RuntimeError('요소 지정을 취소했습니다.')
                        if not chosen:raise RuntimeError('지정 시간이 지났습니다. 다시 시도하세요.')
                        adapter.profile[arg]=chosen
                        self.events.put(('mapped',arg))
                        pp=DATA/'etas_selectors.json';pp.write_text(json.dumps(adapter.profile,ensure_ascii=False,indent=2),'utf-8')
                        self.events.put(('profile',str(pp)))
                        self.events.put(('done','화면 연결을 저장했습니다. 다음 화면으로 이동하려면 해당 요소를 다시 클릭하세요.'))
                    if cmd=='collect':
                        if not adapter:raise RuntimeError('먼저 공단 사이트 열기로 브라우저를 실행하세요.')
                        adapter.current=None
                        ids,folder=arg;q=Queue(DATA/'queue.sqlite')
                        try:
                            with tempfile.TemporaryFile(dir=folder) as check:
                                check.write(b'daewoon-write-check');check.flush()
                            for i in ids:
                                if self.stop.is_set():break
                                task=q.get(i)
                                if task['status']=='완료':
                                    if not q.completed_valid(i):
                                        q.mark(i,'확인 필요','완료 파일이 없거나 변경되었습니다. G: 연결과 원본을 확인 후 재수집하세요.')
                                        self.events.put(('refresh',None))
                                    continue
                                q.mark(i,'진행 중');self.events.put(('refresh',None))
                                try:
                                    with tempfile.TemporaryDirectory(prefix='daewoon-') as temp:
                                        src=adapter.collect(task,temp)
                                        try:q.store(i,src,folder)
                                        except Exception as validation_error:
                                            review=DATA/'review';review.mkdir(exist_ok=True)
                                            retained=review/f"task-{i}-{time.time_ns()}{Path(src).suffix}"
                                            try:shutil.copyfile(src,retained)
                                            except Exception as backup_error:
                                                raise RuntimeError(f'파일 검증/저장 실패: {validation_error}. 검토용 원본 보관도 실패: {backup_error}') from validation_error
                                            raise (ItemError if isinstance(validation_error,ValueError) else ConnectionError)(f'파일 검증/저장 실패: {validation_error}. 검토용 원본: {retained}') from validation_error
                                except Cancelled:
                                    q.mark(i,'대기','관리자 일시중지');self.stop.set()
                                except ItemError as e:
                                    q.mark(i,'확인 필요',str(e));self.events.put(('info','확인 필요: '+str(e)))
                                    adapter.close_report()
                                except Exception as e:
                                    reason=f'{adapter.stage}: {e}'
                                    q.mark(i,'확인 필요',reason);self.events.put(('info','중단: '+reason))
                                    self.stop.set()
                                self.events.put(('refresh',None))
                        finally:
                            q.db.close();adapter.close_report()
                        self.events.put(('done','작업 종료/일시정지. 실패·확인필요 목록을 검토하세요. G: 저장과 클라우드 동기화는 별개입니다.'))
                except Exception as e:self.events.put(('done',str(e)))
    def poll(self):
        try:
            while True:
                kind,msg=self.events.get_nowait()
                if isinstance(msg,str):
                    self.banner.set(msg)
                    try:
                        with (DATA/'collector.log').open('a',encoding='utf-8') as log:log.write(time.strftime('%Y-%m-%d %H:%M:%S')+' '+msg+'\n')
                    except OSError:pass
                if kind=='profile':self.config['profile']=msg;self.persist()
                if kind=='mapped':
                    keys=list(self.map_keys);index=list(self.map_keys.values()).index(msg)
                    self.map_label.set(keys[min(index+1,len(keys)-1)])
                if kind=='audit':
                    names={d['name'] for d in msg['drivers']}
                    targets={t['name'] for t in self.visible() if t['month']==msg['month']}
                    missing=sorted(targets-names)
                    messagebox.showinfo('페이지·기사 점검',f"목록 {msg['pages']}개 / 공단 기사 {len(names)}명 / 수집대상 중 미발견 {len(missing)}명\n"+'\n'.join(missing[:30])+'\n전체 공단 명단은 '+str(DATA/'page_audit.json'))
                if kind=='done':self.busy=False
                self.refresh()
        except queue.Empty:pass
        self.root.after(300,self.poll)
    def close(self):
        if self.busy and not messagebox.askyesno('종료','진행 중 다운로드가 중단될 수 있습니다. 미완료 작업은 다음 실행에서 재개할 수 있습니다. 종료할까요?'):return
        self.stop.set();self.persist();self.commands.put(('close',None));self.root.destroy()

if __name__=='__main__':
    root=tk.Tk();App(root);root.mainloop()
