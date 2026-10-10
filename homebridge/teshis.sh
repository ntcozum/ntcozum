#!/bin/bash
# Homebridge teşhis raporu (macOS).
# Şifre/anahtar gibi gizli alanları maskeleyip Masaüstüne tek bir metin dosyası yazar.
# Kullanım:  bash teshis.sh

HB="${HB_STORAGE:-$HOME/.homebridge}"
OUT="$HOME/Desktop/homebridge-teshis.txt"

{
echo "===== SİSTEM ====="
sw_vers 2>/dev/null
echo "Model: $(sysctl -n hw.model 2>/dev/null)  Mimari: $(uname -m)"
echo "Homebridge klasörü: $HB"

echo; echo "===== NODE / NPM ====="
echo "node: $(command -v node) $(node -v 2>/dev/null)"
echo "npm:  $(npm -v 2>/dev/null)"

echo; echo "===== KURULU PAKETLER ====="
npm ls -g --depth=0 2>/dev/null | grep -iE "homebridge|tuya|miot|xiaomi|mi-|tapo|tplink|kasa"
[ -d "$HB/node_modules" ] && ls "$HB/node_modules" | grep -iE "homebridge|tuya|miot|xiaomi|tapo"

echo; echo "===== SERVİS DURUMU ====="
hb-service status 2>&1 | tail -n 20

echo; echo "===== GÜÇ / UYKU AYARLARI ====="
pmset -g 2>/dev/null | grep -E "sleep|disksleep|powernap|womp|tcpkeepalive"

echo; echo "===== config.json (gizli alanlar maskeli) ====="
node -e '
const fs = require("fs");
const secret = /pass|secret|token|key|access|username|email|^uid$|^pin$/i;
const mask = o => Array.isArray(o) ? o.map(mask)
  : (o && typeof o === "object")
    ? Object.fromEntries(Object.entries(o).map(([k, v]) =>
        [k, secret.test(k) && typeof v !== "object" ? "***" : mask(v)]))
    : o;
try { console.log(JSON.stringify(mask(JSON.parse(fs.readFileSync(process.argv[1], "utf8"))), null, 2)); }
catch (e) { console.log("config.json okunamadı: " + e.message); }
' "$HB/config.json"

echo; echo "===== TUYA CİHAZ LİSTESİ (bulut cache) ====="
found=0
for f in "$HB"/persist/TuyaDeviceList*.json; do
  [ -f "$f" ] || continue
  found=1
  node -e '
const list = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const devs = Array.isArray(list) ? list : (list.devices || []);
console.log("Toplam cihaz: " + devs.length);
for (const d of devs) {
  const codes = (d.schema || []).map(s => s.code).join(",");
  console.log(`- ${d.name} | kategori=${d.category} | ürün=${d.product_name || "-"} | online=${d.online} | schema=[${codes}]`);
}
' "$f"
done
[ $found = 0 ] && echo "TuyaDeviceList dosyası yok (eklenti buluta hiç bağlanamamış olabilir)."

echo; echo "===== LOG: Tuya / hata satırları (son 250) ====="
grep -iE "tuya|error|warn|unsupported|not supported|fail" "$HB/homebridge.log" 2>/dev/null | tail -n 250

echo; echo "===== LOG: son 80 satır ====="
tail -n 80 "$HB/homebridge.log" 2>/dev/null
} > "$OUT" 2>&1

echo "Rapor hazır: $OUT"
echo "Dosyayı açıp içeriğini Claude'a yapıştırabilir ya da dosyayı yükleyebilirsin."
