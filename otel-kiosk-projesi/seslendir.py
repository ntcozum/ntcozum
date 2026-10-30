#!/usr/bin/env python3
"""LOBİ sunumunu seslendirir.

anlatim.md'deki metni kadın sesiyle (Microsoft Edge "Emel" Türkçe sinir ağı sesi)
okur ve şunları üretir:
  ses/slayt_NN.mp3              her slayt için ayrı ses (PowerPoint'e eklemek için)
  LOBI_Sunum_Sesli.mp4          slaytlar + anlatım, 1920x1080 video
  LOBI_Anlatim.mp3              tüm anlatım tek dosyada
  LOBI_Proje_Taslagi_Sesli.pdf  her sayfasına kendi ses dosyası gömülü PDF

Kurulum:   pip install edge-tts pypdf pypdfium2 pillow imageio-ffmpeg
Kullanım:  python seslendir.py
           python seslendir.py --ses tr-TR-EmelNeural --hiz=-4%
           python seslendir.py --test   (ses servisi olmadan, sessiz deneme)
"""
import argparse
import asyncio
import hashlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

KOK = Path(__file__).resolve().parent
PDF = KOK / "LOBI_Proje_Taslagi.pdf"
METIN = KOK / "anlatim.md"
ON_BOSLUK, SON_BOSLUK = 0.5, 1.2  # slayt başında / sonunda saniye


def anlatimi_oku():
    parcalar = re.split(r"^## Slayt (\d+) — (.+)$", METIN.read_text(encoding="utf-8"), flags=re.M)
    return [
        (int(parcalar[i]), parcalar[i + 1].strip(), " ".join(parcalar[i + 2].split()))
        for i in range(1, len(parcalar), 3)
    ]


def ffmpeg_yolu():
    try:
        import imageio_ffmpeg

        return imageio_ffmpeg.get_ffmpeg_exe()
    except ImportError:
        yol = shutil.which("ffmpeg")
        if not yol:
            sys.exit("ffmpeg bulunamadı. Kurmak için: pip install imageio-ffmpeg")
        return yol


def calistir(ffmpeg, *argumanlar):
    subprocess.run([ffmpeg, "-y", "-hide_banner", "-loglevel", "error", *argumanlar], check=True)


def sure(ffmpeg, dosya):
    cikti = subprocess.run([ffmpeg, "-hide_banner", "-i", str(dosya)], capture_output=True, text=True).stderr
    s, d, sn = re.search(r"Duration: (\d+):(\d+):([\d.]+)", cikti).groups()
    return int(s) * 3600 + int(d) * 60 + float(sn)


async def seslendir(slaytlar, klasor, ses, hiz):
    import edge_tts

    dosyalar = []
    for no, _, metin in slaytlar:
        hedef = klasor / f"slayt_{no:02d}.mp3"
        imza = hashlib.sha1(f"{ses}|{hiz}|{metin}".encode()).hexdigest()
        imza_dosyasi = hedef.with_suffix(".imza")
        if not (hedef.exists() and imza_dosyasi.exists() and imza_dosyasi.read_text() == imza):
            print(f"  ses üretiliyor: slayt {no:02d}")
            await edge_tts.Communicate(metin, ses, rate=hiz).save(str(hedef))
            imza_dosyasi.write_text(imza)
        dosyalar.append(hedef)
    return dosyalar


def sessiz_deneme(ffmpeg, slaytlar, klasor):
    """Ses servisi olmadan akışı denemek için: kelime sayısına göre sessiz MP3."""
    dosyalar = []
    for no, _, metin in slaytlar:
        hedef = klasor / f"slayt_{no:02d}.mp3"
        saniye = max(3.0, len(metin.split()) / 2.4)
        calistir(ffmpeg, "-f", "lavfi", "-i", "anullsrc=r=24000:cl=mono", "-t", f"{saniye:.2f}", "-c:a", "libmp3lame", "-q:a", "9", str(hedef))
        dosyalar.append(hedef)
    return dosyalar


def slayt_gorselleri(klasor):
    import pypdfium2 as pdfium

    belge = pdfium.PdfDocument(str(PDF))
    yollar = []
    for i, sayfa in enumerate(belge):
        yol = klasor / f"slayt_{i + 1:02d}.png"
        sayfa.render(scale=1920 / sayfa.get_width()).to_pil().convert("RGB").save(yol)
        sayfa.close()
        yollar.append(yol)
    belge.close()
    return yollar


