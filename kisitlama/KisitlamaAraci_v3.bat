<# : ----------------------------------------------------------------------
:: KULLANICI KISITLAMA ARACI v3  -  TEK DOSYA (batch + PowerShell)
:: Cift tiklayin. Bu bolum cmd icindir; PowerShell burayi yorum olarak gorur.
@echo off
setlocal
title Kullanici Kisitlama Araci v3

:: Yonetici mi? (fltmc, Sunucu hizmeti kapaliyken de dogru sonuc verir)
fltmc >nul 2>&1
if not errorlevel 1 goto :yonetici
if /i "%~1"=="/yukseltildi" (
    echo HATA: Yonetici yetkisi alinamadi.
    pause
    exit /b 1
)
echo Yonetici yetkisi isteniyor...
set "KA_DOSYA=%~f0"
powershell -NoProfile -Command "Start-Process -FilePath $env:KA_DOSYA -ArgumentList '/yukseltildi' -Verb RunAs" >nul 2>&1
if errorlevel 1 (
    echo Yonetici izni verilmedi.
    pause
)
exit /b

:yonetici
set "KA_DOSYA=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([IO.File]::ReadAllText($env:KA_DOSYA))"
echo.
echo Cikmak icin bir tusa basin...
pause >nul
exit /b
: ---------------------------------------------------------------------- #>

# ==========================================================================
#  KULLANICI KISITLAMA ARACI v3
#
#  Secilen kullanici icin:
#   1) Ayarlar / Denetim Masasi / ag ayarlari engeli   (kayit defteri ilkesi)
#   2) Internet engeli: guvenlik duvari, YALNIZ o hesap (SID bazli)
#   3) Istege bagli: o kullanici bilgisayarin basindayken ag adaptorlerini
#      kapatma. Sectiginiz adaptorler ACIK birakilir.
#   4) Istege bagli: Wi-Fi kilidi. Wi-Fi adaptoru acik olsa bile yalniz izin
#      verilen ag(lar) gorunur; hic izin yoksa hicbir aga baglanilamaz.
#
#  3 ve 4 icin SYSTEM olarak surekli calisan kucuk bir ajan kurulur
#  (C:\ProgramData\KisitlamaAraci). Ajan 5 saniyede bir konsoldaki
#  kullaniciya bakar: kisitli kullanici basindaysa kurallari uygular,
#  degilse YALNIZ kendi yaptigi degisiklikleri geri alir.
#
#  Her adim uygulandiktan sonra dogrulanir. Sessiz basarisizlik yoktur.
#  Turkce karakter kullanilmaz (Windows PowerShell 5.1 kod sayfasi sorunu).
# ==========================================================================

$ErrorActionPreference = 'Stop'

$KLASOR        = Join-Path $env:ProgramData 'KisitlamaAraci'
$AJAN_DOSYA    = Join-Path $KLASOR 'Ajan.ps1'
$AYAR_DOSYA    = Join-Path $KLASOR 'ayarlar.json'
$DURUM_DOSYA   = Join-Path $KLASOR 'durum.json'
$LOG_DOSYA     = Join-Path $KLASOR 'ajan.log'
$GOREV_ADI     = 'KisitlamaAraci_Ajan'
$ESKI_GOREVLER = @('NetKisitlama_Oturum', 'NetKisitlama_Logon')     # v1 / v2
$ESKI_KLASOR   = Join-Path $env:ProgramData 'NetKisitlama'           # v2
$TMP_HIVE      = 'KISITLAMA_TMP'
$KURAL_GRUBU   = 'KisitlamaAraci'

# Dil bagimsiz olmak icin gruplar hep SID ile kullanilir
$SID_SYSTEM = 'S-1-5-18'
$SID_ADMINS = 'S-1-5-32-544'
$SID_USERS  = 'S-1-5-32-545'

# ---------------------------------------------------------------- cikti
function Basli($m) {
    Write-Host ''
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
    Write-Host "  $m" -ForegroundColor Cyan
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
}
function Ok($m)    { Write-Host "  [ TAMAM ] $m" -ForegroundColor Green }
function Hata($m)  { Write-Host "  [ HATA  ] $m" -ForegroundColor Red }
function Uyari($m) { Write-Host "  [ UYARI ] $m" -ForegroundColor Yellow }
function Adim($m)  { Write-Host "  ...       $m" -ForegroundColor DarkGray }
function Bilgi($m) { Write-Host "  $m" -ForegroundColor DarkGray }

$script:HataSayisi = 0
function HataEkle($m) { Hata $m; $script:HataSayisi++ }

# ---------------------------------------------------------- genel yardimci
function EvetMi([string]$Soru, [bool]$Varsayilan) {
    $ek = if ($Varsayilan) { '[E]' } else { '[H]' }
    $c = Read-Host "  $Soru (E/H) $ek"
    if ($null -eq $c) { $c = '' }
    $c = $c.Trim()
    if (-not $c) { return $Varsayilan }
    return ($c -match '^[eEyY]')
}

function YoneticiMi {
    $kimlik = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $kimlik).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function SiddenHesap([string]$Sid) {
    try {
        (New-Object Security.Principal.SecurityIdentifier $Sid).Translate(
            [Security.Principal.NTAccount]).Value
    } catch { $null }
}

# Yoneticiler grubunun uye SID'leri. Belirlenemezse $null.
function YoneticiSidleri {
    try {
        return ,@(Get-LocalGroupMember -SID $SID_ADMINS -ErrorAction Stop |
            ForEach-Object { $_.SID.Value })
    } catch { }
    # Yedek yol: Get-LocalGroupMember cozulemeyen uyelerde hata verebilir
    try {
        $grupAd = (SiddenHesap $SID_ADMINS).Split('\')[-1]
        $grup = [ADSI]"WinNT://$env:COMPUTERNAME/$grupAd,group"
        return ,@($grup.psbase.Invoke('Members') | ForEach-Object {
            $b = $_.GetType().InvokeMember('objectSid', 'GetProperty', $null, $_, $null)
            (New-Object Security.Principal.SecurityIdentifier($b, 0)).Value
        })
    } catch { }
    return $null
}

# Harici program calistir; stderr hata firlatmasin, cikis kodu donsun.
function Komut([string]$Exe, [string[]]$Argumanlar) {
    $ErrorActionPreference = 'Continue'
    $cikti = & $Exe @Argumanlar 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ Kod = $LASTEXITCODE; Cikti = (($cikti -join ' ') -replace '\s+', ' ').Trim() }
}

# netsh: tirnakli SSID'leri bozmamak icin komut satiri birebir verilir.
function Netsh([string]$Arguman) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\netsh.exe'
    $psi.Arguments = $Arguman
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try {
        $cp = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage').OEMCP
        $psi.StandardOutputEncoding = [Text.Encoding]::GetEncoding($cp)
        $psi.StandardErrorEncoding = [Text.Encoding]::GetEncoding($cp)
    } catch { }
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    [pscustomobject]@{ Kod = $p.ExitCode; Cikti = ("$out`n$err").Trim() }
}

