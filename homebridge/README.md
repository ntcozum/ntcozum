# Homebridge kurulumu — Tuya, Xiaomi, Tapo → Apple Home

Sunucu: MacBook Air (A1466), Homebridge + Homebridge UI.

## 1. Durum tespiti

Mac'te Terminal'i açıp çalıştır:

```bash
bash teshis.sh
```

Masaüstüne `homebridge-teshis.txt` dosyası yazılır. Şifre, accessKey, PIN gibi
alanlar maskelenir. Bu dosyanın içeriğiyle hangi cihazın neden gelmediği
kesinleşir.

## 2. Tuya: cihazların bir kısmı gelmiyorsa (en sık nedenler)

Eklenti: `homebridge-tuya-platform` (Tuya IoT Cloud üzerinden çalışır).

1. **Cihaz bulut projesine bağlı değil.** iot.tuya.com → Cloud → projen →
   *Devices* → *Link App Account*: Tuya Smart / Smart Life uygulamasındaki
   hesabı bağla. Uygulamada birden fazla "Ev" varsa hepsi gelmeli; config'te
   `homeWhitelist` varsa yalnızca o evler çekilir.
2. **Veri merkezi uyuşmuyor.** Türkiye hesabı için proje veri merkezi
   genelde *Central Europe*. Projede uygulama hesabının bölgesi seçili olmalı.
3. **Kontrol modu "Standard Instruction".** *Devices* listesinde her cihaz için
   *Change Control Instruction Mode* → **DP Instruction** seç. Pek çok ucuz
   priz/ampul/sensör Standard modda eksik şema döndürür ve eklenti atlar.
4. **API servisleri / deneme süresi.** *Service API* sekmesinde şunlar
   yetkili olmalı: IoT Core, Authorization Token Management, Smart Home Basic
   Service, Device Status Notification. IoT Core deneme süresi dolunca cihazlar
   gelmez; *Cloud → Cloud Services → IoT Core → Extend Trial* ile uzatılır
   (ayda bir / 6 ayda bir yenileme gerekebilir).
5. **Desteklenmeyen kategori.** Logda `Unsupported category` veya
   `not supported` görünen cihazlar için config'e `deviceOverrides` eklenir;
   cihazın kategorisi ve DP kodları teşhis raporunda listelenir.
6. **IR kumanda / Zigbee alt cihazı.** IR'ye bağlı sanal cihazlar ve bazı ağ
   geçidi alt cihazları sınırlı desteklenir; gerekirse ayrı ele alınır.

Değişiklikten sonra: Homebridge UI → yeniden başlat. Hâlâ eksik cihaz kalırsa
UI → *Cihaz önbelleğini temizle* (sadece Tuya köprüsü için) yapıp tekrar başlat.

## 3. Xiaomi (sonraki adım)

Eklenti önerisi: `homebridge-miot`. Cihazlar için **token** gerekir; Mi Home
hesabıyla eklentinin içinden veya `micloud` aracıyla alınır. Bluetooth / Zigbee
cihazlar (ör. Mi sıcaklık sensörü) ağ geçidi olmadan Wi-Fi gibi kontrol
edilemez — hangi cihazların Wi-Fi olduğu listelenmeli.

## 4. Tapo (sonraki adım)

- Priz/ampul: Homebridge UI'da "tapo" ara; yeni KLAP şifrelemesini destekleyen,
  güncel bakımı olan eklentiyi seç (eski `homebridge-tapo-p100` yeni
  firmware'lerde çalışmıyor).
- Kamera: `homebridge-tapo-camera`. Tapo uygulamasında kamera ayarlarından
  *Gelişmiş → Kamera Hesabı* oluşturulmalı.
- Tapo hesabının şifresi eklentiye girilir; iki adımlı doğrulama sorun
  çıkarırsa geçici kapatılır.

## 5. Mac'in 7/24 açık kalması

Mac uyursa Apple Home'da tüm cihazlar "Yanıt Yok" olur.

```bash
sudo pmset -a sleep 0 disksleep 0 powernap 0
sudo pmset -a womp 1 autorestart 1
```

- Kapak kapalıyken MacBook harici ekran olmadan uyur — kapağı açık bırak ya da
  `sudo pmset -a disablesleep 1` kullan.
- Şarj kablosu takılı kalsın.
- Her eklentiyi Homebridge UI'da **Child Bridge** olarak çalıştır; biri
  çökerse diğerleri etkilenmez.
- Apple Home'da ev merkezi (Apple TV / HomePod) varsa uzaktan erişim çalışır.
