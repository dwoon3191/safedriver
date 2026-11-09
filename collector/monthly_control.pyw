import json,os,queue,sys,tempfile,threading,traceback,time
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
        self.root=root;root.title('대운교통 공단 보고서 수집기 v2.0');root.geometry('1150x760')
        self.q=Queue(DATA/'queue.sqlite');self.events=queue.Queue();self.commands=queue.Queue();self.stop=threading.Event();self.busy=False;self.roster=[]
        self.config={}
        try:self.config=json.loads((DATA/'settings.json').read_text('utf-8'))
        except Exception:pass
        self.start=tk.StringVar(value=self.config.get('start','2026-01'));self.end=tk.StringVar(value=self.config.get('end','2026-01'));self.folder=tk.StringVar(value=self.config.get('folder',''))
        self.banner=tk.StringVar(value='자동 다운로드는 현장 연결 시험 필요 · 수동 파일 등록 사용 가능 · 문자 발송 없음')
        ttk.Label(root,textvariable=self.banner,wraplength=1100).pack(fill='x',padx=12,pady=8)
        form=ttk.Frame(root);form.pack(fill='x',padx=12)
        for label,var in [('시작월 YYYY-MM',self.start),('종료월 YYYY-MM',self.end)]:ttk.Label(form,text=label).pack(side='left');ttk.Entry(form,textvariable=var,width=12).pack(side='left',padx=6)
        ttk.Button(form,text='기사명부 불러오기',command=self.load_roster).pack(side='left',padx=4)
        ttk.Button(form,text='① 기간별 작업 생성',command=self.plan).pack(side='left',padx=4)
        pathrow=ttk.Frame(root);pathrow.pack(fill='x',padx=12,pady=8)
        ttk.Entry(pathrow,textvariable=self.folder).pack(side='left',fill='x',expand=True)
        ttk.Button(pathrow,text='저장 루트 선택(G: 가능)',command=self.choose_folder).pack(side='left')
        buttons=ttk.Frame(root);buttons.pack(fill='x',padx=12)
        for text,cmd in [('② 공단 사이트 열기',lambda:self.command('open')),('③ 선택 작업 수집/재수집',self.collect),('일시중지',self.stop.set),('미완료 대기 건 선택',self.select_pending),('실패·확인필요 건 선택',self.select_errors),('연결 설정 파일 선택',self.profile)]:ttk.Button(buttons,text=text,command=cmd).pack(side='left',padx=2)
        mapping=ttk.Frame(root);mapping.pack(fill='x',padx=12,pady=5)
        ttk.Label(mapping,text='첫 연결 도움:').pack(side='left')
        self.map_label=tk.StringVar(value='보고서 저장 아이콘')
        self.map_keys={'조회 연도':'year','조회 월':'month','조회 버튼':'query','상세창 파일다운로드':'file_download','보고서 저장 아이콘':'export_open','파일 형식 선택':'format','파일명 입력칸':'filename','전체 페이지':'all_pages','최종 저장 버튼':'save'}
        ttk.Combobox(mapping,textvariable=self.map_label,values=list(self.map_keys),state='readonly',width=23).pack(side='left')
        ttk.Button(mapping,text='화면에서 해당 요소 지정',command=self.pick).pack(side='left',padx=6)
        ttk.Label(mapping,text='누른 뒤 공단 브라우저에서 해당 요소를 한 번 클릭 (60초)').pack(side='left')
        ttk.Label(root,text='Ctrl/Shift로 여러 항목 선택 → 재직상태 확인 → 선택 수집. 휴직·퇴사자는 자동 제외하지 않습니다. 보류·제외는 자동 재선택하지 않습니다.').pack(fill='x',padx=12,pady=8)
        frame=ttk.Frame(root);frame.pack(fill='both',expand=True,padx=12)
        self.tree=ttk.Treeview(frame,columns=('name','month','kind','employment','status','reason'),show='headings',selectmode='extended')
        for key,label,width in [('name','기사',120),('month','분석월',85),('kind','형식',60),('employment','재직',60),('status','상태',100),('reason','사유',520)]:self.tree.heading(key,text=label);self.tree.column(key,width=width)
        scroll=ttk.Scrollbar(frame,command=self.tree.yview);self.tree.configure(yscrollcommand=scroll.set);self.tree.pack(side='left',fill='both',expand=True);scroll.pack(side='right',fill='y')
        lower=ttk.Frame(root);lower.pack(fill='x',padx=12,pady=8)
        for text,cmd in [('수동 다운로드 파일 연결',self.manual),('선택 건 보류',lambda:self.mark('보류')),('이번 수집 제외',lambda:self.mark('제외')),('공단 자료 없음 확인',lambda:self.mark('자료 없음')),('선택 건 대기로 되돌리기',lambda:self.mark('대기')),('결과 CSV 내보내기',self.export),('저장 폴더 열기',self.open_folder)]:ttk.Button(lower,text=text,command=cmd).pack(side='left',padx=2)
        ttk.Label(root,text='웹 등록은 기존 웹앱 → 수집·등록 → 파일 검사·계정 연결 → 웹 등록 → 월별 보고서 검증 → 게시 순서로 진행하세요.').pack(fill='x',padx=12,pady=6)
        self.refresh();threading.Thread(target=self.worker,daemon=True).start();self.poll();root.protocol('WM_DELETE_WINDOW',self.close)
    def persist(self):
        self.config.update(start=self.start.get(),end=self.end.get(),folder=self.folder.get());(DATA/'settings.json').write_text(json.dumps(self.config,ensure_ascii=False,indent=2),'utf-8')
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
        self.commands.put((cmd,None));self.banner.set('브라우저 실행 중. 열린 브라우저에서 직접 로그인하고 종합진단표 화면으로 이동하세요.')
    def collect(self):
        if self.busy:return
        ids=[int(i) for i in self.tree.selection()]
        if not ids:return messagebox.showinfo('선택 필요','수집할 작업을 선택하세요.')
        if not Path(self.folder.get()).is_dir():return messagebox.showerror('저장 위치','접근 가능한 저장 루트를 선택하세요.')
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
        self.busy=True;self.commands.put(('pick',self.map_keys[self.map_label.get()]));self.banner.set('공단 브라우저에서 '+self.map_label.get()+' 요소를 한 번 클릭하세요. 지정용 클릭은 실제 실행되지 않습니다.')
    def worker(self):
        from playwright.sync_api import sync_playwright
        from etas_adapter import EtasAdapter
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
                        context=pw.chromium.launch_persistent_context(str(DATA/'browser'),headless=False,accept_downloads=True)
                        profile={}
                        if self.config.get('profile'):profile=json.loads(Path(self.config['profile']).read_text('utf-8'))
                        adapter=EtasAdapter(context,profile);adapter.open();self.events.put(('info','공단 로그인 후 종합진단표 화면을 열고, 수집할 작업을 선택하세요.'))
                    if cmd=='pick':
                        if not adapter:raise RuntimeError('먼저 공단 사이트 열기를 실행하세요.')
                        script="""() => {
                          window.__dw_pick=null;
                          if(window.__dw_handler)document.removeEventListener('click',window.__dw_handler,true);
                          window.__dw_handler=(e)=>{
                            e.preventDefault();e.stopImmediatePropagation();
                            let el=e.target.closest('button,a,input,select,label')||e.target;
                            if(el.tagName==='LABEL'&&el.htmlFor)el=document.getElementById(el.htmlFor)||el;
                            const parts=[];
                            while(el&&el.nodeType===1){
                              if(el.id&&document.querySelectorAll('#'+CSS.escape(el.id)).length===1){parts.unshift('#'+CSS.escape(el.id));break;}
                              let n=1,p=el;while((p=p.previousElementSibling))if(p.tagName===el.tagName)n++;
                              parts.unshift(el.tagName.toLowerCase()+':nth-of-type('+n+')');el=el.parentElement;
                            }
                            window.__dw_pick=parts.join(' > ');
                            document.removeEventListener('click',window.__dw_handler,true);
                          };document.addEventListener('click',window.__dw_handler,true);
                        }"""
                        frames=[f for p in context.pages for f in p.frames]
                        for f in frames:
                            try:f.evaluate(script)
                            except Exception:pass
                        chosen=None;deadline=time.time()+60
                        while time.time()<deadline and not chosen:
                            for f in frames:
                                try:
                                    chosen=f.evaluate('window.__dw_pick')
                                    if chosen:break
                                except Exception:pass
                            if not chosen:context.pages[0].wait_for_timeout(200)
                        for f in frames:
                            try:f.evaluate("document.removeEventListener('click',window.__dw_handler,true)")
                            except Exception:pass
                        if not chosen:raise RuntimeError('지정 시간이 지났습니다. 다시 시도하세요.')
                        adapter.profile[arg]=chosen
                        pp=DATA/'etas_selectors.json';pp.write_text(json.dumps(adapter.profile,ensure_ascii=False,indent=2),'utf-8')
                        self.events.put(('profile',str(pp)))
                        self.events.put(('done','화면 연결을 저장했습니다. 다음 화면으로 이동하려면 해당 요소를 다시 클릭하세요.'))
                    if cmd=='collect':
                        if not adapter:raise RuntimeError('먼저 공단 사이트 열기로 브라우저를 실행하세요.')
                        adapter.current=None
                        ids,folder=arg;q=Queue(DATA/'queue.sqlite')
                        try:
                            for i in ids:
                                if self.stop.is_set():break
                                task=q.get(i)
                                if task['status']=='완료':continue
                                q.mark(i,'진행 중');self.events.put(('refresh',None))
                                try:
                                    with tempfile.TemporaryDirectory(prefix='daewoon-') as temp:
                                        src=adapter.collect(task,temp);q.store(i,src,folder)
                                except Exception as e:
                                    q.mark(i,'확인 필요',str(e));self.events.put(('info','확인 필요: '+str(e)))
                                    # Structural/session errors must not repeat across hundreds of drivers.
                                    self.stop.set()
                                self.events.put(('refresh',None))
                        finally:q.db.close()
                        self.events.put(('done','작업 종료/일시정지. 실패·확인필요 목록을 검토하세요. G: 저장과 클라우드 동기화는 별개입니다.'))
                except Exception as e:self.events.put(('done',str(e)))
    def poll(self):
        try:
            while True:
                kind,msg=self.events.get_nowait()
                if msg:self.banner.set(msg)
                if kind=='profile':self.config['profile']=msg;self.persist()
                if kind=='done':self.busy=False
                self.refresh()
        except queue.Empty:pass
        self.root.after(300,self.poll)
    def close(self):
        if self.busy and not messagebox.askyesno('종료','진행 중 다운로드가 중단될 수 있습니다. 미완료 작업은 다음 실행에서 재개할 수 있습니다. 종료할까요?'):return
        self.stop.set();self.persist();self.commands.put(('close',None));self.root.destroy()

if __name__=='__main__':
    root=tk.Tk();App(root);root.mainloop()
