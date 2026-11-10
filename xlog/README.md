# XLOG — LAN'dan dışarıya SSL VPN bağlantılarını engelleme

Amaç: iç ağdaki kullanıcılar dışarıdaki bir sunucuya SSL VPN programıyla
(OpenVPN, FortiClient, AnyConnect, GlobalProtect, SSTP, NordVPN, Psiphon vb.)
bağlanamasın. XLOG'un kendi VPN'i (şube bağlantıları, dışarıdan içeri SSL VPN)
etkilenmez, çünkü kurallar yalnızca **LAN → WAN** yönüne yazılır.

## Neden tek bir kural yetmiyor

SSL VPN'lerin çoğu **TCP 443** üzerinden çalışır, yani normal HTTPS gibi
görünür. 443'ü kapatırsan internet de kapanır. Bu yüzden katmanlı yapılır:

1. Uygulama filtresi (DPI): VPN programlarını imzasından tanır, 443'te bile.
2. Güvenlik duvarı: 443 dışındaki VPN portlarını kapatır.
3. Web filtresi: VPN sağlayıcılarının sitelerini/giriş sunucularını kapatır.
4. DNS: kullanıcıların DNS ile filtreyi atlatmasını engeller.

Menü adları XLOG dokümanlarından alındı; sürüme göre küçük farklar olabilir.

## 1. Uygulama filtresi (en önemli adım)

1. **Profiller → Uygulama Profilleri** → yeni profil ekle (ör. `VPN-ENGEL`),
   ad/açıklama yaz, kaydet.
2. Profili düzenle; **VPN / Proxy / Tünel / Anonimleştirici** benzeri
   kategoriyi tümüyle **Engelli** yap. Kategori adı farklıysa listede tek tek
   ara ve engelle: OpenVPN, FortiClient / Fortinet SSL VPN, Cisco AnyConnect,
   GlobalProtect, SSTP, SoftEther, WireGuard, NordVPN, ExpressVPN, ProtonVPN,
   Surfshark, Hotspot Shield, Windscribe, TunnelBear, Psiphon, Ultrasurf, Tor,
   Cloudflare WARP, Opera VPN.
