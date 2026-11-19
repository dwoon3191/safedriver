import os
import json
import socket
import subprocess
import time
import urllib.request
from pathlib import Path

def whale_path(explicit=''):
    if explicit:
        p=Path(explicit)
        if p.is_file() and p.name.lower()=='whale.exe':return str(p)
        raise ValueError('웨일 실행 파일(whale.exe)을 다시 선택하세요.')
    for env in ('ProgramFiles','ProgramFiles(x86)','LOCALAPPDATA'):
        root=os.environ.get(env)
        if root:
            p=Path(root)/'Naver'/'Naver Whale'/'Application'/'whale.exe'
            if p.is_file():return str(p)
    raise ValueError('웨일을 찾지 못했습니다. [웨일 실행파일 선택]에서 whale.exe를 선택하세요. 다른 브라우저로 자동 전환하지 않습니다.')

class OwnedContext:
    """Close only the dedicated browser launched by this collector."""
    def __init__(self, browser, process):
        self.browser=browser
        self.process=process
        self.context=browser.contexts[0]
        self.closed=False

    def __getattr__(self, name):
        return getattr(self.context,name)

    def close(self):
        if self.closed:return
        self.closed=True
        try:
            session=self.browser.new_browser_cdp_session()
            session.send('Browser.close')
        except Exception:pass
        finally:
            try:self.browser.close()
            except Exception:pass
            stop_owned(self.process)

def stop_owned(process):
    if process.poll() is None:
        try:process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:process.wait(timeout=3)
            except subprocess.TimeoutExpired:process.kill()

def launch_whale(pw,data,executable):
    exe=whale_path(executable)
    root=Path(data)
    profile=root/'browser_whale_cdp'
    profile.mkdir(parents=True,exist_ok=True)
    # Never attach to a browser left over from another collector session.
    active=profile/'DevToolsActivePort'
    if active.exists():
        try:
            oldport=int(active.read_text().splitlines()[0])
            with socket.create_connection(('127.0.0.1',oldport),timeout=0.3):
                raise RuntimeError('이전 수집 전용 웨일 창이 열려 있습니다. 그 창을 닫고 다시 실행하세요.')
        except (OSError,ValueError,IndexError):pass
        active.unlink(missing_ok=True)
    logpath=root/'whale_launch.log'
    def record(message):
        with logpath.open('a',encoding='utf-8') as out:
            out.write(time.strftime('%Y-%m-%d %H:%M:%S')+' '+message+'\n')
    record('v2.0.4: starting dedicated Whale; waiting for CDP endpoint')
    # Port 0 asks the browser to allocate a free local debugging port.
    args=[exe,'--user-data-dir='+str(profile),'--remote-debugging-address=127.0.0.1',
          '--remote-debugging-port=0','--no-first-run','--no-default-browser-check',
          '--start-maximized','about:blank']
    with logpath.open('ab') as log:
        process=subprocess.Popen(args,stdin=subprocess.DEVNULL,stdout=log,stderr=log)
    browser=None
    try:
        deadline=time.monotonic()+30
        endpoint=None
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
        exit_logged=False
        while time.monotonic()<deadline:
            try:
                port=int(active.read_text().splitlines()[0])
                if not 1<=port<=65535:raise ValueError('invalid port')
                endpoint='http://127.0.0.1:'+str(port)
                with opener.open(endpoint+'/json/version',timeout=1) as response:
                    info=json.load(response)
                if info.get('webSocketDebuggerUrl'):break
            except (OSError,ValueError,IndexError):pass
            code=process.poll()
            if code is not None and not exit_logged:
                record('Initial process exited: '+str(code)+'; checking dedicated endpoint')
                exit_logged=True
            if code not in (None,0):
                raise RuntimeError('웨일 실행 프로세스가 오류로 종료되었습니다. 종료코드: '+str(code))
            time.sleep(0.2)
        else:raise RuntimeError('웨일 연결 준비가 30초 안에 완료되지 않았습니다.')
        record('CDP endpoint ready; attaching collector')
        browser=pw.chromium.connect_over_cdp(endpoint,timeout=15000)
        if not browser.contexts:raise RuntimeError('웨일 수집 창을 찾지 못했습니다.')
        record('Collector attached successfully')
        return OwnedContext(browser,process)
    except Exception as exc:
        record('Connection failed: '+type(exc).__name__+'; see collector error message')
        if browser:
            try:browser.close()
            except Exception:pass
        stop_owned(process)
        raise RuntimeError('웨일 연결 실패: '+str(exc)+'\n실행기록: '+str(logpath)+'\n일반 웨일에서 whale://version 을 열어 버전을 확인하고 오류와 함께 전달해주세요.') from exc

def launch_browser(pw,data,choice,executable=''):
    if choice=='웨일':return launch_whale(pw,data,executable)
    options=dict(headless=False,accept_downloads=True,no_viewport=True,args=['--start-maximized'])
    return pw.chromium.launch_persistent_context(str(Path(data)/'browser'),**options)
