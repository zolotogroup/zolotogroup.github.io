/* Пульт: слой читабельности разделов (кегли по шкале гайда, h1 40 px, без жирного, красный только для просрочек, ₽ не отрывается) и шапка телефона в одну строку с меню. */
(function(){
function isRedColor(col){
 const m=String(col||'').replace(/\s/g,'').match(/rgba?\((\d+),(\d+),(\d+)/);
 if(!m) return false;
 const r=+m[1], g=+m[2], b=+m[3];
 return r>=150 && g<=90 && b<=90 && r>g*1.5 && r>b*1.5;
}
function snapPx(px, tag){
 /* заголовок раздела и крупные цифры (KPI от 30 px) не подгоняем: их размер задают стили, на телефоне h1 28 px */
 if(tag==='H1') return null;
 if(px>=30) return null;
 const scale=[11,13,14,16.5,18,23,26];
 let best=11, dist=1e9;
 scale.forEach(s=>{
  const d=Math.abs(s-px);
  if(d<dist || (d===dist && s>best)){ dist=d; best=s; }
 });
 return best;
}
window.liftSmall=function(doc){
 if(!doc||!doc.body||doc.__zgLift) return;
 doc.__zgLift=1;
 if(!doc.getElementById('zg-guide-sec')){
  const st=doc.createElement('style');
  st.id='zg-guide-sec';
  st.textContent=[
   'b,strong{font-weight:400!important}',
   'html body table th{font-family:"Aeroport Mono",ui-monospace,Menlo,monospace!important;font-size:11px!important;font-weight:400!important;letter-spacing:.08em!important}',
   'html body table{font-variant-numeric:tabular-nums}',
   'html body h1{font-family:"Zoloto Display","Stratos",sans-serif!important;font-weight:400!important}',
   '@media(min-width:801px){html body h1{font-size:40px!important;line-height:1.12!important}}',
   '@media(max-width:800px){html body h1{font-size:28px!important;line-height:1.15!important}}'
  ].join('');
  (doc.head||doc.documentElement).appendChild(st);
 }
 const run=()=>{
  const view=doc.defaultView;
  if(!view||!doc.body) return;
  const sec=(view.frameElement&&view.frameElement.dataset.sec)||'';
  const els=doc.querySelectorAll('body *');
  for(const e of els){
   if(e.closest('style,script')) continue;
   if(e.closest('svg')){
    if((e.tagName==='text'||e.tagName==='tspan')){
     const w=view.getComputedStyle(e).fontWeight;
     if(w==='bold'||Number(w)>=600) e.style.setProperty('font-weight','400','important');
    }
    continue;
   }
   const own=[...e.childNodes].filter(n=>n.nodeType===3).map(n=>n.textContent).join(' ').replace(/\s+/g,' ').trim();
   const t=(e.textContent||'').replace(/\s+/g,' ').trim();
   const cs=view.getComputedStyle(e);
   const fw0=cs.fontWeight;
   if(fw0==='bold'||fw0==='600'||fw0==='700'||Number(fw0)>=600) e.style.setProperty('font-weight','400','important');
   if(!own) continue;
   const px=parseFloat(cs.fontSize);
   if(px){
    const next=snapPx(px, e.tagName);
    const want=next+'px';
    if(next!==null && Math.abs(next-px)>0.2 && e.style.getPropertyValue('font-size')!==want) e.style.setProperty('font-size', want,'important');
   }
   const fam=(cs.fontFamily||'').split(',')[0]||'';
   if(/monospace/i.test(cs.fontFamily) && !/Aeroport/i.test(fam)) e.style.setProperty('font-family','"Aeroport Mono",ui-monospace,Menlo,monospace','important');
   const col=cs.color;
   const warn=/просроч|не поступило/i.test(own);
   if(isRedColor(col) && !warn) e.style.setProperty('color','#1d1d1b','important');
   const bg=cs.backgroundColor;
   if(isRedColor(bg)){
    e.style.setProperty('background','#fff','important');
    e.style.setProperty('box-shadow','inset 0 0 0 2px #e30c13','important');
   }
   if(px>=20 && /₽/.test(own) && /млн/.test(own)) e.style.setProperty('white-space','nowrap','important');
  }
  if(sec==='fin'||sec==='fot'||sec==='kassa'||sec==='taxi'||sec==='lic'||sec==='org'){
   doc.querySelectorAll('.tabpane > div').forEach(el=>{
    const text=(el.innerText||'').replace(/\s+/g,'').trim();
    if(!text && !el.querySelector('img,svg,canvas,table,button')) el.remove();
   });
  }
 };
 run();
 setTimeout(run, 400);
 setTimeout(run, 1400);
 doc.addEventListener('click', ()=>{ clearTimeout(doc.__zgLiftT); doc.__zgLiftT=setTimeout(run, 80); }, true);
 const MO=doc.defaultView&&doc.defaultView.MutationObserver;
 if(!doc.__zgLiftMo && MO){
  doc.__zgLiftMo=new MO(()=>{ clearTimeout(doc.__zgLiftT); doc.__zgLiftT=setTimeout(run, 150); });
  doc.__zgLiftMo.observe(doc.body,{childList:true,subtree:true});
 }
};
const MENU_IDS=['testbtn','pfbtn','animbtn','viewsw','grpbtn','biobtn','exitbtn'];
function layoutHead(){
 const top=document.querySelector('.top');
 const menu=document.getElementById('headmenu');
 const btn=document.getElementById('menubtn');
 if(!top||!menu||!btn) return;
 const phone=window.matchMedia('(max-width:760px)').matches;
 const anchor=document.getElementById('zg-head-search');
 MENU_IDS.forEach(id=>{
  const el=document.getElementById(id);
  if(!el) return;
  if(phone){ if(el.parentElement!==menu) menu.appendChild(el); }
  else if(el.parentElement!==top){
   if(anchor&&anchor.parentElement===top) top.insertBefore(el, anchor);
   else top.appendChild(el);
  }
 });
 if(!phone){ menu.hidden=true; btn.setAttribute('aria-expanded','false'); }
}
function boot(){
 layoutHead();
 const menuBtn=document.getElementById('menubtn');
 const menu=document.getElementById('headmenu');
 if(menuBtn&&menu&&!menuBtn.dataset.wired){
  menuBtn.dataset.wired='1';
  menuBtn.onclick=ev=>{
   ev.stopPropagation();
   const open=menu.hidden;
   menu.hidden=!open;
   menuBtn.setAttribute('aria-expanded', open?'true':'false');
  };
  document.addEventListener('click', ev=>{
   if(!menu.hidden && !(ev.target.closest&&ev.target.closest('#headmenu,#menubtn'))){ menu.hidden=true; menuBtn.setAttribute('aria-expanded','false'); }
  });
  window.addEventListener('resize', layoutHead);
 }
}
if(document.readyState==='loading') document.addEventListener('DOMContentLoaded', boot); else boot();
})();
