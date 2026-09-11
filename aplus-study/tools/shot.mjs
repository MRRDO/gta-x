import { chromium } from '/opt/node22/lib/node_modules/playwright/index.mjs';
import fs from 'fs';
const body = fs.readFileSync('aplus.html','utf8');
const page_html = `<!doctype html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>:root{color-scheme:light}body{margin:0;font:14px system-ui;background:#faf9f7}img{max-width:100%}[hidden]{display:none!important}</style></head><body>${body}</body>`;
fs.writeFileSync('preview.html', page_html);
const b = await chromium.launch({ executablePath:'/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const errs=[];
const p = await b.newPage({ viewport:{width:420,height:900}, deviceScaleFactor:2 });
p.on('console', m=>{ if(m.type()==='error') errs.push(m.text()); });
p.on('pageerror', e=>errs.push('PAGEERROR: '+e.message));
await p.goto('file://'+process.cwd()+'/preview.html');
await p.waitForTimeout(1800);
await p.screenshot({ path:'s1-status.png', fullPage:true });
await p.click('[data-tab="drill"]'); await p.waitForTimeout(300);
await p.screenshot({ path:'s2-drill.png', fullPage:true });
// run a quiz question
await p.click('.tiles .tile'); await p.waitForTimeout(400);
await p.click('.opt'); await p.waitForTimeout(400);
await p.screenshot({ path:'s3-quiz.png', fullPage:true });
// pbq
await p.click('#qx'); await p.waitForTimeout(300);
const tiles = await p.$$('.tiles .tile');
await tiles[tiles.length-1].click(); await p.waitForTimeout(400);
await p.click('.chipdrag'); await p.click('.slot'); await p.waitForTimeout(200);
await p.screenshot({ path:'s4-pbq.png', fullPage:true });
await p.click('[data-tab="cards"]'); await p.waitForTimeout(300);
await p.click('.btn.primary.wide'); await p.waitForTimeout(300);
await p.click('.fc'); await p.waitForTimeout(600);
await p.screenshot({ path:'s5-card.png', fullPage:true });
await p.click('[data-tab="exam"]'); await p.waitForTimeout(300);
await p.screenshot({ path:'s6-exam.png', fullPage:true });
await p.click('[data-tab="progress"]'); await p.waitForTimeout(300);
await p.screenshot({ path:'s7-progress.png', fullPage:true });
console.log(errs.length? 'ERRORS:\n'+errs.join('\n') : 'no console errors');
await b.close();
