import { chromium } from '/opt/node22/lib/node_modules/playwright/index.mjs';
const B='/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
const b = await chromium.launch({ executablePath:B });
const ctx = await b.newContext({ viewport:{width:420,height:900} });
const p = await ctx.newPage();
const errs=[]; const log=[];
p.on('console', m=>{ if(m.type()==='error' && !/ERR_(CONNECTION|NAME|INTERNET)/.test(m.text())) errs.push(m.text()); });
p.on('pageerror', e=>errs.push('PAGEERROR: '+e.message));
const say=(...a)=>{ log.push(a.join(' ')); console.log(...a); };
const T = async (sel,n=0)=>{ const els=await p.$$(sel); return els[n]; };

await p.goto('file://'+process.cwd()+'/preview.html');
await p.waitForTimeout(1200);

// ---- EXAM: start a 30q Core 1 exam
await p.click('[data-tab="exam"]'); await p.waitForTimeout(250);
await p.click('#segLen button[data-v="30"]'); await p.waitForTimeout(100);
await p.click('.btn.primary.wide'); await p.waitForTimeout(400);
let clock = await p.textContent('#exClock');
say('exam started, clock =', clock);
if(clock !== '30:00') errs.push('BAD: expected 30:00, got '+clock);

// answer 3 questions
for(let i=0;i<3;i++){
  await p.click('.opts .opt'); await p.waitForTimeout(150);
  const nx = await p.$$('.btnrow .btn.primary'); await nx[0].click(); await p.waitForTimeout(200);
}
let navDone = await p.$$eval('.qcell.done', e=>e.length);
say('answered 3, navigator shows done cells =', navDone);
if(navDone !== 3) errs.push('BAD: navigator done count = '+navDone);

// let the clock actually tick
await p.waitForTimeout(2600);
const beforePause = await p.textContent('#exClock');
say('clock before pause =', beforePause);
if(beforePause === '30:00') errs.push('BAD: clock never ticked');

// ---- PAUSE
const btns = await p.$$('.exam-hud .btn'); await btns[0].click(); await p.waitForTimeout(400);
const pausedTxt = await p.textContent('#screen');
say('paused screen mentions "in progress":', /in progress/i.test(pausedTxt));
if(!/in progress/i.test(pausedTxt)) errs.push('BAD: no paused card');

// clock must NOT tick while paused
const remA = await p.evaluate(()=>JSON.parse(localStorage.getItem('benchtest.state.v1')).exam.remain);
await p.waitForTimeout(3000);
const remB = await p.evaluate(()=>JSON.parse(localStorage.getItem('benchtest.state.v1')).exam.remain);
say('remain while paused:', remA, '->', remB);
if(remA !== remB) errs.push('BAD: clock kept running while paused ('+remA+'->'+remB+')');

// ---- RELOAD, then RESUME (the real cross-session test)
await p.reload(); await p.waitForTimeout(1200);
await p.click('[data-tab="exam"]'); await p.waitForTimeout(300);
const afterReload = await p.textContent('#screen');
say('exam survived reload:', /in progress/i.test(afterReload));
if(!/in progress/i.test(afterReload)) errs.push('BAD: exam lost on reload');
await p.click('.btn.primary.grow'); await p.waitForTimeout(500);
const resumedClock = await p.textContent('#exClock');
say('resumed clock =', resumedClock, '(was', beforePause+')');
const toS = t=>{ const [m,s]=t.split(':').map(Number); return m*60+s; };
if(Math.abs(toS(resumedClock)-toS(beforePause)) > 3) errs.push('BAD: clock jumped on resume');
const doneAfter = await p.$$eval('.qcell.done', e=>e.length);
say('answers survived reload, done =', doneAfter);
if(doneAfter !== 3) errs.push('BAD: answers lost, done='+doneAfter);

