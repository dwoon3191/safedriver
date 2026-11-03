from __future__ import annotations
import json, os, sys, time, hashlib, struct, re, math, threading, traceback, urllib.parse, urllib.request, urllib.error, getpass
from pathlib import Path
from datetime import datetime, timedelta, date, timezone
from collections import defaultdict

VERSION='DaewoonCollector-1.0.0'
KST=timezone(timedelta(hours=9))
DTG_EPOCH=datetime(2000,1,1)
RECORD_SIZE=128
CONFIG_PATH=Path(__file__).with_name('collector_config.json')
STATE_PATH=Path(__file__).with_name('collector_state.json')
LOG_PATH=Path(__file__).with_name('collector.log')

DEFAULT_CONFIG={
  'supabase_url':'', 'supabase_anon_key':'', 'login_id':'관리자', 'password':'',
  'taco_folder':r'E:\Choyoung\ADTviewer\Data', 'scan_seconds':5, 'stable_seconds':8,
  'tago_service_key':'', 'city_code':'', 'city_name':'창원시', 'bis_poll_seconds':60,
  'bis_confirm_polls':2, 'bis_recent_minutes':12, 'speed_watch_kmh':80,
  'enable_bis':True, 'enable_taco':True
}

def log(msg):
    line=f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line,flush=True)
    try:
        with LOG_PATH.open('a',encoding='utf-8') as f:f.write(line+'\n')
    except: pass

def load_json(path,default):
    try:return json.loads(path.read_text(encoding='utf-8'))
    except:return default.copy() if isinstance(default,dict) else default

def save_json(path,obj):
    tmp=path.with_suffix(path.suffix+'.tmp'); tmp.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding='utf-8'); tmp.replace(path)

class Supabase:
    def __init__(self,cfg): self.url=cfg['supabase_url'].rstrip('/'); self.key=cfg['supabase_anon_key']; self.token=''; self.cfg=cfg
    def rpc(self,fn,payload):
        u=f"{self.url}/rest/v1/rpc/{fn}"; data=json.dumps(payload,ensure_ascii=False).encode('utf-8')
        req=urllib.request.Request(u,data=data,method='POST',headers={'Content-Type':'application/json','apikey':self.key,'Authorization':'Bearer '+self.key})
        try:
            with urllib.request.urlopen(req,timeout=40) as r:
                b=r.read(); return json.loads(b.decode('utf-8')) if b else None
        except urllib.error.HTTPError as e:
            body=e.read().decode('utf-8','replace')
            try: m=json.loads(body).get('message',body)
            except: m=body
            raise RuntimeError(f"Supabase {fn}: {m}")
    def login(self):
        pw=self.cfg.get('password') or getpass.getpass(f"{self.cfg.get('login_id','관리자')} 비밀번호: ")
        s=self.rpc('app_login',{'p_login_id':self.cfg.get('login_id','관리자'),'p_password':pw})
        if s.get('must_change_password'): raise RuntimeError('관리자 초기 비밀번호를 웹앱에서 먼저 변경하세요.')
        self.token=s['token']; log(f"Supabase 로그인: {s.get('display_name')}")
    def dispatch(self,d): return self.rpc('collector_get_dispatch',{'p_token':self.token,'p_service_date':d.isoformat()}) or []
    def changes(self,d): return self.rpc('collector_get_vehicle_changes',{'p_token':self.token,'p_service_date':d.isoformat()}) or []
    def ingest_changes(self,rows): return self.rpc('collector_ingest_vehicle_changes',{'p_token':self.token,'p_changes':rows})
    def ingest_taco(self,imp,events,summaries): return self.rpc('collector_ingest_taco',{'p_token':self.token,'p_import':imp,'p_events':events,'p_summaries':summaries})

# ---------- DT-202 CDT ----------
def u16(b,p): return b[p]|(b[p+1]<<8)
def u32(b,p): return b[p]|(b[p+1]<<8)|(b[p+2]<<16)|(b[p+3]<<24)
def sha256_file(p):
    h=hashlib.sha256()
    with open(p,'rb') as f:
        for c in iter(lambda:f.read(1024*1024),b''):h.update(c)
    return h.hexdigest()

