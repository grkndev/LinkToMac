# Dosya gönderimi: hata analizi ve iyileştirme planı

> **Durum (2026-10-15):** Plandaki her şey uygulandı ve yayınlandı (0.10.0 ve 0.11.0).
> P0 ve P1 ile P2'nin büyük kısmı 0.10.0'da (Mac: `153dd79`, Android: `b1d3967`); sonrasında
> Files ekranı, 1 GB sınırı, kaldığı yerden devam, telefondan klasör gönderimi (Mac artık `dir`
> başlığını yazıyor) ve bildirimden iptal 0.11.0'da geldi. Uygulama sırasında ayrılan kararlar:
> test hedefi eklendi (`LinkToMacTests`), klasörler `dir` başlığıyla yapıyı koruyarak gidiyor,
> çoklu dosyada tek progress bar + tek özet bildirimi var. Kapsam dışı kalan tek şey: file-promise
> sürüklemeleri (Mail eki, Fotoğraflar) çözülemiyor ama artık bildiriliyor. Güncel protokol:
> `TECHNICAL.md` §5.4.

Tarih: 2026-10-15 · Kapsam: Mac→telefon sürükle-bırak (`FileSender`, `FileDropZone`,
`StatusItemController`), telefon→Mac alma (`FileInbox`), Android paylaşım/alma tarafı.

## 1. Kök neden: çökme (kanıtlı)

`~/Library/Logs/DiagnosticReports/LinkToMac-2026-10-15-155600.ips` (v0.9.0, build 13):

```
EXC_BREAKPOINT / SIGTRAP
BUG IN CLIENT OF LIBDISPATCH: Semaphore object deallocated while in use (current value < original value)
Thread 6  dev.grkn.LinkToMac.filesend
  _dispatch_semaphore_dispose -> closure #1 in FileSender.send(url:overLAN:emit:progress:done:)
```

İki hatanın birleşimi:

**A. `FileSender` her transferde yeni `DispatchSemaphore` yaratıp eskisini bırakıyor**
(`FileDrop.swift:298`, `window = DispatchSemaphore(value: ackWindow)`). libdispatch, değeri
başlangıç değerinden küçük bir semaforun dealloc edilmesini process-kill ile cezalandırır.
Transfer erken biterse (zaman aşımı, okuma hatası) semafor "borçlu" kalır; bir sonraki
`send` onu değiştirdiği anda uygulama çöker.

**B. Mac→telefon küçük dosyalar (< 640 KiB) için telefon ack göndermiyor, Mac 30 sn bekleyip pes ediyor.**
- `FileFrame.payload` (Swift, `RelayProtocol.swift:125`) `id`'yi yalnızca `count > 1` iken yazıyor.
- Kotlin `FileFrame.encode` ise `id` verilmişse tek parçada da yazıyor ve yorumu "id ack'i tetikler"
  diyor. Swift tarafı bu sözleşmeden sapmış.
- Sonuç: tek parçalı dosya `id`'siz gidiyor → telefon `frame.id?.let { ack }` yüzünden ack atmıyor →
  Mac son "pencereyi geri al" döngüsünde (`FileDrop.swift:326`) 3 permit alıp 4.'de 30 sn bekliyor →
  `done(.failed("Your phone stopped responding"))` (dosya aslında karşıya ulaşmış olsa da) →
  semafor değeri 0 < 4 → **sonraki sürükle-bırakta çökme**.

Bu, "bazen çöküyor" ve "çoklu dosyada çöküyor" şikâyetlerinin ikisini de açıklar: kullanıcı çoğu
dosyada küçük bir dosya gönderir, 30 sn sonra yanlış bir hata bildirimi görür, sonra ikinci
dosyayı bırakınca uygulama kapanır.

## 2. Diğer tespit edilen sorunlar