3. Kuralları **cihaza yükle**.
4. Profilin gerçekten uygulanması için onu LAN'dan dışarı çıkan kurala /
   kullanıcı grubuna bağla (XLOG'da uygulama engelleme kural bazlıdır).
   Profil hiçbir kurala bağlı değilse etkisi olmaz.

## 2. Güvenlik duvarı: 443 dışındaki VPN portlarını kapat

### Seçenek A (önerilen): giden trafikte "varsayılan reddet"

LAN → WAN için yalnızca gerekenlere izin ver, en alta "LAN → WAN her şey
REDDET" koy. Böylece bilinen/bilinmeyen tüm VPN portları tek seferde kapanır.

| İzin | Not |
|---|---|
| TCP 80, TCP 443 | Web |
| DNS (UDP/TCP 53) yalnızca XLOG'a / iç DNS'e | Bkz. adım 4 |
| NTP (UDP 123) yalnızca XLOG'a veya belirli sunucuya | |
| Mail (TCP 465, 587, 993) | Kullanılıyorsa |
| İşin gerektirdiği diğer portlar | Logdan bakıp ekle |

Bu yapıda UDP 443 de kapanır. Tarayıcılar QUIC yerine otomatik TCP 443'e
döner; bu, web filtresinin de daha iyi çalışmasını sağlar.

### Seçenek B: yalnızca bilinen VPN portlarını reddet

Mevcut "LAN → WAN izin" kuralının **üstüne** şu REDDET kurallarını ekle:

| Port / protokol | Kim kullanır |
|---|---|
| TCP + UDP 1194 | OpenVPN (varsayılan) |
| UDP 443 | AnyConnect / FortiClient DTLS, ayrıca QUIC |
| TCP 4433 | SonicWall NetExtender |
| TCP 10443, 4443, 8443 | FortiGate ve diğer SSL VPN alternatif portları (8443'ü bazı web panelleri de kullanır, loga bak) |
| UDP 4501 | GlobalProtect |
| UDP 500, UDP 4500, ESP (protokol 50) | IPSec / IKEv2 VPN'ler |
| UDP 1701 | L2TP |
| TCP 1723, GRE (protokol 47) | PPTP |
| UDP 51820 | WireGuard (NordLynx vb.) |
| UDP 2408 | Cloudflare WARP |
| TCP 9001, 9030 | Tor |
| TCP 853 | DNS-over-TLS (DNS atlatma) |

Kurallar yukarıdan aşağı işlenir; REDDET kuralları genel izin kuralının
üstünde olmalı.

## 3. Web filtresi: VPN sitelerini ve giriş sunucularını kapat

1. **HTTP/HTTPS Filtreleme → Web Filtre Kuralları** → kuralları görüntüle;
   **Proxy / Anonimleştirici / VPN** kategorisini **Engelli** yap.
2. **Engelleme Kategorileri** altında yeni kategori (ör. `VPN-SITELERI`) aç ve
   ekle: `nordvpn.com`, `expressvpn.com`, `protonvpn.com`, `proton.me`,
   `surfshark.com`, `hotspotshield.com`, `windscribe.com`, `tunnelbear.com`,
   `psiphon.ca`, `psiphon3.com`, `torproject.org`, `ultrasurf.us`,
   `softether.org`, `vpngate.net`, `hide.me`, `privateinternetaccess.com`,
   `cyberghostvpn.com`, `urban-vpn.com`, `browsec.com`, `zenmate.com`.
3. **Web filtre kurallarını sisteme yükle.**

Hazır VPN uygulamaları bağlanmadan önce kendi sitelerine / API'lerine giriş
yapar; bunlar kapanınca giriş başarısız olur. İndirme siteleri de kapanmış olur.

## 4. DNS'i zorunlu kıl

- LAN → WAN **UDP/TCP 53** yalnızca XLOG'a (veya iç DNS sunucusuna) açık
  olsun, dışarıdaki diğer DNS'lere REDDET.
- **TCP 853** (DoT) kapalı olsun (yukarıdaki tabloda var).
- DNS-over-HTTPS adreslerini web filtresine ekle: `dns.google`,
  `cloudflare-dns.com`, `one.one.one.one`, `mozilla.cloudflare-dns.com`,
  `dns.quad9.net`, `doh.opendns.com`, `dns.adguard.com`, `dns.nextdns.io`.

## 5. Uç nokta tarafı (önerilir)

- Kullanıcılar Windows'ta yönetici olmasın: OpenVPN, FortiClient, WireGuard
  gibi istemciler sürücü kurar, yönetici yetkisi ister.
- Tarayıcı VPN eklentileri aslında HTTPS proxy'dir. Chrome/Edge'de GPO ile
  `ExtensionInstallBlocklist = *` ve yalnızca izinli eklentiler için
  `ExtensionInstallAllowlist` kullan.

## 6. İstisna gerekiyorsa

Müşteri/tedarikçi VPN'ine bağlanması gereken kişiler varsa: bu kişilerin IP'si
veya grubu için, REDDET kurallarının **üstüne** hedef IP'si belirli bir İZİN
kuralı yaz ve bu gruba `VPN-ENGEL` profilini atama.

## 7. Test

Bir istemciden dene:

- Herhangi bir ücretsiz OpenVPN profili (ör. vpngate) → bağlanmamalı.
- ProtonVPN / Psiphon / Windscribe ücretsiz sürüm → bağlanmamalı.
- Tarayıcıdan normal siteler → açılmalı.

Sonra **Kayıtlar → Detaylı Kayıtlar** ekranından firewall loglarına ve
uygulama engelleme sonuçlarına bak: hangi kural/profil tarafından
engellendiği görünmeli. Bağlanabilen bir program kalırsa, logda hangi hedef
IP/porta gittiğini bulup kural ekle.

## Sınır

Kendi sunucusunda 443'te çalışan, özel yapılandırılmış bir SSL VPN'i hiçbir
güvenlik duvarı %100 ayırt edemez. Yukarıdaki katmanlar bilinen tüm
programları ve sıradan kullanıcıyı durdurur; geri kalan risk uç nokta
kısıtlamaları (adım 5) ve log takibiyle kapatılır.