def read_header(fp):
    fields={}
    for i in range(1,13):
        line=fp.readline()
        if not line.startswith(b'$'): raise ValueError(f'CDT 헤더 오류 line {i}')
        m=re.match(rb'\$(\d{2}),(.*)\*\r?\n?$',line,re.S)
        if not m: raise ValueError(f'CDT 헤더 형식 오류 line {i}')
        k=m.group(1).decode(); fields[k]=m.group(2).decode('cp949','replace') if k!='12' else m.group(2).hex()
    mf=fields.get('01',''); mm=re.search(r'(DT-[A-Za-z0-9]+),([0-9.]+)',mf)
    return {'vehicle_no':fields.get('04','').strip(),'driver_code':fields.get('06','').strip(),'model':mm.group(1) if mm else 'DT-202','firmware':mm.group(2) if mm else 'unknown','fields':fields}

def decode_record(raw):
    dt=DTG_EPOCH+timedelta(seconds=u32(raw,0)); speed=int(raw[24]); rpm=min(u16(raw,20),9999); flags=int(raw[25]); brake=bool(flags&0x80 or raw[62]&1)
    lon_i=u32(raw,8);lat_i=u32(raw,12); gps=124_000_000<lon_i<132_000_000 and 32_000_000<lat_i<39_000_000
    return {'dt':dt,'speed':speed,'rpm':rpm,'brake':brake,'lon':lon_i/1e6 if gps else None,'lat':lat_i/1e6 if gps else None,'heading':u16(raw,16) if gps and u16(raw,16)<=360 else 0,'gps':gps}

def service_date_from_filename(p,fallback):
    m=re.match(r'(20\d{6})',Path(p).name)
    if m:
        try:return datetime.strptime(m.group(1),'%Y%m%d').date()
        except: pass
    return fallback.date()

def group_contiguous_events(hits):
    """동일 기사/노선/회차/이벤트 유형에서 1초 연속 판정을 하나의 사건으로 묶는다."""
    buckets=defaultdict(list)
    for e in hits:
        k=(e.get('driver_name',''),e.get('route_no',''),e.get('run_order',-1),e.get('event_type',''))
        buckets[k].append(e)
    out=[]
    for _,items in buckets.items():
        items=sorted(items,key=lambda x:x['recorded_at']); groups=[]
        for e in items:
            if not groups or (e['recorded_at']-groups[-1][-1]['recorded_at']).total_seconds()!=1:
                groups.append([e])
            else:
                groups[-1].append(e)
        for g in groups:
            out.append(g[0] | {'speed_after':g[-1]['speed_after'],'evidence':{**g[0].get('evidence',{}),'duration_sec':len(g)}})
    return sorted(out,key=lambda x:x['recorded_at'])

def resolve_assignment(rec_dt,vehicle,dispatch,changes):
    t=rec_dt.replace(tzinfo=KST)
    direct=[]
    for d in dispatch:
        if d.get('vehicle_no')!=vehicle: continue
        st=parse_dt(d.get('shift_start')); en=parse_dt(d.get('shift_end'))
        if st and en and st<=t<=en: direct.append(d)
    if direct:return direct[0]
    # replacement vehicle after detected change
    valid=[c for c in changes if c.get('new_vehicle')==vehicle and parse_dt(c.get('detected_at')) and parse_dt(c.get('detected_at'))<=t]
    if valid:
        c=max(valid,key=lambda x:parse_dt(x['detected_at']))
        return {'driver_name':c.get('driver_name',''),'route_no':c.get('route_no',''),'run_order':c.get('run_order',-1),'vehicle_no':vehicle,'shift_type':'REPLACEMENT'}
    # if only AM/PM without times, use clock split as fallback
    cand=[d for d in dispatch if d.get('vehicle_no')==vehicle]
    if cand:
        typ='AM' if rec_dt.hour<12 else 'PM'; x=[d for d in cand if d.get('shift_type')==typ]
        return (x or cand)[0]
    return None

def parse_dt(v):
    if not v:return None
    try:return datetime.fromisoformat(str(v).replace('Z','+00:00')).astimezone(KST)
    except:return None

