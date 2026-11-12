# Link to Mac — Mac Uygulaması: Ekran Envanteri, Tasarım Dili ve Dizin Yapısı

> **⚠️ Güncel değil (v0.12.1 öncesi).** Bu belge **v0.12.0 (build 16)** arayüzünü anlatır ve yeniden
> tasarımın girdisi olarak hazırlanmıştı; yeniden tasarım v0.12.1'de çıktı. Bugünkü uygulama: kenar
> çubuklu, yeniden boyutlandırılabilir, açık/koyu temalı pano penceresi; ayrı bir **Ayarlar** penceresi
> (beş sekme); yeni **eşleştirme** penceresi; yeniden çizilmiş menü çubuğu paneli. `PhonePanel`,
> `SettingsScreen`, `RelayScreen`, `ServerSettingsView`, `PairingView` ve `PanelComponents` artık yok.
> Güncel dosya ve sorumluluk dökümü için `TECHNICAL.md` §4'e ve `mac/Sources/LinkToMac/`'e bakın.
> Aşağıdaki metin **tarihçe** olarak, düzeltilmeden saklanıyor.

Yeniden tasarım için hazırlanmış, ekran-ekran döküm. Kaynak: `mac/Sources/LinkToMac/*` ve
`mac/ShareExtension/*`. Metinler ekranda göründüğü hâliyle (çoğunlukla İngilizce) alıntılanmıştır.
Durum: **v0.12.0 (build 16), 2026-11-08**. Android karşılığı: tasarım projesindeki `SCREENS.md`.

---

## 1. Genel bakış

- **Platform:** yalnızca macOS 14+ (SwiftUI, Swift 6 sıkı eşzamanlılık). Bağımlılık yalnızca **Sparkle**
  (otomatik güncelleme), geri kalan her şey sistem framework'leri.
- **Dört yüzey var:** (1) **dashboard penceresi**, (2) **menü çubuğu öğesi + açılır panel**,
  (3) **Dock simgesi**, (4) pencere dışı sistem yüzeyleri (bildirim bandı, Finder paylaşım menüsü, sistem
  diyalogları). Pencere kapatılsa bile uygulama menü çubuğunda yaşamaya devam eder.
- **Dock ve menü çubuğu çalışma anında açılıp kapanır** (Settings ▸ APPEARANCE). En az biri her zaman
  açık kalır, uygulama ulaşılmaz olamaz.
- **Görsel dil şu an:** Material 3 (Expressive) **yalnızca koyu**. Android uygulamasının eski
  (Compose) ekran görüntülerinden örneklenmiş bir palet. Sistem fontu SF (Roboto gömülü değil).
- **Pencere sabit boyutlu:** 1280 × 760, yeniden boyutlandırılamaz, tam ekran yok, yakınlaştırma düğmesi
  kapalı. Başlık çubuğu saydam, içerik üst kenara kadar uzanıyor.
- **İki dil karışık:** Uygulama İngilizce, ama **`PairingView` Türkçe** ve eski bir akışı anlatıyor (§7).
- **Tek eşleşme:** v1 bir telefon ve bir Mac. Mac eşleşmeyi ilk açılışta kendi üretir, QR'ı Mac gösterir.
- **Gerçek veri / yer tutucu:**
  - Gerçek: telefon kimliği (ad, pil), bağlantı durumu, Bluetooth mesafesi, pano geçmişi, yansıyan bildirimler,
    mesajlar (1:1 yanıt dahil), dosya alma/gönderme, tüm ayarlar.
  - **Yer tutucu (roadmap, veri kaynağı yok):** *Lock Phone* ve *Cast Screen* kutucukları, *Media Player* kartı
    ("Next Future"), *Calls* ve *Photos* sekmeleri (uydurma örnek satırlar).

## 2. Navigasyon haritası

