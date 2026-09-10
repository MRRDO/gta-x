<script>
/* ============================================================
   Bench Test — app engine
   ============================================================ */
const LS_KEY = "benchtest.state.v1";
const DB_PATH = "state/main";
const RANKS = [
  [0,  "Cold Boot",        "Nothing logged yet. Run a drill and let's get a baseline."],
  [15, "Cable Monkey",     "You know which end plugs in. Keep going."],
  [30, "Tier 1",           "You can close easy tickets. The hard domains are still soft."],
  [45, "Field Tech",       "Solid working knowledge. Weak spots are what's holding the score down."],
  [60, "Bench Certified",  "You'd survive a real bench. Not exam-safe yet."],
  [72, "Senior Tech",      "Strong. Tighten the last two or three domains."],
  [84, "Exam Ready",       "This is passing territory. Run full timed sims now."],
  [93, "Overqualified",    "You're teaching this at this point. Go book the test."]
];
const LEITNER = [0, 1, 3, 7, 21];
const CARD_TAB_KEY = "cards";

let S = null, DB = null, saveTimer = null, tick = null, ui = {};

/* ---------- state ---------- */
function blankState(){
  const id = "sem" + Date.now();
  return {
    v:1, updatedAt: Date.now(),
    profile:{ examDate:null, dailyGoal:20, focus:"both", theme:"auto" },
    mastery:{}, cards:{}, days:{}, streak:{n:0,last:null},
    semesters:[{ id, name:"Semester 1", start: todayKey(), end:null, dom:{}, tot:{c:0,w:0} }],
    cur:id, exam:null, bestSpeed:0
  };
}
function todayKey(d){ const t = d||new Date(); return t.getFullYear()+"-"+String(t.getMonth()+1).padStart(2,"0")+"-"+String(t.getDate()).padStart(2,"0"); }
function dayNum(k){ const [y,m,d]=k.split("-").map(Number); return Math.floor(Date.UTC(y,m-1,d)/864e5); }

function mergeState(a,b){
  if(!a) return b; if(!b) return a;
  const newer = (a.updatedAt||0) >= (b.updatedAt||0) ? a : b, older = newer===a?b:a;
  const out = JSON.parse(JSON.stringify(newer));
  // mastery: keep whichever entry has more attempts
  for(const k in older.mastery||{}){
    const o = older.mastery[k], n = out.mastery[k];
    if(!n || (o.c+o.w) > (n.c+n.w)) out.mastery[k] = o;
  }
  for(const k in older.cards||{}){
    const o = older.cards[k], n = out.cards[k];
    if(!n || (o.reps||0) > (n.reps||0)) out.cards[k] = o;
  }
  for(const k in older.days||{}){
    const o = older.days[k], n = out.days[k];
    if(!n || o.a > n.a) out.days[k] = o;
  }
  const byId = {}; (out.semesters||[]).forEach(s=>byId[s.id]=s);
  (older.semesters||[]).forEach(s=>{
    const e = byId[s.id];
    if(!e){ out.semesters.push(s); }
    else if((s.tot.c+s.tot.w) > (e.tot.c+e.tot.w)){ Object.assign(e, s); }
  });
  out.bestSpeed = Math.max(out.bestSpeed||0, older.bestSpeed||0);
  if((older.streak?.n||0) > (out.streak?.n||0)) out.streak = older.streak;
  return out;
}
function loadLocal(){ try{ const r = localStorage.getItem(LS_KEY); return r ? JSON.parse(r) : null; }catch(e){ return null; } }
function saveLocal(){ try{ localStorage.setItem(LS_KEY, JSON.stringify(S)); }catch(e){} }
function save(){
  S.updatedAt = Date.now(); saveLocal();
  clearTimeout(saveTimer);
  saveTimer = setTimeout(()=>{ if(DB) DB.doc(DB_PATH).set(S).catch(()=>{}); }, 700);
}

/* ---------- scoring ---------- */
function activeDomains(){
  const f = S.profile.focus;
  return DOMAINS.filter(d => f==="both" || (f==="c1"&&d.core===1) || (f==="c2"&&d.core===2));
}
function qsIn(k){ return QUESTIONS.filter(q=>q.d===k); }
function domainStat(k){
  const all = qsIn(k); let c=0,w=0,seen=0;
  all.forEach(q=>{ const m=S.mastery[q.i]; if(m){ seen++; c+=m.c; w+=m.w; } });
  const att = c+w;
  const acc = att ? c/att : 0;
  const cov = all.length ? Math.min(1, seen/all.length) : 0;
  return { total:all.length, seen, c, w, att, acc, cov, ready: acc*cov };
}
function readiness(){
  const ds = activeDomains(); if(!ds.length) return 0;
  let num=0, den=0;
  const perCore = {};
  ds.forEach(d=>{ perCore[d.core]=(perCore[d.core]||0)+d.w; });
  const cores = Object.keys(perCore).length;
  ds.forEach(d=>{
    const share = (d.w/perCore[d.core])/cores;
    num += share * domainStat(d.k).ready; den += share;
  });
  return den ? Math.round(100*num/den) : 0;
}
function rankFor(p){ let r=RANKS[0]; for(const x of RANKS) if(p>=x[0]) r=x; return r; }
function totals(){
  let c=0,w=0; for(const k in S.mastery){ c+=S.mastery[k].c; w+=S.mastery[k].w; } return {c,w};
}
function curSem(){ return S.semesters.find(s=>s.id===S.cur) || S.semesters[S.semesters.length-1]; }
function missedIds(){ return Object.keys(S.mastery).filter(k=>S.mastery[k].lastWrong && QUESTIONS.some(q=>q.i===k)); }
function dueCards(){
  const t = dayNum(todayKey());
  return CARDS.filter(c=>{ const m=S.cards[c.i]; return !m || (m.due||0) <= t; });
}
function daysUntilExam(){
  if(!S.profile.examDate) return null;
  return Math.ceil((new Date(S.profile.examDate+"T00:00:00") - new Date(todayKey()+"T00:00:00"))/864e5);
}

/* ---------- recording ---------- */
function recordAnswer(q, correct){
  const m = S.mastery[q.i] || {c:0,w:0};
  if(correct){ m.c++; m.lastWrong=false; } else { m.w++; m.lastWrong=true; }
  m.seen = Date.now(); S.mastery[q.i] = m;

  const dk = todayKey(), day = S.days[dk] || {a:0,c:0};
  day.a++; if(correct) day.c++; S.days[dk] = day;

  if(S.streak.last !== dk){
    const gap = S.streak.last ? dayNum(dk)-dayNum(S.streak.last) : 99;
    S.streak.n = gap===1 ? S.streak.n+1 : 1;
    S.streak.last = dk;
  }
  const sem = curSem();
  if(sem){
    sem.dom[q.d] = sem.dom[q.d] || {c:0,w:0};
    sem.dom[q.d][correct?"c":"w"]++;
    sem.tot[correct?"c":"w"]++;
  }
  save();
}

/* ---------- question selection ---------- */
function shuffle(a){ a=a.slice(); for(let i=a.length-1;i>0;i--){ const j=Math.floor(Math.random()*(i+1)); [a[i],a[j]]=[a[j],a[i]]; } return a; }
function pool(){ const ks = activeDomains().map(d=>d.k); return QUESTIONS.filter(q=>ks.includes(q.d)); }
function smartPick(n, src){
  const list = src || pool();
  const scored = list.map(q=>{
    const m = S.mastery[q.i];
    let s = Math.random();
    if(!m) s += 1.4;                         // never seen
    else {
      if(m.lastWrong) s += 1.9;              // missed last time
      const acc = m.c/(m.c+m.w);
      s += (1-acc) * 1.1;
      s -= Math.min(0.7, m.c*0.18);          // stop grinding what you know
    }
    s += (1 - domainStat(q.d).ready) * 0.9;  // weak domain boost
    return {q, s};
  });
  scored.sort((a,b)=>b.s-a.s);
  return shuffle(scored.slice(0, Math.min(n*2, scored.length))).slice(0,n).map(x=>x.q);
}
function examPick(n, core){
  const ds = DOMAINS.filter(d=>core?d.core===core:true);
  const totalW = ds.reduce((a,d)=>a+d.w,0);
  let out = [];
  ds.forEach(d=>{
    const want = Math.round(n * d.w/totalW);
    out = out.concat(shuffle(qsIn(d.k)).slice(0, want));
  });
  const rest = shuffle(QUESTIONS.filter(q=>ds.some(d=>d.k===q.d) && !out.includes(q)));
  while(out.length < n && rest.length) out.push(rest.pop());
  return shuffle(out).slice(0,n);
}
function videoURL(q){
  const t = encodeURIComponent("Professor Messer " + (q.core===2?"220-1202":"220-1201") + " " + (q.t||""));
  return "https://www.youtube.com/results?search_query=" + t;
}
function domainOf(k){ return DOMAINS.find(d=>d.k===k); }

