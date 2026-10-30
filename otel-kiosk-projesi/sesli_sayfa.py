#!/usr/bin/env python3
"""Sesli sunum sayfasını üretir: sesli-sunum/index.html + sesli-sunum/slides/*.jpg

Sayfa anlatımı izleyicinin cihazındaki Türkçe sesle okur (Edge'de Emel, Apple'da Yelda,
Android'de Google), slaytları anlatımla birlikte ilerletir ve okunan cümleyi altyazı yapar.

Kullanım: python sesli_sayfa.py     (gerekenler: pip install pypdfium2 pillow)
"""
import json
import re
from pathlib import Path

import pypdfium2 as pdfium

KOK = Path(__file__).resolve().parent
HEDEF = KOK / "sesli-sunum"

# Tarayıcı sesleri büyük harfli kısaltmaları harf harf okuyabildiği için okunuşu sabitlenen kelimeler.
OKUNUS = [("LOBİ", "Lobi"), ("PMS Lite", "pe me se layt"), (r"\bPIN\b", "pin")]


def anlatim():
    md = (KOK / "anlatim.md").read_text(encoding="utf-8")
    parcalar = re.split(r"^## Slayt (\d+) — (.+)$", md, flags=re.M)
    for i in range(1, len(parcalar), 3):
        metin = " ".join(parcalar[i + 2].split())
        cumleler = re.split(r"(?<=[.!?])\s+(?=[A-ZÇĞİÖŞÜ0-9])", metin)
        yield int(parcalar[i]), parcalar[i + 1].strip(), cumleler


def okunus(cumle):
    for eski, yeni in OKUNUS:
        cumle = re.sub(eski, yeni, cumle)
    return cumle


def main():
    (HEDEF / "slides").mkdir(parents=True, exist_ok=True)
    belge = pdfium.PdfDocument(str(KOK / "LOBI_Proje_Taslagi.pdf"))
    for i, sayfa in enumerate(belge):
        sayfa.render(scale=1600 / sayfa.get_width()).to_pil().convert("RGB").save(
            HEDEF / "slides" / f"s{i + 1:02d}.jpg", quality=84, optimize=True, progressive=True
        )
        sayfa.close()
    sayfa_sayisi = len(belge)
    belge.close()

    slaytlar = [
        {"no": no, "baslik": baslik, "gorsel": f"slides/s{no:02d}.jpg",
         "cumleler": [[c, okunus(c)] for c in cumleler]}
        for no, baslik, cumleler in anlatim()
    ]
    if len(slaytlar) != sayfa_sayisi:
        raise SystemExit(f"PDF'te {sayfa_sayisi} sayfa var ama anlatim.md'de {len(slaytlar)} slayt var.")
    veri = json.dumps(slaytlar, ensure_ascii=False).replace("</", "<\\/")
    sablon = (HEDEF / "sablon.html").read_text(encoding="utf-8")
    (HEDEF / "index.html").write_text(sablon.replace("__SLAYTLAR__", veri), encoding="utf-8")
    print(f"{HEDEF / 'index.html'} · {len(slaytlar)} slayt, {sum(len(s['cumleler']) for s in slaytlar)} cümle")


if __name__ == "__main__":
    main()