### Mac — gönderme
| # | Sorun | Yer | Etki |
|---|---|---|---|
| 1 | Çoklu dosya: yalnızca ilk dosya işleniyor (`providers.first`, `urls.first`, `open urls` döngüsü her dosyada `sendFileToPhone` çağırıp ikincisini `isSending` ile reddediyor) | `FileDropZone.swift:106`, `StatusItemController.swift:155`, `LinkToMacApp.swift:83` | Kullanıcı 5 dosya bırakır, 1 gider, hiçbir uyarı yok |
| 2 | `ack(id:)` `window`'u kilitsiz okuyor, `send` kilit altında yazıyor | `FileDrop.swift:256-261` vs `298` | Veri yarışı (TSan'da görünür) |
| 3 | `isSending` ile `activeID` ataması arasında aralık: `activeID` kuyrukta async set ediliyor, ana thread'deki `guard !isSending` iki hızlı çağrıyı geçirir; ikincisi kuyrukta bekler, `outgoingFile` üst üste yazılır, ilkinin `done`'ı ikincinin ilerleme çubuğunu siler | `RelayClient.swift:517-527` | Titreyen/yanlış UI, yanlış "gönderildi" bildirimi |
| 4 | `overLAN` transfer başında bir kez sabitleniyor; yorum "her chunk'ta yeniden kontrol" diyor ama yalnızca pacing için kullanılıyor. Transfer ortasında LAN düşerse chunk'lar boşa gidiyor (`lan?.sendFile` peer yoksa no-op) | `FileDrop.swift:310`, `RelayClient.swift:538` | 30 sn sessizlik + hata (ve bkz. #A çökmesi) |
| 5 | `sendFile` her chunk için ayrı `Task { try? await send }` açıyor: sıra garantisi yok, hata yutuluyor | `RelayClient.swift:317` | Chunk sırası bozulabilir; socket yazma hatası görünmez, ack timeout'una kadar bilinmez |
| 6 | Klasör bırakılınca `fileSize` nil → "X is empty" mesajı yanıltıcı | `FileDrop.swift:279-284` | Kullanıcı neden olmadığını anlamıyor |
| 7 | `loadDataRepresentation` hatası/`nil` URL sessizce yutuluyor; `return true` önceden dönüyor. File-promise sürüklemeleri (Mail eki, Fotoğraflar, tarayıcı indirme paneli) `fileURL` taşımaz → hiçbir şey olmaz | `FileDropZone.swift:104-116` | "Bıraktım, hiçbir şey olmadı" |
| 8 | Dosya adı UTF-8 başlığı u16 sınırını (65535) aşabilir, `frame()` buna bakmıyor; çok uzun ad → bozuk başlık | `RelayProtocol.swift:140-147` | Nadir ama sessiz bozulma |
| 9 | İptal yok; ilerleme çubuğu chunk *gönderildi*'yi sayıyor, ack'i değil; "Sent" bildirimi iyi ama başarısızlıkta kullanıcı yeniden deneyemiyor | `FileDrop.swift:320` | UX |
| 10 | `StatusDropView.draggingEntered` panelin `show`'unu her enter'da çağırıyor; sürükleme panelden çıkınca `transient` popover kapanırsa bırakma hedefi kaybolabiliyor | `StatusItemController.swift:145-152` | Menü çubuğunda "bazen çalışmıyor" |

### Mac — alma (telefon→Mac)
| # | Sorun | Yer |
|---|---|---|
| 11 | Ack, dosya *saklanmadan önce* gönderiliyor (`sendFileAck` → `fileInbox.accept` → `saveIncomingFile`). Kabul reddedilse (`maxConcurrent`, boyut, diske yazma hatası) bile telefon "Saved on your Mac" der. Teslim makbuzu yalan söylüyor. Kotlin tarafında da aynı (`conn?.sendFile(ack)` önce) | `RelayClient.swift:470`, `ClipForegroundService.kt:441` |
| 12 | `FileInbox.sweep()` yalnızca yeni bir frame gelince çalışıyor; gönderen kaybolursa `incomingFile` (dashboard "receiving" satırı) süresiz takılı kalır | `FileDrop.swift:143, 198` |
| 13 | 64 MB'a kadar `Data` birleştirme ve `write(.atomic)` ana aktörde, UI donar | `FileDrop.swift:189`, `RelayClient.swift:495` |
| 14 | `save()` çakışma döngüsü 999'da biter ve son adayın varlığını kontrol etmeden üzerine yazar; çok uzun ad (>255 bayt) yazmayı düşürür | `FileDrop.swift:71-77` |