/* ---------- tiny dom helpers ---------- */
function esc(s){ return String(s).replace(/[&<>"]/g,m=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[m])); }
function el(html){ const t=document.createElement("div"); t.innerHTML=html.trim(); return t.firstElementChild; }
function toast(msg){
  const old = document.querySelector(".toast"); if(old) old.remove();
  const t = el('<div class="toast">'+esc(msg)+'</div>'); document.body.appendChild(t);
  setTimeout(()=>t.remove(), 2100);
}
function ring(pct, size, stroke, color){
  const r = (size-stroke)/2, cir = 2*Math.PI*r;
  return '<svg width="'+size+'" height="'+size+'" viewBox="0 0 '+size+' '+size+'" aria-hidden="true">'+
    '<circle cx="'+size/2+'" cy="'+size/2+'" r="'+r+'" fill="none" stroke="var(--surf3)" stroke-width="'+stroke+'"></circle>'+
    '<circle cx="'+size/2+'" cy="'+size/2+'" r="'+r+'" fill="none" stroke="'+color+'" stroke-width="'+stroke+
    '" stroke-linecap="round" stroke-dasharray="'+cir+'" stroke-dashoffset="'+(cir*(1-pct/100))+'"></circle></svg>';
}
function meterColor(p){ return p>=75?"var(--ok)": p>=45?"var(--gold)":"var(--bad)"; }

/* ============================================================
   ROUTING
   ============================================================ */
const TABS = [
  ["status","Status",'<path d="M3 12a9 9 0 0 1 18 0"/><path d="M12 12l4.5-3"/><circle cx="12" cy="12" r="1.4"/><path d="M3 12v3M21 12v3"/>'],
  ["drill","Drill",  '<circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="4.5"/><circle cx="12" cy="12" r=".9"/>'],
  ["cards","Cards",  '<rect x="3" y="7" width="18" height="13" rx="2.5"/><path d="M6.5 4h11M5 7V5.5"/>'],
  ["exam","Exam",    '<circle cx="12" cy="13" r="8"/><path d="M12 9v4l2.5 1.6M9 2h6"/>'],
  ["progress","Progress",'<path d="M4 19V9M9.5 19V5M15 19v-7M20.5 19v-4"/>']
];
let route = "status", sub = null;

function go(r, s){ route = r; sub = s||null; window.scrollTo(0,0); render(); }
function renderTabs(){
  ui.tabs.innerHTML = TABS.map(([k,label,path])=>
    '<button class="tab" data-tab="'+k+'" aria-selected="'+(route===k)+'"><svg viewBox="0 0 24 24">'+path+'</svg><span>'+label+'</span></button>'
  ).join("");
  ui.tabs.querySelectorAll("[data-tab]").forEach(b=>b.onclick=()=>go(b.dataset.tab));
}

function render(){
  renderTabs();
  const s = ui.screen;
  if(sub && VIEWS[sub]) { s.innerHTML=""; s.appendChild(VIEWS[sub]()); }
  else { s.innerHTML=""; s.appendChild(VIEWS[route]()); }
  ui.coreLabel.textContent = ({both:"CORE 1 + CORE 2 · V15", c1:"CORE 1 · 220-1201", c2:"CORE 2 · 220-1202"})[S.profile.focus];
}

/* ============================================================
   VIEW: STATUS
   ============================================================ */
function statusView(){
  const p = readiness(), rank = rankFor(p), t = totals();
  const ratio = t.w ? (t.c/t.w).toFixed(2) : (t.c ? "∞" : "—");
  const dk = todayKey(), today = S.days[dk] || {a:0,c:0};
  const goal = S.profile.dailyGoal;
  const goalPct = Math.min(100, Math.round(100*today.a/goal));
  const dLeft = daysUntilExam();
  const ds = activeDomains().map(d=>({d, st:domainStat(d.k)}));
  const weak = ds.filter(x=>x.st.att>0).sort((a,b)=>a.st.ready-b.st.ready).slice(0,2);
  const untouched = ds.filter(x=>x.st.att===0);

  const wrap = el('<div class="stack"></div>');

  wrap.appendChild(el(
    '<div class="readout">'+
      '<div class="readout-top">'+
        '<div class="dial">'+ring(p,104,9,meterColor(p))+
          '<div class="dial-val"><b>'+p+'</b><small>ready</small></div></div>'+
        '<div class="grow">'+
          '<div class="eyebrow">Current standing</div>'+
          '<div class="rank">'+esc(rank[1])+'</div>'+
          '<div class="rank-sub">'+esc(rank[2])+'</div>'+
        '</div>'+
      '</div>'+
      '<div class="readout-strip">'+
        '<div class="strip-cell"><b>'+t.c+' <span style="color:var(--ink3);font-weight:400">/</span> '+t.w+'</b><div class="eyebrow">Right / Wrong</div></div>'+
        '<div class="strip-cell"><b>'+ratio+'</b><div class="eyebrow">W/L ratio</div></div>'+
        '<div class="strip-cell"><b>'+S.streak.n+'</b><div class="eyebrow">Day streak</div></div>'+
      '</div>'+
    '</div>'
  ));

  if(t.c+t.w > 0){
    const wpct = Math.round(100*t.c/(t.c+t.w));
    wrap.appendChild(el(
      '<div class="card"><div class="sec-h"><h2>Lifetime accuracy</h2><span class="mono" style="font-size:13px;color:'+meterColor(wpct)+'">'+wpct+'%</span></div>'+
      '<div class="wl"><i class="w" style="width:'+wpct+'%"></i><i class="l" style="width:'+(100-wpct)+'%"></i></div>'+
      '<div class="row" style="margin-top:9px;justify-content:space-between"><span class="eyebrow" style="color:var(--ok)">'+t.c+' correct</span>'+
      '<span class="eyebrow" style="color:var(--bad)">'+t.w+' missed</span></div></div>'
    ));
  }

  // today + countdown
  const cd = el('<div class="card"></div>');
  cd.innerHTML =
    '<div class="sec-h"><h2>Today</h2><span class="mono" style="font-size:12px;color:var(--ink3)">'+today.a+' / '+goal+' questions</span></div>'+
    '<div class="meter-track"><div class="meter-fill" style="width:'+goalPct+'%;background:'+(goalPct>=100?"var(--ok)":"var(--gold)")+'"></div></div>'+
    '<div class="row" style="margin-top:11px;gap:9px">'+
      '<button class="btn primary grow" id="goDrill">'+(today.a?"Keep drilling":"Start today's drill")+'</button>'+
      (dueCards().length ? '<button class="btn" id="goCards">'+dueCards().length+' cards due</button>' : '')+
    '</div>'+
    (dLeft!==null ? '<div class="row" style="margin-top:12px;padding-top:11px;border-top:1px solid var(--line);justify-content:space-between">'+
      '<span class="eyebrow">Exam day</span><span class="mono" style="font-size:13px;color:'+(dLeft<=14?"var(--bad)":"var(--gold)")+'">'+
      (dLeft>0? dLeft+" days out" : dLeft===0 ? "TODAY — go get it" : "passed")+'</span></div>' : '');
  wrap.appendChild(cd);

  // domain readout
  const dv = el('<div class="card"><div class="sec-h"><h2>Domain readout</h2><span class="eyebrow">Accuracy × coverage</span></div></div>');
  ds.forEach(({d,st})=>{
    const r = Math.round(st.ready*100);
    dv.appendChild(el(
      '<div class="meter"'+(st.att?'':' style="padding:8px 0"')+'>'+
        '<div class="meter-name"><span class="dot" style="background:'+d.c+'"></span>'+
          '<span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">'+esc(d.n)+'</span>'+
          '<em>C'+d.core+' '+d.o+'</em></div>'+
        '<div class="meter-pct"'+(st.att?'':' style="color:var(--ink3);font-size:11px;letter-spacing:.08em;text-transform:uppercase"')+'>'+
          (st.att ? r+'%' : 'untouched')+'</div>'+
        '<div class="meter-track"><div class="meter-fill" style="width:'+r+'%;background:'+meterColor(r)+'"></div></div>'+
        (st.att ? '<div class="meter-note">'+Math.round(st.acc*100)+'% correct · '+st.seen+'/'+st.total+' questions seen</div>' : '')+
      '</div>'
    ));
  });
  wrap.appendChild(dv);

  // weak spots
  if(weak.length || untouched.length){
    const ws = el('<div class="card"><div class="sec-h"><h2>Where you\'re losing points</h2></div><div class="stack" style="gap:8px"></div></div>');
    const body = ws.querySelector(".stack");
    weak.forEach(({d,st})=>{
      const r = Math.round(st.ready*100);
      const row = el('<div class="rec"><div class="rec-i" style="background:'+d.c+';color:#0d1117">'+d.o[0]+'</div>'+
        '<div class="grow"><b>'+esc(d.n)+'</b> — '+Math.round(st.acc*100)+'% correct over '+st.att+' attempts. '+
        'That domain is '+d.w+'% of '+CORE_INFO[d.core].name+'.</div></div>');
      const b = el('<button class="btn sm">Drill</button>'); b.onclick=()=>startQuiz({label:d.n, src:qsIn(d.k), n:10});
      row.appendChild(b); body.appendChild(row);
    });
    if(untouched.length){
      const first = untouched.slice(0,3).map(x=>x.d.n).join(", ");
      const more = untouched.length>3 ? ", and "+(untouched.length-3)+" more" : "";
      const heaviest = untouched.slice().sort((a,b)=>b.d.w-a.d.w)[0].d;
      const row = el('<div class="rec"><div class="rec-i" style="background:var(--surf3);color:var(--ink2)">?</div>'+
        '<div class="grow"><b>'+untouched.length+' domain'+(untouched.length>1?'s':'')+' untouched</b> — '+
        esc(first)+esc(more)+'. Zero coverage caps your readiness no matter how good your accuracy is. '+
        'Start with <b>'+esc(heaviest.n)+'</b>, it is the heaviest of them at '+heaviest.w+'%.</div></div>');
      const b = el('<button class="btn sm">Start</button>');
      b.onclick=()=>startQuiz({label:heaviest.n, src:qsIn(heaviest.k), n:10});
      row.appendChild(b); body.appendChild(row);
    }
    wrap.appendChild(ws);
  }

  setTimeout(()=>{
    const a = document.getElementById("goDrill"); if(a) a.onclick=()=>startQuiz({label:"Smart mix", n:10});
    const b = document.getElementById("goCards"); if(b) b.onclick=()=>go(CARD_TAB_KEY);
  },0);
  return wrap;
}

/* ============================================================
   VIEW: DRILL (launcher)
   ============================================================ */
function drillView(){
  const wrap = el('<div class="stack"></div>');
  const miss = missedIds().length;

  wrap.appendChild(el('<div class="sec-h"><h2>Practice</h2><span class="eyebrow">'+pool().length+' questions in scope</span></div>'));

  const tiles = el('<div class="tiles"></div>');
  const mk = (tag,title,desc,fn,disabled)=>{
    const t = el('<button class="tile"'+(disabled?' disabled':'')+'><span class="tag">'+esc(tag)+'</span><b>'+esc(title)+'</b><p>'+esc(desc)+'</p></button>');
    if(!disabled) t.onclick = fn; else t.style.opacity=".45";
    return t;
  };
  tiles.appendChild(mk("Recommended","Smart mix","Weighted toward your weak domains, questions you've never seen, and ones you got wrong.",()=>startQuiz({label:"Smart mix", n:10})));
  tiles.appendChild(mk(miss?"Ready":"Empty","Redo my misses", miss? miss+" questions you got wrong are waiting. Clear them to take them off the list." : "Nothing missed yet. Get some wrong first — that's the point.", ()=>startQuiz({label:"Redo misses", src:QUESTIONS.filter(q=>missedIds().includes(q.i)), n:Math.min(15,miss)}), !miss));
  wrap.appendChild(tiles);

  // by domain
  const bd = el('<div><div class="sec-h" style="margin-top:6px"><h2>By domain</h2></div><div class="card" style="padding:4px 15px"></div></div>');
  const list = bd.querySelector(".card");
  activeDomains().forEach(d=>{
    const st = domainStat(d.k), r = Math.round(st.ready*100);
    const row = el('<div class="meter" style="grid-template-columns:1fr auto auto;align-items:center">'+
      '<div class="meter-name"><span class="dot" style="background:'+d.c+'"></span>'+esc(d.n)+'</div>'+
      '<div class="meter-pct" style="margin-right:8px">'+r+'%</div></div>');
    const b = el('<button class="btn sm">Go</button>');
    b.onclick=()=>startQuiz({label:d.n, src:qsIn(d.k), n:Math.min(12, st.total)});
    row.appendChild(b);
    row.appendChild(el('<div class="meter-track" style="grid-column:1/-1"><div class="meter-fill" style="width:'+r+'%;background:'+meterColor(r)+'"></div></div>'));
    list.appendChild(row);
  });
  wrap.appendChild(bd);

  // PBQs
  const pv = el('<div><div class="sec-h" style="margin-top:6px"><h2>Performance-based sims</h2><span class="eyebrow">Drag &amp; drop</span></div><div class="tiles"></div></div>');
  const pt = pv.querySelector(".tiles");
  PBQS.forEach(p=>{
    const done = S.mastery["PBQ:"+p.i];
    const t = el('<button class="tile"><span class="tag">'+esc(p.kind==="order"?"Sequence":"Matching")+'</span><b>'+esc(p.title)+'</b>'+
      '<p>'+esc(domainOf(p.d).n)+(done? ' · '+(done.c)+'✓ '+(done.w)+'✗' : ' · not attempted')+'</p></button>');
    t.onclick=()=>startPBQ(p); pt.appendChild(t);
  });
  wrap.appendChild(pv);
  return wrap;
}

/* ============================================================
   QUIZ ENGINE
   ============================================================ */
let quiz = null;
function startQuiz(opts){
  const src = opts.src && opts.src.length ? opts.src : pool();
  const qs = opts.shuffled ? shuffle(src).slice(0,opts.n) : smartPick(Math.min(opts.n, src.length), src);
  if(!qs.length){ toast("No questions in that set"); return; }
  quiz = { label:opts.label, src:opts.src||null, qs, i:0, answered:null, right:0, wrong:0, log:[] };
  go(route, "quiz");
}
function quizView(){
  const q = quiz.qs[quiz.i], d = domainOf(q.d);
  const wrap = el('<div></div>');
  wrap.appendChild(el(
    '<div class="qbar"><button class="icobtn" id="qx" aria-label="Exit drill">✕</button>'+
    '<div class="qprog"><i style="width:'+(100*quiz.i/quiz.qs.length)+'%"></i></div>'+
    '<span class="mono" style="font-size:12.5px;color:var(--ink2)">'+(quiz.i+1)+'/'+quiz.qs.length+'</span></div>'
  ));
  wrap.appendChild(el('<div class="qmeta"><span class="pill gold">'+esc(quiz.label)+'</span>'+
    '<span class="pill">'+esc(d.n)+'</span><span class="pill">'+CORE_INFO[d.core].code+' · '+q.o+'</span></div>'));
  wrap.appendChild(el('<p class="qtext">'+esc(q.q)+'</p>'));

  const order = quiz.order || (quiz.order = shuffle(q.c.map((_,i)=>i)));
  const opts = el('<div class="opts"></div>');
  order.forEach((oi,pos)=>{
    const b = el('<button class="opt"><span class="key">'+"ABCD"[pos]+'</span><span>'+esc(q.c[oi])+'</span></button>');
    b.onclick = ()=>answer(oi);
    opts.appendChild(b);
  });
  wrap.appendChild(opts);

  if(quiz.answered !== null){
    const right = quiz.answered === q.a;
    opts.querySelectorAll(".opt").forEach((b,pos)=>{
      const oi = order[pos]; b.disabled = true;
      if(oi === q.a) b.classList.add("correct");
      else if(oi === quiz.answered) b.classList.add("wrong");
      else b.classList.add("dim");
    });
    const v = el('<div class="verdict '+(right?"good":"bad")+'">'+
      '<h3>'+(right?'<span style="color:var(--ok)">✓ Correct</span>':'<span style="color:var(--bad)">✗ Not quite</span>')+'</h3>'+
      '<p>'+esc(q.w)+'</p>'+
      '<div class="ex"><b>In practice:</b> '+esc(q.x)+'</div>'+
      '<a class="watch" target="_blank" rel="noopener" href="'+videoURL(Object.assign({core:d.core},q))+'">▶ Watch a video on '+esc(q.t)+'</a>'+
      '</div>');
    const next = el('<button class="btn primary wide" style="margin-top:13px">'+(quiz.i+1<quiz.qs.length?"Next question":"See results")+'</button>');
    next.onclick = ()=>{
      quiz.answered=null; quiz.order=null; quiz.i++;
      if(quiz.i >= quiz.qs.length) go(route,"quizdone"); else render();
    };
    wrap.appendChild(v); wrap.appendChild(next);
  }
  setTimeout(()=>{ const x=document.getElementById("qx"); if(x) x.onclick=()=>{ sub=null; render(); }; },0);
  return wrap;
}
function answer(oi){
  if(quiz.answered !== null) return;
  const q = quiz.qs[quiz.i], right = oi === q.a;
  quiz.answered = oi; right ? quiz.right++ : quiz.wrong++;
  quiz.log.push({q, right});
  recordAnswer(q, right);
  render();
}
function quizDoneView(){
  const pct = Math.round(100*quiz.right/quiz.qs.length);
  const wrap = el('<div class="stack"></div>');
  wrap.appendChild(el('<div class="card" style="text-align:center;padding:26px 16px">'+
    '<div class="eyebrow">'+esc(quiz.label)+' complete</div>'+
    '<div class="score-big" style="color:'+meterColor(pct)+';margin:8px 0 4px">'+pct+'%</div>'+
    '<div class="mono" style="font-size:13px;color:var(--ink2)">'+quiz.right+' right · '+quiz.wrong+' wrong</div></div>'));

  if(quiz.wrong){
    const rv = el('<div class="card"><div class="sec-h"><h2>What you missed</h2></div><div class="stack" style="gap:9px"></div></div>');
    const b = rv.querySelector(".stack");
    quiz.log.filter(l=>!l.right).forEach(l=>{
      b.appendChild(el('<div class="rec"><div class="rec-i" style="background:var(--bad-dim);color:var(--bad)">✗</div>'+
        '<div class="grow"><b>'+esc(l.q.q)+'</b><br>Answer: '+esc(l.q.c[l.q.a])+'</div></div>'));
    });
    wrap.appendChild(rv);
  }
  const row = el('<div class="btnrow"></div>');
  const again = el('<button class="btn primary grow">Another '+quiz.qs.length+'</button>');
  again.onclick = ()=>startQuiz({label:quiz.label, src:quiz.src, n:quiz.qs.length});
  const done = el('<button class="btn">Done</button>');
  done.onclick = ()=>{ sub=null; go("status"); };
  row.appendChild(again); row.appendChild(done); wrap.appendChild(row);
  return wrap;
}

/* ============================================================
   PBQ ENGINE
   ============================================================ */
let pbq = null;
function startPBQ(p){
  const slots = p.kind==="order"
    ? p.items.map((v,i)=>({label:"", answer:v}))
    : p.slots.map(([l,a])=>({label:l, answer:a}));
  pbq = { p, slots, filled: slots.map(()=>null), poolItems: shuffle(slots.map(s=>s.answer)), armed:null, checked:false };
  go(route, "pbq");
}
function pbqView(){
  const {p, slots, filled, poolItems, armed, checked} = pbq;
  const wrap = el('<div></div>');
  wrap.appendChild(el('<div class="qbar"><button class="icobtn" id="px" aria-label="Exit">✕</button>'+
    '<div class="grow"><b style="font-family:\'IBM Plex Sans Condensed\',sans-serif;font-size:16px">'+esc(p.title)+'</b></div>'+
    '<span class="pill">'+esc(p.kind==="order"?"Sequence":"Match")+'</span></div>'));
  wrap.appendChild(el('<p style="font-size:14px;color:var(--ink2);margin:0 0 13px;line-height:1.5">'+esc(p.prompt)+
    (checked?'':' <span style="color:var(--ink3)">Tap an item, then tap where it goes.</span>')+'</p>'));

  const poolBox = el('<div class="pbq-pool" style="margin-bottom:13px"></div>');
  const remaining = poolItems.filter(v=>!filled.includes(v));
  if(!remaining.length) poolBox.appendChild(el('<span style="font-size:12px;color:var(--ink3);padding:4px">All placed — hit Check.</span>'));
  remaining.forEach(v=>{
    const c = el('<button class="chipdrag'+(armed===v?" picked":"")+'">'+esc(v)+'</button>');
    c.onclick = ()=>{ if(checked) return; pbq.armed = (armed===v?null:v); render(); };
    poolBox.appendChild(c);
  });
  wrap.appendChild(poolBox);

  const slotBox = el('<div class="stack" style="gap:7px"></div>');
  slots.forEach((s,i)=>{
    let cls = "slot";
    if(checked) cls += (filled[i]===s.answer ? " right" : " wrongslot");
    else if(armed) cls += " armed";
    const row = el('<div class="'+cls+'"></div>');
    if(p.kind==="order") row.appendChild(el('<span class="slot-n">'+(i+1)+'</span>'));
    else row.appendChild(el('<span class="slot-label">'+esc(s.label)+'</span>'));
    row.appendChild(el('<span class="slot-val grow"'+(p.kind==="match"?' style="text-align:right"':'')+'>'+
      (filled[i]? esc(filled[i]) : '<span style="color:var(--ink3);font-size:12.5px">—</span>')+'</span>'));
    if(checked && filled[i]!==s.answer) row.appendChild(el('<span class="mono" style="font-size:11px;color:var(--ok);flex:none">'+esc(s.answer)+'</span>'));
    row.onclick = ()=>{
      if(checked) return;
      if(filled[i]){ pbq.filled[i]=null; render(); return; }
      if(armed){ pbq.filled[i]=armed; pbq.armed=null; render(); }
    };
    slotBox.appendChild(row);
  });
  wrap.appendChild(slotBox);

  if(!checked){
    const b = el('<button class="btn primary wide" style="margin-top:14px"'+(filled.includes(null)?" disabled":"")+'>Check answers</button>');
    b.onclick = ()=>{
      pbq.checked = true;
      const got = filled.filter((v,i)=>v===slots[i].answer).length;
      recordAnswer({i:"PBQ:"+p.i, d:p.d}, got===slots.length);
      render();
    };
    wrap.appendChild(b);
  } else {
    const got = filled.filter((v,i)=>v===slots[i].answer).length, all = got===slots.length;
    wrap.appendChild(el('<div class="verdict '+(all?"good":"bad")+'" style="margin-top:14px">'+
      '<h3>'+(all?'<span style="color:var(--ok)">✓ All correct</span>':'<span style="color:var(--bad)">'+got+' of '+slots.length+' correct</span>')+'</h3>'+
      '<p>'+esc(p.why)+'</p></div>'));
    const row = el('<div class="btnrow" style="margin-top:12px"></div>');
    const retry = el('<button class="btn primary grow">Try again</button>'); retry.onclick=()=>startPBQ(p);
    const back = el('<button class="btn">Back</button>'); back.onclick=()=>{ sub=null; go("drill"); };
    row.appendChild(retry); row.appendChild(back); wrap.appendChild(row);
  }
  setTimeout(()=>{ const x=document.getElementById("px"); if(x) x.onclick=()=>{ sub=null; go("drill"); }; },0);
  return wrap;
}

/* ============================================================
   VIEW: CARDS
   ============================================================ */
let deck = null, speed = null;
function cardsView(){
  const due = dueCards(), wrap = el('<div class="stack"></div>');
  const learned = CARDS.filter(c=>(S.cards[c.i]?.box||0) >= 4).length;

  wrap.appendChild(el('<div class="card">'+
    '<div class="sec-h"><h2>Flashcards</h2><span class="mono" style="font-size:12px;color:var(--ink3)">'+learned+'/'+CARDS.length+' locked in</span></div>'+
    '<div class="meter-track"><div class="meter-fill" style="width:'+Math.round(100*learned/CARDS.length)+'%;background:var(--gold)"></div></div>'+
    '<p style="margin:11px 0 0;font-size:12.5px;color:var(--ink3);line-height:1.5">Cards you miss come back tomorrow. Cards you know come back in 1, 3, 7, then 21 days.</p>'+
    '</div>'));

  const start = el('<button class="btn primary wide">'+(due.length? "Review "+due.length+" due cards" : "Nothing due — review anyway")+'</button>');
  start.onclick = ()=>{ deck = { qs: shuffle(due.length?due:CARDS).slice(0,20), i:0, flipped:false, done:0 }; go("cards","deck"); };
  wrap.appendChild(start);

  wrap.appendChild(el('<div class="sec-h" style="margin-top:8px"><h2>Speed round</h2><span class="eyebrow">60 seconds</span></div>'));
  const sp = el('<div class="card"><p style="margin:0 0 12px;font-size:13px;color:var(--ink2);line-height:1.5">'+
    'Rapid-fire ports and acronyms. One minute, as many as you can get. Best so far: <b class="mono">'+(S.bestSpeed||0)+'</b>.</p></div>');
  const sb = el('<button class="btn wide">Start speed round</button>');
  sb.onclick = ()=>{ speed = { i:0, score:0, left:60, items: shuffle(SPEED), answered:null }; go("cards","speed"); };
  sp.appendChild(sb); wrap.appendChild(sp);
  return wrap;
}
function deckView(){
  const c = deck.qs[deck.i];
  if(!c){
    const w = el('<div class="stack"><div class="card" style="text-align:center;padding:30px 16px">'+
      '<div class="eyebrow">Deck complete</div><div class="score-big" style="color:var(--gold);margin:8px 0 4px">'+deck.done+'</div>'+
      '<div class="mono" style="font-size:13px;color:var(--ink2)">cards reviewed</div></div></div>');
    const b = el('<button class="btn primary wide">Back to cards</button>'); b.onclick=()=>{ sub=null; go("cards"); };
    w.appendChild(b); return w;
  }
  const m = S.cards[c.i] || {box:0}, d = domainOf(c.d);
  const wrap = el('<div></div>');
  wrap.appendChild(el('<div class="qbar"><button class="icobtn" id="dx" aria-label="Exit">✕</button>'+
    '<div class="qprog"><i style="width:'+(100*deck.i/deck.qs.length)+'%"></i></div>'+
    '<span class="mono" style="font-size:12.5px;color:var(--ink2)">'+(deck.i+1)+'/'+deck.qs.length+'</span></div>'));
  wrap.appendChild(el('<div class="qmeta"><span class="pill">'+esc(d.n)+'</span><span class="pill gold">Box '+(m.box||0)+'/4</span></div>'));

  const fc = el('<div class="fc'+(deck.flipped?" flipped":"")+'">'+
    '<div class="fc-in">'+
      '<div class="fc-face"><div class="fc-term">'+esc(c.t)+'</div><div class="fc-hint">tap to flip</div></div>'+
      '<div class="fc-face fc-back"><div class="eyebrow" style="margin-bottom:8px">'+esc(c.t)+'</div>'+
        '<div class="fc-def">'+esc(c.b)+'</div><div class="fc-ex" style="margin-top:10px">'+esc(c.x)+'</div></div>'+
    '</div></div>');
  fc.onclick = ()=>{ deck.flipped = !deck.flipped; render(); };
  wrap.appendChild(fc);

  if(deck.flipped){
    const row = el('<div class="btnrow"></div>');
    const bad = el('<button class="btn grow" style="border-color:var(--bad);color:var(--bad)">Missed it</button>');
    const good = el('<button class="btn primary grow">Got it</button>');
    const grade = ok=>{
      const cur = S.cards[c.i] || {box:0, reps:0};
      cur.box = ok ? Math.min(4, (cur.box||0)+1) : 0;
      cur.reps = (cur.reps||0)+1;
      cur.due = dayNum(todayKey()) + LEITNER[cur.box];
      S.cards[c.i] = cur; save();
      deck.done++; deck.i++; deck.flipped=false; render();
    };
    bad.onclick=()=>grade(false); good.onclick=()=>grade(true);
    row.appendChild(bad); row.appendChild(good); wrap.appendChild(row);
  }
  setTimeout(()=>{ const x=document.getElementById("dx"); if(x) x.onclick=()=>{ sub=null; go("cards"); }; },0);
  return wrap;
}
function speedView(){
  const wrap = el('<div></div>');
  if(speed.left <= 0){
    if(speed.score > (S.bestSpeed||0)){ S.bestSpeed = speed.score; save(); }
    wrap.appendChild(el('<div class="card" style="text-align:center;padding:30px 16px">'+
      '<div class="eyebrow">Time</div><div class="score-big" style="color:var(--gold);margin:8px 0 4px">'+speed.score+'</div>'+
      '<div class="mono" style="font-size:13px;color:var(--ink2)">correct in 60 seconds · best '+(S.bestSpeed||0)+'</div></div>'));
    const row = el('<div class="btnrow" style="margin-top:13px"></div>');
    const again = el('<button class="btn primary grow">Run it back</button>');
    again.onclick=()=>{ speed = { i:0, score:0, left:60, items: shuffle(SPEED), answered:null }; startSpeedClock(); render(); };
    const back = el('<button class="btn">Done</button>'); back.onclick=()=>{ sub=null; go("cards"); };
    row.appendChild(again); row.appendChild(back); wrap.appendChild(row);
    return wrap;
  }
  const it = speed.items[speed.i % speed.items.length];
  if(!speed.choices || speed.forIdx !== speed.i){
    const others = shuffle(SPEED.filter(s=>s.a!==it.a)).slice(0,3).map(s=>s.a);
    speed.choices = shuffle([it.a, ...others]); speed.forIdx = speed.i;
  }
  wrap.appendChild(el('<div class="qbar"><button class="icobtn" id="sx" aria-label="Exit">✕</button>'+
    '<div class="grow"><span class="eyebrow">Score</span> <b class="mono" style="font-size:16px">'+speed.score+'</b></div>'+
    '<span class="mono" id="spClock" style="font-size:17px;font-weight:600;color:'+(speed.left<=10?"var(--bad)":"var(--gold)")+'">0:'+String(speed.left).padStart(2,"0")+'</span></div>'));
  wrap.appendChild(el('<div class="speed-term" style="text-align:center">'+esc(it.q)+'</div>'));
  wrap.appendChild(el('<p style="text-align:center;font-size:12px;color:var(--ink3);margin:0 0 16px">'+
    (/^\d/.test(it.a)||it.a.includes("/")&&it.a.length<8 ? "port number?" : "what does it stand for?")+'</p>'));
  const opts = el('<div class="opts"></div>');
  speed.choices.forEach(v=>{
    const b = el('<button class="opt'+(speed.answered? (v===it.a?" correct":(v===speed.answered?" wrong":" dim")) : "")+'"><span>'+esc(v)+'</span></button>');
    b.onclick = ()=>{
      if(speed.answered) return;
      speed.answered = v;
      if(v===it.a) speed.score++;
      render();
      setTimeout(()=>{ if(!speed) return; speed.answered=null; speed.i++; render(); }, v===it.a?260:900);
    };
    opts.appendChild(b);
  });
  wrap.appendChild(opts);
  setTimeout(()=>{ const x=document.getElementById("sx"); if(x) x.onclick=()=>{ stopClocks(); speed=null; sub=null; go("cards"); }; },0);
  return wrap;
}
function startSpeedClock(){
  stopClocks();
  tick = setInterval(()=>{
    if(!speed || sub!=="speed"){ stopClocks(); return; }
    speed.left--;
    if(speed.left<=0){ stopClocks(); render(); return; }
    const c = document.getElementById("spClock");
    if(c){ c.textContent = "0:"+String(speed.left).padStart(2,"0"); if(speed.left<=10) c.style.color="var(--bad)"; }
  },1000);
}
function stopClocks(){ if(tick){ clearInterval(tick); tick=null; } }

/* ============================================================
   VIEW: EXAM (separate, pausable, splittable)
   ============================================================ */
function examView(){
  const wrap = el('<div class="stack"></div>');
  const e = S.exam;

  if(e && !e.submitted){
    const mins = Math.floor(e.remain/60), done = e.answers.filter(a=>a!==null).length;
    const card = el('<div class="card" style="border-color:var(--gold-dim)">'+
      '<div class="sec-h"><h2>Exam in progress</h2><span class="pill gold">Paused</span></div>'+
      '<p style="margin:0 0 12px;font-size:13px;color:var(--ink2);line-height:1.5">'+
      CORE_INFO[e.core].name+' · '+CORE_INFO[e.core].code+' — '+done+' of '+e.qids.length+' answered, '+
      '<b class="mono">'+mins+' min '+(e.remain%60)+' sec</b> left on the clock. Pick it back up whenever.</p></div>');
    const row = el('<div class="btnrow"></div>');
    const res = el('<button class="btn primary grow">Resume exam</button>'); res.onclick=()=>{ go("exam","examrun"); };
    const kill = el('<button class="btn">Discard</button>');
    kill.onclick = ()=>{ if(confirm("Throw away this exam attempt?")){ S.exam=null; save(); render(); } };
    row.appendChild(res); row.appendChild(kill); card.appendChild(row); wrap.appendChild(card);
    return wrap;
  }

  wrap.appendChild(el('<div class="card"><div class="sec-h"><h2>Timed exam simulation</h2></div>'+
    '<p style="margin:0;font-size:13px;color:var(--ink2);line-height:1.55">The real thing is up to 90 questions in 90 minutes. '+
    'Passing is <b class="mono">675/900</b> on Core 1 and <b class="mono">700/900</b> on Core 2.<br><br>'+
    'You can pause any exam and the clock stops. Do 10 minutes now, 20 tonight — it picks up exactly where you left it.</p></div>'));

  let core = 1, len = 90;
  const seg1 = el('<div class="seg" id="segCore"><button data-v="1" aria-pressed="true">Core 1</button><button data-v="2" aria-pressed="false">Core 2</button></div>');
  const seg2 = el('<div class="seg" id="segLen"><button data-v="30" aria-pressed="false">30 q / 30 min</button><button data-v="45" aria-pressed="false">45 q / 45 min</button><button data-v="90" aria-pressed="true">Full 90</button></div>');
  const cfg = el('<div class="card"><div class="field"><label>Which core</label></div><div class="field"><label>Length</label></div></div>');
  cfg.children[0].appendChild(seg1); cfg.children[1].appendChild(seg2);
  seg1.querySelectorAll("button").forEach(b=>b.onclick=()=>{ core=+b.dataset.v; seg1.querySelectorAll("button").forEach(x=>x.setAttribute("aria-pressed", x===b)); });
  seg2.querySelectorAll("button").forEach(b=>b.onclick=()=>{ len=+b.dataset.v; seg2.querySelectorAll("button").forEach(x=>x.setAttribute("aria-pressed", x===b)); });
  const start = el('<button class="btn primary wide" style="margin-top:4px">Start exam</button>');
  start.onclick = ()=>{
    const qs = examPick(len, core);
    S.exam = { core, qids: qs.map(q=>q.i), answers: qs.map(()=>null), flags: qs.map(()=>false),
               i:0, remain: len*60, started: Date.now(), submitted:false };
    save(); go("exam","examrun");
  };
  cfg.appendChild(start); wrap.appendChild(cfg);

  const hist = (S.examHistory||[]);
  if(hist.length){
    const h = el('<div class="card"><div class="sec-h"><h2>Past attempts</h2></div><div class="stack" style="gap:8px"></div></div>');
    const b = h.querySelector(".stack");
    hist.slice(-6).reverse().forEach(x=>{
      b.appendChild(el('<div class="rec"><div class="rec-i" style="background:'+(x.pass?"var(--ok-dim)":"var(--bad-dim)")+';color:'+(x.pass?"var(--ok)":"var(--bad)")+'">'+(x.pass?"P":"F")+'</div>'+
        '<div class="grow"><b>'+CORE_INFO[x.core].name+' — '+x.scaled+'/900</b><br>'+x.right+'/'+x.n+' correct · '+esc(x.date)+'</div></div>'));
    });
    wrap.appendChild(h);
  }
  return wrap;
}
function examRunView(){
  const e = S.exam;
  const qs = e.qids.map(id=>QUESTIONS.find(q=>q.i===id)).filter(Boolean);
  const q = qs[e.i], d = domainOf(q.d);
  const wrap = el('<div></div>');
  const mm = Math.floor(e.remain/60), ss = e.remain%60;

  const hud = el('<div class="exam-hud">'+
    '<span class="exam-clock'+(e.remain<300?" low":"")+'" id="exClock">'+mm+':'+String(ss).padStart(2,"0")+'</span>'+
    '<div class="grow mono" style="font-size:12.5px;color:var(--ink2)">Q'+(e.i+1)+' / '+qs.length+'</div></div>');
  const pause = el('<button class="btn sm">Pause</button>');
  pause.onclick = ()=>{ stopClocks(); save(); sub=null; go("exam"); toast("Exam paused — clock stopped"); };
  hud.appendChild(pause); wrap.appendChild(hud);

  wrap.appendChild(el('<p class="qtext">'+esc(q.q)+'</p>'));
  if(!e.orders) e.orders = {};
  if(!e.orders[e.i]) e.orders[e.i] = shuffle(q.c.map((_,i)=>i));
  const order = e.orders[e.i];
  const opts = el('<div class="opts"></div>');
  order.forEach((oi,pos)=>{
    const sel = e.answers[e.i] === oi;
    const b = el('<button class="opt"'+(sel?' style="border-color:var(--gold);background:var(--surf2)"':'')+'>'+
      '<span class="key"'+(sel?' style="color:var(--gold)"':'')+'>'+"ABCD"[pos]+'</span><span>'+esc(q.c[oi])+'</span></button>');
    b.onclick = ()=>{ e.answers[e.i]=oi; save(); render(); };
    opts.appendChild(b);
  });
  wrap.appendChild(opts);

  const nav = el('<div class="btnrow" style="margin-top:14px"></div>');
  const prev = el('<button class="btn"'+(e.i===0?" disabled":"")+'>← Prev</button>');
  prev.onclick=()=>{ if(e.i>0){ e.i--; render(); } };
  const flag = el('<button class="btn"'+(e.flags[e.i]?' style="border-color:var(--gold);color:var(--gold)"':'')+'>⚑ Flag</button>');
  flag.onclick=()=>{ e.flags[e.i]=!e.flags[e.i]; save(); render(); };
  const next = el('<button class="btn primary grow">'+(e.i+1<qs.length?"Next →":"Review & submit")+'</button>');
  next.onclick=()=>{ if(e.i+1<qs.length){ e.i++; render(); } else go("exam","examreview"); };
  nav.appendChild(prev); nav.appendChild(flag); nav.appendChild(next); wrap.appendChild(nav);

  const grid = el('<div style="margin-top:18px"><div class="eyebrow" style="margin-bottom:8px">Navigator</div><div class="qgrid"></div></div>');
  const g = grid.querySelector(".qgrid");
  qs.forEach((_,i)=>{
    const c = el('<button class="qcell'+(e.answers[i]!==null?" done":"")+(e.flags[i]?" flag":"")+(i===e.i?" cur":"")+'">'+(i+1)+'</button>');
    c.onclick=()=>{ e.i=i; render(); };
    g.appendChild(c);
  });
  wrap.appendChild(grid);
  startExamClock();
  return wrap;
}
function startExamClock(){
  stopClocks();
  tick = setInterval(()=>{
    const e = S.exam;
    if(!e || sub!=="examrun"){ stopClocks(); return; }
    e.remain--;
    if(e.remain <= 0){ e.remain=0; stopClocks(); save(); toast("Time's up"); go("exam","examresult"); return; }
    if(e.remain % 15 === 0) saveLocal();
    const c = document.getElementById("exClock");
    if(c){ c.textContent = Math.floor(e.remain/60)+":"+String(e.remain%60).padStart(2,"0"); if(e.remain<300) c.classList.add("low"); }
  },1000);
}
function examReviewView(){
  const e = S.exam, n = e.qids.length;
  const blank = e.answers.filter(a=>a===null).length, flagged = e.flags.filter(Boolean).length;
  const wrap = el('<div class="stack"></div>');
  wrap.appendChild(el('<div class="card"><div class="sec-h"><h2>Before you submit</h2></div>'+
    '<p style="margin:0;font-size:13.5px;color:var(--ink2);line-height:1.6">'+
    '<b class="mono">'+(n-blank)+'</b> answered · <b class="mono">'+blank+'</b> blank · <b class="mono">'+flagged+'</b> flagged.<br>'+
    (blank? 'Unanswered questions score as wrong. There is no penalty for guessing on the real exam — never leave one blank.' : 'Everything is answered. Go ahead.')+
    '</p></div>'));
  const grid = el('<div class="card"><div class="eyebrow" style="margin-bottom:9px">Jump to a question</div><div class="qgrid"></div></div>');
  const g = grid.querySelector(".qgrid");
  e.qids.forEach((_,i)=>{
    const c = el('<button class="qcell'+(e.answers[i]!==null?" done":"")+(e.flags[i]?" flag":"")+'">'+(i+1)+'</button>');
    c.onclick=()=>{ e.i=i; go("exam","examrun"); };
    g.appendChild(c);
  });
  wrap.appendChild(grid);
  const row = el('<div class="btnrow"></div>');
  const back = el('<button class="btn grow">Back to questions</button>'); back.onclick=()=>go("exam","examrun");
  const sub2 = el('<button class="btn primary grow">Submit exam</button>');
  sub2.onclick = ()=>{ if(confirm("Submit and score this exam?")) go("exam","examresult"); };
  row.appendChild(back); row.appendChild(sub2); wrap.appendChild(row);
  return wrap;
}
function examResultView(){
  const e = S.exam;
  stopClocks();
  if(!e.submitted){
    e.submitted = true;
    let right = 0;
    const byDom = {};
    e.qids.forEach((id,i)=>{
      const q = QUESTIONS.find(x=>x.i===id); if(!q) return;
      const ok = e.answers[i] === q.a; if(ok) right++;
      byDom[q.d] = byDom[q.d] || {c:0,n:0}; byDom[q.d].n++; if(ok) byDom[q.d].c++;
      recordAnswer(q, ok);
    });
    const pct = right/e.qids.length;
    e.result = { right, n:e.qids.length, pct, byDom,
                 scaled: Math.round(100 + 800*pct), pass: Math.round(100+800*pct) >= CORE_INFO[e.core].pass };
    S.examHistory = S.examHistory || [];
    S.examHistory.push({ core:e.core, scaled:e.result.scaled, right, n:e.qids.length, pass:e.result.pass, date: todayKey() });
    save();
  }
  const r = e.result, need = CORE_INFO[e.core].pass;
  const wrap = el('<div class="stack"></div>');
  wrap.appendChild(el('<div class="card" style="text-align:center;padding:26px 16px;border-color:'+(r.pass?"var(--ok)":"var(--bad)")+'">'+
    '<div class="eyebrow">'+CORE_INFO[e.core].name+' · '+CORE_INFO[e.core].code+'</div>'+
    '<div class="score-big '+(r.pass?"verdict-pass":"verdict-fail")+'" style="margin:10px 0 2px">'+r.scaled+'</div>'+
    '<div class="mono" style="font-size:12.5px;color:var(--ink3)">estimated scaled score · '+need+' to pass</div>'+
    '<div style="margin-top:12px;font-size:15px;font-weight:600;color:'+(r.pass?"var(--ok)":"var(--bad)")+'">'+
      (r.pass?"PASS":"NOT YET")+' — '+r.right+' of '+r.n+' correct ('+Math.round(r.pct*100)+'%)</div></div>'));

  const bd = el('<div class="card"><div class="sec-h"><h2>Where the points went</h2></div></div>');
  Object.keys(r.byDom).sort((a,b)=>(r.byDom[a].c/r.byDom[a].n)-(r.byDom[b].c/r.byDom[b].n)).forEach(k=>{
    const d = domainOf(k), s = r.byDom[k], p = Math.round(100*s.c/s.n);
    bd.appendChild(el('<div class="meter"><div class="meter-name"><span class="dot" style="background:'+d.c+'"></span>'+esc(d.n)+'</div>'+
      '<div class="meter-pct">'+s.c+'/'+s.n+'</div>'+
      '<div class="meter-track"><div class="meter-fill" style="width:'+p+'%;background:'+meterColor(p)+'"></div></div></div>'));
  });
  wrap.appendChild(bd);

  const worst = Object.keys(r.byDom).sort((a,b)=>(r.byDom[a].c/r.byDom[a].n)-(r.byDom[b].c/r.byDom[b].n))[0];
  if(worst){
    const d = domainOf(worst);
    const rec = el('<div class="rec"><div class="rec-i" style="background:'+d.c+';color:#0d1117">!</div>'+
      '<div class="grow"><b>'+esc(d.n)+'</b> cost you the most. It is '+d.w+'% of this exam, so it is the highest-leverage thing to fix.</div></div>');
    const b = el('<button class="btn sm">Drill it</button>');
    b.onclick=()=>{ S.exam=null; save(); startQuiz({label:d.n, src:qsIn(d.k), n:12}); };
    rec.appendChild(b); wrap.appendChild(rec);
  }
  const done = el('<button class="btn primary wide">Close out</button>');
  done.onclick=()=>{ S.exam=null; save(); sub=null; go("status"); };
  wrap.appendChild(done);
  return wrap;
}

/* ============================================================
   VIEW: PROGRESS (semesters, calendar, history)
   ============================================================ */
function progressView(){
  const wrap = el('<div class="stack"></div>');
  const sem = curSem();

  // heatmap: last 84 days
  const hm = el('<div class="card"><div class="sec-h"><h2>Study calendar</h2><span class="eyebrow">Last 12 weeks</span></div><div class="heat"></div>'+
    '<div class="row" style="margin-top:10px;justify-content:space-between"><span class="eyebrow">less</span>'+
    '<span class="eyebrow" style="color:var(--gold)">'+Object.keys(S.days).length+' active days</span><span class="eyebrow">more</span></div></div>');
  const h = hm.querySelector(".heat"), goal = S.profile.dailyGoal;
  for(let i=83;i>=0;i--){
    const d = new Date(); d.setDate(d.getDate()-i);
    const k = todayKey(d), rec = S.days[k];
    const lvl = !rec ? 0 : rec.a >= goal ? 3 : rec.a >= goal/2 ? 2 : 1;
    h.appendChild(el('<i data-l="'+lvl+'"'+(i===0?' data-today="1"':'')+' title="'+k+(rec?": "+rec.a+" questions":": nothing")+'"></i>'));
  }
  wrap.appendChild(hm);

  // current semester
  wrap.appendChild(el('<div class="sec-h" style="margin-top:6px"><h2>Semesters</h2><span class="eyebrow">'+S.semesters.length+' total</span></div>'));

  S.semesters.slice().reverse().forEach(s=>{
    const live = s.id === S.cur;
    const att = s.tot.c + s.tot.w;
    const acc = att ? Math.round(100*s.tot.c/att) : 0;
    const card = el('<div class="sem'+(live?" live":"")+'">'+
      '<div class="sem-h"><b>'+esc(s.name)+(live?' <span class="pill gold" style="margin-left:6px">Active</span>':'')+'</b>'+
      '<span class="mono" style="font-size:11.5px;color:var(--ink3)">'+esc(s.start)+(s.end?' → '+esc(s.end):'')+'</span></div>');

    if(!att){
      card.appendChild(el('<p style="margin:0;font-size:12.5px;color:var(--ink3)">No questions answered in this semester yet.</p>'));
    } else {
      card.appendChild(el('<div class="row" style="gap:14px;margin-bottom:10px">'+
        '<div><b class="mono" style="font-size:20px;color:'+meterColor(acc)+'">'+acc+'%</b><div class="eyebrow">accuracy</div></div>'+
        '<div><b class="mono" style="font-size:20px">'+s.tot.c+'<span style="color:var(--ink3);font-weight:400">/</span>'+s.tot.w+'</b><div class="eyebrow">right / wrong</div></div>'+
        '<div><b class="mono" style="font-size:20px">'+(s.tot.w? (s.tot.c/s.tot.w).toFixed(2) : "∞")+'</b><div class="eyebrow">W/L</div></div>'+
      '</div>'));
      card.appendChild(el('<div class="wl" style="margin-bottom:12px"><i class="w" style="width:'+acc+'%"></i><i class="l" style="width:'+(100-acc)+'%"></i></div>'));

      const rows = Object.keys(s.dom).map(k=>{
        const v = s.dom[k], n = v.c+v.w;
        return { k, d:domainOf(k), n, p: n? Math.round(100*v.c/n) : 0, v };
      }).filter(r=>r.d).sort((a,b)=>a.p-b.p);

      rows.forEach(r=>{
        card.appendChild(el('<div class="meter"><div class="meter-name"><span class="dot" style="background:'+r.d.c+'"></span>'+
          '<span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">'+esc(r.d.n)+'</span></div>'+
          '<div class="meter-pct">'+r.v.c+'/'+r.n+' · '+r.p+'%</div>'+
          '<div class="meter-track"><div class="meter-fill" style="width:'+r.p+'%;background:'+meterColor(r.p)+'"></div></div></div>'));
      });

      const bad = rows.filter(r=>r.p < 70 && r.n >= 3).slice(0,3);
      if(bad.length){
        card.appendChild(el('<div class="eyebrow" style="margin:13px 0 7px">Recommended for you</div>'));
        bad.forEach(r=>{
          const rec = el('<div class="rec" style="margin-bottom:7px"><div class="rec-i" style="background:'+r.d.c+';color:#0d1117">↓</div>'+
            '<div class="grow"><b>'+esc(r.d.n)+' — '+r.p+'%</b><br>'+
            (r.p<50?'This is bleeding points. Run a full domain drill before anything else.'
                   :'Close, but under passing. A couple of focused sets should fix it.')+'</div></div>');
          const b = el('<button class="btn sm">Drill</button>');
          b.onclick=()=>startQuiz({label:r.d.n, src:qsIn(r.k), n:12});
          rec.appendChild(b); card.appendChild(rec);
        });
      } else {
        card.appendChild(el('<div class="rec" style="margin-top:12px"><div class="rec-i" style="background:var(--ok-dim);color:var(--ok)">✓</div>'+
          '<div class="grow">Nothing under 70% with enough attempts to judge. Keep widening coverage — every domain needs volume before the readout means anything.</div></div>'));
      }
    }
    if(live){
      const b = el('<button class="btn sm wide" style="margin-top:12px">Close this semester &amp; start a new one</button>');
      b.onclick = ()=>{
        const name = prompt("Name the new semester:", "Semester " + (S.semesters.length+1));
        if(!name) return;
        s.end = todayKey();
        const id = "sem"+Date.now();
        S.semesters.push({ id, name, start: todayKey(), end:null, dom:{}, tot:{c:0,w:0} });
        S.cur = id; save(); render(); toast("Started " + name);
      };
      card.appendChild(b);
    }
    wrap.appendChild(card);
  });
  return wrap;
}

/* ============================================================
   SETTINGS
   ============================================================ */
function openSettings(){
  const sheet = el('<div class="sheet"><div class="sheet-in"></div></div>');
  const box = sheet.querySelector(".sheet-in");
  box.innerHTML =
    '<div class="sec-h"><h2>Settings</h2><button class="icobtn" id="closeSet" aria-label="Close">✕</button></div>'+
    '<div class="field"><label for="setExam">Exam date (for the countdown)</label>'+
      '<input type="date" id="setExam" value="'+(S.profile.examDate||"")+'"></div>'+
    '<div class="field"><label for="setGoal">Daily question goal</label>'+
      '<input type="number" id="setGoal" min="5" max="200" value="'+S.profile.dailyGoal+'"></div>'+
    '<div class="field"><label>What am I studying</label><div class="seg" id="setFocus">'+
      '<button data-v="both" aria-pressed="'+(S.profile.focus==="both")+'">Both cores</button>'+
      '<button data-v="c1" aria-pressed="'+(S.profile.focus==="c1")+'">Core 1</button>'+
      '<button data-v="c2" aria-pressed="'+(S.profile.focus==="c2")+'">Core 2</button></div></div>'+
    '<div class="field"><label>Appearance</label><div class="seg" id="setTheme">'+
      '<button data-v="auto" aria-pressed="'+(S.profile.theme==="auto")+'">Auto</button>'+
      '<button data-v="dark" aria-pressed="'+(S.profile.theme==="dark")+'">Dark</button>'+
      '<button data-v="light" aria-pressed="'+(S.profile.theme==="light")+'">Light</button></div></div>'+
    '<div style="border-top:1px solid var(--line);margin:16px 0 13px"></div>'+
    '<p style="margin:0 0 12px;font-size:12px;color:var(--ink3);line-height:1.55">Progress syncs to your Claude account, so this is the same on your phone and your laptop. '+
    'It also caches locally, so it works with no signal.</p>'+
    '<div class="btnrow"><button class="btn sm" id="btnExport">Export backup</button>'+
    '<button class="btn sm" id="btnReset" style="border-color:var(--bad);color:var(--bad)">Reset everything</button></div>';

  const close = ()=>sheet.remove();
  sheet.onclick = e=>{ if(e.target===sheet) close(); };
  box.querySelector("#closeSet").onclick = close;
  box.querySelector("#setExam").onchange = e=>{ S.profile.examDate = e.target.value || null; save(); render(); };
  box.querySelector("#setGoal").onchange = e=>{ S.profile.dailyGoal = Math.max(5, +e.target.value||20); save(); render(); };
  box.querySelectorAll("#setFocus button").forEach(b=>b.onclick=()=>{
    S.profile.focus = b.dataset.v; save();
    box.querySelectorAll("#setFocus button").forEach(x=>x.setAttribute("aria-pressed", x===b)); render();
  });
  box.querySelectorAll("#setTheme button").forEach(b=>b.onclick=()=>{
    S.profile.theme = b.dataset.v; applyTheme(); save();
    box.querySelectorAll("#setTheme button").forEach(x=>x.setAttribute("aria-pressed", x===b));
  });
  box.querySelector("#btnExport").onclick = async ()=>{
    const json = JSON.stringify(S,null,2);
    try{
      const dl = await window.claude?.use?.("downloads");
      if(dl){ await dl.save({ filename:"bench-test-backup.json", data:json }); toast("Backup saved"); return; }
    }catch(e){}
    try{ await navigator.clipboard.writeText(json); toast("Backup copied to clipboard"); }
    catch(e){ toast("Could not export here"); }
  };
  box.querySelector("#btnReset").onclick = ()=>{
    if(!confirm("Wipe ALL progress on every device? This cannot be undone.")) return;
    S = blankState(); save(); close(); go("status"); toast("Reset");
  };
  document.body.appendChild(sheet);
}
function applyTheme(){
  const t = S.profile.theme;
  if(t==="auto") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.setAttribute("data-theme", t);
}

/* ============================================================
   BOOT
   ============================================================ */
const VIEWS = {
  status:statusView, drill:drillView, cards:cardsView, exam:examView, progress:progressView,
  quiz:quizView, quizdone:quizDoneView, pbq:pbqView, deck:deckView, speed:speedView,
  examrun:examRunView, examreview:examReviewView, examresult:examResultView
};

function start(){
  ui.screen = document.getElementById("screen");
  ui.tabs = document.getElementById("tabs");
  ui.coreLabel = document.getElementById("coreLabel");
  ui.dot = document.getElementById("syncDot");
  document.getElementById("btnSettings").onclick = openSettings;

  S = loadLocal() || blankState();
  if(!S.profile.theme) S.profile.theme = "auto";
  applyTheme();
  render();

  // light up the cross-device sync when the viewer grants it
  window.claude?.use?.("db").then(db=>{
    if(!db) return;
    DB = db;
    DB.doc(DB_PATH).get().then(snap=>{
      if(snap.exists){
        S = mergeState(S, snap.data());
        applyTheme(); render();
      }
      DB.doc(DB_PATH).set(S).catch(()=>{});
      ui.dot.classList.add("on"); ui.dot.title = "Synced to your account";
      DB.doc(DB_PATH).onSnapshot(sn=>{
        if(!sn.exists) return;
        const remote = sn.data();
        if((remote.updatedAt||0) > (S.updatedAt||0) + 1500 && !sub){
          S = mergeState(S, remote); saveLocal(); render();
        }
      }, ()=>{});
    }).catch(()=>{});
  }).catch(()=>{});
}

// keep the speed clock honest when that view mounts
const _render = render;
render = function(){ _render(); if(sub==="speed" && speed && speed.left>0 && !tick) startSpeedClock(); };

window.addEventListener("beforeunload", ()=>{ saveLocal(); });
if(window.claude?.hot?.ready) window.claude.hot.ready(start); else start();
</script>
