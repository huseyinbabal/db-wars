const { chromium } = require('playwright');
(async () => { const b = await chromium.launch({ channel: 'chrome', headless: true }); const p = await b.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
  for (const t of ['read', 'write', 'spike', 'big']) { await p.goto(`http://127.0.0.1:3391/d/dbwars-${t}?kiosk=1&theme=dark`); await p.waitForTimeout(7000); await p.screenshot({ path: `${process.argv[2]}/grafana-${t}.png` }); }
  await b.close(); })();
