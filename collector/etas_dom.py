"""DOM selectors captured from the user's actual eTAS screens, not coordinates."""
PATH_JS = r"""
function pathFor(el) {
 const parts=[];
 while(el && el.nodeType===1){
  if(el.id && document.querySelectorAll('#'+CSS.escape(el.id)).length===1){parts.unshift('#'+CSS.escape(el.id));break;}
  let n=1,p=el;while((p=p.previousElementSibling))if(p.tagName===el.tagName)n++;
  parts.unshift(el.tagName.toLowerCase()+':nth-of-type('+n+')');el=el.parentElement;
 } return parts.join(' > ');
}
"""
PICK_SCRIPT = r"""(kind) => {
""" + PATH_JS + r"""
 window.__dw_pick=null;
 window.__dw_error=null;
 window.__dw_handler=(e)=>{
  e.preventDefault();e.stopImmediatePropagation();
  let el=e.target.closest('button,a,input,select,label,[role="button"],[onclick]')||e.target;
  if(kind==='driver_list'){
   const tables=[];let t=el.closest('table');
   while(t){tables.push(t);t=t.parentElement?.closest('table');}
   el=tables.find(t=>/운전자\s*이름/.test(t.innerText))||tables[0];
   if(!el){window.__dw_error='기사 목록의 이름을 클릭하세요. 표를 찾지 못했습니다.';return;}
  }else if(kind==='pagination'){
   let p=el.parentElement;el=null;
   while(p && p!==document.body){
    const text=p.innerText.trim();
    const numbers=[...p.querySelectorAll('a,span,strong,b,em')].filter(x=>!x.querySelector('a,span,strong,b,em') && /^\d+$/.test(x.textContent.trim()));
    if(p.querySelectorAll('a').length && numbers.length>=2 && text.length<250 && !/[가-힣A-Za-z]/.test(text)) {el=p;break;}
    p=p.parentElement;
   }
   if(!el){window.__dw_error='기사 목록 아래 페이지 번호를 클릭하세요. 번호 영역을 특정하지 못했습니다.';return;}
  }
  if(el.tagName==='LABEL'&&el.htmlFor)el=document.getElementById(el.htmlFor)||el;
  window.__dw_pick=pathFor(el);
  document.removeEventListener('click',window.__dw_handler,true);
 };
 document.addEventListener('click',window.__dw_handler,true);
}"""
CLEAR_PICK = "document.removeEventListener('click',window.__dw_handler,true);window.__dw_handler=null;window.__dw_pick=null;window.__dw_error=null;"

# Semantic labels include image alt/title and nested icons. Avoid matching by filename or position.
BUTTONS_SCRIPT = r"""(key) => {
""" + PATH_JS + r"""
 const patterns={query:/^조회$/,file_download:/^(파일다운로드|파일download)$/i,
 pdf_download:/^(pdf|pdf다운로드|pdf저장|pdfdownload|downloadpdf|savepdf)$/i,
 xls_download:/^(excel|xls|엑셀|엑셀다운로드|엑셀저장|exceldownload|downloadexcel|saveexcel)$/i};
 const match=patterns[key];if(!match)return [];
 const out=new Set();
 for(const node of document.querySelectorAll('a,button,input,img,[role="button"],[onclick],[title],[aria-label]')){
  const labels=[node.textContent,node.getAttribute('alt'),node.getAttribute('title'),node.getAttribute('aria-label'),node.getAttribute('value')];
  if(!labels.some(s=>s && match.test(s.replace(/\s+/g,''))))continue;
  const el=node.closest('button,a,input,[role="button"],[onclick]')||node;
  const rect=el.getBoundingClientRect();if(rect.width && rect.height)out.add(pathFor(el));
 }return [...out];
}"""
