# Teşhis raporu ve log gizliliği: plan

> **Durum (2026-11-12):** Uygulandı (`feat/diagnostics`, 0.13.0). Plandan sapmalar ve doğrulama durumu §12'de.

Tarih: 2026-11-08 · Kapsam: Android uygulaması (`mobile/`): log üretimi, Logs ve Daemon Log
paylaşımı, yeni **Send diagnostics** ekranı, GitHub issue şablonu, `ApplicationExitInfo`.
Mac uygulaması ve relay bu planın dışında (bkz. §8).

## 1. Neden

Proje public: tanımadığım biri APK'yı indirip kullanabilir. Üç şey birlikte bir ihtiyaç doğuruyor:

1. **Prod'daki hataları görmek istiyoruz.** Şu an hiçbir hata raporlaması yok.
2. **Gizlilik vaadi var.** README: "nothing leaves hardware you control", "Nothing routes through a third
   party". Sunucu tarafında zaten "içerik asla loglanmaz" kuralı var.
3. **Mevcut log paylaşımı bu vaadi bozuyor.** Log'lar pano metnini, dosya adlarını ve relay adresini
   içeriyor (§2) ve **Logs ▸ Share** hepsini olduğu gibi dışarı veriyor. Tanımadığın biri bunu public bir
   GitHub issue'ya yapıştırırsa kendi panosunu yayınlamış olur.

**Karar:** Merkezi telemetri kurmuyoruz. Hata bilgisi, **kullanıcı isteyerek paylaştığı, cihazda
hazırlanmış ve önizlenebilen** bir rapor olarak gelir. Sentry/GlitchTip gibi otomatik toplama, gerçekten
yığın izi gerekirse sonradan, varsayılan kapalı bir seçenek olarak (§9).

## 2. Bulgu: log'larda hassas veri envanteri

Kod taranarak çıkarıldı (2026-11-08). "Sınırda" = dışa verilirken temizleyici (§4.1) yakalar,
"kaynakta" = log satırı hiç yazılmaz (§4.2).

| Nerede | Ne yazılıyor | Risk | Çözüm |
|---|---|---|---|
| `ClipForegroundService.kt:254` | `clip [kaynak]: ${text.take(60)}` pano metninin ilk 60 karakteri | **Yüksek** | Kaynakta: yalnızca uzunluk. Sınırda: `<clipboard text>` |
| `src/app/logs.tsx` (`onClip` dinleyicisi) | `clip ⬆ "${preview(e.text, 50)}"` pano metninin ilk 50 karakteri (JS tarafı) | **Yüksek** | Kaynakta: satırı uzunluğa indir. Sınırda: aynısı |
| `ClipForegroundService.kt:1017, 1073, 1076` | `share -> Mac file: $name`, `couldn't read $name: ${e.message}` dosya adı (+ istisna mesajında yol) | **Yüksek** | Kaynakta: ad yok (boyut/parça sayısı kalır). Sınırda: `<file>` |
| `ClipForegroundService.kt:355`, `ConnectionManager.kt:320` | `relay=<url>`, `relay fallback -> <url>` kullanıcının kendi sunucusu | Orta-yüksek | Kaynakta: "relay: evet/hayır". Sınırda: `<host>` |
| `SelfAdbModule.kt:167, 175, 279` | `pairing/connecting $host:$port` telefonun LAN IP'si | Orta | Kaynakta: adres yok. Sınırda: `<host>` |
| `LanDiscovery.kt:130` | `mdns: found Mac at $host:$port` Mac'in LAN IP'si | Orta | Aynı |
| `NotificationListener.kt:125` | `note dropped (service down): $pkg` yüklü uygulamanın paket adı | Düşük-orta | Kaynakta: paket adı yok. Sınırda: `<app>` |
| `ClipboardAgent.java:238` | `image skipped: source <pkg> lacks read access to <authority>` | Düşük-orta | Aynı |
| Çok sayıda yerde `${e.message}` | İstisna metni: yol, `content://` URI, dosya adı sızabilir | Orta | Sınırda: yol/URI temizliği |
| `relay: … · lastError` (JS satırı) | Hata metni URL içerebilir | Orta | Sınırda: `<host>` |