def active_dispatch_rows(rows, now=None):
    """현재 시각에 실제 근무 중인 배차만 BIS 비교 대상으로 사용.
    근무시각 자료가 있으면 그것을 우선하고, 없을 때만 AM/PM을 보조 기준으로 사용한다.
    """
    now=now or datetime.now(KST); out=[]
    for d in rows:
        st=parse_dt(d.get('shift_start')); en=parse_dt(d.get('shift_end'))
        if st and en:
            if st<=now<=en: out.append(d)
            continue
        typ=str(d.get('shift_type') or '').upper()
        if typ=='AM' and now.hour<12: out.append(d)
        elif typ=='PM' and now.hour>=12: out.append(d)
        elif typ not in ('AM','PM'): out.append(d)
    return out

def analyze_cdt(path,cfg,dispatch,changes):
    p=Path(path); file_hash=sha256_file(p); records=[]
    with p.open('rb') as fp:
        header=read_header(fp)
        while True:
            raw=fp.read(RECORD_SIZE)
            if not raw:break
            if len(raw)!=RECORD_SIZE: raise ValueError('마지막 CDT 레코드 길이 오류')
            records.append(decode_record(raw))
    if not records: raise ValueError('CDT 운행레코드 없음')
    svc=service_date_from_filename(p,records[0]['dt']); vehicle=header['vehicle_no'] or extract_vehicle(p.name)
    hits=[]; sums=defaultdict(lambda:{'distance_km':0.0,'max_speed':0,'rapid_start':0,'rapid_accel':0,'rapid_decel':0,'rapid_stop':0,'speed_watch':0,'valid_pair_count':0,'gap_seconds':0})
    prev=None
    for r in records:
        ass=resolve_assignment(r['dt'],vehicle,dispatch,changes); dn=ass.get('driver_name','') if ass else ''; route=str(ass.get('route_no','')) if ass else ''; run=ass.get('run_order',-1) if ass else -1
        key=(dn,route)
        if dn:
            sums[key]['distance_km']+=r['speed']/3600; sums[key]['max_speed']=max(sums[key]['max_speed'],r['speed'])
            if r['speed']>=cfg.get('speed_watch_kmh',80):
                hits.append({'event_type':'speed_watch','recorded_at':r['dt'],'speed_before':r['speed'],'speed_after':r['speed'],'brake_on':r['brake'],'lat':r['lat'],'lon':r['lon'],'driver_name':dn,'route_no':route,'run_order':run,'evidence':{'speed_kmh':r['speed'],'threshold_kmh':cfg.get('speed_watch_kmh',80)}})
        if prev:
            gap=(r['dt']-prev['dt']).total_seconds()
            if dn and gap>1:sums[key]['gap_seconds']+=max(0,int(gap)-1)
            if gap==1:
                if dn:sums[key]['valid_pair_count']+=1
                dv=r['speed']-prev['speed']; types=[]
                if prev['speed']<=5 and dv>=8:types.append('rapid_start')
                if prev['speed']>=6 and dv>=6:types.append('rapid_accel')
                if r['speed']>=6 and dv<=-9:types.append('rapid_decel')
                if r['speed']<=5 and dv<=-9:types.append('rapid_stop')
                for typ in types:
                    if dn: hits.append({'event_type':typ,'recorded_at':r['dt'],'speed_before':prev['speed'],'speed_after':r['speed'],'brake_on':r['brake'],'lat':r['lat'],'lon':r['lon'],'driver_name':dn,'route_no':route,'run_order':run,'evidence':{'delta_kmh':dv}})
        prev=r
    events=[]
    grouped=group_contiguous_events(hits)
    for e in grouped:
        if e.get('driver_name'):
            k=(e['driver_name'],str(e.get('route_no',''))); typ=e['event_type']
            if typ in sums[k]: sums[k][typ]+=1
        ts=e['recorded_at'].replace(tzinfo=KST).isoformat(); ek=hashlib.sha1(f"{vehicle}|{ts}|{e['event_type']}|{e.get('driver_name','')}|{e.get('route_no','')}".encode()).hexdigest()
        events.append({'event_key':ek,'service_date':svc.isoformat(),'vehicle_no':vehicle,'driver_name':e['driver_name'],'route_no':e['route_no'],'run_order':e['run_order'],'recorded_at':ts,'event_type':e['event_type'],'severity':'candidate','speed_before':e['speed_before'],'speed_after':e['speed_after'],'brake_on':str(bool(e['brake_on'])).lower(),'latitude':e['lat'] if e['lat'] is not None else '','longitude':e['lon'] if e['lon'] is not None else '','criteria_version':'LOCAL-CANDIDATE-v1','evidence':e['evidence']})
    summaries=[]
    for (dn,route),s in sums.items():
        if not dn:continue
        total_pairs=max(1,s['valid_pair_count']); gap=s['gap_seconds']; q='good' if gap<300 else ('review' if gap<1800 else 'limited')
        summaries.append({'service_date':svc.isoformat(),'driver_name':dn,'vehicle_no':vehicle,'route_no':route,'distance_km':round(s['distance_km'],3),'max_speed':s['max_speed'],'rapid_start':s['rapid_start'],'rapid_accel':s['rapid_accel'],'rapid_decel':s['rapid_decel'],'rapid_stop':s['rapid_stop'],'speed_watch':s['speed_watch'],'valid_pair_count':s['valid_pair_count'],'gap_seconds':gap,'data_quality':q})
    imp={'source_file':p.name,'source_path':str(p),'sha256':file_hash,'service_date':svc.isoformat(),'vehicle_no':vehicle,'first_record_at':records[0]['dt'].replace(tzinfo=KST).isoformat(),'last_record_at':records[-1]['dt'].replace(tzinfo=KST).isoformat(),'record_count':len(records),'parser_version':VERSION}
    return imp,events,summaries