// ---- answer everything then submit
for(let i=0;i<40;i++){
  const opt = await T('.opts .opt', 0); if(!opt) break;
  await opt.click(); await p.waitForTimeout(60);
  const nx = await p.$$('.btnrow .btn.primary'); if(!nx.length) break;
  const label = await nx[0].textContent();
  await nx[0].click(); await p.waitForTimeout(90);
  if(/Review/.test(label)) break;
}
const reviewTxt = await p.textContent('#screen');
say('reached review screen:', /Before you submit/.test(reviewTxt));
p.on('dialog', d=>d.accept());
const rbtns = await p.$$('.btnrow .btn.primary'); await rbtns[0].click(); await p.waitForTimeout(700);
const resultTxt = await p.textContent('#screen');
const scaled = (resultTxt.match(/\b(\d{3})\b/)||[])[1];
say('result screen scaled score =', scaled, '| pass/fail shown:', /PASS|NOT YET/.test(resultTxt));
if(!/PASS|NOT YET/.test(resultTxt)) errs.push('BAD: no verdict on result screen');
if(!/Where the points went/.test(resultTxt)) errs.push('BAD: no domain breakdown');

await p.screenshot({ path:'f1-result.png', fullPage:true });
await p.click('.btn.primary.wide'); await p.waitForTimeout(500); // close out

// ---- STATUS should now show real numbers
const statusTxt = await p.textContent('#screen');
const st = await p.evaluate(()=>{ const s=JSON.parse(localStorage.getItem('benchtest.state.v1'));
  let c=0,w=0; for(const k in s.mastery){c+=s.mastery[k].c;w+=s.mastery[k].w;}
  return {c,w,sem:s.semesters[0].tot, streak:s.streak.n, days:Object.keys(s.days).length}; });
say('after exam -> mastery', st.c+'/'+st.w, '| semester', st.sem.c+'/'+st.sem.w, '| streak', st.streak, '| active days', st.days);
if(st.c+st.w !== 30) errs.push('BAD: mastery total = '+(st.c+st.w)+', expected 30');
if(st.sem.c+st.sem.w !== 30) errs.push('BAD: semester total = '+(st.sem.c+st.sem.w));
if(/Cold Boot/.test(statusTxt)) errs.push('BAD: status still says Cold Boot after 30 answers');
await p.screenshot({ path:'f2-status-live.png', fullPage:true });

// ---- SEMESTERS
await p.click('[data-tab="progress"]'); await p.waitForTimeout(400);
await p.screenshot({ path:'f3-progress.png', fullPage:true });
const semBtns = await p.$$('.sem .btn.sm.wide');
say('found close-semester button:', semBtns.length>0);
if(semBtns.length){
  p.once('dialog', d=>d.accept('Semester 2'));
  await semBtns[0].click(); await p.waitForTimeout(600);
  const s2 = await p.evaluate(()=>{ const s=JSON.parse(localStorage.getItem('benchtest.state.v1'));
    return {n:s.semesters.length, cur:s.semesters.find(x=>x.id===s.cur).name, prevEnd:s.semesters[0].end}; });
  say('semesters =', s2.n, '| active =', s2.cur, '| previous closed on', s2.prevEnd);
  if(s2.n !== 2) errs.push('BAD: new semester not created');
  if(!s2.prevEnd) errs.push('BAD: previous semester not closed');
  // new semester must start at zero but old one keeps its data
  const zero = await p.evaluate(()=>{ const s=JSON.parse(localStorage.getItem('benchtest.state.v1'));
    const cur=s.semesters.find(x=>x.id===s.cur); return {cur:cur.tot, old:s.semesters[0].tot}; });
  say('new semester tot =', JSON.stringify(zero.cur), '| old kept =', JSON.stringify(zero.old));
  if(zero.cur.c+zero.cur.w !== 0) errs.push('BAD: new semester not zeroed');
  if(zero.old.c+zero.old.w !== 30) errs.push('BAD: old semester lost data');
}
await p.screenshot({ path:'f4-two-semesters.png', fullPage:true });

console.log('\n' + (errs.length ? '❌ FAILURES:\n'+errs.join('\n') : '✅ exam + semester flow clean, no errors'));
await b.close();
process.exit(errs.length?1:0);