**Temiz olanlar:** SMS ve bildirim *içeriği* loglanmıyor (yalnızca sayı ve `corr` UUID'si). JS tarafında
hiç `console.*` yok. Relay `ct`/`nonce`/içeriği loglamıyor.

**Neden iki katman:** Serbest metin log'larda tek başına regex'e güvenemeyiz (yeni bir satır eklenip
unutulabilir). Bu yüzden (a) **kaynakta** hassas veriyi hiç yazma, (b) **sınırda** her çıkışta temizle,
(c) kullanıcıya **tam olarak neyin gideceğini önizlet**.

## 3. Hedefler ve hedef olmayanlar

**Hedefler**
- Uygulamadan dışarı çıkan hiçbir log/rapor panoyu, dosya adını, adresi, adı ya da anahtarı içermesin.
- Kullanıcı tek dokunuşla, neyin gideceğini görerek, bir hata raporu paylaşabilsin.
- En sık gerçek sorun olan **süreç ölümleri** (lmkd/One UI, ANR) raporda görünsün.
- Yeni log satırı eklenirken yanlışlıkla hassas veri sızdırmak zorlaşsın (§4.2 bekçi betiği).

**Hedef olmayanlar**
- Otomatik gönderim ya da herhangi bir uzak toplama (Sentry, Crashlytics, kendi sunucu).
- Mac uygulaması ve relay için yeni tanı (§8).
- Kullanıcı ekran görüntüsü almasını engellemek (yalnızca ekranda gösterilen log'u da temizliyoruz, §4.3).

## 4. Tasarım

### 4.1 Temizleyici: `sanitizeLog`

Yeni dosya `mobile/src/features/diagnostics/sanitize.ts`. Saf, yan etkisiz, idempotent TypeScript.

```ts
sanitizeLine(line: string, known: KnownValues): string
sanitizeLines(lines: string[], known: KnownValues): string[]
// KnownValues: bu cihaza özgü, çalışma zamanında bilinen hassas dizgiler (relay host, Mac adı, ...)
```

Kurallar, bu sırayla:

1. **Pano satırları:** `clip [x]: …` ve `clip ⬆ "…"` için yükü `<clipboard text>` yap, önek kalsın.
2. **Dosya adları:** `share -> Mac file: …`, `couldn't read …:`, `no access to …:` içindeki ad `<file>`.
3. **Adresler:** `wss?://…`, `https?://…`, `host:port`, IPv4, IPv6, `*.local` → `<host>`.
4. **Yollar ve URI'ler:** `content://…`, `/storage/…`, `/sdcard/…`, `/data/…` → `<path>`.
5. **Paket adı benzeri** (üç ve daha fazla noktalı segment) → `<app>`; `com.grkndev.linktomac*` hariç.
6. **E-posta**, **≥ 7 haneli telefon numarası** → `<redacted>`.
7. **Uzun belirteçler** (≥ 24 karakter base64/hex) → `<token>`.
8. **Dinamik gizli değerler:** `known` içindeki her dizgi (relay host, Mac adı, telefon adı, LAN IP'leri)
   metinde nerede geçerse `<mac>` / `<host>` ile değişir. Bu liste eşleşme (`usePairing`) ve
   relay yapılandırmasından çıkar.

Bu bir **en iyi çaba** katmanıdır, son savunma değil (§2'deki gerekçe). Önizleme (§4.4) ve kaynakta
temizlik (§4.2) onun eksiğini kapatır.

**Test:** JS test koşucusu yok ama paket yöneticisi `bun`. `bun test` yalnızca bu dosya için yeterli (kurulum
gerekmez). `sanitize.test.ts`, §2'deki gerçek satırlardan türetilmiş fixture'larla: her kural için
"önce / sonra", **idempotans** (iki kez temizlemek sonucu değiştirmez), ve bir **canary testi**
(`CANARY-clip`, `canary-tax.pdf`, `bifrost.example`, `Canary's MacBook` hiçbir çıktıda geçmemeli).
`package.json`'a `"test": "bun test"` eklenir.

### 4.2 Kaynakta temizlik (APK gerektirir) ve bekçi

- §2 tablosundaki Kotlin/Java satırları değiştirilir: kullanıcı verisi yerine **uzunluk, sayaç, durum**.
  `logs.tsx`'teki `clip ⬆` satırı da uzunluğa iner.
- **Kural:** Log çağrıları kullanıcı verisi (`text`, `body`, `name`, `url`, `host`, `addr`, `title`,
  `path`, `pkg`, …) interpolasyonu yapmaz. `e.message` serbest metin olduğundan sınırda temizlenir.
- **Bekçi:** `mobile/scripts/check-log-privacy.mjs`. `ClipBus.log(` / `log(` çağrılarında bu değişken
  adlarını arayan basit bir tarama, `bun run lint` zincirine bağlanır. Yeni bir satır sızdırırsa lint kırılır.

### 4.3 Dışa çıkış noktaları: hepsi `sanitize`'dan geçer

| Çıkış | Bugün | Sonra |
|---|---|---|
| Logs ▸ Share (`logs.tsx`, `shareAll`) | Ham metin | Temizlenmiş |
| Daemon Log ▸ Share (`daemon-logs.tsx`) | Ham metin | Temizlenmiş |
| Logs / Daemon Log **ekranda gösterim** | Ham | Temizlenmiş (ekran görüntüsü de güvenli olsun). `__DEV__` derlemede ham görünüm açık kalır |
| Yeni **Send diagnostics** | yok | Temizlenmiş, önizlemeli |

Ham log hiçbir üretim yolundan dışarı çıkmaz.

### 4.4 Send diagnostics ekranı

Yeni rota `src/app/diagnostics.tsx`, **Settings ▸ Support** altında Logs'un yanında bir satır.
Mevcut M3 sözlüğü ve `LogView` (monospace) kullanılır, yeni bileşen gerekmez.

**Akış:** Ekran açılınca raporu cihazda üretir ve **önizleme** olarak gösterir. Altında iki düğme:

- **Share report:** Android paylaşma sayfası (`Share.share`). Kullanıcı e-posta, dosyalar, mesaj ya da
  kendi seçtiği uygulamayla gönderir.
- **Open GitHub issue:** `https://github.com/grkndev/LinkToMac/issues/new?template=bug_report.yml&title=…&body=…`
  adresini açar. URL ~8 KB ile sınırlı olduğundan gövdede yalnızca **kısa özet** (≤ ~1,2 KB: sürüm, kanal,
  cihaz, bağlantı durumu) olur. Metin, tam raporu **dosya olarak eklemesini** söyler.

Ekranda, düğmelerin üstünde sabit bir not: *"Her şey bu cihazda hazırlanır, hiçbir şey otomatik
gönderilmez. GitHub issue'ları herkese açıktır: göndermeden önce raporu okuyun."*

**Panoya kopyalama yok.** Uygulamanın kendi pano eşitlemesi kopyalanan raporu Mac'e iletirdi ve pano
geçmişine yazardı. Bunun yerine paylaşma sayfası kullanılır.

**Raporun içeriği** (kullanıcı için başlıklarla, sonu ~200 log satırı):

| Bölüm | Alanlar | Kaynak |
|---|---|---|
| Uygulama | sürüm, `versionCode`, kanal, runtime sürümü, `updateId`, gömülü mü OTA mı, expo-updates açık mı | `expo-constants`, `expo-updates` |
| Cihaz | üretici, model, Android sürümü / API | `expo-device`, `Platform` |
| Durum | eşleşme var/yok, bağlantı (LAN/relay), karşı taraf çevrimiçi mi, capture durumu, daemon canlı mı, relay **yapılandırılmış mı (evet/hayır, adres yok)**, LAN-direct açık mı | `relayGetStatus`, `useClipBootContext`, `isDaemonAlive` |
| İzinler | bildirim, bildirim erişimi, SMS oku/gönder, Nearby Devices, pil optimizasyonu, `WRITE_SECURE_SETTINGS` | mevcut `has*` fonksiyonları |
| Güncelleme | `getAppUpdateState` (yalnızca durum ve sürüm) | mevcut |
| Son kapanışlar | tarih, neden, önem, açıklama | **yeni** `getExitReasons` (§4.5) |
| Daemon log | son N satır, temizlenmiş | `readDaemonLog` |
| Uygulama log | son N satır, temizlenmiş | `getLogs` |

**Rapora asla girmeyenler:** pano metni, dosya adları, adresler ve IP'ler, Mac ve telefon adı, oda kimliği
ve anahtar, SMS ve bildirim içeriği, yüklü uygulama listesi.

### 4.5 `ApplicationExitInfo` (APK gerektirir)

minSdk 30 olduğundan `ActivityManager.getHistoricalProcessExitReasons(packageName, 0, 10)` kullanılabilir.
İşletim sistemi son kapanışları kendisi saklar, ayrıca bir depolama gerekmez.

- `SelfAdbModule.kt`'e `getExitReasons(limit)` eklenir. Çıktı: `[{ timestamp, reason, importance, status,
  description }]`. `reason` okunur ada çevrilir (`LOW_MEMORY`, `USER_REQUESTED`, `CRASH`, `ANR`, …).
- ANR **iz akışı** (trace) rapora konmaz: büyük ve veri sızdırabilir. `description` OEM'e özgü serbest
  metin olabilir, bu yüzden `sanitize`'dan geçer.
- JS tarafı **özellik algılama** yapar (`typeof SelfAdb.getExitReasons === "function"`, `getAutoUpdate`
  örneğindeki gibi). Böylece aşama 1'in OTA'sı eski APK'da hata vermeden bu bölümü atlar.
- Bu, dosyada geçen issue #29–31 türünden **sessiz ölümlerin** (One UI'ın daemon'u/servisi öldürmesi) tek
  doğrudan kanıtı. Sentry bunu görmezdi, çünkü bunlar exception değil.

### 4.6 GitHub issue şablonu

Yeni `.github/ISSUE_TEMPLATE/bug_report.yml` ve `config.yml`. Bugün hiç `.github/` yok.

- Alanlar: ne oldu, beklenen, adımlar, **teşhis raporu (dosya ekleyin)**; uygulamanın doldurduğu özet
  önceden gelir.
- En üstte görünür bir uyarı: *"Bu sayfa herkese açıktır. Rapor dosyasını eklemeden önce okuyun."*
- `config.yml`: boş issue'ya izin ver, iletişim bağlantısı olarak About'taki e-posta.

### 4.7 Belgeler

- **README** gizlilik bölümü: "Telemetri yok. Teşhis raporu yalnızca sen isteyince, cihazda hazırlanır."
  Neyin dahil olduğu ve olmadığı. "Nothing routes through a third party" cümlesi bu yüzden doğru kalır.
- **TECHNICAL.md** güvenlik bölümü: "log'lar kullanıcı verisi içermez" kuralı ve bekçi betiği.
- **`mobile/CLAUDE.md`** (yerel): temizleyici, bekçi, Diagnostics ekranı, `getExitReasons`.
- Sürüm notu ve `CHANGELOG`.

## 5. Aşamalar ve dağıtım

| Aşama | Ne | Nasıl gider |
|---|---|---|
| **1a (acil)** | `sanitize.ts` + testler; Logs / Daemon Log paylaşım ve ekran temizliği; `logs.tsx`'teki `clip ⬆` satırı | **OTA** (0.12.1 runtime) |
| **1b** | Send diagnostics ekranı ve Settings satırı (exit reasons olmadan); `.github` şablonu; README/TECHNICAL | **OTA** |
| **2** | Kaynakta log temizliği (Kotlin/Java); `getExitReasons`; bekçi betiği; Diagnostics'e "Son kapanışlar" | **Yeni APK** (yeni sürüm, yeni runtime) |
| **3 (ops.)** | Varsayılan kapalı opt-in Sentry (yalnızca çökme), "Mac'e kaydet" (mevcut dosya hattı) | Sonra |

**1a gizlilik açığını hemen kapatır** ve tek başına yeterli bir ilk adım. OTA'yı `eas channel:rollout` ile önce
bir yüzdeye aç, **EAS Update Insights** ile bak, sonra genişlet; `eas update:rollback` hazır. Aşama 2 yeni
APK olduğu için sürüm numarasını yükseltir (0.12.2 ya da 0.13.0, §10).

## 6. Dosyalar

**Yeni**
- `mobile/src/features/diagnostics/sanitize.ts`, `sanitize.test.ts`
- `mobile/src/features/diagnostics/build-report.ts` (rapor derleyici)
- `mobile/src/app/diagnostics.tsx`
- `mobile/scripts/check-log-privacy.mjs`
- `.github/ISSUE_TEMPLATE/bug_report.yml`, `config.yml`

**Değişen**
- `mobile/src/app/logs.tsx`, `mobile/src/app/daemon-logs.tsx` (temizleme, paylaşım)
- `mobile/src/app/settings.tsx` (Support altına satır), `mobile/src/app/_layout.tsx` (rota)
- `mobile/package.json` (`test`, lint zincirine bekçi)
- Aşama 2: `ClipForegroundService.kt`, `ConnectionManager.kt`, `SelfAdbModule.kt`, `LanDiscovery.kt`,
  `NotificationListener.kt`, `ClipboardAgent.java` (log satırları), `SelfAdbModule.kt` (`getExitReasons`),
  `SelfAdb.ts` / `SelfAdb.types.ts`
- `README.md`, `TECHNICAL.md`, `CHANGELOG.md`

## 7. Doğrulama

**Birim (aşama 1a)**
- `bun test`: her kural, idempotans, canary seti. Fixture'lar §2'deki gerçek satırlardan.
- `npx tsc --noEmit`, `bun run lint` (bekçi dahil).

**Cihazda uçtan uca (canary)**
1. Telefonda `CANARY-clip-7f3a` kopyala, `canary-tax.pdf` adlı bir dosya paylaş, relay adresi ve Mac adı
   bilinen değerlerde olsun.
2. **Logs** ve **Daemon Log** ekranında bunların hiçbiri görünmemeli (ekran görüntüsü ile).
3. **Send diagnostics** önizlemesinde ve **Share report** çıktısında yok, **GitHub issue** URL gövdesinde yok.
4. Ham log yalnızca `__DEV__` derlemede.

**Dağıtım**
- OTA'yı **0.12.1 APK'sında** çalıştır: "Son kapanışlar" bölümü yok ama hata da yok.
- Aşama 2'den sonra yeni APK + yeni JS: bölüm dolu; bir kapanış nedeni oluştur (`adb shell am kill` ya da
  uygulamayı sistemden temizle) ve raporda göründüğünü doğrula.
- Regresyon: Logs ekranının canlı akışı, Share, Clear, Daemon Log Restart hâlâ çalışıyor.
- Release derlemesinde "Developer" bölümü gibi dev-only şeylerin sızmadığı yine kontrol edilir.

## 8. Kapsam dışı: Mac ve relay

- **Relay:** içerik zaten loglanmıyor (`logger.ts` yalnızca 6 karakterlik oda önekini yazar). İsteğe bağlı olarak
  içeriksiz sayaçlar (bağlantı, `join` hatası, hız sınırı vuruşları) eklenebilir. Ayrı iş.
- **Mac:** notarize olduğu için çökme raporları `~/Library/Logs/DiagnosticReports`'ta; kullanıcıdan istenebilir.
  Mac uygulamasının log içeriği bu planda **taranmadı**; benzer bir envanter ayrı yapılmalı.

## 9. Karar kaydı: neden telemetri değil

| Seçenek | Reddedilme / erteleme nedeni |
|---|---|
| Barındırılan Sentry/GlitchTip | Otomatik veri üçüncü tarafa gider, README vaadini değiştirir, onay akışı ve veri sorumluluğu getirir. **Sonra, opt-in** düşünülebilir (aşama 3). |
| Kendi VPS'inde GlitchTip | Bakım yükü; "tanımadığım kullanıcıların verisini tutan" taraf olmak. |
| Crashlytics | Google'a gider, gizlilik duruşuyla uyumsuz. |
| Play Console vitals | Uygulama Play'de değil. |
| **EAS Update Insights** | Zaten kullanılan `expo-updates` verisi, kod gerekmez. **Kullanılır** (§5). |

## 10. Açık sorular

1. **Ekranda da temizleyelim mi?** Öneri: evet (ekran görüntüsü de güvenli olsun), `__DEV__`'de ham.
   Hata ayıklarken kendi log'unu görmek istersen "ham göster" geliştirici anahtarı eklenebilir.
2. **Aşama 2 sürüm numarası:** 0.12.2 (yamaya benzer) mi, 0.13.0 mı? Yeni bir kullanıcı özelliği
   (Send diagnostics) içerdiği için 0.13.0 daha dürüst, ama bu bir tercih.
3. **GitHub hesabı olmayan kullanıcı:** Share report e-posta ile de gider (About'taki iletişim adresi),
   ayrıca bir şey gerekmez. İstenirse Diagnostics'e "E-posta ile gönder" kısayolu eklenebilir.

## 11. Kabul ölçütleri

- [x] `sanitize.test.ts` geçiyor, canary seti hiçbir çıktıda yok.
- [ ] Logs, Daemon Log ve Diagnostics çıktılarında pano metni, dosya adı, adres, Mac/telefon adı yok.
- [ ] Send diagnostics önizlemesi gönderilecek metnin **aynısı**.
- [ ] Hiçbir şey otomatik gönderilmiyor (ağ trafiği yok).
- [ ] OTA, 0.12.1 APK'sında çalışıyor, "Son kapanışlar" yoksa atlanıyor.
- [ ] Aşama 2: kapanış nedenleri raporda, bekçi betiği lint'te, kaynakta hassas log satırı kalmadı.
- [ ] README/TECHNICAL gizlilik metni güncel.

## 12. Uygulama notları (2026-11-12)

Dal `feat/diagnostics`, hepsi tek sürümde (0.13.0). Plandan farklar ve yan bulgular:

- **Envanter genişledi (§2).** Kaynaktaki taramada tabloda olmayan ~10 satır daha çıktı ve kaynakta temizlendi:
  alınan dosya adları (`ClipForegroundService.kt` `file: couldn't save` / `file saved to Downloads`),
  `pairAuto` içindeki IP'ler (`SelfAdbModule.kt:326, 334`), `PickActivity.kt` içindeki `content://` URI'si ve
  `ClipboardAgent.java:241, 302, 326, 558` içindeki istisna metinleri. URI/yol taşıyabilen `e.message` satırlarından
  `share: metadata query failed`, `pick: metadata query failed` ve `openFile failed` istisna **sınıf adına** indi;
  geri kalan `${e.message}` satırları teşhis değeri için bilerek duruyor ve sınırda temizleniyor.
- **Temizleyicinin sınırı.** Desenler yalnızca tanıyabildiği biçimleri yakalar (URL, IP, yol, paket adı, bilinen ad).
  OEM `description` ya da bir hata metni içinde *çıplak* bir kelime (ör. bir dosya adı) yakalanamaz. İlk test
  fixture'ım bunu gösterdi; testi gevşetmek yerine fixture'ları bu alanlara gerçekte girebilecek biçimlere çevirdim.
  Bu, kaynak kuralının (§4.2) ve önizlemenin (§4.4) neden var olduğunun somut örneği.
- **Bekçi (§4.2)** tek bir regex yerine küçük bir tokenizer: Kotlin'in iç içe `${if (…) "a" else "b"}` ifadeleri
  basit bir tarama ile yanlış okunuyordu. İlk çalıştırmada 6 bulgu çıktı; hepsi incelendi ve yanlış pozitif çıktı
  (`victim.key` = temizlenmiş transfer id'si, kendi güncelleme APK adı, kendi paket adı, `launchDaemon`'a argüman
  olarak giden `secret` ve yalnızca `!= null` kontrolü). `launchDaemon` dönüşü komutun stdout'u (`LAUNCHED`), gizli
  anahtar log'a girmiyor. `!= null` kontrolü genel olarak güvenli sayıldı, kalan dördü `// log-privacy: ok — <neden>`
  ile işaretlendi. Testleri düzeltmeden önceki gerçek sızıntı satırlarını çalıştırır.
- **Issue Form önceden doldurma** alan id'siyle (`summary`) **ve** `body=` ile yapılır. Telefonda denendi: GitHub
  Android uygulaması `template=` ve form alanlarını yok sayıp kendi düz "Create Issue" ekranını açıyor, yalnızca başlığı
  ve `body=`'yi dolduruyor; yalnızca `summary=` gönderince özet sessizce kayboluyordu. Tarayıcı Issue Form'unun
  `body=`'yi yok sayıp saymadığı doğrulanmadı. Özet iki kez sayıldığı için `issueUrl` URL ~7,5 KB'ı aşarsa kısaltır.
- **Loopback** (`127.0.0.1`, `::1`) temizlenmez: köprünün daemon'a ulaşamadığı raporlarda tam bu adres gerekiyor ve
  kimsenin adresi değil. Gerçek cihaz raporunda bu satırlar önce `/<host>` oluyordu.
- **TS 6 + `bun:test`.** TS 6 `@types/*` paketlerini otomatik yüklemiyor; `tsconfig`'e `types` eklemek RN'in global
  tiplerini bozabileceğinden `@types/bun` yalnızca test dosyalarında `/// <reference types="bun" />` ile alınır.
- `.github/ISSUE_TEMPLATE/config.yml` iletişim bağlantısı `mailto:` kullanır; GitHub'ın bunu bağlantı olarak
  gösterdiği ilk yayında kontrol edilmeli.

**Henüz doğrulanmadı (cihaz gerekir):** §7'deki canary uçtan uca senaryosu, `getExitReasons`'ın gerçek bir kapanışla
dolması, eski APK'da OTA ile bölümün atlanması. Birim testleri, `tsc`, lint ve JVM testleri geçiyor.