def extract_vehicle(name):
    m=re.search(r'(경남\d{2}자\d{4})',name); return m.group(1) if m else ''

# ---------- TAGO BIS ----------
class Tago:
    BASE_ROUTE='https://apis.data.go.kr/1613000/BusRouteInfoInqireService'
    BASE_LOC='https://apis.data.go.kr/1613000/BusLcInfoInqireService'
    def __init__(self,cfg): self.key=cfg.get('tago_service_key',''); self.city_code=cfg.get('city_code',''); self.city_name=cfg.get('city_name','창원시'); self.route_cache={}
    def get(self,url,params):
        q=urllib.parse.urlencode({**params,'serviceKey':self.key,'_type':'json'},safe='%')
        req=urllib.request.Request(url+'?'+q,headers={'User-Agent':'DaewoonSafeDrive/1.0'})
        with urllib.request.urlopen(req,timeout=25) as r: return json.loads(r.read().decode('utf-8','replace'))
    @staticmethod
    def items(j):
        x=(j.get('response') or {}).get('body',{}).get('items',{}).get('item',[])
        if isinstance(x,dict):return [x]
        return x or []
    def ensure_city(self):
        if self.city_code:return self.city_code
        j=self.get(self.BASE_ROUTE+'/getCtyCodeList',{'numOfRows':300,'pageNo':1})
        for x in self.items(j):
            nm=str(x.get('cityname') or x.get('cityName') or '')
            if self.city_name in nm or nm in self.city_name:
                self.city_code=str(x.get('citycode') or x.get('cityCode')); break
        if not self.city_code: raise RuntimeError(f'TAGO 도시코드에서 {self.city_name}을 찾지 못했습니다. collector_config.json의 city_code를 직접 입력하세요.')
        log(f'TAGO 도시코드: {self.city_name}={self.city_code}')
        return self.city_code
    def route_id(self,route_no):
        if route_no in self.route_cache:return self.route_cache[route_no]
        city=self.ensure_city(); j=self.get(self.BASE_ROUTE+'/getRouteNoList',{'cityCode':city,'routeNo':route_no,'numOfRows':100,'pageNo':1})
        candidates=self.items(j); exact=[x for x in candidates if str(x.get('routeno') or x.get('routenum') or x.get('routenm') or '').strip()==str(route_no).strip()]
        x=(exact or candidates)[0] if (exact or candidates) else None
        if not x:return None
        rid=str(x.get('routeid') or x.get('routeId') or '')
        if rid:self.route_cache[route_no]=rid
        return rid or None
    def locations(self,route_no):
        rid=self.route_id(route_no)
        if not rid:return []
        j=self.get(self.BASE_LOC+'/getRouteAcctoBusLcList',{'cityCode':self.ensure_city(),'routeId':rid,'numOfRows':300,'pageNo':1})
        out=[]
        for x in self.items(j):
            out.append({'vehicle':normalize_vehicle(str(x.get('vehicleno') or x.get('vehicleNo') or '')),'node_order':int(x.get('nodeord') or 0),'node_name':x.get('nodenm') or '','lat':x.get('gpslati') or '', 'lon':x.get('gpslong') or '', 'raw':x})
        return [x for x in out if x['vehicle']]