```
Uygulama açılır
 ├── Dock simgesi  (isteğe bağlı, Settings ▸ Show in Dock)
 ├── Menü çubuğu öğesi  (isteğe bağlı, Settings ▸ Show in Menu Bar)
 │     └── tıkla ──► Açılır panel (MenuPanel, 340 pt)
 │                     ├── Open Window ──► Dashboard penceresi
 │                     └── Quit
 │         dosya sürükle ──► panel kendiliğinden açılır + "Drop to send" yüzeyi (compact)
 │
 └── Dashboard penceresi  (açılışta, odağı çalmadan; Dock'a tıklayınca yeniden açılır)
       ├── ANA EKRAN: iki sütun
       │     ├── Sol  — PhonePanel: kimlik · 2×2 eylem ızgarası · (gelen dosya satırı) · medya kartı
       │     │            ├── Clipboard ──► ClipHistoryScreen
       │     │            └── Settings  ──► SettingsScreen
       │     └── Sağ  — FeaturePanel: sekmeler  Notifications │ Messages │ Calls │ Photos
       │                  └── Messages ──► konuşma görünümü (yanıt kutusu, 1:1 ise)
       │
       └── ALT EKRANLAR (üst üste, başlık çubuğunda "‹ Back  <ad>", ⌘[ ile de geri)
             ├── ClipHistoryScreen   (Clipboard History)
             └── SettingsScreen      (Settings)
                   ├── Relay Server ──► RelayScreen  (Relay Server)
                   ├── Pairing QR   ──► PairingView  (SHEET, "Done" ile kapanır)
                   ├── Save files to ──► NSOpenPanel (klasör seçici)
                   ├── Unpair…      ──► NSAlert onayı
                   └── About        ──► AboutView    (About)

Pencere dışı:  bildirim bandı (UNUserNotification) · Finder ▸ Paylaş ▸ "Send to Phone" ·
               Sparkle güncelleme penceresi · bildirim izni istemi
Her yerde:     dosya sürükle-bırak (pencere / menü simgesi / panel)
```

- Alt ekranlar bir `DashRoute` yığınında (`clipboard`, `settings`, `relay`, `about`). **Ana ekran yığının altında
  bağlı kalır** (gizlenir ama yok edilmez): seçili sekme, açık SMS konuşması ve sayfa numarası kaybolmaz.
- **Geri düğmesi başlık çubuğundadır** (trafik ışıklarının yanında), SwiftUI içinde çizilmez; macOS 27'de
  saydam başlık bandının üstüne çizilen içerik görünmediği için.

---

## 3. Yüzeyler ve ekranlar

### 3.1 Dashboard penceresi — ana ekran (`DashboardWindow.swift`)

- **Ölçü:** 1280 × 760. Sol sütun **466 pt**, boşluk **17 pt**, sağ sütun **732 pt** (esnek). Kenar boşlukları
  32 / 33 pt, üstte 40 pt (trafik ışıklarını açmak için). Zemin `M3.surface` (`#0C0E12`).
- **Sürükle-bırak:** Pencerenin tamamı dosya hedefidir. Sürüklenirken içerik `FileDropZone` ile **değiştirilir**
  (§3.7), gönderim sürerken yüzey yüzdeyle birlikte kalır.
- **Tema:** Zorla koyu (`.preferredColorScheme(.dark)`, pencere `darkAqua`).

### 3.2 Sol sütun — `PhonePanel` (`PhonePanel.swift`)

Yukarıdan aşağıya:

1. **Kimlik:** Telefon render'ı (`PhoneRender`, 118 × 240) solda. Sağda: telefon adı (`headline 28`, yoksa
   "Android"), durum noktası + "Connected" / "Disconnected" (11 pt nokta; bağlıysa yeşil `#4ADE80`), isteğe bağlı
   **mesafe satırı** (`dot.radiowaves.left.and.right` + "Nearby (−67 dBm)", yalnızca otomatik kilit açık ve
   telefon menzilde iken), altında **durum chip'leri**:
   - taşıma: `LAN` (wifi) / `Relay` (bulut) / `Offline` (wifi.slash),
   - telefon pili: `%NN` + pil simgesi (şarjdaysa yıldırım). Değer yoksa chip hiç görünmez.
2. **2×2 eylem ızgarası** (tek bağlı blok, yalnızca dış köşeler büyük yuvarlak, aralık 3 pt, her kutu 112 pt):
   `Lock Phone` (soluk, yer tutucu) · `Cast Screen` (soluk, yer tutucu) · **`Clipboard`** (→ geçmiş) ·
   **`Settings`** (→ ayarlar). Üzerine gelince ton yükselir.
3. **Gelen dosya satırı** (yalnızca bir dosya geliyorken): `arrow.down.circle.fill` rozeti + dosya adı +
   ince ilerleme çubuğu + `%NN`. Bilerek satır içi: gelen aktarım kullanıcının istediği bir şey olmadığı için
   pencereyi örtmez.
4. **Media Player kartı** (yer tutucu): "Media Player / Next Future", soluk, 112 pt.

### 3.3 Sağ sütun — `FeaturePanel` (`FeaturePanel.swift`)

- **Sekme şeridi:** dört filtre chip'i, **bağlı buton grubu** (44 pt yüksek, aralık 3): `Notifications` (bell) ·
  `Messages` (message) · `Calls` (phone) · `Photos` (photo). Seçili: `secondaryContainer`; boşta: `surfaceContainer`.
- **Notifications (gerçek):** Yansıyan telefon bildirimleri, en yeni üstte, **tek bağlı liste grubu**, iki satırlı
  satırlar: uygulama ikonu rozeti (yoksa zil) · uygulama adı · "başlık: metin" · göreli zaman ("2m").
  Üstte sağda **Clear**. Boşken: `bell.slash` rozeti + "No notifications yet" + "Notifications from your phone
  appear here."
