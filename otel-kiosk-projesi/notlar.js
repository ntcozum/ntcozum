// sunum.html + anlatim.md -> LOBI_Konusmaci_Notlari.pdf (A4 yatay, sayfa başına bir slayt + anlatım)
// Kullanım: node notlar.js
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');

(async () => {
  const md = fs.readFileSync(path.join(__dirname, 'anlatim.md'), 'utf8');
  const parcalar = md.split(/^## Slayt (\d+) — (.+)$/m);
  const notlar = [];
  for (let i = 1; i < parcalar.length; i += 3) {
    notlar.push({ no: +parcalar[i], baslik: parcalar[i + 1].trim(), metin: parcalar[i + 2].trim().replace(/\s+/g, ' ') });
  }

  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 720 }, deviceScaleFactor: 1.5 });
  await page.goto('file://' + path.join(__dirname, 'sunum.html'), { waitUntil: 'load' });
  await page.evaluate(() => document.fonts.ready);
  const slaytlar = await page.$$('.slide');
  if (slaytlar.length !== notlar.length) throw new Error(`${slaytlar.length} slayt var ama ${notlar.length} not var`);
  const gorseller = [];
  for (const s of slaytlar) gorseller.push((await s.screenshot({ type: 'jpeg', quality: 88 })).toString('base64'));

  let toplam = 0;
  const sayfalar = notlar.map((n, i) => {
    const sn = Math.round(n.metin.split(' ').length / 2.3) + 2;
    toplam += sn;
    return `<section>
      <img src="data:image/jpeg;base64,${gorseller[i]}">
      <div class="m">
        <div class="k">Slayt ${n.no} / ${notlar.length} · yaklaşık ${sn} sn</div>
        <h2>${esc(n.baslik)}</h2>
        <p>${esc(n.metin)}</p>
      </div>
    </section>`;
  });

  await page.setContent(`<!doctype html><html lang="tr"><head><meta charset="utf-8"><style>
    @page { size: A4 landscape; margin: 0; }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: Inter, sans-serif; color: #182234; -webkit-print-color-adjust: exact; }
    section { width: 297mm; height: 210mm; padding: 14mm 14mm 12mm; display: grid; grid-template-columns: 172mm 1fr; gap: 10mm; break-after: page; position: relative; background: #FBFAF7; }
    section:last-child { break-after: auto; }
    img { width: 172mm; border-radius: 3mm; box-shadow: 0 2mm 6mm -3mm rgba(15,28,46,.35); align-self: start; }
    .k { font-size: 8.5pt; font-weight: 600; letter-spacing: .08em; text-transform: uppercase; color: #0A7A74; }
    h2 { font-family: "Inter Display", Inter; font-size: 15pt; font-weight: 700; margin-top: 2mm; letter-spacing: -.01em; }
    p { font-size: 10.6pt; line-height: 1.55; margin-top: 4mm; color: #24303F; }
    section::after { content: "LOBİ · Konuşmacı notları"; position: absolute; left: 14mm; bottom: 7mm; font-size: 8pt; color: #8592A4; }
  </style></head><body>${sayfalar.join('')}</body></html>`, { waitUntil: 'load' });
  await page.evaluate(() => document.fonts.ready);
  const out = path.join(__dirname, 'LOBI_Konusmaci_Notlari.pdf');
  await page.pdf({ path: out, preferCSSPageSize: true, printBackground: true });
  await browser.close();
  console.log('PDF:', out, `· tahmini toplam süre ≈ ${Math.round(toplam / 60)} dk`);
})();
