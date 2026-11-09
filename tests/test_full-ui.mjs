import {chromium} from 'playwright';import path from 'node:path';import {fileURLToPath} from 'node:url';const APP_ROOT=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');import fs from 'node:fs';import assert from 'node:assert/strict';
const browser=await chromium.launch({headless:true});
const page=await browser.newPage();let errs=[];page.on('pageerror',e=>errs.push(e.message));const session={token:'test-session',role:'admin',display_name:'관리자',user_id:'admin',must_change_password:false};
await page.route('**/*',async route=>{let path=new URL(route.request().url()).pathname;
 if(path.startsWith('/rest/v1/rpc/')){const name=path.split('/').pop();return route.fulfill({json:name==='app_login'||name==='app_me'?session:{ok:true}});}
 if(path==='/.netlify/functions/monthly'){return route.fulfill({json:[]});}
 if(path==='/config.js')return route.fulfill({body:'window.DAEWOON_CONFIG={url:"https://mock.test",key:"anon-test"};',contentType:'application/javascript'});
 if(path.includes('xlsx'))return route.fulfill({body:'',contentType:'application/javascript'});
 if(path==='/')path='/index.html';let p=APP_ROOT+path;if(!fs.existsSync(p))p=APP_ROOT+path;
 return route.fulfill({body:fs.readFileSync(p),contentType:path.endsWith('.html')?'text/html':path.endsWith('.js')?'application/javascript':path.endsWith('.css')?'text/css':'application/octet-stream'});
});
await page.addInitScript(()=>localStorage.setItem('daewoon_admin_device_setup_v13_admin','ok'));await page.goto('https://app.test');await page.locator('#loginId').fill('관리자');await page.locator('#loginPw').fill('testpass');await page.locator('#loginBtn').click();await page.waitForSelector('#mrTable',{timeout:3000}).catch(async e=>{console.log('ERRORS',errs);console.log(await page.locator('body').innerText());throw e});assert.equal(await page.locator('#nav [data-page="changes"]').count(),0);assert.equal(await page.locator('#nav [data-page="collector"]').count(),1);
await page.locator('#nav [data-page="settings"]').click();assert.equal(await page.getByText('백그라운드 Collector',{exact:true}).count(),0);assert.equal(await page.locator('#spBtn').count(),1);
await page.locator('#nav [data-page="collector"]').click();await page.waitForSelector('#mrScan');
await page.locator('#nav [data-page="dashboard"]').click();await page.waitForSelector('#mrTable');assert.deepEqual(errs,[]);console.log('PASS full app: existing login, navigation integration, settings, new collection page');await browser.close();