function JsonOku([string]$Yol) {
    if (-not (Test-Path -LiteralPath $Yol)) { return $null }
    $t = [IO.File]::ReadAllText($Yol)
    if (-not $t.Trim()) { return $null }
    return ($t | ConvertFrom-Json)
}
function JsonYaz([string]$Yol, $Nesne) {
    $metin = $Nesne | ConvertTo-Json -Depth 6
    $gecici = "$Yol.yeni"
    [IO.File]::WriteAllText($gecici, $metin, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Yol) {
        # Not: $null burada bos metne donusur ve Replace hata verir; yedek adi sart
        $yedek = "$Yol.eski"
        Remove-Item -LiteralPath $yedek -Force -ErrorAction SilentlyContinue
        [IO.File]::Replace($gecici, $Yol, $yedek)
        Remove-Item -LiteralPath $yedek -Force -ErrorAction SilentlyContinue
    } else { [IO.File]::Move($gecici, $Yol) }
}

function KapaliMi($a) { ("$($a.Status)" -eq 'Disabled') -or ($a.State -eq 3) }

function AdaptorTuru($a) {
    switch ([int]$a.NdisPhysicalMedium) {
        9  { 'Wi-Fi' }
        14 { 'Kablolu' }
        10 { 'Bluetooth' }
        8  { 'Mobil' }
        default { 'Diger' }
    }
}

# ------------------------------------------------------------ kovan yonetimi
# Kullanici oturum acmissa kovani zaten yuklu; degilse NTUSER.DAT geciciye.
function KovanAc([string]$Sid, [string]$ProfilYolu) {
    if (Test-Path "Registry::HKEY_USERS\$Sid") {
        return [pscustomobject]@{ Kok = "Registry::HKEY_USERS\$Sid"; Gecici = $false }
    }
    $dat = Join-Path $ProfilYolu 'NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $dat)) { throw "NTUSER.DAT bulunamadi: $dat" }
    if (Test-Path "Registry::HKEY_USERS\$TMP_HIVE") {
        # Yarida kalmis onceki bir calismadan kalmis olabilir
        [void](Komut 'reg.exe' @('unload', "HKU\$TMP_HIVE"))
    }
    $r = Komut 'reg.exe' @('load', "HKU\$TMP_HIVE", $dat)
    if ($r.Kod -ne 0) { throw "Profil kovani yuklenemedi (reg load): $($r.Cikti)" }
    [pscustomobject]@{ Kok = "Registry::HKEY_USERS\$TMP_HIVE"; Gecici = $true }
}

function KovanKapat($Kovan) {
    if (-not $Kovan -or -not $Kovan.Gecici) { return }
    # Registry saglayicisinin actigi handle'lar birakilmadan unload olmaz
    $r = $null
    for ($i = 1; $i -le 5; $i++) {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
        $r = Komut 'reg.exe' @('unload', "HKU\$TMP_HIVE")
        if ($r.Kod -eq 0) { return }
        Start-Sleep -Milliseconds 400
    }
    Uyari "Gecici kovan kaldirilamadi ($($r.Cikti)). Yeniden baslatma bunu temizler."
}

function DegerYaz([string]$Anahtar, [string]$Ad, [int]$Deger) {
    if (-not (Test-Path $Anahtar)) { New-Item -Path $Anahtar -Force | Out-Null }
    New-ItemProperty -Path $Anahtar -Name $Ad -Value $Deger -PropertyType DWord -Force | Out-Null
}
function DegerSil([string]$Anahtar, [string]$Ad) {
    if (Test-Path $Anahtar) {
        Remove-ItemProperty -Path $Anahtar -Name $Ad -Force -ErrorAction SilentlyContinue
    }
}
function DegerOku([string]$Anahtar, [string]$Ad) {
    if (-not (Test-Path $Anahtar)) { return $null }
    (Get-ItemProperty -Path $Anahtar -Name $Ad -ErrorAction SilentlyContinue).$Ad
}

# Kullanici ilkeleri. NC_* ilkelerinde 0 = "yasak" demektir.
$POL_EXP = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
$POL_NC  = 'Software\Policies\Microsoft\Windows\Network Connections'
$ILKELER = @(
    @{ Yol = $POL_EXP; Ad = 'NoControlPanel';              Deger = 1; Aciklama = 'Ayarlar + Denetim Masasi kapali' }
    @{ Yol = $POL_EXP; Ad = 'HideSCANetwork';              Deger = 1; Aciklama = 'Gorev cubugu ag simgesi gizli' }
    @{ Yol = $POL_NC;  Ad = 'NC_LanProperties';            Deger = 0; Aciklama = 'Baglanti ozellikleri kapali' }
    @{ Yol = $POL_NC;  Ad = 'NC_LanChangeProperties';      Deger = 0; Aciklama = 'Bilesen ozellikleri kapali' }
    @{ Yol = $POL_NC;  Ad = 'NC_AddRemoveComponents';      Deger = 0; Aciklama = 'Ag bileseni ekle/kaldir kapali' }
    @{ Yol = $POL_NC;  Ad = 'NC_ChangeBindState';          Deger = 0; Aciklama = 'Bilesen ac/kapa kapali' }
    @{ Yol = $POL_NC;  Ad = 'NC_AllowAdvancedTCPIPConfig'; Deger = 0; Aciklama = 'Gelismis TCP/IP ayarlari kapali' }
    @{ Yol = $POL_NC;  Ad = 'NC_NewConnectionWizard';      Deger = 0; Aciklama = 'Yeni baglanti (VPN/cevirmeli) kapali' }
)
# v2'nin yazdigi ama kullanici kovaninda etkisiz olan deger: temizlenir
$ESKI_ILKELER = @(
    @{ Yol = $POL_NC; Ad = 'NC_ShowSharedAccessUI' }
)

# ------------------------------------------------------------ guvenlik duvari
function KuralId([string]$Sid) { "KisitlamaAraci_NoNet_$Sid" }

function KuralDogrula($K) {
    $r = Get-NetFirewallRule -Name (KuralId $K.Sid) -ErrorAction SilentlyContinue
    if (-not $r) { return $false }
    $sf = $r | Get-NetFirewallSecurityFilter
    return (("$($r.Enabled)" -eq 'True') -and ("$($r.Action)" -eq 'Block') -and
            ("$($r.Direction)" -eq 'Outbound') -and ("$($sf.LocalUser)" -match [regex]::Escape($K.Sid)))
}

