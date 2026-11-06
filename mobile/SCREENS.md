# Link to macOS — Mobil Uygulama Ekran Envanteri

> **Güncelleme (redesign sonrası):** Claude Design "Link to Mac Android" tasarımı uygulandı. Değişenler:
> 15 route (yeni: `appearance`); tüm ekranlar native Compose (eski RN ekranlar kalmadı); Home tek
> `StatusCard` (isim + durum + LAN/Relay, pil, mesafe kutuları); Settings başlıklı bölümler
> (Mirroring / Mac / Connection / System / Support) + en altta ayrı "Remove pairing"; izin eksikleri
> satır altı `InlineNotice`; Files gün gruplu (Today / Yesterday / Earlier); Clipboard'da en yeni öğe
> vurgulu; arayüz tek dil (İngilizce); Cast Screen "Soon" etiketli pasif kutu. Yeni **Appearance** ekranı:
> tema (System / Light / Dark) + vurgu rengi (System-duvar kâğıdı / Blue / Teal / Violet / Rose / Amber).
> Aşağıdaki ekran açıklamaları davranış ve veri için hâlâ geçerli; görsel düzen için CLAUDE.md "Layout".
> Pil optimizasyonu satırı artık "System" bölümünde. 6-hane kod alanı tek `OutlinedTextField` (6 kutu yerine).

Yeniden tasarım için hazırlanmış ekran-ekran döküm. Kaynak: `mobile/src/app/*` (Expo Router) ve
`mobile/src/features/*`. Metinler ekranda göründüğü dilde (çoğunlukla İngilizce) alıntılanmıştır.

---

## 1. Genel bakış