- **Messages (gerçek):** Konuşma listesi (kişi adı, son mesaj önizlemesi — giden ise "You: …", zaman). Bir
  konuşmaya dokununca **konuşma görünümü**: geri oku + rozet + ad (+ numara), sohbet balonları
  (giden: sağda `primaryContainer`, gelen: solda `surfaceContainerHigh`; her birinde saat; gönderiliyor → soluk +
  saat simgesi "Sending…"; başarısız → kırmızı ünlem "Not delivered (…)"), **en yeni mesaja** demirli kaydırma,
  ve **yalnızca 1:1 konuşmalarda** altta **yanıt kutusu** ("Text Message" alanı + yukarı ok düğmesi). Grup
  konuşmalarında yanıt kutusu gizlenir. Boşken: "No messages yet" + "Text messages from your phone appear here."
- **Sayfalama:** Hem bildirim hem konuşma listesi sayfa başına **7** satır + alt çubukta `‹  1 / 3  ›`
  (tek sayfaysa gizli). Pencerenin dış kaydırması olmadığı için: sabit yükseklik sınırı.
- **Calls ve Photos (yer tutucu):** 6'şar uydurma satır ("Ada Yılmaz · Incoming • 4m 12s", "IMG_2048.HEIC ·
  Shared from S24 Ultra" …).

### 3.4 `ClipHistoryScreen` — "Clipboard History" (`ClipHistoryScreen.swift`)

- Ortalanmış **600 pt** sütun. Telefondan gelen kopyaların bellek içi halkası (en çok 50), yeniliğe göre
  **TODAY / EARLIER** bölümleri; ilk bölümün başlığında sağda **Clear** (primary renk).
- **Satır** (64 pt, bağlı liste grubu): içerik türü rozeti — Link (`link`), Command (`terminal.fill`),
  Phone number (`phone.fill`), Text (`text.alignleft`), Image (`photo`) — başlıkta kopya metni (tek satır, ortadan
  kısaltılır; link ve komutlarda monospace), altsatırda "Tür · zaman", sağda kopya simgesi (üzerine gelince
  parlar). **Dokununca panoya geri kopyalar**: simge onay işaretine döner, alt satır "Copied to clipboard"
  (yeşil) olur, ~1,3 sn sonra geri döner.
- **Görsel satırlar yalnızca gösterim** (baytlar saklanmıyor): kopya simgesi yok, dokunmak bir şey yapmaz.
- Boşken: büyük rozet + "No clips yet" + "Copies received from your phone will appear here."

### 3.5 `SettingsScreen` — "Settings" (`SettingsScreen.swift`)

Ortalanmış **600 pt** sütun, kaydırılabilir. Tek parça bağlı gruplar, üstünde büyük harfli bölüm başlığı:

| Bölüm | Satırlar |
|---|---|
| **CLIPBOARD** | Anahtar: *Send copies to Android* ("Mirror this Mac's clipboard to the phone") · Anahtar: *Sync images* ("Send copied images to the phone's clipboard") |
| **FILES** | *Save files to* → klasör seçici; değer: klasör adı ("Where "Send as a File" drops land, shared from your phone") |
| **NOTIFICATIONS** | Anahtar: *Notification banners*. İzin reddedildiyse alt metin "Blocked in System Settings…" olur ve altına *Open Notification Settings…* satırı eklenir |
| **SECURITY** | Anahtar: *Lock when phone leaves* (açıkken alt metin canlı durum). Açıkken iki seçici satır: *Sensitivity* (Near / Balanced / Far), *Lock after* (10 / 20 / 30 / 60 s) |
| **CONNECTION** | *Relay Server* → `RelayScreen` (alt metin: `host:port` ya da "LAN-direct only — no relay set") · *Pairing QR* → sheet ("Show the code to pair a phone") · *Connect / Disconnect* ("Relay link is active / paused") |
| **APPEARANCE** | Anahtar: *Show in Dock* · Anahtar: *Show in Menu Bar* |
| **GENERAL** | Anahtar: *Start at login* · *Check for Updates* · *About* → `AboutView` |
| **DANGER ZONE** | *Unpair…* (kırmızı rozet ve metin) → onay `NSAlert`: "Unpair this Mac?" |

### 3.6 `RelayScreen` / `ServerSettingsView` — "Relay Server"