def normalize_vehicle(v): return re.sub(r'\s+','',v).replace('경남71자','경남71자')

def infer_changes(route,expected_rows,live,state,cfg):
    key=str(route); rs=state.setdefault('bis_routes',{}).setdefault(key,{'last':{},'candidates':{},'replacements':{}})
    expected={normalize_vehicle(d['vehicle_no']):d for d in expected_rows if d.get('vehicle_no')}
    # already accepted replacements become expected
    for old,new in rs.get('replacements',{}).items():
        if old in expected:
            d=expected.pop(old); d=d.copy(); d['vehicle_no']=new; expected[new]=d
    live_map={x['vehicle']:x for x in live}; now=datetime.now(KST)
    # unexpected currently on route, missing expected recently seen on this route
    unexpected=[v for v in live_map if v not in expected]
    missing=[v for v in expected if v not in live_map]
    results=[]
    last=rs.get('last',{})
    recent_min=cfg.get('bis_recent_minutes',12)
    pairs=[]
    for newv in unexpected:
        nx=live_map[newv]; cand=[]
        for oldv in missing:
            prev=last.get(oldv)
            if not prev:continue
            try: age=(now-datetime.fromisoformat(prev['seen_at'])).total_seconds()/60
            except:continue
            if age<=recent_min:
                diff=abs(int(prev.get('node_order',0))-int(nx.get('node_order',0))); cand.append((diff,oldv))
        if cand:
            diff,oldv=min(cand); pairs.append((oldv,newv,diff))
    # strong simple pair even without previous node only when exactly 1:1 and missing vehicle seen recently
    if not pairs and len(unexpected)==1 and len(missing)==1 and missing[0] in last:pairs=[(missing[0],unexpected[0],99)]
    for oldv,newv,diff in pairs:
        ck=f'{oldv}->{newv}'; c=rs.setdefault('candidates',{}).setdefault(ck,{'count':0}); c['count']+=1
        if c['count']>=cfg.get('bis_confirm_polls',2) and oldv not in rs.get('replacements',{}):
            d=expected_rows[[normalize_vehicle(x['vehicle_no']) for x in expected_rows].index(oldv)] if oldv in [normalize_vehicle(x['vehicle_no']) for x in expected_rows] else {}
            x=live_map[newv]; detected=now.isoformat(); change_key=hashlib.sha1(f'{now.date()}|{route}|{oldv}|{newv}'.encode()).hexdigest()
            results.append({'change_key':change_key,'service_date':now.date().isoformat(),'route_no':str(route),'run_order':d.get('run_order',-1),'driver_name':d.get('driver_name',''),'old_vehicle':oldv,'new_vehicle':newv,'detected_at':detected,'node_order':x.get('node_order',''),'latitude':x.get('lat',''),'longitude':x.get('lon',''),'confidence':'high' if diff<=3 else 'medium','source':'TAGO','raw':{'node_name':x.get('node_name'),'distance_node_order':diff}})
            rs.setdefault('replacements',{})[oldv]=newv
            log(f'BIS 차량변경 후보 확정 노선 {route}: {oldv} -> {newv} ({d.get("driver_name","")})')
    # refresh last snapshot in local state only
    for v,x in live_map.items():rs.setdefault('last',{})[v]={'node_order':x['node_order'],'seen_at':now.isoformat(),'lat':x.get('lat'),'lon':x.get('lon')}
    # trim stale candidates
    if len(rs.get('candidates',{}))>100:rs['candidates']={k:v for k,v in list(rs['candidates'].items())[-50:]}
    return results

