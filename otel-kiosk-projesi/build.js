// sunum.html -> LOBI_Proje_Taslagi.pdf (16:9, 1280x720 px sayfalar)
// Kullanım: node build.js [--check]
const path = require('path');
const { chromium } = require('playwright');

(async () => {
  const src = 'file://' + path.join(__dirname, 'sunum.html');
  const out = path.join(__dirname, 'LOBI_Proje_Taslagi.pdf');
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
  await page.goto(src, { waitUntil: 'load' });
  await page.evaluate(() => document.fonts.ready);

  if (process.argv.includes('--check')) {
    // Slayt sınırlarını (alt boşluk dahil) aşan öğeleri raporla
    const issues = await page.evaluate(() => {
      const res = [];
      document.querySelectorAll('.slide').forEach((s, i) => {
        const sb = s.getBoundingClientRect();
        const limit = sb.bottom - (s.hasAttribute('data-nofoot') ? 0 : 44);
        s.querySelectorAll('*').forEach(el => {
          if (el.closest('.foot') || el.closest('svg.art')) return;
          const r = el.getBoundingClientRect();
          if (r.width === 0 || r.height === 0) return;
          if (r.bottom > limit + 1 || r.right > sb.right - 20 + 1) {
            res.push(`slayt ${i + 1}: <${el.tagName.toLowerCase()} class="${el.className.baseVal ?? el.className}"> alt=${Math.round(r.bottom - sb.top)} sağ=${Math.round(r.right - sb.left)} "${(el.textContent || '').trim().slice(0, 40)}"`);
          }
        });
        // taşan metin kutuları
        s.querySelectorAll('.card, .fs, .kpi, td, .s, .c').forEach(el => {
          if (el.scrollHeight > el.clientHeight + 1) res.push(`slayt ${i + 1}: iç taşma "${el.textContent.trim().slice(0, 40)}"`);
        });
      });
      return res;
    });
    console.log(issues.length ? issues.join('\n') : 'Taşma yok');
  }

  await page.pdf({ path: out, width: '1280px', height: '720px', printBackground: true, preferCSSPageSize: true });
  await browser.close();
  console.log('PDF:', out);
})();