- Ortalanmış 600 pt sütun, iki bölüm ve alt sağda **Save** düğmesi (pill):
  - **RELAY SERVER:** açıklama ("Where this Mac and your phone meet. These values ride in the pairing QR, so the
    phone configures itself on scan.") · alanlar: *Server address*, *Port* (geçersizse etiket kırmızı), anahtar *TLS
    (wss://)* ("Encrypted — needs a certificate" / "Plaintext — LAN only"), *Password* (gizli alan).
  - **LAN-DIRECT:** anahtar *LAN-direct* ("Phone connects straight to this Mac over Wi-Fi"); açıksa *LAN port*.
- **Save**, en az bir geçerli taşıma yoksa (geçerli relay ya da LAN-direct) devre dışı. Kaydedince relay yeniden
  bağlanır ve LAN sunucusu yeniden kurulur.

### 3.7 `FileDropZone` — dosya gönderme yüzeyi (`FileDropZone.swift`)

- Pencerede **tam boy**, menü panelinde **compact**. Kesikli 2 pt `primary` çerçeveli, `surfaceContainer` kart.
- **Davet hâli** (sürüklerken): `arrow.down.circle` + "Drop to send to *<telefon adı>*" (+ tam boyda "Lands in
  Downloads on your phone").
- **Gönderim hâli:** çerçeve düz çizgi olur; "rapor.pdf (50%)" (uçtaki dosya ve kendi yüzdesi), **tek** belirgin
  ilerleme çubuğu (tüm grup için), birden fazla dosyada `3 / 5`, **Cancel** düğmesi.
- Birden çok dosya/klasör **tek grup** olarak gider; dosya sözü (Mail eki, Fotoğraflar) olan öğeler okunamaz ve
  bildirimle söylenir: "Couldn't read N item(s) — Drop files from Finder instead."

### 3.8 Menü çubuğu öğesi ve açılır panel (`StatusItemController.swift`, `MenuPanel.swift`)

- **Simge:** şablon görsel (`MenuBarIcon`, 18/36 px), sistem açık/koyu menü çubuğuna göre renklendirir.
  **Telefon bağlı değilken %45 saydam.** Tıklayınca panel açılır. **Üzerine dosya sürüklenince panel kendiliğinden
  açılır** (uygulamayı etkinleştirmeden — aksi hâlde Finder'ın sürükleme oturumu kilitlenir).
- **Panel** (340 pt genişlik, 16 pt dolgu, zorla koyu, `NSPopover`, şeffaf kapanır):
  1. **Üstte** alt çubuk: **Open Window** (primary) · **Quit** (⌘Q).
  2. **Kimlik:** küçük telefon render'ı (68 × 138) + ad (`headline 20`) + durum noktası/metni + chip'ler
     (LAN/Relay/Offline, pil).
  3. **Last copy** kartı (varsa): `doc.on.clipboard` rozeti + "Last copy" + metin (tek satır).
- **Durum metinleri:** Connected (yeşil) · Waiting for phone (amber) · Connecting… (amber) · Disconnected (gri) ·
  Connection error (kırmızı). Relay hiç yapılandırılmamışsa bu normal LAN-only kurulumdur, "Waiting for phone".
- **Salt okunur:** hiçbir ayar yok, hepsi dashboard'da. Bu Mac'in kendi pili hiçbir yerde gösterilmez.

### 3.9 `AboutView` — "About"

Ortalanmış 600 pt sütun. **Hero:** uygulamanın gerçek Dock simgesi (100 × 100), "Link to Mac" (`headline 28`),
"Android ⇄ Mac clipboard & control", chip: ✓ "Version 0.12.0 (16)". Sonra **Check for Updates** ("Get the
latest version"; Sparkle'ın kendi penceresini açar) ve **LINKS** grubu: *Release notes*, *Source code*,
*Developer* (grkndev), *Contact* (info@grkn.dev); hepsi sağda `arrow.up.right`.

### 3.10 `PairingView` — "Eşleştirme" (sheet) (`PairingView.swift`)

**Sistem stilinde (M3 değil), 320 pt genişlikte küçük sheet**, Settings ▸ CONNECTION ▸ *Pairing QR*'dan açılır,
altında **Done**. İçerik: başlık "Eşleştirme", **240 × 240 QR** (CoreImage, düzeltme M), açıklama "Telefonda Relay
sekmesi → "QR Tara" ile bu kodu okut.", `Room: <6 karakter>` (monospace, seçilebilir), anahtarlık
kaydı başarısızsa turuncu uyarı. **Bu ekran eski bir akışı anlatıyor** (§7).

### 3.11 Pencere dışı yüzeyler

- **Bildirim bandı** (`MacNotifier`): sistem biçimi, bizim çizmediğimiz. Türleri: yansıyan telefon bildirimi
  (başlık = uygulama/konu, gövde = metin, kaynak uygulamanın ikonu ek olarak), dosya özetleri ("Saved from your
  phone", gönderim özeti), "Phone isn't connected", "Nothing to send", "Image not synced", "Couldn't read N
  items". macOS banner'ın sol üstünde **bizim** uygulama ikonunu çizer (değiştirilemez).
- **Finder ▸ Paylaş ▸ "Send to Phone"** (`ShareExtension/`): **arayüzü yok**, dosyayı alır almaz kapanır;
  yolu `linktomac://send?path=…` ile uygulamaya iletir. Yalnızca Developer ID imzalı sürümde çalışır.
- **Sistem diyalogları:** bildirim izni istemi (ilk kullanımda), Sparkle güncelleme penceresi, klasör seçici
  (`NSOpenPanel`), "Unpair this Mac?" (`NSAlert`).
- **Dock simgesi:** `AppIcon` (Icon Composer). Not: şu an **eski ikon tasarımı**; Android'in yeni "Synced Mac"
  işareti Mac'e taşınmadı (ayrı konu).
- **Ana menü:** özelleştirilmemiş (SwiftUI varsayılanı); Ayarlar menü öğesi kaldırılmış. Tek özel kısayol: alt
  ekranlarda **⌘[** (geri).

---

## 4. Tasarım dili (bugünkü hâli)

### 4.1 Renkler — `M3` (`DashboardComponents.swift`), yalnızca koyu

| Rol | Hex | Kullanım |
|---|---|---|
| `surface` | `#0C0E12` | Pencere / panel zemini |
| `surfaceContainerLowest` | `#090A0E` | |
| `surfaceContainerLow` | `#14161B` | Durgun |
| `surfaceContainer` | `#1B1E24` | Kartlar, satırlar, boştaki chip |
| `surfaceContainerHigh` | `#252931` | Üzerine gelme, soluk rozet |
| `surfaceContainerHighest` | `#30343C` | |
| `primary` | `#A8C7FA` | Anahtar, bağlantı, vurgu |
| `onPrimary` | `#0A305F` | Dolu düğme metni |
| `primaryContainer` / `onPrimaryContainer` | `#274777` / `#D7E3FF` | Giden mesaj balonu |
| `secondaryContainer` / `onSecondaryContainer` | `#3A4456` / `#DBE6F8` | Tonal rozet, chip, seçili sekme |
| `onSurface` | `#E4E2E9` | Başlıklar |
| `onSurfaceVariant` | `#AAAEB9` | Alt metinler, boştaki etiketler |
| `outline` / `outlineVariant` | `#8B919C` / `#3C424A` | Ayırıcılar |
| `success` | `#4ADE80` | Bağlı noktası, "Copied" |
| `error` / `errorContainer` | `#FFB4AB` / `#93000A` | Yıkıcı eylem |
| *(amber)* | `#F39C12` | Geçici durumlar (yalnızca `MenuPanel` içinde sabit) |

### 4.2 Şekil (dp)

`corSmall 8` · `corMedium 12` (chip) · `corLarge 16` · `corLargeIncreased 20` (grup dış köşesi, kartlar) ·
`corExtraLarge 28` (medya kartı, bırakma yüzeyi) · **bağlı grupta iç köşe `6`**. Hücreler arası boşluk **3 pt**.

### 4.3 Tipografi (SF)

`headline(28)` bold (pencere başlıkları) · `titleLarge 22` semibold (boş durum başlığı) · `titleMedium 16` semibold
(satır başlığı) · `bodyLarge 15` · `bodyMedium 13.5` (alt metin) · `labelLarge 14` medium (chip, düğme, sekme).
Bölüm başlığı 12 pt semibold, büyük harf. Linkler ve komutlar monospace.

### 4.4 Bileşenler (hepsi `DashboardComponents.swift`)

| Bileşen | Ne | Ölçü |
|---|---|---|
| `M3IconBadge` | Daire, `secondaryContainer` dolgu + SF Symbol | 36 / 40 / 44 / 48 / 52 / 56 / 64 |
| `M3ImageBadge` | Daire, gerçek görsel (bildirim uygulama ikonu), yoksa `M3IconBadge` | 44 |
| `M3Chip` | Tonal yuvarlak dikdörtgen (kapsül değil) | 34 yüksek |
| `M3ActionTile` | Uzun kart, ortada rozet + etiket | 112 yüksek |
| `M3Tab` | Filtre chip'i, bağlı yatay grup | 44 yüksek |
| `M3Row` | İki satırlı liste öğesi (rozet · başlık · alt metin · sağ metin) | 68 yüksek |
| `M3SettingsRow` | Dokunulabilir ayar satırı (`role: .destructive` kırmızı) | 64 yüksek |
| `M3ToggleRow` | Anahtarlı ayar satırı | 64 yüksek |
| `M3FieldRow` | Etiket + satır içi alan (gizli alan desteği) | 64 yüksek |
| `M3PickerRow` | Seçili değeri tonal kapsül olarak gösteren açılır menü | 64 yüksek |
| `M3Button` | Dolu `primary` kapsül | 40 yüksek |
| `M3SectionHeader` | Büyük harfli grup başlığı | 12 pt |
| `M3GroupCorners` / `M3GroupPosition` | Bağlı grup köşe mantığının tek kaynağı (satır, sekme şeridi, 2×2 ızgara) | |

**Etkileşim:** Üzerine gelince `surfaceContainerHigh`, kartlar basılabilir, boş durumlarda büyük soluk rozet.
**Hareket:** neredeyse yok (`.snappy` onay işareti, 0,15 sn bırakma yüzeyi geçişi).
**Ölü kod:** `PanelComponents.swift` (145 satır: `Card`, `ToggleRow`, `PickerRow`, …) **hiçbir yerden çağrılmıyor** (§7).

---

## 5. Veri kaynakları: ekran neyi nereden gösteriyor

Hepsi `RelayClient` (`@MainActor @Observable`) üzerinden, değiştikçe ekran canlı yenilenir.

| Gösterilen | Kaynak |
|---|---|
| Telefon adı, pil, şarj | `phoneName`, `phoneBatteryLevel`, `phoneCharging` (gelen `stat`) |
| Bağlı mı / taşıma | `isLinked`, `lanPeerConnected`, `peerOnline`, `status`, `isRelayConfigured`, `isActive` |
| BLE mesafesi | `ProximityMonitor.distanceText` (yalnızca otomatik kilit açıkken) |
| Pano geçmişi | `clipHistory` (50, bellekte, en yeni üstte); `recopy()`, `clearClipHistory()` |
| Son kopya | `lastClip` |
| Bildirimler | `notifications` (100, bellekte, `key` ile günceller/kaldırır); `showNotificationBanners` |
| Mesajlar | `messages` (500), `conversations` (türetilmiş); `sendReply`, `clearMessages` |
| Gelen / giden dosya | `incomingFile` (`TransferProgress`), `outgoingBatch` (`BatchProgress`); `cancelOutgoing()` |
| Pano gönderimi | `sendToAndroid`, `syncImages` (kalıcı) |
| Kaydetme klasörü | `fileDrop.folder` (`FileDropStore`) |
| Relay ayarı | `ServerSettingsStore` (UserDefaults + Keychain) |
| Otomatik kilit | `ProximityMonitor.enabled`, `sensitivity`, `graceSeconds`, `statusText` |
| Dock / menü çubuğu | `AppearanceStore.showInDock`, `showInMenuBar` |
| Oturum başlatma | `LoginItem.isEnabled` |
| Eşleşme / QR | `PairingStore` (Keychain), `client.pairingQRPayload`, `pairingRoomShort` |
| Bildirim izni | `MacNotifier.currentStatus()` (uygulama öne gelince yeniden okunur) |

**Mac'in kendi pili** telefona gönderilir ama burada hiç gösterilmez.

## 6. Yeniden tasarımda korunması gereken davranışlar

1. **En az bir yüzey (Dock / menü çubuğu) hep görünür** kalmalı; ikisi birden kapatılamaz.
2. **Açılışta odağı çalma:** "Start at login" ile arka planda başlayan uygulama pencereyi öne alır ama
   etkinleştirmez. Dock'a tıklamak ve "Open Window" ise etkinleştirir.
3. **Pencere kapanınca uygulama yaşar** (menü çubuğunda); Dock tıklaması yeniden açar.
4. **Menü simgesine dosya sürüklemek paneli açar**, ve bunu **uygulamayı etkinleştirmeden** yapmak zorundadır
   (aksi hâlde Finder'ın sürükleme oturumu kilitlenir). Bu yüzden simge `NSStatusItem` + `NSPopover`.
5. **Bırakma yüzeyi mevcut ekranı örter**, küçük bir kutu eklemez; gönderim sürerken yüzde ile kalır; **tek
   ilerleme çubuğu** + iptal; çoklu dosya tek grup, tek özet bildirimi.
6. **Gelen dosya, pencereyi örtmez** (satır içi ilerleme).
7. **Ana ekran, alt ekranın altında canlı kalır**; sekme, açık konuşma ve sayfa durumu kaybolmaz.
8. **Geri düğmesi başlık çubuğunda**, ⌘[ ile de çalışır.
9. **Pencerenin dış kaydırması yok**: sağ sütun listeleri **sayfalanır** (7), konuşma görünümü kendi içinde kayar.
10. **Konuşma yalnızca 1:1 ise yanıtlanabilir**; giden mesajın durumu (gönderiliyor / iletilmedi) görünür.
11. **Pano görselleri geçmişte yalnızca gösterilir** (yeniden kopyalanamaz).
12. **Bildirim izni reddedilirse** ayar satırı bunu söyler ve sistem ayarına götürür (uygulama öne gelince yeniden okunur).
13. **Bağlı grup köşe mantığı** (dış köşe büyük, iç köşe küçük, 3 pt aralık) ürünün imzası.
14. **Telefon bağlı değilken menü simgesi soluk**: bir bakışta durum ipucu.
15. **Zorla koyu tema** şu an bilinçli; değişecekse (açık tema / dinamik) bu bir karar.

## 7. Açık noktalar ve tasarım fırsatları

**Hatalar / tutarsızlıklar**
- **`PairingView` eski ve tutarsız:** Türkçe ("Eşleştirme", "QR oluşturulamadı"), sistem stilinde (M3 değil), ve
  **eski bir akışı anlatıyor**: "Telefonda Relay sekmesi → "QR Tara"". Android uygulamasında artık Relay sekmesi
  yok; ilk eşleşme ekranı **Pair your device ▸ Scan QR code**, sonradan **Settings ▸ Re-pair**.
- **İlk açılışta eşleşme rehberliği yok:** Mac ilk açılışta eşleşmeyi kendi üretir ve doğrudan dashboard'u
  açar ("Android · Disconnected"). **QR, ancak Settings ▸ CONNECTION ▸ Pairing QR ile** bulunur. Yeni bir kullanıcı
  için ilk adım görünür değil. Android tarafında bunun karşılığı olan bir onboarding var.
- **`PanelComponents.swift` ölü kod** (hiçbir çağrı yok). `mac/CLAUDE.md` hâlâ "SettingsScreen'in `PickerRow`'u
  kullanıyor" diyor, yanlış.
- **Menü panelinde "Open Window / Quit" en üstte**, kimlik altında: alışılmış sıranın tersi, tasarımla mı seçildi
  belirsiz.
- **Yer tutucular gerçek gibi duruyor:** *Lock Phone*, *Cast Screen*, *Media Player* ("Next Future"), *Calls*,
  *Photos* (uydurma, kısmen Türkçe adlı satırlar). Ya kaldırılmalı ya "Soon" olarak tasarlanmalı.
- **Mac'in `Settings` penceresi yok**: ayarlar dashboard içinde ve pencere sabit boyutlu; küçük ekranlarda
  yeniden boyutlandırma yok.

**Android ile hizalama**
- Android uygulaması artık yeni marka işaretine ("Synced Mac"), açık/koyu tema ve dinamik renge sahip. Mac
  hâlâ **eski ikon**, sabit koyu palet, eski telefon render'ı (`PhoneRender`) kullanıyor.
- Android'de Home tek bir **durum kartı** (ad + tek durum hapı + taşıma/pil/mesafe kutucukları) ve Settings
  **başlıklı bölümler** halinde. Mac'te aynı bilgiler dağınık (kimlik + chip'ler + mesafe satırı).
- Android'in başlangıç animasyonu ve boot ekranı var; Mac'te açılış deneyimi yok.

**Eksik özellikler (veri var, UI yok / zayıf)**
- Dosya geçmişi (gönderilen/alınan) Mac'te yok. Android'de **Files** ekranı var (geçmiş, yeniden dene).
- Mac'in kendi pili gösterilmiyor (kasıtlı).
- Pano geçmişinde görseller yeniden kopyalanamıyor.
- Mesajlarda grup konuşmasına yanıt, okundu bilgisi, arama yok.

## 8. Dizin yapısı

```
LinkToMac/                      ← repo kökü
├── mac/                        ← bu belgedeki uygulama
│   ├── project.yml             XcodeGen şartnamesi (.xcodeproj üretilir, git'te yok); sürüm 0.12.0 / build 16
│   ├── Config.xcconfig, Secrets*.xcconfig   artık işlevsiz (relay çalışma anında ayarlanır)
│   ├── CLAUDE.md               dosya rolleri, ayar değerleri, değişmezler
│   ├── scripts/build-release.sh   evrensel DMG: imzala + noter onayı + Sparkle appcast
│   ├── Resources/
│   │   ├── Info.plist          LSUIElement=false, linktomac:// şeması, Bluetooth izin metni, Sparkle adresi/anahtarı
│   │   ├── LinkToMac.entitlements    yalnızca Bluetooth
│   │   ├── AppIcon.icon/       Dock simgesi (Icon Composer; hâlâ eski tasarım)
│   │   └── Assets.xcassets/    MenuBarIcon (18/36 px şablon), PhoneRender (telefon görseli)
│   ├── ShareExtension/         Finder ▸ Paylaş ▸ "Send to Phone" (ShareViewController.swift, Info.plist, entitlements)
│   ├── Tests/                  swift-testing: AckWindow, FileSender, FileInbox, FileBatchPlanner, FileFrame(+Vectors), BurstCounter
│   └── Sources/LinkToMac/
│       │  — ARAYÜZ —
│       ├── LinkToMacApp.swift          @main + AppDelegate; pencereyi kurar (1280×760), LAN sunucusunu bağlar
│       ├── StatusItemController.swift  menü çubuğu öğesi + NSPopover + sürükleme hedefi
│       ├── MenuPanel.swift             açılır panel (§3.8)
│       ├── DashboardWindow.swift       DashboardView (iki sütun), DashboardNav, başlık çubuğu Geri düğmesi
│       ├── PhonePanel.swift            sol sütun (§3.2)
│       ├── FeaturePanel.swift          sağ sütun: sekmeler, bildirimler, mesajlar (§3.3)
│       ├── ClipHistoryScreen.swift     Clipboard History (§3.4)
│       ├── SettingsScreen.swift        Settings (§3.5)
│       ├── RelayScreen.swift + ServerSettingsView.swift   Relay Server (§3.6)
│       ├── AboutView.swift             About (§3.9)
│       ├── PairingView.swift           QR sheet (§3.10)  ← eski, Türkçe, M3 değil
│       ├── FileDropZone.swift          bırakma yüzeyi + .phoneFileDrop değiştiricisi (§3.7)
│       ├── DashboardComponents.swift   M3 jetonları + tüm M3* bileşenleri + DashRoute (§4)
│       ├── PanelComponents.swift       ÖLÜ KOD
│       ├── AppearanceSettings.swift    Dock / menü çubuğu tercihleri
│       ├── MacNotifier.swift           bildirim bandı sarmalayıcısı
│       │  — MANTIK / AĞ (ekran yok) —
│       ├── RelayClient.swift           merkez: relay WS, durum, geçmişler, gelen/giden dosya (1349 satır)
│       ├── RelayProtocol.swift         çerçeve tipleri + FileFrame (sunucu ve Kotlin ile elle ayna)
│       ├── LanServer.swift             relay'siz LAN-direct WebSocket sunucusu + Bonjour
│       ├── ClipCodec.swift             uçtan uca şifreleme (ChaCha20-Poly1305)
│       ├── Pairing.swift               room+key üretimi, Keychain, QR (v3)
│       ├── Config.swift, ServerSettings.swift   çalışma anı relay uç noktası
│       ├── FileTransfer.swift, FileDrop.swift   gönderici, alıcı, klasör, sıra mantığı
│       ├── PasteboardWatcher.swift     pano yoklama (500 ms) + yankı bastırma
│       ├── ImagePrep.swift             kopyalanan görseli çerçeve sınırına sığdırma
│       ├── BatteryMonitor.swift        Mac pili → telefona
│       ├── ProximityMonitor.swift + ProximityConfig.swift   BLE otomatik kilit
│       ├── ScreenLock.swift            ekran kilidi (özel API, dlopen)
│       └── LoginItem.swift             oturum açılışında başlatma

docs/
├── mac-screens.md              ← bu dosya
└── plans/                      2026-10-15-file-transfer-hardening.md, 2026-11-08-diagnostics-and-log-privacy.md
                                (mac/CLAUDE.md'de anılan 2026-06-23-mac-dashboard-window-design.md depoda YOK)

local-assets/                   ← Mac paletinin örneklendiği Android ekran görüntüleri ve referans görseller
    Screenshot_2026062*_Link To Mac.jpg, "MacBook Air - 1.png"
```

> Not: `docs/plans/2026-06-23-mac-dashboard-window-design.md` `mac/CLAUDE.md`'de anılıyor ama çalışma ağacında yok
> (`docs/plans/` altında yalnızca iki dosya var); özgün tasarım notuna ihtiyaç varsa git geçmişine bakılmalı.

## 9. Ekran boyutu cetveli (tasarım aracı için)

| Yüzey | Boyut |
|---|---|
| Dashboard penceresi | **1280 × 760** (sabit) |
| Sol sütun | 466 genişlik |
| Sağ sütun | 732 genişlik (esnek) |
| Sütun boşluğu / kenarlar | 17 / 32 sol, 33 sağ, 40 üst |
| Alt ekran sütunu | en çok 600 genişlik, ortalı, 32 yatay / 28 dikey dolgu |
| Menü paneli | 340 genişlik, 16 dolgu |
| Pairing sheet | 320 genişlik, 240 × 240 QR |
| Telefon render'ı | 118 × 240 (pencere), 68 × 138 (panel) |
| Menü simgesi | 18 pt (şablon, @2x 36 px) |
| About uygulama simgesi | 100 × 100 |