# $true = Windows guvenlik duvari tum profillerde acik
function GuvenlikDuvariKontrol([bool]$Duzelt) {
    $tamam = $true
    try {
        $kapali = @(Get-NetFirewallProfile -PolicyStore ActiveStore | Where-Object { "$($_.Enabled)" -ne 'True' })
        if ($kapali.Count -and $Duzelt) {
            Uyari "Windows guvenlik duvari su profillerde KAPALI: $($kapali.Name -join ', ')"
            if (EvetMi 'Bu profillerde guvenlik duvarini acayim mi?' $true) {
                Set-NetFirewallProfile -Profile $kapali.Name -Enabled True
                $kapali = @(Get-NetFirewallProfile -PolicyStore ActiveStore | Where-Object { "$($_.Enabled)" -ne 'True' })
            }
        }
        if ($kapali.Count) {
            Uyari "Guvenlik duvari KAPALI: $($kapali.Name -join ', '). Bu profillerde internet engeli CALISMAZ."
            $tamam = $false
        } else {
            Ok 'Windows guvenlik duvari tum profillerde acik'
        }
    } catch {
        Uyari "Guvenlik duvari profilleri okunamadi: $($_.Exception.Message)"
        $tamam = $false
    }
    try {
        $digerleri = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName FirewallProduct -ErrorAction Stop |
            Where-Object { $_.displayName -and $_.displayName -notmatch 'Windows' } |
            ForEach-Object { $_.displayName })
        if ($digerleri.Count) {
            Uyari "Baska bir guvenlik duvari yuklu: $($digerleri -join ', ')"
            Uyari 'Bu durumda Windows guvenlik duvari kurallari uygulanmayabilir;'
            Uyari 'internet engelini o programda da tanimlayin.'
        }
    } catch { }   # sunucu surumlerinde SecurityCenter2 yoktur
    return $tamam
}

# ------------------------------------------------------------------- AJAN
# Bu kod C:\ProgramData\KisitlamaAraci\Ajan.ps1 olarak yazilir ve SYSTEM
# olarak surekli calisir.
$AJAN_KODU = @'
# KisitlamaAraci v3 - AJAN (arac tarafindan yazildi, elle degistirmeyin)
# SYSTEM olarak surekli calisir. 5 saniyede bir konsoldaki kullaniciya bakar:
#  - ayarlar.json'daki kisitli bir kullanici basindaysa adaptor / Wi-Fi kurallari
#  - degilse YALNIZ bu ajanin yaptigi degisiklikler geri alinir (durum.json)
$ErrorActionPreference = 'Stop'
$KLASOR = Join-Path $env:ProgramData 'KisitlamaAraci'
$AYAR_YOLU   = Join-Path $KLASOR 'ayarlar.json'
$DURUM_YOLU  = Join-Path $KLASOR 'durum.json'
$LOG_YOLU    = Join-Path $KLASOR 'ajan.log'
$ARALIK = 5
$script:Gorulen = @{}
$script:WifiTekrar = $null
$script:WifiSonIstek = $null

function Log([string]$m) {
    try {
        if ((Test-Path -LiteralPath $LOG_YOLU) -and ((Get-Item -LiteralPath $LOG_YOLU).Length -gt 512KB)) {
            Remove-Item -LiteralPath "$LOG_YOLU.1" -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $LOG_YOLU -Destination "$LOG_YOLU.1"
        }
        $satir = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $m
        [IO.File]::AppendAllText($LOG_YOLU, $satir + "`r`n", (New-Object Text.UTF8Encoding($false)))
    } catch { }
}
function LogBirKez([string]$m) {
    if (-not $script:Gorulen.ContainsKey($m)) { $script:Gorulen[$m] = 1; Log $m }
}

function JsonOku([string]$Yol) {
    if (-not (Test-Path -LiteralPath $Yol)) { return $null }
    $t = [IO.File]::ReadAllText($Yol)
    if (-not $t.Trim()) { return $null }
    return ($t | ConvertFrom-Json)
}
function JsonYaz([string]$Yol, $Nesne) {
    $metin = $Nesne | ConvertTo-Json -Depth 6
    $gecici = "$Yol.yeni"
    [IO.File]::WriteAllText($gecici, $metin, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Yol) {
        # Not: $null burada bos metne donusur ve Replace hata verir; yedek adi sart
        $yedek = "$Yol.eski"
        Remove-Item -LiteralPath $yedek -Force -ErrorAction SilentlyContinue
        [IO.File]::Replace($gecici, $Yol, $yedek)
        Remove-Item -LiteralPath $yedek -Force -ErrorAction SilentlyContinue
    } else { [IO.File]::Move($gecici, $Yol) }
}

function Netsh([string]$Arguman) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\netsh.exe'
    $psi.Arguments = $Arguman
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try {
        $cp = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage').OEMCP
        $psi.StandardOutputEncoding = [Text.Encoding]::GetEncoding($cp)
        $psi.StandardErrorEncoding = [Text.Encoding]::GetEncoding($cp)
    } catch { }
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    [pscustomobject]@{ Kod = $p.ExitCode; Cikti = (("$out $err") -replace '\s+', ' ').Trim() }
}

function KapaliMi($a) { ("$($a.Status)" -eq 'Disabled') -or ($a.State -eq 3) }

function DurumOku {
    $d = $null
    try { $d = JsonOku $DURUM_YOLU } catch { Log "durum.json okunamadi: $($_.Exception.Message)" }
    [pscustomobject]@{
        Adaptorler  = @($d.Adaptorler | Where-Object { $_ })
        WifiDenyAll = [bool]$d.WifiDenyAll
        WifiIzinli  = @($d.WifiIzinli | Where-Object { $_ })
    }
}
function DurumKaydet {
    try { JsonYaz $DURUM_YOLU $script:Durum } catch { LogBirKez "durum.json yazilamadi: $($_.Exception.Message)" }
}

function KonsolKullanicisi {
    $ad = [string](Get-CimInstance -ClassName Win32_ComputerSystem).UserName
    $sid = ''
    if ($ad) {
        try { $sid = ([Security.Principal.NTAccount]$ad).Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
    }
    [pscustomobject]@{ Ad = $ad; Sid = $sid }
}

function HedefBul($ayar, $konsol) {
    if (-not $ayar -or -not $konsol.Ad) { return $null }
    foreach ($k in @($ayar.Kullanicilar | Where-Object { $_ })) {
        if ($konsol.Sid) { if ($k.Sid -eq $konsol.Sid) { return $k } }
        elseif ($k.Hesap -eq $konsol.Ad) { return $k }
    }
    return $null
}

function AdaptorleriUygula($hedef) {
    $liste = New-Object System.Collections.ArrayList
    foreach ($g in $script:Durum.Adaptorler) { [void]$liste.Add([string]$g) }
    $adaptorler = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)

    if ($hedef -and $hedef.AdaptorKapat) {
        $acik = @($hedef.AcikKalacak | Where-Object { $_ })
        foreach ($a in $adaptorler) {
            $g = [string]$a.InterfaceGuid
            if (($acik -contains $g) -or (KapaliMi $a)) { continue }
            if (-not $liste.Contains($g)) {
                # Once kaydet: yarida kesilirse sonradan geri acilabilsin
                [void]$liste.Add($g)
                $script:Durum.Adaptorler = @($liste)
                DurumKaydet
            }
            try {
                $a | Disable-NetAdapter -Confirm:$false -ErrorAction Stop
                Log "Adaptor kapatildi: $($a.Name)"
            } catch { LogBirKez "Adaptor kapatilamadi: $($a.Name): $($_.Exception.Message)" }
        }
        $geriAc = @($liste | Where-Object { $acik -contains $_ })
    } else {
        $geriAc = @($liste)
    }

    foreach ($g in $geriAc) {
        $a = $adaptorler | Where-Object { [string]$_.InterfaceGuid -eq $g } | Select-Object -First 1
        if (-not $a) { continue }   # takili degil; takilinca acilir
        try {
            if (KapaliMi $a) {
                $a | Enable-NetAdapter -Confirm:$false -ErrorAction Stop
                Log "Adaptor acildi: $($a.Name)"
            }
            [void]$liste.Remove($g)
            $script:Durum.Adaptorler = @($liste)
            DurumKaydet
        } catch { LogBirKez "Adaptor acilamadi: $($a.Name): $($_.Exception.Message)" }
    }
}

