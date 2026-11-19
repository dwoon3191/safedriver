const assert=require('node:assert/strict');const core=require('../assets/dispatch.js');
const csvHead=['일자','회사명','노선번호','운행순번','오전출발시간','오후출발시간','차량번호'];
const xlsHead=['업체명','운행일자','차량번호','노선명','운행순위','지원노선명','지원운행순위','오전승무원명','오후승무원명'];
const C=(d,r,s,am,pm,car)=>['20'+d,'대운교통',r,String(s),am,pm,car];
const X=(d,car,r,s,a,p,sr='',ss='')=>['대운교통주식회사','20'+d.slice(0,2)+'-'+d.slice(2,4)+'-'+d.slice(4),car,r,String(s),sr,ss,a,p];
function run(csvRows,xlsRows){const c=core.records('csv',[csvHead,...csvRows],'a.csv'),x=core.records('xls',[xlsHead,...xlsRows],'b.xls');return {c,x,days:core.merge(c.records,x.records)};}
(()=>{
 // happy path, two dates, 73-1 stays text
 let r=run([C('261119','106',1,'0500','1247','경남71자1191'),C('261119','73-1',1,'0600','1400','경남71자1187'),C('261120','106',1,'0505','1250','경남71자1191')],
           [X('261119','경남71자1191','106',1,'가나다','라마바'),X('261119','경남71자1187','73-1',1,'사아자','차카타'),X('261120','경남71자1191','106',1,'파하갸','거너더')]);
 assert.equal(r.days.length,2);assert.ok(r.days.every(d=>!d.errors.length));
 assert.equal(r.days[0].rows[1].route,'73-1');assert.equal(r.days[0].rows[0].am_time,'0500');assert.equal(r.days[0].rows[0].pm_name,'라마바');
 // date-corrupted routes are rejected (text, serial number, Date object)
 for(const bad of ['1월-77','Jan-77','1977-01-01',28126,new Date(Date.UTC(1977,0,1))]){
  const x=core.records('xls',[xlsHead,X('261119','경남71자1','x',1,'a','b').map((v,i)=>i===3?bad:v)],'b.xls');
  assert.equal(x.records.length,0,String(bad));assert.equal(x.errors.length,1);assert.match(x.errors[0],/노선/);
 }
 // lost leading zero in time
 let c=core.records('csv',[csvHead,C('261119','106',1,'500','1247','경남71자1191')],'a.csv');assert.equal(c.records.length,0);assert.match(c.errors[0],/4자리/);
 c=core.records('csv',[csvHead,C('261119','106',1,'2560','1247','경남71자1191')],'a.csv');assert.equal(c.records.length,0);
 // car mismatch, one-sided rows
 r=run([C('261119','106',1,'0500','1247','경남71자1191'),C('261119','106',2,'0517','1304','경남71자1162')],
       [X('261119','경남71자9999','106',1,'가','나'),X('261119','경남71자7777','107',1,'다','라')]);
 const e=r.days[0].errors.join('\n');assert.match(e,/차량번호 불일치/);assert.match(e,/CSV에만/);assert.match(e,/XLS에만/);assert.equal(r.days[0].rows.length,0);
 // same person twice (am and pm / two routes) is blocked
 r=run([C('261119','106',1,'0500','1247','경남71자1'),C('261119','107',1,'0510','1300','경남71자2')],
       [X('261119','경남71자1','106',1,'가나','다라'),X('261119','경남71자2','107',1,'마바','가나')]);
 assert.match(r.days[0].errors.join('\n'),/중복 배차: 가나/);
 // identical duplicate line = warning only; conflicting duplicate = error
 r=run([C('261119','106',1,'0500','1247','경남71자1'),C('261119','106',1,'0500','1247','경남71자1')],[X('261119','경남71자1','106',1,'가','나')]);
 assert.equal(r.days[0].errors.length,0);assert.match(r.days[0].warnings.join(),/중복/);
 r=run([C('261119','106',1,'0500','1247','경남71자1'),C('261119','106',1,'0511','1247','경남71자1')],[X('261119','경남71자1','106',1,'가','나')]);
 assert.ok(r.days[0].errors.length>=1);
 // gaps, blank crew, support route are warnings, not errors
 r=run([C('261119','107',1,'0500','1247','경남71자1'),C('261119','107',3,'0520','1300','경남71자2')],
       [X('261119','경남71자1','107',1,'가','','108','2'),X('261119','경남71자2','107',3,'다','라')]);
 assert.equal(r.days[0].errors.length,0);const w=r.days[0].warnings.join('\n');assert.match(w,/빠진 운행순번.*107번 2/);assert.match(w,/오후 승무원이 비어/);assert.match(w,/지원노선/);
 assert.equal(r.days[0].rows[0].support_route,'108');
 // unmatched names use NFC
 r=run([C('261119','106',1,'0500','1247','경남71자1')],[X('261119','경남71자1','106',1,'강돈희'.normalize('NFD'),'모름')]);
 // names are NFC-normalized when read
 assert.equal(r.x.records[0].am_name,'강돈희');
 assert.deepEqual(r.days[0].unmatchedCheck(['강돈희'.normalize('NFD')]),['모름']);
 // missing columns / detection
 assert.equal(core.detect([csvHead]),'csv');assert.equal(core.detect([xlsHead]),'xls');assert.equal(core.detect([['a','b']]),'');
 assert.match(core.records('csv',[['일자','노선번호']],'q.csv').errors[0],/필요한 열/);
 // csv parser: quotes, CRLF, BOM
 assert.deepEqual(core.parseCsv('﻿a,"b,c"\r\n"d""e",f\r\n'),[['a','b,c'],['d"e','f']]);
 // formatting helpers
 assert.equal(core.fmtTime('0513'),'오전 5:13');assert.equal(core.fmtTime('1300'),'오후 1:00');assert.equal(core.fmtTime('1247'),'오후 12:47');assert.equal(core.fmtTime('0000'),'오전 12:00');assert.equal(core.fmtTime(null),'');
 assert.equal(core.dateLabel('2026-11-22').long,'11월 22일 (일)');
 assert.equal(core.seoulDate(0,new Date('2026-11-19T16:00:00Z')),'2026-11-20');assert.equal(core.seoulDate(2,new Date('2026-11-19T10:00:00Z')),'2026-11-21');
 assert.equal(core.carShort('경남71자1191'),'1191');
 console.log('PASS: dispatch core — merge/validation, date-corruption guards, duplicates, gaps, NFC, formatting');
})();