class Collector:
    def __init__(self,cfg): self.cfg=cfg; self.sb=Supabase(cfg); self.state=load_json(STATE_PATH,{'processed':{},'bis_routes':{}}); self.stop=False; self.tago=Tago(cfg)
    def run(self):
        self.sb.login(); log(f'{VERSION} 시작')
        threads=[]
        if self.cfg.get('enable_bis') and self.cfg.get('tago_service_key'):
            t=threading.Thread(target=self.bis_loop,daemon=True);t.start();threads.append(t)
        if self.cfg.get('enable_taco'):
            t=threading.Thread(target=self.taco_loop,daemon=True);t.start();threads.append(t)
        if not threads: log('활성화된 수집 기능이 없습니다.');return
        try:
            while True: time.sleep(1)
        except KeyboardInterrupt: log('종료')
    def taco_loop(self):
        folder=Path(self.cfg.get('taco_folder',DEFAULT_CONFIG['taco_folder'])); log(f'타코 폴더 감시: {folder}')
        while True:
            try:
                if folder.exists():
                    for p in sorted(folder.glob('*')):
                        if p.is_file() and p.suffix.upper()=='.CDT': self.process_cdt(p)
                else: log(f'경고: 타코 폴더가 없습니다: {folder}')
            except Exception as e: log('타코 감시 오류: '+repr(e))
            time.sleep(max(3,int(self.cfg.get('scan_seconds',5))))
    def process_cdt(self,p):
        key=str(p.resolve()); st=p.stat(); sig=f'{st.st_size}:{int(st.st_mtime)}'
        if self.state['processed'].get(key)==sig:return
        time.sleep(self.cfg.get('stable_seconds',8)); st2=p.stat()
        if st2.st_size!=st.st_size:return
        try:
            # read header/first date cheaply, then get matching dispatch
            with p.open('rb') as fp: h=read_header(fp); raw=fp.read(128); first=decode_record(raw) if len(raw)==128 else None
            if not first:return
            svc=service_date_from_filename(p,first['dt']); dispatch=self.sb.dispatch(svc); changes=self.sb.changes(svc)
            imp,events,summaries=analyze_cdt(p,self.cfg,dispatch,changes)
            res=self.sb.ingest_taco(imp,events,summaries); log(f'CDT 수집 {p.name}: records={imp["record_count"]}, events={len(events)}, summaries={len(summaries)}')
            self.state['processed'][key]=sig; save_json(STATE_PATH,self.state)
        except Exception as e: log(f'CDT 처리 실패 {p.name}: {e}\n{traceback.format_exc()}')
    def bis_loop(self):
        log('BIS(TAGO) 차량변경 감시 시작')
        while True:
            try:
                now=datetime.now(KST); today=now.date(); rows=active_dispatch_rows(self.sb.dispatch(today),now); by_route=defaultdict(list)
                for d in rows:
                    route=str(d.get('route_no') or '').strip()
                    if route and route!='-1':by_route[route].append(d)
                all_changes=[]
                for route,ers in by_route.items():
                    try:
                        live=self.tago.locations(route); all_changes.extend(infer_changes(route,ers,live,self.state,self.cfg)); time.sleep(.25)
                    except Exception as e: log(f'BIS 노선 {route} 조회 오류: {e}')
                if all_changes:
                    r=self.sb.ingest_changes(all_changes); log(f'BIS 변경 저장: {r}')
                save_json(STATE_PATH,self.state)
            except Exception as e: log('BIS 감시 오류: '+repr(e))
            time.sleep(max(30,int(self.cfg.get('bis_poll_seconds',60))))

def ensure_config():
    if not CONFIG_PATH.exists():
        save_json(CONFIG_PATH,DEFAULT_CONFIG); print(f'설정파일을 생성했습니다: {CONFIG_PATH}\n값을 입력한 후 다시 실행하세요.'); return None
    cfg=load_json(CONFIG_PATH,DEFAULT_CONFIG)
    missing=[k for k in ('supabase_url','supabase_anon_key') if not cfg.get(k)]
    if missing: print('collector_config.json에 Supabase URL과 anon key를 입력하세요.'); return None
    return {**DEFAULT_CONFIG,**cfg}

if __name__=='__main__':
    cfg=ensure_config()
    if cfg:
        try: Collector(cfg).run()
        except Exception as e: log('시작 실패: '+repr(e)); input('Enter 키를 누르면 종료합니다...')