function WifiUygula($hedef) {
    $d = $script:Durum
    $isteDeny = [bool]($hedef -and $hedef.WifiKilit)
    $isteIzin = @()
    if ($isteDeny) { $isteIzin = @($hedef.IzinliSSID | Where-Object { $_ }) }

    $istenen = "$isteDeny|" + (@($isteIzin | Sort-Object) -join "`n")
    $mevcut  = "$($d.WifiDenyAll)|" + (@($d.WifiIzinli | Sort-Object) -join "`n")
    if ($istenen -ceq $mevcut) { return }   # her sey yerinde
    # Ayni istek az once basarisiz olduysa 30 sn bekle (netsh'i bosuna yorma)
    if ($istenen -ceq $script:WifiSonIstek -and $script:WifiTekrar -and (Get-Date) -lt $script:WifiTekrar) { return }
    $script:WifiSonIstek = $istenen
    $script:WifiTekrar = $null
    $hataVar = $false

    # 1) Yeni izinli aglar (kilit gelmeden once ki o aga bagli kalinsin)
    foreach ($s in $isteIzin) {
        if ($d.WifiIzinli -ccontains $s) { continue }
        [void](Netsh "wlan delete filter permission=allow ssid=`"$s`" networktype=infrastructure")
        $r = Netsh "wlan add filter permission=allow ssid=`"$s`" networktype=infrastructure"
        if ($r.Kod -eq 0) {
            $d.WifiIzinli = @($d.WifiIzinli) + $s
            DurumKaydet
            Log "Wi-Fi izinli ag eklendi: $s"
        } else { $hataVar = $true; LogBirKez "Wi-Fi izinli ag eklenemedi ($s): $($r.Cikti)" }
    }

    # 2) Kilit (diger tum aglar engelli)
    if ($isteDeny -and -not $d.WifiDenyAll) {
        [void](Netsh 'wlan delete filter permission=denyall networktype=infrastructure')
        $r = Netsh 'wlan add filter permission=denyall networktype=infrastructure'
        if ($r.Kod -eq 0) { $d.WifiDenyAll = $true; DurumKaydet; Log 'Wi-Fi kilidi devrede' }
        else { $hataVar = $true; LogBirKez "Wi-Fi kilidi eklenemedi: $($r.Cikti)" }
    }
    if (-not $isteDeny -and $d.WifiDenyAll) {
        $r = Netsh 'wlan delete filter permission=denyall networktype=infrastructure'
        if ($r.Kod -eq 0) { $d.WifiDenyAll = $false; DurumKaydet; Log 'Wi-Fi kilidi kaldirildi' }
        else { $hataVar = $true; LogBirKez "Wi-Fi kilidi kaldirilamadi: $($r.Cikti)" }
    }

    # 3) Artik istenmeyen izinler
    foreach ($s in @($d.WifiIzinli)) {
        if ($isteIzin -ccontains $s) { continue }
        $r = Netsh "wlan delete filter permission=allow ssid=`"$s`" networktype=infrastructure"
        if ($r.Kod -eq 0) {
            $d.WifiIzinli = @($d.WifiIzinli | Where-Object { $_ -cne $s })
            DurumKaydet
            Log "Wi-Fi izinli ag kaldirildi: $s"
        } else { $hataVar = $true; LogBirKez "Wi-Fi izinli ag kaldirilamadi ($s): $($r.Cikti)" }
    }

    if ($hataVar) { $script:WifiTekrar = (Get-Date).AddSeconds(30) }
}

# ---------------------------------------------------------------- dongu
Log "Ajan basladi (PID $PID)"
$script:Durum = DurumOku
$sonHal = $null
while ($true) {
    try {
        $ayar = $null
        try { $ayar = JsonOku $AYAR_YOLU } catch { LogBirKez "ayarlar.json okunamadi: $($_.Exception.Message)" }
        $konsol = KonsolKullanicisi
        $hedef = HedefBul $ayar $konsol
        $hal = if ($hedef) { "K|$($hedef.Sid)" } else { "S|$($konsol.Ad)" }
        if ($hal -ne $sonHal) {
            $ne = if ($hedef) { 'KISITLAMA UYGULANIYOR' } else { 'serbest' }
            Log "Konsol: '$($konsol.Ad)' -> $ne"
            $sonHal = $hal
            $script:Gorulen = @{}
        }
        AdaptorleriUygula $hedef
        WifiUygula $hedef
    } catch {
        LogBirKez "Dongu hatasi: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $ARALIK
}
'@

# -------------------------------------------------------- ajan yonetimi
function AyarOku {
    $liste = New-Object System.Collections.ArrayList
    $a = JsonOku $AYAR_DOSYA
    foreach ($k in @($a.Kullanicilar | Where-Object { $_ })) {
        [void]$liste.Add([pscustomobject]@{
            Sid           = [string]$k.Sid
            Hesap         = [string]$k.Hesap
            AdaptorKapat  = [bool]$k.AdaptorKapat
            AcikKalacak   = @($k.AcikKalacak | Where-Object { $_ })
            AcikKalacakAd = @($k.AcikKalacakAd | Where-Object { $_ })
            WifiKilit     = [bool]$k.WifiKilit
            IzinliSSID    = @($k.IzinliSSID | Where-Object { $_ })
        })
    }
    return ,$liste
}

# Klasor: sahibi Yoneticiler; SYSTEM/Yoneticiler tam, Kullanicilar yalniz okur.
# Bir standart kullanici klasoru onceden olusturmus olsa bile sahiplik ve
# acik izinler sifirlanir (aksi halde SYSTEM'in calistirdigi dosyayi degistirebilirdi).
function KlasorKilitle {
    if (-not (Test-Path -LiteralPath $KLASOR)) { New-Item -Path $KLASOR -ItemType Directory -Force | Out-Null }
    $r = Komut 'icacls.exe' @($KLASOR, '/setowner', "*$($SID_ADMINS)", '/T', '/C', '/Q')
    if ($r.Kod -ne 0) { throw "icacls /setowner basarisiz: $($r.Cikti)" }
    $r = Komut 'icacls.exe' @($KLASOR, '/reset', '/T', '/C', '/Q')
    if ($r.Kod -ne 0) { throw "icacls /reset basarisiz: $($r.Cikti)" }
    $r = Komut 'icacls.exe' @($KLASOR, '/inheritance:r', '/grant:r',
        "*$($SID_SYSTEM):(OI)(CI)F", "*$($SID_ADMINS):(OI)(CI)F", "*$($SID_USERS):(OI)(CI)RX", '/Q')
    if ($r.Kod -ne 0) { throw "icacls /grant basarisiz: $($r.Cikti)" }
}

function KlasorDogrula {
    $yazma = 0x10000000 -bor 0x40000000 -bor [int][Security.AccessControl.FileSystemRights](
        'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete, ' +
        'DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership')
    $nesneler = @(Get-Item -LiteralPath $KLASOR -Force) + @(Get-ChildItem -LiteralPath $KLASOR -Force -Recurse)
    foreach ($n in $nesneler) {
        $acl = Get-Acl -LiteralPath $n.FullName
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $SID_ADMINS) { return $false }
        foreach ($k in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ("$($k.AccessControlType)" -ne 'Allow') { continue }
            if (@($SID_SYSTEM, $SID_ADMINS) -contains $k.IdentityReference.Value) { continue }
            if (([int]$k.FileSystemRights -band $yazma) -ne 0) { return $false }
        }
    }
    return [bool](Get-Acl -LiteralPath $KLASOR).AreAccessRulesProtected
}

function GorevDurdur {
    $g = Get-ScheduledTask -TaskName $GOREV_ADI -ErrorAction SilentlyContinue
    if (-not $g -or "$($g.State)" -ne 'Running') { return }
    Stop-ScheduledTask -TaskName $GOREV_ADI
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if ("$((Get-ScheduledTask -TaskName $GOREV_ADI).State)" -ne 'Running') { return }
    }
    Uyari 'Ajan gorevi durdurulamadi'
}

function AjanKur($Liste) {
    Adim 'Ajan klasoru hazirlaniyor ve kilitleniyor'
    KlasorKilitle
    [IO.File]::WriteAllText($AJAN_DOSYA, $AJAN_KODU, [Text.Encoding]::ASCII)
    JsonYaz $AYAR_DOSYA ([pscustomobject]@{ Surum = 3; Kullanicilar = @($Liste) })
    KlasorKilitle   # yeni dosyalar da ayni izinleri alsin
    if ([IO.File]::ReadAllText($AJAN_DOSYA) -ne $AJAN_KODU) { throw 'Ajan dosyasi dogrulanamadi' }
    if (-not (KlasorDogrula)) { throw 'Ajan klasoru izinleri dogrulanamadi (standart kullanicilar degistirebilir)' }
    Ok "Ajan ve ayarlar yazildi, klasor kilitli: $KLASOR"

    Adim 'Zamanlanmis gorev kaydediliyor'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $eylem = New-ScheduledTaskAction -Execute $ps `
        -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$AJAN_DOSYA`""
    $tetik = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn))
    $asil = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $ayar = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

    GorevDurdur   # eski ajan kopyasi calisiyorsa yenisi baslasin
    Register-ScheduledTask -TaskName $GOREV_ADI -Action $eylem -Trigger $tetik -Principal $asil `
        -Settings $ayar -Description 'KisitlamaAraci v3 ajani' -Force | Out-Null
    Start-ScheduledTask -TaskName $GOREV_ADI

    $calisiyor = $false
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 500
        if ("$((Get-ScheduledTask -TaskName $GOREV_ADI).State)" -eq 'Running') { $calisiyor = $true; break }
    }
    if ($calisiyor) { Ok 'Ajan gorevi kayitli ve CALISIYOR' }
    else { throw "Ajan baslatilamadi (son sonuc: $((Get-ScheduledTaskInfo -TaskName $GOREV_ADI).LastTaskResult))" }
}

# Ajanin kapattigi adaptorleri acar, ekledigi Wi-Fi filtrelerini siler.
function AjanIzleriniGeriAl {
    $d = $null
    try { $d = JsonOku $DURUM_DOSYA } catch { HataEkle "durum.json okunamadi: $($_.Exception.Message)"; return }
    if (-not $d) { return }

    $adaptorler = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    foreach ($g in @($d.Adaptorler | Where-Object { $_ })) {
        $a = $adaptorler | Where-Object { [string]$_.InterfaceGuid -eq $g } | Select-Object -First 1
        if (-not $a) {
            Uyari "Ajanin kapattigi bir adaptor su an takili degil ($g). Takinca Ag Baglantilari'ndan acin."
            continue
        }
        try {
            if (KapaliMi $a) { $a | Enable-NetAdapter -Confirm:$false -ErrorAction Stop }
            Ok "Adaptor acildi: $($a.Name)"
        } catch { HataEkle "Adaptor acilamadi ($($a.Name)): $($_.Exception.Message)" }
    }
    if ($d.WifiDenyAll) {
        $r = Netsh 'wlan delete filter permission=denyall networktype=infrastructure'
        if ($r.Kod -eq 0) { Ok 'Wi-Fi kilidi kaldirildi' } else { HataEkle "Wi-Fi kilidi kaldirilamadi: $($r.Cikti)" }
    }
    foreach ($s in @($d.WifiIzinli | Where-Object { $_ })) {
        $r = Netsh "wlan delete filter permission=allow ssid=`"$s`" networktype=infrastructure"
        if ($r.Kod -eq 0) { Ok "Wi-Fi izin filtresi silindi: $s" } else { HataEkle "Wi-Fi izin filtresi silinemedi ($s): $($r.Cikti)" }
    }
}

function AjanKaldir {
    $g = Get-ScheduledTask -TaskName $GOREV_ADI -ErrorAction SilentlyContinue
    if ($g) {
        GorevDurdur
        Unregister-ScheduledTask -TaskName $GOREV_ADI -Confirm:$false
        if (Get-ScheduledTask -TaskName $GOREV_ADI -ErrorAction SilentlyContinue) { HataEkle 'Ajan gorevi silinemedi' }
        else { Ok 'Ajan gorevi silindi' }
    }
    AjanIzleriniGeriAl
    if (Test-Path -LiteralPath $KLASOR) {
        Remove-Item -LiteralPath $KLASOR -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $KLASOR) { HataEkle "Klasor silinemedi: $KLASOR" }
        else { Ok "Klasor silindi: $KLASOR" }
    }
}

# v1/v2 kalintilari. v2 ajani TUM fiziksel adaptorleri kapatiyordu.
function EskiSurumVarMi {
    if (Test-Path -LiteralPath $ESKI_KLASOR) { return $true }
    foreach ($ad in $ESKI_GOREVLER) {
        if (Get-ScheduledTask -TaskName $ad -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}
function EskiSurumTemizle {
    if (-not (EskiSurumVarMi)) { return }
    Adim 'Eski surum (v1/v2) kalintilari temizleniyor'
    foreach ($ad in $ESKI_GOREVLER) {
        if (Get-ScheduledTask -TaskName $ad -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $ad -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $ad -Confirm:$false
            Ok "Eski gorev silindi: $ad"
        }
    }
    if (Test-Path -LiteralPath $ESKI_KLASOR) {
        Remove-Item -LiteralPath $ESKI_KLASOR -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $ESKI_KLASOR) { HataEkle "Eski klasor silinemedi: $ESKI_KLASOR" }
        else { Ok "Eski klasor silindi: $ESKI_KLASOR" }
    }
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { KapaliMi $_ })) {
        try {
            $a | Enable-NetAdapter -Confirm:$false -ErrorAction Stop
            Ok "Eski surumun kapattigi adaptor acildi: $($a.Name)"
        } catch { HataEkle "Adaptor acilamadi ($($a.Name)): $($_.Exception.Message)" }
    }
}

# ------------------------------------------------------------ secimler
function ProfilleriListele {
    $kok = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    foreach ($a in Get-ChildItem $kok) {
        $sid = $a.PSChildName
        # Yerel/etki alani (S-1-5-21) ve Microsoft Entra (S-1-12-1) hesaplari
        if ($sid -notmatch '^S-1-(5-21|12-1)-[\d-]+$') { continue }
        $hesap = SiddenHesap $sid
        if (-not $hesap) { continue }
        $yol = [Environment]::ExpandEnvironmentVariables([string](Get-ItemProperty -LiteralPath $a.PSPath).ProfileImagePath)
        [pscustomobject]@{ Sid = $sid; Hesap = $hesap; Profil = $yol }
    }
}

function KullaniciSec {
    Basli 'KULLANICI KISITLAMA ARACI v3'
    $profiller = @(ProfilleriListele | Sort-Object Hesap)
    if (-not $profiller.Count) { throw 'Bu bilgisayarda secilebilecek kullanici profili yok (hesap en az bir kez oturum acmali).' }
    $yoneticiler = YoneticiSidleri
    $ben = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

    Bilgi 'Bu bilgisayardaki kullanici profilleri:'
    for ($i = 0; $i -lt $profiller.Count; $i++) {
        $p = $profiller[$i]
        $etiket = @()
        if ($null -ne $yoneticiler -and $yoneticiler -contains $p.Sid) { $etiket += 'yonetici' }
        if ($p.Sid -eq $ben) { $etiket += 'siz' }
        if (Get-NetFirewallRule -Name (KuralId $p.Sid) -ErrorAction SilentlyContinue) { $etiket += 'kisitli' }
        $ek = if ($etiket.Count) { '   (' + ($etiket -join ', ') + ')' } else { '' }
        Write-Host ('     [{0}] {1}{2}' -f ($i + 1), $p.Hesap, $ek) -ForegroundColor Gray
    }
    Write-Host ''

    $secilen = $null
    while (-not $secilen) {
        $giris = Read-Host '  Kullanici numarasi veya adi'
        if ($null -eq $giris) { $giris = '' }
        $giris = $giris.Trim()
        if (-not $giris) { continue }
        $n = 0
        if ([int]::TryParse($giris, [ref]$n)) {
            if ($n -ge 1 -and $n -le $profiller.Count) { $secilen = $profiller[$n - 1] }
        } else {
            $secilen = $profiller | Where-Object { $_.Hesap -eq $giris -or $_.Hesap.Split('\')[-1] -eq $giris } |
                Select-Object -First 1
        }
        if (-not $secilen) { Uyari 'Boyle bir kullanici yok, tekrar deneyin.' }
    }

    $yonetici = if ($null -eq $yoneticiler) { $null } else { [bool]($yoneticiler -contains $secilen.Sid) }
    [pscustomobject]@{
        Sid      = $secilen.Sid
        Hesap    = $secilen.Hesap
        Kisa     = $secilen.Hesap.Split('\')[-1]
        Profil   = $secilen.Profil
        Yonetici = $yonetici
        Ben      = ($secilen.Sid -eq $ben)
    }
}

function AdaptorSec {
    $adaptorler = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Sort-Object Name)
    if (-not $adaptorler.Count) { Uyari 'Fiziksel ag adaptoru bulunamadi.'; return ,@() }
    Write-Host ''
    Bilgi 'Fiziksel ag adaptorleri:'
    for ($i = 0; $i -lt $adaptorler.Count; $i++) {
        $a = $adaptorler[$i]
        Write-Host ('     [{0}] {1,-24} {2,-10} {3,-13} {4}' -f ($i + 1), $a.Name, (AdaptorTuru $a), $a.Status, $a.InterfaceDescription) -ForegroundColor Gray
    }
    Bilgi 'Kisitli kullanici basindayken bu adaptorler KAPATILIR.'
    Bilgi 'ACIK kalmasini istediklerinizin numarasini yazin (ornek: 1,3). Bos = hepsi kapansin.'

    while ($true) {
        $giris = Read-Host '  Acik kalacak adaptorler'
        if ($null -eq $giris) { $giris = '' }
        $secilen = @()
        $gecerli = $true
        foreach ($p in @($giris -split '[,; ]+' | Where-Object { $_ })) {
            $n = 0
            if ([int]::TryParse($p, [ref]$n) -and $n -ge 1 -and $n -le $adaptorler.Count) {
                if ($secilen -notcontains $adaptorler[$n - 1]) { $secilen += $adaptorler[$n - 1] }
            } else {
                Uyari "Gecersiz numara: $p"
                $gecerli = $false
                break
            }
        }
        if ($gecerli) { break }
    }
    if ($secilen.Count) { Ok "Acik kalacak: $(($secilen | ForEach-Object { $_.Name }) -join ', ')" }
    else { Ok 'Kisitli kullanici basindayken TUM fiziksel adaptorler kapanacak' }
    if ($secilen.Count -eq $adaptorler.Count) { Uyari 'Tum adaptorler acik kalacak; adaptor kapatma bir sey yapmayacak.' }
    return ,$secilen
}

function SuankiSsidler {
    $liste = @()
    $r = Netsh 'wlan show interfaces'
    if ($r.Kod -ne 0) { return ,$liste }
    foreach ($s in ($r.Cikti -split "`r?`n")) {
        if ($s -match '^\s*SSID\s*:\s*(.+?)\s*$') { $liste += $matches[1] }
    }
    return ,$liste
}

function SsidSec {
    $mevcut = SuankiSsidler
    Write-Host ''
    Bilgi 'WI-FI KILIDI: kisitli kullanici basindayken yalniz izin verdiginiz ag(lar)'
    Bilgi 'gorunur ve baglanilabilir. Hic izin vermezseniz Wi-Fi adaptoru acik olsa'
    Bilgi 'bile HICBIR aga baglanilamaz. Ag adlari buyuk/kucuk harfe duyarlidir.'
    if ($mevcut.Count) { Bilgi "Su an bagli Wi-Fi agi: $($mevcut -join ', ')" }
    $varsayilan = if ($mevcut.Count) { $mevcut -join ', ' } else { 'hicbiri' }

    while ($true) {
        $giris = Read-Host "  Izinli ag adlari (virgulle; bos = $varsayilan; - = hicbiri)"
        if ($null -eq $giris) { $giris = '' }
        $giris = $giris.Trim()
        if (-not $giris)        { $liste = @($mevcut) }
        elseif ($giris -eq '-') { $liste = @() }
        else { $liste = @($giris -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        if (@($liste | Where-Object { $_ -match '"' }).Count) { Uyari 'Ag adinda cift tirnak olamaz.'; continue }
        break
    }
    $tekil = @()
    foreach ($s in $liste) { if ($tekil -cnotcontains $s) { $tekil += $s } }
    if ($tekil.Count) { Ok "Izinli Wi-Fi aglari: $($tekil -join ', ')" }
    else { Uyari 'Hicbir Wi-Fi agina izin yok: kisitli kullanici basindayken Wi-Fi kullanilamaz.' }
    return ,$tekil
}

# -------------------------------------------------------------------- DURUM
function Durum($K) {
    Basli "DURUM: $($K.Hesap)"
    if ($K.Yonetici -eq $true) { Uyari 'Bu hesap YONETICI: kisitlamalari kendisi kaldirabilir.' }

    $kovan = $null
    try {
        $kovan = KovanAc $K.Sid $K.Profil
        foreach ($i in $ILKELER) {
            $v = DegerOku "$($kovan.Kok)\$($i.Yol)" $i.Ad
            if ($v -eq $i.Deger) { Ok "$($i.Ad) = $v  ($($i.Aciklama))" }
            else { Uyari "$($i.Ad) ayarli DEGIL (okunan: $(if ($null -eq $v) { 'yok' } else { $v }))" }
        }
        foreach ($i in $ESKI_ILKELER) {
            if ($null -ne (DegerOku "$($kovan.Kok)\$($i.Yol)" $i.Ad)) { Adim "$($i.Ad): eski surumden kalan etkisiz deger" }
        }
    } catch {
        HataEkle "Kayit defteri okunamadi: $($_.Exception.Message)"
    } finally {
        KovanKapat $kovan
    }

    Write-Host ''
    if (KuralDogrula $K) { Ok 'Internet engeli (guvenlik duvari kurali) aktif' }
    elseif (Get-NetFirewallRule -Name (KuralId $K.Sid) -ErrorAction SilentlyContinue) { Uyari 'Guvenlik duvari kurali var ama beklenen ayarda degil' }
    else { Uyari 'Internet engeli YOK' }
    if (Get-NetFirewallRule -DisplayName "Kisitlama_NoNet_$($K.Kisa)" -ErrorAction SilentlyContinue) {
        Uyari 'v2 kurali hala duruyor (UYGULA veya KALDIR temizler)'
    }
    [void](GuvenlikDuvariKontrol $false)

    Write-Host ''
    $g = Get-ScheduledTask -TaskName $GOREV_ADI -ErrorAction SilentlyContinue
    if ($g) {
        if ("$($g.State)" -eq 'Running') { Ok 'Ajan calisiyor' }
        else { Uyari "Ajan gorevi var ama CALISMIYOR (State=$($g.State), son sonuc=$((Get-ScheduledTaskInfo -TaskName $GOREV_ADI).LastTaskResult))" }
    } else {
        Adim 'Ajan kurulu degil (adaptor kapatma / Wi-Fi kilidi kullanilmiyor)'
    }

    try {
        $liste = AyarOku
        $kayit = $liste | Where-Object { $_.Sid -eq $K.Sid } | Select-Object -First 1
        if ($kayit) {
            if ($kayit.AdaptorKapat) {
                $ac = if ($kayit.AcikKalacakAd.Count) { $kayit.AcikKalacakAd -join ', ' } else { 'hicbiri' }
                Ok "Adaptor kapatma ACIK. Acik kalacak adaptorler: $ac"
            } else { Adim 'Adaptor kapatma: kullanilmiyor' }
            if ($kayit.WifiKilit) {
                $iz = if ($kayit.IzinliSSID.Count) { $kayit.IzinliSSID -join ', ' } else { 'hicbiri (Wi-Fi kullanilamaz)' }
                Ok "Wi-Fi kilidi ACIK. Izinli aglar: $iz"
            } else { Adim 'Wi-Fi kilidi: kullanilmiyor' }
        }
        $digerleri = @($liste | Where-Object { $_.Sid -ne $K.Sid } | ForEach-Object { $_.Hesap })
        if ($digerleri.Count) { Adim "Ajanin kisitladigi diger kullanicilar: $($digerleri -join ', ')" }

        $d = JsonOku $DURUM_DOSYA
        if ($d) {
            $kapali = @($d.Adaptorler | Where-Object { $_ })
            if ($kapali.Count) {
                $hepsi = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
                $adlar = foreach ($gu in $kapali) {
                    $a = $hepsi | Where-Object { [string]$_.InterfaceGuid -eq $gu } | Select-Object -First 1
                    if ($a) { $a.Name } else { "$gu (takili degil)" }
                }
                Uyari "Ajanin su an kapattigi adaptorler: $($adlar -join ', ')"
            }
            if ($d.WifiDenyAll) { Uyari 'Wi-Fi kilidi su an DEVREDE' }
        }
    } catch {
        HataEkle "Ajan ayarlari okunamadi: $($_.Exception.Message)"
    }

    if (Test-Path -LiteralPath $LOG_DOSYA) {
        Write-Host ''
        Bilgi 'Ajan gunlugu (son 5 satir):'
        Get-Content -LiteralPath $LOG_DOSYA -Tail 5 -Encoding UTF8 | ForEach-Object { Bilgi "   $_" }
    }
    if (EskiSurumVarMi) { Uyari 'Eski surum (v2) gorevi/klasoru duruyor (UYGULA veya KALDIR temizler)' }
}

# ------------------------------------------------------------------- UYGULA
function Uygula($K) {
    Basli "KISITLAMALAR UYGULANIYOR: $($K.Hesap)"

    if ($K.Ben) { Uyari 'Secilen hesap SU AN bu araci calistiran hesap! Kendinizi kisitlamak uzeresiniz.' }
    if ($K.Yonetici -eq $true) {
        Uyari "'$($K.Hesap)' Yoneticiler grubunda: kisitlamalari kendisi kaldirabilir."
        Uyari 'Once hesabi standart kullaniciya cevirmeniz onerilir.'
    } elseif ($null -eq $K.Yonetici) {
        Uyari 'Hesabin yonetici olup olmadigi belirlenemedi.'
    }
    if ($K.Ben -or $K.Yonetici -eq $true) {
        if (-not (EvetMi 'Yine de devam edilsin mi?' $false)) { Uyari 'Iptal edildi, hicbir sey degistirilmedi.'; return }
    }

    # ---- Sorular (once hepsi sorulur, sonra uygulanir)
    Write-Host ''
    $internetEngel = EvetMi 'Bu kullanicinin internetini guvenlik duvari ile engelleyeyim mi? (onerilen)' $true

    Write-Host ''
    Uyari 'Adaptor kapatma MAKINE GENELINDE etkilidir: kisitli kullanici basindayken'
    Uyari 'secmediginiz adaptorler herkes icin kapanir; baskasi basa gecince ajan geri acar.'
    $adaptorKapat = EvetMi 'Bu kullanici basindayken ag adaptorlerini kapatayim mi?' $false
    $acikKalacak = @()
    if ($adaptorKapat) { $acikKalacak = AdaptorSec }

    $wifiKilit = $false
    $izinliSsid = @()
    $wifiler = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.NdisPhysicalMedium -eq 9 })
    if ($wifiler.Count) {
        $wifiAcikKalir = (-not $adaptorKapat) -or (@($acikKalacak | Where-Object { $_.NdisPhysicalMedium -eq 9 }).Count -gt 0)
        Write-Host ''
        $wifiKilit = EvetMi 'Wi-Fi kilidi uygulansin mi? (Wi-Fi acik olsa bile ag degistirilemez)' $wifiAcikKalir
        if ($wifiKilit) { $izinliSsid = SsidSec }
    } else {
        Adim 'Wi-Fi adaptoru yok; Wi-Fi kilidi atlandi'
    }

    Write-Host ''
    try { EskiSurumTemizle } catch { HataEkle "Eski surum temizligi: $($_.Exception.Message)" }

    # 1) Kayit defteri ilkeleri
    $kovan = $null
    try {
        Adim 'Profil kovani aciliyor'
        $kovan = KovanAc $K.Sid $K.Profil
        if (-not $kovan.Gecici) { Uyari 'Kullanicinin oturumu acik: ilkeler bir sonraki oturumda tam gecerli olur.' }
        foreach ($i in $ILKELER) {
            $anahtar = "$($kovan.Kok)\$($i.Yol)"
            DegerYaz $anahtar $i.Ad $i.Deger
            $v = DegerOku $anahtar $i.Ad
            if ($v -eq $i.Deger) { Ok "$($i.Ad) -> $($i.Deger)   $($i.Aciklama)" }
            else { HataEkle "$($i.Ad) yazilamadi (okunan: $v)" }
        }
        foreach ($i in $ESKI_ILKELER) { DegerSil "$($kovan.Kok)\$($i.Yol)" $i.Ad }
    } catch {
        HataEkle "Kayit defteri asamasi: $($_.Exception.Message)"
    } finally {
        KovanKapat $kovan
    }

    # 2) Internet engeli
    Write-Host ''
    try {
        Get-NetFirewallRule -DisplayName "Kisitlama_NoNet_$($K.Kisa)" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        Get-NetFirewallRule -Name (KuralId $K.Sid) -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        if ($internetEngel) {
            Adim 'Guvenlik duvari kurali olusturuluyor'
            New-NetFirewallRule -Name (KuralId $K.Sid) -DisplayName "KisitlamaAraci - $($K.Hesap) internet engeli" `
                -Group $KURAL_GRUBU -Direction Outbound -Action Block -Profile Any -Enabled True `
                -LocalUser "D:(A;;CC;;;$($K.Sid))" `
                -Description "KisitlamaAraci v3: $($K.Hesap) hesabinin tum giden trafigi engellenir." | Out-Null
            if (KuralDogrula $K) { Ok "Internet engeli aktif (yalniz $($K.Hesap))" }
            else { HataEkle 'Guvenlik duvari kurali dogrulanamadi' }
            if (-not (GuvenlikDuvariKontrol $true)) { HataEkle 'Guvenlik duvari kapali oldugu icin internet engeli ETKISIZ' }
        } else {
            Adim 'Internet engeli istenmedi (varsa eski kural kaldirildi)'
        }
    } catch {
        HataEkle "Guvenlik duvari: $($_.Exception.Message)"
    }

    # 3) Ajan: adaptor kapatma / Wi-Fi kilidi
    Write-Host ''
    try {
        $yeni = New-Object System.Collections.ArrayList
        foreach ($girdi in (AyarOku)) { if ($girdi.Sid -ne $K.Sid) { [void]$yeni.Add($girdi) } }
        if ($adaptorKapat -or $wifiKilit) {
            [void]$yeni.Add([pscustomobject]@{
                Sid           = $K.Sid
                Hesap         = $K.Hesap
                AdaptorKapat  = [bool]$adaptorKapat
                AcikKalacak   = @($acikKalacak | ForEach-Object { [string]$_.InterfaceGuid })
                AcikKalacakAd = @($acikKalacak | ForEach-Object { [string]$_.Name })
                WifiKilit     = [bool]$wifiKilit
                IzinliSSID    = @($izinliSsid)
            })
        } else {
            Adim 'Adaptor kapatma ve Wi-Fi kilidi istenmedi'
        }
        if ($yeni.Count -gt 0) { AjanKur $yeni } else { AjanKaldir }
    } catch {
        HataEkle "Ajan: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------- KALDIR
function Kaldir($K) {
    Basli "KISITLAMALAR KALDIRILIYOR: $($K.Hesap)"
    try { EskiSurumTemizle } catch { HataEkle "Eski surum temizligi: $($_.Exception.Message)" }

    $kovan = $null
    try {
        $kovan = KovanAc $K.Sid $K.Profil
        foreach ($i in ($ILKELER + $ESKI_ILKELER)) {
            $anahtar = "$($kovan.Kok)\$($i.Yol)"
            DegerSil $anahtar $i.Ad
            if ($null -eq (DegerOku $anahtar $i.Ad)) { Ok "$($i.Ad) kaldirildi" }
            else { HataEkle "$($i.Ad) silinemedi" }
        }
    } catch {
        HataEkle "Kayit defteri asamasi: $($_.Exception.Message)"
    } finally {
        KovanKapat $kovan
    }

    try {
        $kurallar = @(Get-NetFirewallRule -Name (KuralId $K.Sid) -ErrorAction SilentlyContinue) +
                    @(Get-NetFirewallRule -DisplayName "Kisitlama_NoNet_$($K.Kisa)" -ErrorAction SilentlyContinue)
        if ($kurallar.Count) {
            $kurallar | Remove-NetFirewallRule
            Ok 'Guvenlik duvari kurali silindi'
        } else { Adim 'Guvenlik duvari kurali zaten yoktu' }
    } catch {
        HataEkle "Guvenlik duvari: $($_.Exception.Message)"
    }

    try {
        $kalan = New-Object System.Collections.ArrayList
        foreach ($girdi in (AyarOku)) { if ($girdi.Sid -ne $K.Sid) { [void]$kalan.Add($girdi) } }
        if ($kalan.Count -gt 0) {
            Adim "Ajan diger kullanicilar icin calismaya devam ediyor: $(($kalan | ForEach-Object { $_.Hesap }) -join ', ')"
            AjanKur $kalan
        } else {
            AjanKaldir
        }
    } catch {
        HataEkle "Ajan: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------- ANA
function Ana {
    if (-not (YoneticiMi)) {
        Basli 'YONETICI YETKISI GEREKLI'
        Hata 'Bu araci yonetici olarak calistirin.'
        return
    }

    $K = KullaniciSec

    Write-Host ''
    Write-Host '  [1] Kisitlamalari UYGULA / DEGISTIR' -ForegroundColor White
    Write-Host '  [2] Kisitlamalari KALDIR' -ForegroundColor White
    Write-Host '  [3] Sadece DURUM goster' -ForegroundColor White
    $secim = Read-Host '  Seciminiz'
    if ($null -eq $secim) { $secim = '' }
    $secim = $secim.Trim()

    switch ($secim) {
        '1' { Uygula $K; Durum $K }
        '2' { Kaldir $K; Durum $K }
        '3' { Durum $K }
        default { Uyari 'Gecersiz secim, hicbir sey yapilmadi.'; return }
    }

    Basli 'SONUC'
    if ($script:HataSayisi -eq 0) {
        Ok 'Tum adimlar uygulandi ve dogrulandi.'
        if ($secim -eq '1') {
            Write-Host ''
            Adim 'Kayit defteri ilkeleri kullanicinin BIR SONRAKI oturum acisinda tam gecerli olur.'
        }
    } else {
        Hata "$($script:HataSayisi) adim basarisiz. Yukaridaki [ HATA ] satirlarina bakin."
    }
}

try {
    Ana
} catch {
    Basli 'BEKLENMEYEN HATA'
    Hata $_.Exception.Message
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
}
