/* mentor previewing assets/page.js: inlined into review.html at assembly, where 99-foot.html has its include line (page-contract.md sections 1 and 7). Edit it here, never in a page. */
(function(){try{
var slug=(document.querySelector('meta[name="mentor-subject"]')||{}).content||'';
var ls=null;try{ls=window.localStorage;ls.getItem('mentor-preview:probe');}catch(e){ls=null;}
var live=document.getElementById('pv-live');
function say(m){if(live){live.textContent='';setTimeout(function(){live.textContent=m;},30);}}
var ns=document.querySelector('.pv-noscript');if(ns&&ns.parentNode)ns.parentNode.removeChild(ns);
function pick(s,a){return s.querySelector('.pv-ax-'+a+' input:checked');}
function block(s){var ta=s.querySelector('.pv-ta'),t=ta?ta.value.trim():'';
 var v=pick(s,'variant'),w=pick(s,'view');
 var l='[mentor:preview] subject='+slug+' scenario='+s.dataset.id+' "'+(s.dataset.title||'').replace(/"/g,"'")+'"';
 if(v)l+=' variant='+v.dataset.id;
 l+=' view='+(w?w.dataset.id:(s.dataset.viewDefault||'after'));
 return {text:l+'\n'+t,empty:!t};}
function copy(text,box){function fb(){var f=box&&box.querySelector('.pv-fallback');if(!f)return;f.hidden=false;f.value=text;f.focus();f.select();say('Clipboard blocked. The text is selected; copy it with the keyboard.');}
 try{if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(text).then(function(){say('Copied.');},fb);}else{fb();}}catch(e){fb();}}
Array.prototype.forEach.call(document.querySelectorAll('.pv-scn'),function(s){
 var ta=s.querySelector('.pv-ta'),b=s.querySelector('.pv-copy');
 if(ta&&ls){try{var d=ls.getItem(ta.dataset.key);if(d)ta.value=d;}catch(e){}
  ta.addEventListener('input',function(){try{ls.setItem(ta.dataset.key,ta.value);}catch(e){}});}
 if(b){b.hidden=false;b.addEventListener('click',function(){copy(block(s).text,s);});}});
var all=document.querySelector('.pv-copy-all');
if(all){all.hidden=false;all.addEventListener('click',function(){var o=[];
 Array.prototype.forEach.call(document.querySelectorAll('.pv-scn'),function(s){var b=block(s);if(!b.empty)o.push(b.text);});
 copy(o.length?o.join('\n\n'):'(no comments yet)',all.parentNode);});}
document.addEventListener('change',function(e){var t=e.target;if(t&&t.type==='radio'){var l=document.querySelector('label[for="'+t.id+'"]');if(l)say(l.textContent.trim());}});
var tb=document.querySelector('.pg-theme'),root=document.documentElement;
try{var th=ls&&ls.getItem('mentor-preview:theme');if(th)root.dataset.theme=th;}catch(e){}
if(tb){tb.hidden=false;tb.addEventListener('click',function(){var n=root.dataset.theme==='light'?'dark':'light';root.dataset.theme=n;try{ls&&ls.setItem('mentor-preview:theme',n);}catch(e){}});}
/* contents: mark where the reader is; on a phone, fold the list after a jump */
var toc=document.querySelector('.pg-toc'),narrow=window.matchMedia?matchMedia('(max-width:860px)'):null;
if(toc&&narrow){if(narrow.matches)toc.open=false;
 var sync=function(){toc.open=!narrow.matches;};if(narrow.addEventListener)narrow.addEventListener('change',sync);
 toc.addEventListener('click',function(e){if(e.target.closest&&e.target.closest('a')&&narrow.matches)toc.open=false;});}
var links={},targets=[];
Array.prototype.forEach.call(document.querySelectorAll('.pg-toc a[href^="#"]'),function(a){var id=a.getAttribute('href').slice(1),el=document.getElementById(id);if(el){links[id]=a;targets.push(el);}});
var cur=null,tick=false;
function spot(){tick=false;var top=(parseFloat(getComputedStyle(root).getPropertyValue('--stick'))||0)*16+120,best=null;
 for(var i=0;i<targets.length;i++){if(targets[i].getBoundingClientRect().top<=top)best=targets[i];}
 if(innerHeight+scrollY>=document.documentElement.scrollHeight-2)best=targets[targets.length-1];
 var a=best?links[best.id]:null;if(a===cur)return;if(cur)cur.removeAttribute('aria-current');cur=a;
 var here=toc&&toc.querySelector('.pg-here');if(here)here.textContent=a?a.textContent.replace(/\s+/g,' ').trim():'';
 if(a){a.setAttribute('aria-current','location');var box=toc;if(box&&box.scrollHeight>box.clientHeight){
  var r=a.getBoundingClientRect(),b=box.getBoundingClientRect();if(r.top<b.top+24||r.bottom>b.bottom-24)box.scrollTop+=r.top-b.top-b.height/3;}}}
if(targets.length){window.addEventListener('scroll',function(){if(!tick){tick=true;requestAnimationFrame(spot);}},{passive:true});spot();}
}catch(e){}})();