### Android
| # | Sorun | Yer |
|---|---|---|
| 15 | Paylaşım menüsü yalnızca `ACTION_SEND`; `ACTION_SEND_MULTIPLE` (çoklu seçim) yok, kullanıcı Galeri'den 5 foto paylaşınca "Send as a File" hiç görünmeyebilir | manifest + `ShareActivity.kt` |
| 16 | Aynı ack-önce-sakla sorunu (#11) | `ClipForegroundService.kt:441` |
| 17 | `sendAsFile` başarısız olursa kısmen gönderilen transferin Mac tarafındaki kısmi dosyası yalnızca 120 sn TTL ile temizleniyor; "iptal" çerçevesi yok | protokol |

## 3. Plan

Sıra: önce çökme (P0), sonra sözleşme/doğruluk (P1), sonra UX (P2). Her adım küçük commit,
conventional commits.

### P0 — Çökmeyi bitir
1. **`FileSender`'ı yeniden yaz: semafor yerine kilitli sayaç + koşul.** `DispatchSemaphore`
   kullanma. Transfer başına `final class Transfer` (id, `NSCondition`, `inFlight` sayacı,
   `cancelled` bayrağı). `ack` → sayaç düşür + `signal`; `send` döngüsü `inFlight < window`
   olana kadar `wait(until:)`. Transfer bitince nesne atılır; "borçlu semafor" kavramı ortadan kalkar.
   Bu aynı zamanda #2 (yarış) ve `ack`'in kilitsiz okumasını da çözer.
2. **Swift `FileFrame.payload`'ı Kotlin sözleşmesine hizala:** `id` verilmişse `count == 1` iken de yaz
   (`if let id { ... }`). Tek parçalı küçük dosyalar artık ack alır; 30 sn bekleme ve yanlış hata
   bildirimi kalkar. Eski telefon (id'siz tek parça gönderimini kabul eden) uyumluluğu bozulmaz:
   alan eklemeli.
3. **Savunma:** son "pencereyi geri al" aşamasında, `count == 1` iken ack gelmezse bile (eski
   telefon) başarısızlık yerine "gönderildi (onaysız)" de ve çökme yolunu kapat.
4. Regresyon testi: SwiftPM test hedefi yok (mac/ test target yok) → `FileSender` mantığını
   `FileTransferWindow` adlı saf bir tipe çıkar ve küçük bir `swift test`/XCTest hedefi ile
   "erken biten transfer → yeni transfer çökmez", "tek parça ack", "duplicate ack" senaryolarını sına.
   (Hedef eklemek `project.yml` değişikliği gerektirir; karar kullanıcıda, bkz. §5.)

### P1 — Doğruluk ve çoklu dosya
5. **Çoklu dosya:** tüm giriş noktaları (`onDrop`, `StatusDropView`, `open urls`) URL *listesi*
   toplasın. `RelayClient`'a `enqueueFiles(_ urls: [URL])` ekle: ana aktörde FIFO kuyruk,
   tek seferde bir transfer; UI "2/5 · foto.jpg", toplam bildirim ("5 dosya gönderildi", dosya başı
   bildirim yok). Klasör bırakılırsa ya içindekileri düz listele ya da net hata ver (ilk sürümde:
   "Klasörler desteklenmiyor" bildirimi, sessiz "empty" değil).
6. **Teslim makbuzunu dürüst yap (#11, #16):** ack'i yalnızca dosya gerçekten saklandıktan sonra
   gönder; reddedilen/başarısız transferde ack yerine `op:"nack"` (ek, geriye uyumlu alan; eski
   gönderen bilinmeyen op'u yok sayar → 30 sn zaman aşımına düşer, bugünkü davranış). Her iki
   `FileFrame` aynı değişiklikle güncellenir (invariant: üç yerde elle ayna).
   Not: chunk'lı akışta akış-kontrolü ack'i ile "dosya kaydedildi" ack'i ayrı olmalı; basit çözüm:
   chunk ack'leri şimdiki gibi hemen, **son chunk için ack, kayıt sonrasında**.
7. **`overLAN` per-chunk:** `emit` içinde taşıyıcıyı her chunk'ta `lanPeerConnected`'e göre seç;
   hiçbir taşıyıcı yoksa transferi hemen "bağlantı koptu" ile bitir (30 sn bekleme yok).
8. **`sendFile` sıra/hata:** chunk gönderimini tek bir seri async kanal üzerinden yap
   (`AsyncStream` + tek tüketici task) ve `send` hatasını `FileSender`'a geri bildir.
9. **Sürükle-bırak sağlamlığı (#7, #10):** `onDrop`'ta *tüm* provider'ları `loadObject(ofClass: URL.self)` /
   `NSFilePromiseReceiver` ile çöz; çözülemeyen için kullanıcıya bildirim ver (`"X okunamadı"`).
   Sürükleme hedefi olarak `NSPanel` benzeri kalıcı bir bırakma yüzeyi ya da popover'ı
   `behavior = .applicationDefined` ile sürükleme boyunca açık tut.
10. **Alma tarafı (#12-14):** `sweep()`'i `Timer`/`Task.sleep` ile periyodik çalıştır, `incomingFile`'ı
    süre dolunca temizle; birleştirme+yazmayı `Task.detached` arka plana al (sonuç ana aktöre
    döner); `save()`'de uzun adı 200 bayta kırp ve 999 sonrası hata fırlat.

### P2 — UX ve ek
11. İptal düğmesi (drop-zone'da) → `cancelled` bayrağı + karşıya `nack`.
12. İlerlemeyi ack'e bağla (gönderilen değil teslim edilen bayt).
13. Android: `ACTION_SEND_MULTIPLE` intent-filter + `ShareActivity` döngüsü, tek foreground servis
    kuyruğu (zaten `shareExec` tek thread).
14. `TECHNICAL.md` §file-transfer, `mac/CLAUDE.md` (FileDrop/FileDropZone/StatusItem satırları) ve
    `mobile/CLAUDE.md` (`FileFrame` satırı) aynı değişiklikte güncellensin.

## 4. Doğrulama
- `xcodebuild` derleme, Swift 6 strict concurrency uyarısız.
- El ile: (a) 1 KB, 500 KB, 5 MB, 50 MB dosya; (b) üst üste 5 küçük dosya; (c) çoklu seçim
  sürükle; (d) transfer ortasında telefonda Wi-Fi kapat → 30 sn beklemeden hata + sonraki gönderim
  çökmesin; (e) menü çubuğu simgesine bırak; (f) klasör bırak; (g) aynı adlı dosya iki kez.
- `sudo log`/Konsol: `BUG IN CLIENT OF LIBDISPATCH` artık çıkmamalı; `ThreadSanitizer` ile `FileSender` turu.
- Telefon→Mac: 1 parçalı + chunk'lı dosya, Mac diski dolu/okunamaz klasör ile nack davranışı.

## 5. Kararlar kullanıcıya ait
- Mac tarafına XCTest hedefi (project.yml) eklensin mi? (CLAUDE.md "test target yok" diyor.)
- Klasör bırakma: reddet mi, zip'leyip gönder mi?
- Çoklu dosyada bildirim tekilleştirme istenen düzeyde mi (tek toplam bildirim)?
