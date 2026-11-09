"""Durable per-driver/month/format queue; no credentials or automatic account inference."""
import calendar,csv,hashlib,json,os,re,shutil,sqlite3,tempfile
from pathlib import Path
from datetime import date

def months(start,end):
    def parse(v):
        if not re.fullmatch(r'\d{4}-(0[1-9]|1[0-2])',v): raise ValueError('기간은 YYYY-MM 형식입니다.')
        y,m=map(int,v.split('-'));return y*12+m-1
    a,b=parse(start),parse(end)
    if b<a or b-a>119: raise ValueError('종료월은 시작월 이후, 최대 120개월입니다.')
    now=date.today();last=now.year*12+now.month-1
    if b>last: raise ValueError('미래 월은 수집할 수 없습니다.')
    return [f'{i//12:04d}-{i%12+1:02d}' for i in range(a,b+1)]

def safe_name(name):
    if not name or len(name)>100 or re.search(r'[<>:"/\\|?*\x00-\x1f]',name) or name.endswith((' ','.')): raise ValueError('파일명으로 사용할 수 없는 기사명입니다.')
    if name.upper() in {'CON','PRN','AUX','NUL',*[f'COM{i}' for i in range(1,10)],*[f'LPT{i}' for i in range(1,10)]}: raise ValueError('예약된 파일명입니다.')
    return name

def validate(path,name,month):
    path=Path(path);ext=path.suffix.lower();b=path.read_bytes()
    if not b: raise ValueError('빈 파일: 공단 자료 없음으로 확정할 수 없습니다.')
    text=''
    if ext=='.pdf':
        if not b.startswith(b'%PDF-'):raise ValueError('PDF 형식 오류')
        from pypdf import PdfReader
        doc=PdfReader(str(path))
        if not doc.pages:raise ValueError('PDF 페이지 없음')
        text='\n'.join(p.extract_text() or '' for p in doc.pages)
    elif ext=='.xlsx':
        from openpyxl import load_workbook
        wb=load_workbook(path,read_only=True,data_only=True)
        text='\n'.join(str(v) for ws in wb for row in ws.values for v in row if v is not None);wb.close()
    elif ext=='.xls':
        import xlrd
        wb=xlrd.open_workbook(str(path));text='\n'.join(str(v) for ws in wb.sheets() for row in range(ws.nrows) for v in ws.row_values(row) if v!='')
    else:raise ValueError('PDF/XLS/XLSX만 가능합니다.')
    # Compare a full Korean name token (preserves suffix B) rather than substring.
    compact=re.sub(r'\s+','',text);y,m=month.split('-')
    name_ok=re.search(re.escape(name)+r'(?:님|의|안전운전|$|[^가-힣A-Za-z0-9])',compact) is not None
    month_ok=re.search(re.escape(y)+r'(?:년|[./-])0?'+str(int(m))+r'(?:월|[./-]|$|[^0-9])',compact) is not None
    if not name_ok or not month_ok:raise ValueError('내용의 기사명·분석월 확인 불가 또는 불일치: 관리자 대조 필요')
    return hashlib.sha256(b).hexdigest()

class Queue:
    def __init__(self,path):
        self.path=Path(path);self.path.parent.mkdir(parents=True,exist_ok=True)
        self.db=sqlite3.connect(self.path);self.db.row_factory=sqlite3.Row
        self.db.execute('pragma journal_mode=WAL')
        self.db.execute('''create table if not exists tasks(id integer primary key,driver_id text,name text,month text,kind text,employment text,effective_date text,status text default '대기',reason text default '',path text,hash text,unique(driver_id,month,kind))''');self.db.commit()
    def plan(self,roster,start,end):
        period=months(start,end);names=set();ids=set()
        for d in roster:
            safe_name(d['name'])
            if not d.get('id') or d['id'] in ids or d['name'] in names:raise ValueError('명부의 ID·이름 중복 또는 누락')
            ids.add(d['id']);names.add(d['name'])
        for d in roster:
            for mo in period:
                for kind in ['pdf','excel']:
                    self.db.execute('insert into tasks(driver_id,name,month,kind,employment,effective_date) values(?,?,?,?,?,?) on conflict(driver_id,month,kind) do update set name=excluded.name,employment=excluded.employment,effective_date=excluded.effective_date', (d['id'],d['name'],mo,kind,d.get('employment','재직'),d.get('effective_date')))
        self.db.commit()
    def rows(self):return [dict(r) for r in self.db.execute('select * from tasks order by month,name,kind')]
    def get(self,i):return dict(self.db.execute('select * from tasks where id=?',(i,)).fetchone())
    def mark(self,i,status,reason=''):
        self.db.execute('update tasks set status=?,reason=? where id=?',(status,reason,i));self.db.commit()
    def store(self,i,source,root,manual=False):
        t=self.get(i);source=Path(source);ext=source.suffix.lower()
        if (t['kind']=='pdf' and ext!='.pdf') or (t['kind']=='excel' and ext not in ['.xls','.xlsx']):raise ValueError('선택 작업과 파일 종류가 다릅니다.')
        try:h=validate(source,t['name'],t['month'])
        except Exception:
            if not manual:raise
            h=hashlib.sha256(source.read_bytes()).hexdigest()
            if not source.stat().st_size:raise ValueError('빈 파일은 저장할 수 없습니다.')
        root=Path(root)
        if not root.is_dir():raise ValueError('저장 루트에 접근할 수 없습니다. G: 연결을 확인하세요.')
        year,mo=t['month'].split('-');folder=root/('기사리포트(PDF)' if t['kind']=='pdf' else '분석용 파일(EXCEL)')/year/mo
        folder.mkdir(parents=True,exist_ok=True);dest=folder/f"{safe_name(t['name'])}({t['month']}){ext}"
        if dest.exists() and hashlib.sha256(dest.read_bytes()).hexdigest()!=h:raise ValueError('동일 이름의 다른 파일이 있습니다. 기존 파일을 별도 보관 후 재시도하세요.')
        if not dest.exists():
            fd,tmp=tempfile.mkstemp(prefix='.pending-',dir=folder);os.close(fd)
            try:
                shutil.copyfile(source,tmp)
                if hashlib.sha256(Path(tmp).read_bytes()).hexdigest()!=h:raise ValueError('복사 검증 실패')
                os.replace(tmp,dest)
            finally:
                if os.path.exists(tmp):os.unlink(tmp)
        self.db.execute("update tasks set status='완료',reason=?,path=?,hash=? where id=?",('관리자 수동 대조' if manual else '파일 내용 대조 완료',str(dest),h,i));self.db.commit();return dest
    def export(self,path):
        with open(path,'w',encoding='utf-8-sig',newline='') as f:
            w=csv.writer(f);w.writerow(['기사','분석월','형식','재직상태','적용일','처리상태','사유','저장경로'])
            for t in self.rows():
                vals=[t[k] or '' for k in ['name','month','kind','employment','effective_date','status','reason','path']]
                w.writerow(["'"+v if str(v).startswith(('=','+','-','@')) else v for v in vals])
