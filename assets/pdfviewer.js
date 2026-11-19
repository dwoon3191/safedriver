/* In-app PDF viewer (pdf.js, loaded on first use). Resolves after page 1 is drawn; rejects on any failure so the caller can fall back. */
window.PdfViewer=(()=>{
 const BASE='https://cdn.jsdelivr.net/npm/pdfjs-dist@3.11.174/legacy/build/';
 let lib=null;
 function load(){
  if(window.pdfjsLib)return Promise.resolve(window.pdfjsLib);
  if(lib)return lib;
  lib=new Promise((resolve,reject)=>{
   const s=document.createElement('script');s.src=BASE+'pdf.min.js';
   const t=setTimeout(()=>{lib=null;reject(Error('PDF 뷰어 로드 시간 초과'));},15000);
   s.onload=()=>{clearTimeout(t);if(window.pdfjsLib){window.pdfjsLib.GlobalWorkerOptions.workerSrc=BASE+'pdf.worker.min.js';resolve(window.pdfjsLib);}else{lib=null;reject(Error('PDF 뷰어 초기화 실패'));}};
   s.onerror=()=>{clearTimeout(t);lib=null;reject(Error('PDF 뷰어를 불러오지 못했습니다'));};
   document.head.appendChild(s);
  });
  return lib;
 }
 const toBytes=b64=>{const bin=atob(b64);const a=new Uint8Array(bin.length);for(let i=0;i<bin.length;i++)a[i]=bin.charCodeAt(i);return a;};
 async function open(base64,{title='',onClose=()=>{}}={}){
  const pdfjs=await load();
  const doc=await pdfjs.getDocument({data:toBytes(base64)}).promise;
  const root=document.createElement('div');root.className='pv-root';
  root.innerHTML=`<div class="pv-bar"><div class="pv-title"></div><div class="pv-ctl"><button class="pv-b" data-z="-1" aria-label="작게">－</button><button class="pv-b" data-z="1" aria-label="크게">＋</button><button class="pv-b pv-x">닫기</button></div></div><div class="pv-body"></div>`;
  root.querySelector('.pv-title').textContent=title;
  document.body.appendChild(root);document.body.classList.add('pv-lock');
  const body=root.querySelector('.pv-body');let zoom=1,token=0,closed=false;
  async function draw(){
   const my=++token;body.innerHTML='';
   const width=Math.max(240,body.clientWidth-8)*zoom;const dpr=Math.min(window.devicePixelRatio||1,2);
   for(let n=1;n<=doc.numPages;n++){
    if(closed||my!==token)return;
    const page=await doc.getPage(n);const v1=page.getViewport({scale:1});
    const scale=width/v1.width;const vp=page.getViewport({scale:scale*Math.min(dpr,2000/(v1.width*scale))});
    const cv=document.createElement('canvas');cv.width=Math.floor(vp.width);cv.height=Math.floor(vp.height);
    cv.style.width=Math.floor(width)+'px';cv.style.height=Math.floor(width*v1.height/v1.width)+'px';cv.className='pv-page';
    body.appendChild(cv);
    await page.render({canvasContext:cv.getContext('2d'),viewport:vp}).promise;
   }
  }
  function close(){if(closed)return;closed=true;token++;root.remove();document.body.classList.remove('pv-lock');try{doc.destroy();}catch{}onClose();}
  root.querySelector('.pv-x').onclick=close;
  root.querySelectorAll('[data-z]').forEach(b=>b.onclick=()=>{zoom=Math.min(3,Math.max(1,zoom+Number(b.dataset.z)*0.5));draw().catch(()=>{});});
  try{
   // First page must render before we report success; later pages continue in the background.
   const first=await doc.getPage(1);const v1=first.getViewport({scale:1});
   const width=Math.max(240,body.clientWidth-8);const dpr=Math.min(window.devicePixelRatio||1,2);
   const scale=width/v1.width;const vp=first.getViewport({scale:scale*Math.min(dpr,2000/(v1.width*scale))});
   const cv=document.createElement('canvas');cv.width=Math.floor(vp.width);cv.height=Math.floor(vp.height);cv.style.width=Math.floor(width)+'px';cv.style.height=Math.floor(width*v1.height/v1.width)+'px';cv.className='pv-page';
   body.appendChild(cv);await first.render({canvasContext:cv.getContext('2d'),viewport:vp}).promise;
   body.innerHTML='';draw().catch(()=>{});
  }catch(err){closed=true;root.remove();document.body.classList.remove('pv-lock');try{doc.destroy();}catch{}throw err;}
  return {close};
 }
 return {open};
})();