def video_yap(ffmpeg, gorseller, sesler, gecici, video, mp3):
    """Önce her slaytın sesini başında/sonunda boşlukla tam süresine tamamlayıp tek
    ses izinde birleştirir, sonra slayt görsellerini aynı sürelerle diziye koyar.
    Tek parça ses izi, slayt geçişlerinde çıtırtı ve kayma olmasını önler."""
    sureler = [sure(ffmpeg, mp3_) + ON_BOSLUK + SON_BOSLUK for mp3_ in sesler]
    girdiler, filtreler = [], []
    for i, (mp3_, t) in enumerate(zip(sesler, sureler)):
        girdiler += ["-i", str(mp3_)]
        filtreler.append(
            f"[{i}:a]aresample=48000,aformat=channel_layouts=stereo,"
            f"adelay={int(ON_BOSLUK * 1000)}:all=1,apad=whole_dur={t:.3f}[a{i}]"
        )
    birlesik = "".join(f"[a{i}]" for i in range(len(sesler)))
    filtreler.append(f"{birlesik}concat=n={len(sesler)}:v=0:a=1[ses]")
    ses_izi = gecici / "anlatim.wav"
    calistir(ffmpeg, *girdiler, "-filter_complex", ";".join(filtreler), "-map", "[ses]", str(ses_izi))

    liste = gecici / "gorseller.txt"
    satirlar = []
    for png, t in zip(gorseller, sureler):
        satirlar += [f"file '{png.as_posix()}'", f"duration {t:.3f}"]
    satirlar.append(f"file '{gorseller[-1].as_posix()}'")
    liste.write_text("\n".join(satirlar), encoding="utf-8")

    calistir(
        ffmpeg, "-f", "concat", "-safe", "0", "-i", str(liste), "-i", str(ses_izi),
        "-map", "0:v", "-map", "1:a", "-vf", "fps=30,scale=1920:1080,format=yuv420p",
        "-c:v", "libx264", "-preset", "veryfast", "-tune", "stillimage", "-crf", "20",
        "-c:a", "aac", "-b:a", "160k", "-shortest", "-movflags", "+faststart", str(video),
    )
    calistir(ffmpeg, "-i", str(ses_izi), "-c:a", "libmp3lame", "-q:a", "4", str(mp3))
    for i, t in enumerate(sureler, 1):
        print(f"  slayt {i:02d}: {t:.1f} sn")


def sesli_pdf(sesler, hedef):
    from pypdf import PdfWriter
    from pypdf.generic import (
        ArrayObject, DecodedStreamObject, DictionaryObject, FloatObject, NameObject, NumberObject, TextStringObject,
    )

    yazici = PdfWriter(clone_from=str(PDF))
    for i, mp3 in enumerate(sesler):
        veri = mp3.read_bytes()
        akis = DecodedStreamObject()
        akis.set_data(veri)
        akis[NameObject("/Type")] = NameObject("/EmbeddedFile")
        akis[NameObject("/Params")] = DictionaryObject({NameObject("/Size"): NumberObject(len(veri))})
        ad = TextStringObject(f"LOBI_Slayt_{i + 1:02d}_Anlatim.mp3")
        dosya = DictionaryObject({
            NameObject("/Type"): NameObject("/Filespec"),
            NameObject("/F"): ad,
            NameObject("/UF"): ad,
            NameObject("/Desc"): TextStringObject(f"Sesli anlatım — Slayt {i + 1}"),
            NameObject("/EF"): DictionaryObject({NameObject("/F"): yazici._add_object(akis)}),
        })
        kutu = yazici.pages[i].mediabox
        sag, ust = float(kutu.right) - 14, float(kutu.top) - 12
        yazici.add_annotation(i, DictionaryObject({
            NameObject("/Type"): NameObject("/Annot"),
            NameObject("/Subtype"): NameObject("/FileAttachment"),
            NameObject("/Rect"): ArrayObject([FloatObject(v) for v in (sag - 14, ust - 18, sag, ust)]),
            NameObject("/FS"): yazici._add_object(dosya),
            NameObject("/Name"): NameObject("/Paperclip"),
            NameObject("/T"): TextStringObject("LOBİ"),
            NameObject("/Contents"): TextStringObject(f"Sesli anlatım — Slayt {i + 1}. Dinlemek için çift tıklayın."),
            NameObject("/C"): ArrayObject([FloatObject(0.055), FloatObject(0.624), FloatObject(0.592)]),
            NameObject("/F"): NumberObject(4),
        }))
    with open(hedef, "wb") as f:
        yazici.write(f)


def main():
    p = argparse.ArgumentParser(description="LOBİ sunumunu seslendirir.")
    p.add_argument("--ses", default="tr-TR-EmelNeural", help="Edge TTS ses adı (varsayılan: Emel, kadın)")
    p.add_argument("--hiz", default="-4%", help="Konuşma hızı, ör. -4%% veya +5%%")
    p.add_argument("--test", action="store_true", help="Ses servisi olmadan sessiz deneme (çıktılar geçici klasöre)")
    a = p.parse_args()

    slaytlar = anlatimi_oku()
    ffmpeg = ffmpeg_yolu()
    cikti = Path(tempfile.mkdtemp(prefix="lobi_test_")) if a.test else KOK
    ses_klasoru = cikti / "ses"
    ses_klasoru.mkdir(exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="lobi_") as g:
        gecici = Path(g)
        print("1/4 Slayt görselleri hazırlanıyor…")
        gorseller = slayt_gorselleri(gecici)
        if len(gorseller) != len(slaytlar):
            sys.exit(f"PDF'te {len(gorseller)} sayfa var ama anlatim.md'de {len(slaytlar)} slayt var.")
        print("2/4 Anlatım seslendiriliyor…")
        sesler = (
            sessiz_deneme(ffmpeg, slaytlar, ses_klasoru) if a.test
            else asyncio.run(seslendir(slaytlar, ses_klasoru, a.ses, a.hiz))
        )
        print("3/4 Video oluşturuluyor…")
        video = cikti / "LOBI_Sunum_Sesli.mp4"
        video_yap(ffmpeg, gorseller, sesler, gecici, video, cikti / "LOBI_Anlatim.mp3")
    print("4/4 Sesli PDF oluşturuluyor…")
    sesli_pdf(sesler, cikti / "LOBI_Proje_Taslagi_Sesli.pdf")
    print(f"Bitti → {cikti}  (toplam süre: {sure(ffmpeg, video) / 60:.1f} dk)")


if __name__ == "__main__":
    main()