- **Platform:** yalnızca Android (Expo SDK 56, RN 0.85). Expo Go yok, dev client gerekir.
- **Toplam 15 route (+ `appearance`) + 1 global modal (güncelleme sheet'i) + 1 boot ekranı.**
- **Görsel dil şu an:** Material 3 (Expressive). Çoğu ekran `@expo/ui/jetpack-compose` ile **native Compose** çiziliyor
  (tonal daire rozetler, gruplu yuvarlak liste, 28dp hero). Renkler seed tabanlı dinamik M3 paleti (`useM3Colors`).
- **Tutarsızlık (tasarımda dikkat):** 5 ekran hâlâ eski stilde, düz React Native + Tailwind/StyleSheet:
  `logs`, `daemon-logs`, `adb-setup` (PairScreen), `server-config`, `qr-scan` (PairScanner). Bunlar M3 dilinden kopuk.
- **Bir app'in iki ana durumu var:** eşleşmemiş (yalnız `pair-mac` + `qr-scan`) ve eşleşmiş (geri kalan her şey).

## 2. Navigasyon haritası

```
Booting (SecureStore okunurken)
   │
   ├── eşleşmemiş ──► pair-mac ──► qr-scan (modal) ──► [eşleşti] ──► index
   │
   └── eşleşmiş ──► index (Home)
                      ├── ⚙ settings
                      │     ├── appearance
                      │     ├── notifications ── notification-apps
                      │     ├── adb-setup  (Automatic capture)
                      │     ├── server-config (Relay server)
                      │     ├── qr-scan (Re-pair, modal)
                      │     ├── logs ── daemon-logs
                      │     └── about
                      ├── files
                      └── clipboard-history

Global: UpdateModal (her ekranın üstünde çıkabilen bottom sheet)
```

- Tüm geçişler `fade` animasyonu; header'lar varsayılan olarak gizli, alt ekranlarda düz (gölgesiz) native header
  ve M3 arka plan rengi.
- **Tek route kapısı:** eşleşme (`pairing`). ADB/otomatik yakalama **kapı değildir** — bozulursa yalnızca
  Settings'teki "Automatic capture" satırında görünür, Home'da banner yok (bilinçli karar).
- Uygulama öne gelince arka planda `autoStart` çalışır; UI buna beklemez.

---

## 3. Ekranlar

### 3.0 Booting — `components/booting.tsx`
Tam ekran, ortada 64dp yuvarlak tonal rozet içinde `LoadingIndicator`, altında "Connecting to Mac...".
Sadece SecureStore eşleşme bilgisini okurken görünür.

### 3.1 Pair Mac — `app/pair-mac.tsx` (eşleşmemiş giriş ekranı)
- **Amaç:** ilk kurulumda Mac ile eşleştirmeyi başlatmak.
- **İçerik (Türkçe, dikkat: diğer ekranlar İngilizce):**
  - Başlık: "Cihazınızı eşleştirin" · alt metin: "Panonu Mac ile senkronize etmek için cihazları eşleştir."
  - 28dp tonal kart içinde 2 numaralı adım: ① Mac uygulamasında menüden "Pairing QR…" penceresini aç ② QR kodu telefonunla tara
  - Birincil filled buton: **QR Kodu Tara** → `qr-scan`
- **Düzen:** dikey ortalı, tek sütun, ekran dolduran.

### 3.2 QR Scan — `app/qr-scan.tsx` + `features/pairing/pair-scanner.tsx` (modal)
- **Amaç:** Mac'in "Pairing QR" ekranını okuyup eşleşme + (opsiyonel) relay sunucu ayarlarını almak. İlk eşleşme ve yeniden eşleşme için ortak.
- **Durumlar:**
  1. İzin durumu bekleniyor: "Camera is preparing…"
  2. İzin yok: "Camera permission required" + "QR code scanning requires camera access." + **Grant Permission** / **Cancel**
  3. Tarama: tam ekran kamera (yalnız QR), altta "Show the "Pairing QR" screen on your Mac to pair." + **Cancel**
- Pairing olmayan QR'lar sessizce yok sayılır. Başarılı taramada `replace('/')` ile Home'a gider.
- **Not:** Eski stil (Tailwind `bg-blue-500` butonlar), M3 ile uyumsuz.

### 3.3 Home — `app/index.tsx`
**Amaç:** eşleşmiş Mac'in kimliği + canlı bağlantı durumu + hızlı eylemler.

Yukarıdan aşağı:
1. **Üst çubuk:** sağda 44dp yuvarlak ⚙ butonu → `settings`.
2. **Hero (ortalı):**
   - 96dp tonal rozet, laptop ikonu
   - Mac adı (`headlineSmall`, "Mac" varsayılan)
   - Chip satırı (yalnız bağlıyken): taşıma türü chip'i (**LAN** / **Relay**) + Mac pil chip'i (`%NN`, şarjdaysa tertiary tonda; masaüstü Mac'lerde hiç çıkmaz)
   - Mesafe satırı (yalnız bağlı + Mac'te yakınlık otomatik kilidi açık + telefon menzilde): sensör ikonu + mesafe etiketi (BLE, Mac ölçer)
   - Durum satırı: renkli nokta + **Connected / Connecting… / Reconnecting… / Disconnected** (3 başarısız denemeden sonra "Disconnected")
3. **Hızlı eylem grubu (ButtonGroup, 2 yan yana tile):**
   - **Lock Mac** — bağlı değilse devre dışı; haptic + `lock` komutu gönderir
   - **Cast Screen** — **placeholder, henüz işlevsiz** (RoadMap'te)
4. **Bilgi listesi (Group, 2 satır, chevron):**
   - **Files** → `files` · değer: `Sending…` / `Send files or a folder` / `N transfer(s)`
   - **Clipboard** → `clipboard-history` · değer: Mac'ten gelen son pano metni (40 karakter) veya `No items received yet`

### 3.4 Settings — `app/settings.tsx`
Tek parça gruplu liste (bölüm başlığı ve ayraç yok). Sırayla:

| # | Satır | Tür | Davranış / not |
|---|---|---|---|
| 1 | **Notifications** | nav | → `notifications`. Alt metin: "Status-bar icon, mirroring to your Mac, and which apps are mirrored." |
| 2 | **Mirror messages** | switch | SMS'leri Mac'e yansıtır; READ_SMS/READ_CONTACTS gerekir |
| 2a | **Grant SMS access** | koşullu eylem | yalnız switch açık ve izin yokken. Android prompt'u reddederse (blocked) ipucu: "Finish in App info: allow restricted settings…" |
| 2b | **Grant SMS Send Access** | koşullu eylem | yalnız switch açık ve SEND_SMS yokken (Mac'ten yanıt için) |
| 3 | **Automatic capture** | nav | → `adb-setup`. Alt metin duruma göre: `live` "On. Copies on this phone reach your Mac without a tap." · `starting` "Checking…" · `pairing` "Setting up…" · `needs-setup` "Off. Set it up…" · `error` "Off. Something went wrong — tap for details." |
| 4 | **Auto-lock** | switch | Telefon menzilden çıkınca Mac kilitlenir (BLE yayını); Mac'te de eşleşen switch açık olmalı |
| 5 | **Battery Optimization** | koşullu | Optimizasyon açıksa eylem satırı "Disable battery optimization" (sistem ayarına gider); değilse salt-okunur bilgi satırı ("Disabled") |
| 6 | **Relay server** | nav | → `server-config` |
| 7 | **Re-pair (Scan QR)** | nav | → `qr-scan` |
| 8 | **Remove Pairing** | nav, **destructive** | Onay sheet'i açar (aşağıda) |
| 9 | **Logs** | nav | → `logs` |
| 10 | **About** | nav | → `about` |

**Onay sheet'i (ConfirmSheet):** "Remove pairing?" / "Your Mac will be disconnected and the pairing removed. To pair again, scan the QR code from your Mac." / **Remove**. Onaylanınca eşleşme silinir, kapı `pair-mac`'e döner.

### 3.5 Notifications — `app/notifications.tsx`
Gruplu liste:
- **Show notification icon** (switch): "A notification icon will be displayed in the status bar."
- **Grant notification permission** (koşullu, izin yoksa): "Without permission, connection status notifications cannot be displayed."
- **Mirror notifications** (switch): telefon bildirimlerini Mac'e iletir
- **Grant notification access** (koşullu, mirror açık + erişim yok): sistemin "Notification access" ayarını açar
- **Select apps** (yalnız mirror açıkken) → `notification-apps`

### 3.6 Select apps — `app/notification-apps.tsx`
Hangi uygulamaların bildirimi Mac'e yansıyacak.
- **Mod seçici (2'li ButtonGroup):** **All apps** (varsayılan; işareti kaldırdıkların hariç) / **Only selected** (yalnız işaretlediklerin)
- Mod'a göre açıklama metni: "Every app is mirrored to your Mac — uncheck the ones you want to keep off it." / "Nothing is mirrored to your Mac except the apps you check."
- **Arama çubuğu** (DockedSearchBar, "Search apps")
- **Uygulama listesi:** ~100 satır, her satır tam renkli launcher ikonu (40dp daire kırpma) + ad + checkbox. Her zaman "bu uygulama Mac'e ulaşır mı?" sorusunu cevaplar.
- Boş/yükleniyor: "Loading apps…", "No apps match your search."
- Değişiklikler anında native tarafta uygulanır (kaydet butonu yok). Mod başına ayrı küme saklanır, mod değiştirince diğerinin seçimi kaybolmaz.
- **Performans kısıtı:** liste sanallaştırılmamış tek Column; deferred value + memoize ile akıcı tutuluyor. Yeni tasarım listeyi ağırlaştırmamalı.

### 3.7 Files — `app/files.tsx`
Telefon ↔ Mac dosya aktarımları.
- **Üst eylem grubu:** **Send files** / **Send folder** (bağlı değilse devre dışı; sistem seçicisini açar)
- **Aktif aktarım kartı** (varsa): `ad (NN%)` + "Sending to your Mac · tap to cancel" (+ "N more waiting"). Dokununca iptal eder.
- **Geçmiş listesi** (en yeni üstte, en fazla 200 satır): yön ikonu (indirme = Mac'ten, yükleme = Mac'e), dosya adı, ikinci satır: `From/To your Mac · klasör · boyut · göreli zaman`
  - Başarılı gelen dosya → dokununca açılır (open-in-new ikonu)
  - Başarısız/iptal → hata tonu, `retryable` ise dokununca yeniden dener (retry ikonu; kaldığı yerden devam eder)
  - Durum metinleri: `Waiting…`, `Sending… N%`, hata mesajı, `Cancelled`
- **Header sağ:** **Clear** (yalnız bitmiş satır varsa; onay Alert'i: "Remove this list? The files themselves stay where they are.")
- **Boş durum:** 72dp rozet + "No transfers yet" + "Send files or a folder from here, share to this app from any other, or drop files on your Mac."
- Yükleniyor: LoadingIndicator.

### 3.8 Clipboard — `app/clipboard-history.tsx`
Mac'ten gelen pano öğeleri (yalnız **Mac → telefon**; telefonun kendi kopyaları listelenmez). Bellekte tutulur, en fazla 100.
- Satır: pano ikonu, metin önizlemesi (100 karakter), göreli zaman, sağda kopyala ikonu. **Dokununca telefon panosuna geri kopyalar** (haptic; bağlantı hazır değilse toast "Couldn't copy — connection not ready").
- **Header sağ:** **Clear** (öğe varsa; onay Alert'i "Remove all received clipboard items?")
- **Boş durum:** 72dp rozet + "No clipboard items yet" + "Items your Mac copies will show up here."
- Not: görseller şu an geçmişte listelenmiyor (sadece metin).

### 3.9 Automatic capture — `app/adb-setup.tsx` → `features/selfadb/pair-screen.tsx`
Otomatik pano **okuma** (self-ADB + shell daemon) kurulumu. Zorunlu değil, bir yetenek. Üç mod:
- **live** — "Capture is on" · "Anything you copy on this phone reaches your Mac on its own." · kart: "Everything else — the Mac link, remote lock, battery, notification and message mirroring — runs without this and keeps working if it ever drops."
- **pair** (hiç eşleşmemiş) — "Capture setup" · adımlar: ① Turn on Wireless debugging ② Tap "Pair device with pairing code" ③ Enter the 6-digit code below · **6 haneli kod alanı** (büyük, harf aralıklı) · **Open Developer Settings** link · **Pair** butonu
- **reconnect** (eşleşmiş ama Wireless Debugging kapalı) — "Reconnect" · "Turn Wireless debugging back on and capture will be restored automatically." · **Open Developer Settings** · **Try Again** (spinner, ≤20 sn)
- Hata metni kırmızı, ortalı (`boot.error`).
- **Not:** eski stil, M3 dışı. Normal alt ekran (header + çalışan geri).

### 3.10 Relay server — `app/server-config.tsx`
Manuel sunucu ayarı formu (QR tarama normalde doldurur).
- Giriş metni: aynı Wi-Fi'da LAN-direct, relay yalnız uzakta senkron için; boş bırakılırsa yalnız LAN.
- Alanlar: **Server address** (opsiyonel, LAN açıksa) · **Port** · **Password** (gizli) · **Use TLS (wss://)** (switch kartı) · **LAN-direct** (switch kartı)
- LAN-direct açıkken ek: **LAN port** (varsayılan 53124) · **Mac IP (optional)** (boşsa mDNS keşfi)
- **Save** (pill). Doğrulama Alert'leri: "Nothing to connect", "Invalid port", "Invalid LAN port", "Save failed". Kayıtta native relay bağlantısı yeniden kurulur ve geri döner. Sabitlenmiş sertifika parmak izi (QR'dan) korunur.
- Klavye uyumlu scroll. **Not:** RN formu + Compose switch karışımı.

### 3.11 Logs — `app/logs.tsx`
Uygulama (JS+native) hata ayıklama konsolu. Native halka tamponundan tohumlanır, canlı olaylarla (`onLog/onStatus/onRelay/onClip`) güncellenir; en yeni üstte, en fazla 500 satır, monospace 11px.
- Araç çubuğu (3 buton): **Daemon Log** → `daemon-logs` · **Share** (tüm log metni) · **Clear** (destructive)
- Renk: hata/fail/retry kırmızı, `clip ⬆` / `-> clipboard` / `captured` yeşil, diğer ikincil.
- Boşken `(no logs yet)`. **Not:** eski stil.

### 3.12 Daemon Log — `app/daemon-logs.tsx`
Ayrıcalıklı Android daemon'unun kendi logu (localhost köprüsü üzerinden okunur).
- Araç çubuğu: **Refresh** · **Restart** (daemon'u yeniden deploy eder, ≤40 sn) · **Share**
- Monospace liste; hata kırmızı, `captured` / `context ready` / `-> emit` / `-> mac` yeşil. Boş: "No daemon log." / "Fetching daemon log…".
- Hata mesajı örn.: "Timed out — is Wireless debugging on? Tap to try again."
- **Not:** eski stil. Geliştirici/destek ekranı; son kullanıcıya düşük öncelikli.

### 3.13 About — `app/about.tsx`
- Hero: uygulama ikonu (96dp), **Link to Mac**, "Phone ↔ Mac clipboard & control"
- Grup 1 (bilgi): **App Version**, **Build number** (tarih tabanlı `YYMMDDNNN`)
- Grup 2: **Check for updates** — alt metin kontrol sırasında "Checking…", yoksa `Channel: <preview|Development>` → `UpdateModal`'ı tetikler
- Grup 3 (bağlantılar): **Release notes** (GitHub releases) · **Source code** (github.com/grkndev/LinkToMac) · **Developer** (grkn.dev) · **Contact** (info@grkn.dev)

### 3.14 Update modal — `features/updates/update-modal.tsx` (global bottom sheet)
Uygulama açılışında veya About'tan elle tetiklenir; üç şekil:
- **native** (yeni APK var): "New version available" · "Version X is ready. Download the new app to update — your settings and pairing are kept." · kaydırılabilir release notları kutusu (150dp) · **Download** (filled, tam genişlik) · **Later**
- **ota** (JS güncellemesi var): "Update available" · "A new update is ready. Download it and restart the app to apply it." · **Update & Restart** · **Later**
- **updating**: "App is updating" · "The app will restart automatically when it's ready. You can continue using the app in the background." · belirsiz ilerleme çubuğu · **Continue in background**. Bu durumda kaydırma/geri/scrim ile kapatma kapalı.

---

## 4. Ortak bileşenler (tasarım sistemi bugünkü hâli)

| Bileşen | Dosya | Rolü |
|---|---|---|
| `M3Screen` / `M3Host` | `components/m3-screen.tsx` | Tohumlu tam ekran Compose host; kaydırmalı ekran iskeleti |
| `Group` / `ButtonGroup` | `components/m3.tsx` | Gruplu liste: tek satır `single`, ilk/orta/son için farklı köşe yarıçapı; ButtonGroup yatay eşdeğeri |
| `IconCircle`, `tonal()` | `components/m3.tsx` | Tonal daire ikon rozeti (primary/secondary/tertiary container) |
| `GroupRow`, `SwitchRow`, `ActionRow`, `InfoRow`, `NavRow`, `ClipRow`, `ActionTile` | `components/rows.tsx` | İki satırlı liste satırları (başlık + alt metin, leading ikon, trailing switch/chevron/checkbox) |
| `SheetHeader/SheetText/SheetButton` | `components/sheet.tsx` | Modal bottom sheet sözlüğü |
| `ConfirmSheet` | `components/confirm-sheet.tsx` | Onay sheet'i (Remove pairing) |
| `HeaderTextButton` | `components/header-button.tsx` | Header'daki "Clear" metin butonu |
| `AlertDialog` | `components/AlertDialog.tsx` | Global alert dialog |
| Renk/aralık | `constants/theme.ts`, `useM3Colors` | `Spacing`, `StatusColors` (online/warn), M3 seed paleti |

Kalıplar: 28dp hero tile, 20dp kartlar, 8dp chip, tonal daire ikon, durum noktası, boş durumda 72dp rozet + başlık + açıklama.

---

## 5. Veri / durum kaynakları (ekran ne gösteriyor, nereden geliyor)

| Gösterilen | Kaynak hook |
|---|---|
| Mac adı | `usePairing().pairing.name` |
| Bağlantı durumu / LAN-Relay | `useRelayStatus` → `useConnectionStatus` |
| Mac pil seviyesi/şarj | `useMacBattery` (stat çerçevesi) |
| BLE mesafe | `useMacDistance` (Mac ölçer, stat ile yollar) |
| Pano geçmişi | `useClipHistory` (yalnız Mac→telefon, 100, bellekte) |
| Dosya geçmişi | `useFileHistory` (200, kalıcı, `onFileTransfer` olayı) |
| Capture durumu | `useClipBootContext` (`live/starting/pairing/needs-setup/error`) |
| Switch/izin durumları | `usePermissionSettings` |
| Bildirim filtresi | `useNotificationAppFilter` |
| Güncelleme | `useAppUpdate` |

---

## 6. Yeniden tasarımda korunması gereken davranışlar

1. **Eşleşme tek kapıdır.** ADB/capture hiçbir ekranı engellememeli; bozulma yalnız Settings > Automatic capture'da raporlanır (Home'da banner yok kararı, issue #29).
2. **Bağlı değilken** Lock Mac, Send files, Send folder devre dışıdır.
3. **Koşullu satırlar** (izin ver, grant, battery) yalnız ilgili durum geçerliyken görünür; izin verilince kaybolur.
4. **İzin "blocked" durumu** (sideload APK'da Android prompt göstermez) için açıklayıcı ipucu + "Open App info" yönlendirmesi gerekir.
5. **Notification-apps** listesinin ~100 satırda akıcı kalması gerekir (sanallaştırma yok, deferred render).
6. **Files**: aktif aktarıma dokunma = iptal; başarısız satıra dokunma = kaldığı yerden devam; gelen dosyaya dokunma = aç.
7. **Clipboard**: satıra dokunma = telefona geri kopyala.
8. **Kısa ömürlü ekranlarda** (Booting, switch host'ları) `matchContents` Compose Host kullanılmamalı — unmount sırasında NPE (sabit boyutlu Host kullan).
9. **Bottom sheet'lerde** buton `weight()` çalışmaz; `fillMaxWidth(fraction)` kullan.
10. **App-içi bottom sheet** `Updates.reloadAsync()` sonrası yaşar; reload öncesi unmount + ~400 ms bekleme gerek.
11. Karanlık/açık tema ve dinamik M3 seed rengi desteklenmeli.
12. Dil: şu an arayüz İngilizce, **yalnız `pair-mac` Türkçe** — tasarımda tek dile karar verilmeli.

## 7. Tasarım için açık noktalar / fırsatlar

- **Cast Screen** tile'ı Home'da var ama işlevsiz (roadmap: ekran yansıtma). Ya gizlenmeli ya da "yakında" olarak tasarlanmalı.
- Settings'te **13 satır tek listede**; bölümlere ayırmak (Bağlantı / Yansıtma / Güvenlik / Gelişmiş) düşünülebilir. Şu an bilinçli olarak "başlıksız tek blok".
- **Logs / Daemon Log** son kullanıcı için değil, "Gelişmiş/Destek" altına taşınabilir.
- **Clipboard** ekranı yalnız Mac→telefon gösteriyor; telefon→Mac gönderimler ve görseller geçmişte yok.
- **Home** şu an mesafe/pil/transport/durum bilgisini ayrı satırlarda gösteriyor; tek kompakt durum bloğuna toplanabilir.
- Eski stildeki 5 ekranın (`qr-scan`, `adb-setup`, `server-config`, `logs`, `daemon-logs`) M3 diline çekilmesi.
- Home'da **bildirim/SMS yansıtma durumu** hiç görünmüyor (yalnız Settings'te); özet satırı eklenebilir.
