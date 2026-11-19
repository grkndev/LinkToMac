# QUIC Faz 0: ölçüm ve spike sonuçları

Plan: [`2026-11-14-quic-data-plane.md`](2026-11-14-quic-data-plane.md). Her aşamanın sonucu tarih, cihaz/OS sürümü ve ham sayılarla buraya yazılır.
Karar kapıları (0.12) tüm aşamalar bitince bu dosyanın sonundaki tabloya işlenir.

**Test cihazları.** Android: Samsung Galaxy S24 Ultra (`SM-S928B`), Android 17, One UI 9.0, `arm64-v8a`. Mac: MacBook Air M4.

---

## 0.1 Android: quinn build zinciri (cargo-ndk + JNI "ping")

**Tarih:** 2026-11-14 · **Sonuç: GEÇTİ**

| Konu | Değer |
|---|---|
| rustc / cargo | 1.94.0 (2026-03-02) |
| cargo-ndk | 4.1.2 |
| NDK | 27.1.12297006 (React Native `libs.versions.toml` ile aynı; `build-so.sh` oradan okur) |
| Hedef / minSdk | `aarch64-linux-android` / `--platform 30` |
| quinn / rustls / ring / tokio | 0.11.12 / 0.23.46 / 0.17.14 / 1.54.1 (`aws-lc-rs` bağımlılık ağacında **yok**) |
| `libquic_core.so` boyutu | 1.755.688 bayt (~1,7 MiB; `lto=thin`, `strip`) |
| Çapraz derleme süresi | 19 sn (temiz `target/`, tüm bağımlılıklar) |
| JNI sembolleri | `Java_expo_modules_selfadb_quic_QuicCore_nativePing`, `..._nativeProbe` (`llvm-nm -D`) |

**Test sonuçları.**
- `.so` yokken `./gradlew :selfadb:checkQuicCoreSo`: uyarı basıldı, `BUILD SUCCESSFUL`.
- `cargo test`: 3/3 geçti (`ping` sürümleri, `probe` bind/close, `probe` tekrarlanabilirliği). `cargo clippy --all-targets -- -D warnings`: temiz.
- `./build-so.sh`: hatasız; `.so` ve iki JNI sembolü doğrulandı.
- `./gradlew :selfadb:testDebugUnitTest`: 79 test, 0 hata (yeni `QuicCoreFallbackTest` 4/4). `.so` varken Gradle uyarısı çıkmıyor.
- Debug APK (`app-debug.apk`, `.dev` paketi): `lib/arm64-v8a/libquic_core.so` pakette.
- `bun run lint` (log gizliliği: 104 dosya temiz), `npx tsc --noEmit`, `bun run test` (59 geçti): temiz.
- **S24 cihaz testi:** Settings ▸ Developer ▸ "QUIC core ping" → `pong quic-core 0.1.0 quinn 0.11.12 | probe ok`. logcat: `nativeloader: Load .../lib/arm64-v8a/libquic_core.so ... ok`; `UnsatisfiedLinkError` ve çökme yok. Uygulama normal açıldı, Home "Connected" (regresyon yok).

**Kararlar.**
- `.so` **commit edilmez** (`/mobile/modules/**/android/src/main/jniLibs/` ve `/mobile/native-src/**/target/` gitignore'da); `build-so.sh` üretir. Gradle eksik `.so` için yalnız uyarır. Release almadan önce `build-so.sh` çalıştırılır.
- `abiFilters` eklenmedi (kütüphane modüllerinde etkisiz); yükleme korumalı (`QuicCore.isAvailable()`), `.so`'suz derleme ve x86_64 emülatör çökmez.
- `probe()` eklendi: quinn + rustls (ring) + tokio'nun cihazda gerçekten çalıştığını kanıtlıyor (TLS 1.3 istemci yapılandırması + UDP endpoint aç/kapat).

**Notlar.** `ring` NDK clang'ını `cargo-ndk` ortamıyla kendiliğinden buldu; ek ayar gerekmedi. Android 15+ 16 KB sayfa boyutu uyumu bu aşamanın dışında, Faz 6.9 paketlemesinde bakılacak. Aşamanın geçici parçaları (`quicPing` AsyncFunction, Settings satırı) Faz 1.7'de kalkar.

---

## 0.2 Mac: kalıcı kimlik (P-256 + elle DER self-signed + SecIdentity)

**Tarih:** 2026-11-14 · **Sonuç: GEÇTİ**

| Konu | Değer |
|---|---|
| Araçlar | Xcode 27.2, Swift 6.4.2 (Swift 6 dil modu, strict concurrency `complete`), macOS 27.2.1, openssl 4.1.0, x509-parser 0.18.1 (Rust, `verify`) |
| Sertifika | v3, `ecdsa-with-SHA256` (parametre yok), issuer = subject `CN=LinkToMac`, 16 bayt pozitif seri (ilk bayt 0x40–0x7F), now−1 gün … +10 yıl, uzantı yok; 295 bayt |
| Anahtar / depo | P-256, dosya tabanlı login keychain, etiket/tag `dev.grkn.LinkToMac/quic-identity` |
| Parmak izi | SHA-256(DER), 64 küçük harf hex; CryptoKit (Swift) = sha2 (Rust) = openssl |

**Test sonuçları.**
- Mac paketi: **142 test geçti**, 0 hata (yeni: `DERWriterTests` 14, `QuicCertificateTests` 6, `QuicIdentityKeychainTests` 9). Uygulama hedefi Swift 6 strict concurrency ile uyarısız derlendi.
- **Golden TBS bağımsız kodlayıcıdan:** 205 baytlık imzasız TBSCertificate (RFC 6979 A.2.5 P-256 genel noktası, sabit seri ve zamanlar), `openssl asn1parse -genconf` ile üretildi ve `DERWriterTests`'te bayt bayt eşit çıktı. Konfigürasyon aşağıda.
- Fixture (`mac-cert.der`) bağımsız ayrıştırıcıyla: `openssl x509 -inform DER` → v3, `CN=LinkToMac`, issuer = subject, `ecdsa-with-SHA256`, `prime256v1`/P-256; `openssl verify -CAfile` (kendi kendine) **OK**.
- Rust: `cargo test` 10/10 (önceki 3 + yeni `mac_cert` 7): `x509-parser` ile ayrışır, `verify_signature` başarılı, CN/issuer/SPKI/OID/seri/geçerlilik doğru, **sha2 parmak izi Mac'in CryptoKit ile yazdığıyla eşit**. `cargo clippy --all-targets -- -D warnings` temiz; Android `.so` derlemesi dev-dependency'den etkilenmedi.
- **Hardened runtime** (`codesign --force --options runtime -s -`, `flags=adhoc,runtime`): atılabilir CLI'da kimlik bir kez üretildi, ikinci çağrı aynı parmak izini verdi, kimliğin özel anahtarıyla imzalanan veri sertifika anahtarıyla doğrulandı, `reset` temiz bıraktı. Keychain izin istemi çıkmadı, takılma yok.
- Regresyon: pairing Keychain öğesi (`dev.grkn.LinkToMac`/`pairing`) etkilenmedi; test sonrası keychain'de `LinkToMac` sertifikası ve test anahtarı artığı yok. Uygulamayı ayrıca çalıştırmadım: kimlik henüz uygulamaya bağlı değil (davranış değişikliği yok), yalnız derleme doğrulandı.

**Bulgular (planı değiştirdi, kullanıcı onaylı).**
1. **Sertifika etiketi CN'den türetilir:** dosya tabanlı keychain'de `SecItemAdd`'e verilen `kSecAttrLabel` yok sayılır, etiket konu CN'i (`LinkToMac`) olur.
2. **`kSecClassIdentity` sorgusu etiketi dikkate almaz:** keychain'deki ilk kimliği (bu Mac'te bir Apple Development sertifikası) döndürür; olduğu gibi kullanılsaydı yanlış kimlik QUIC kimliği sanılırdı. İlk uygulama böyleydi ve testler (`loadNeverCreatesAnything...`) yakaladı.
3. **Çözüm:** özel anahtar `kSecAttrApplicationTag` ile bulunur, public-key hash'i (`kSecAttrApplicationLabel`) sertifikayı bulur, `SecIdentityCreateWithCertificate` kimliği kurar. Anahtarı kalmamış artık sertifikalar CN'e göre temizlenir; testler benzersiz CN kullanarak birbirinden yalıtılır.
4. **Test sızıntısı (düzeltildi):** ilk (hatalı) uygulamada etiketle silme sertifikaları bulamadığı için test koşuları login keychain'e 14 adet `LinkToMac` sertifikası bıraktı; hash'leriyle tek tek silindi, doğrulama: 0 artık, pairing öğesi sağlam. Sonraki tüm koşular artıksız.

**Bilinen risk (gözlenmedi).** Ad-hoc imzalı Debug derlemelerinin her yeniden derlemede cdhash değiştirmesi, dosya tabanlı Keychain'de eski anahtarın başka bir ikili tarafından kullanılırken ACL izin istemi çıkarabilir. Testler ve CLI aynı süreçte üretip kullandığı için istem çıkmadı; ikili değiştirerek bilerek tetiklenmedi (kullanıcının ekranında iletişim kutusu açabilir). Faz 1.6'da gerçek uygulamada ilk kez kullanılırken ve ilk Developer ID build'de izlenecek. Sertifika süresi dolunca yenileme (10 yıl) ve Unpair bağlantısı Faz 1.6/6.9'da.

**Bağımsız vektör konfigürasyonu** (`openssl asn1parse -genconf tbs.cnf -noout -out tbs.der`; `UX/UY` = RFC 6979 A.2.5 genel nokta):

```
asn1 = SEQUENCE:tbs
[tbs]
version = EXPLICIT:0,INTEGER:2
serial = INTEGER:0x0102030405060708090a0b0c0d0e0f10
sigalg = SEQUENCE:sigalg
issuer = SEQUENCE:name
validity = SEQUENCE:validity
subject = SEQUENCE:name
spki = SEQUENCE:spki
[sigalg]
oid = OID:1.2.840.10045.4.3.2
[name]
rdn = SET:rdn
[rdn]
atv = SEQUENCE:atv
[atv]
type = OID:2.5.4.3
value = UTF8:LinkToMac
[validity]
nb = UTCTIME:261113120000Z
na = UTCTIME:361114120000Z
[spki]
alg = SEQUENCE:spkialg
key = FORMAT:HEX,BITSTRING:04<UX><UY>
[spkialg]
a = OID:1.2.840.10045.2.1
b = OID:1.2.840.10045.3.1.7
```

UX = `60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6`, UY = `7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299`.

---

## 0.3 Interop: Network.framework QUIC sunucusu ↔ quinn istemcisi

**Tarih:** 2026-11-14 · **Sonuç: GEÇTİ** (kapı "Interop + kalıcı kimlik": **geçti**, 8 tuhaflık kaydedildi, hiçbiri engelleyici değil)

| Konu | Değer |
|---|---|
| Mac | Network.framework klasik API (`NWProtocolQUIC.Options`, `NWListener.newConnectionGroupHandler`), macOS 27.2.1, Xcode 27.2, Swift 6.4.2 (spike Swift 5 modunda) |
| Telefon | Galaxy S24 Ultra (`SM-S928B`), cargo-ndk ile derlenmiş arm64 ikilisi `adb shell`'den çalıştırıldı; Wi-Fi (`192.168.1.20` → Mac `192.168.1.10`) |
| quinn / rustls / ring | 0.11.12 / 0.23.46 / 0.17.14 |
| Kimlik | 0.2'nin `QuicIdentity`'si (elle yazılmış DER, tek kullanımlık etiket/CN); ALPN `ltm/1`, TLS 1.3 |
| Çalıştırma | `spikes/quic/run-interop.sh` (derle, sunucuyu başlat, üç ortamda koş, temizle) |

**Senaryo sonuçları** (PASS = geçti):

| Senaryo | localhost | LAN IP'si | Telefon (Wi-Fi) |
|---|---|---|---|
| (a) doğru `fp`+`tok` bağlanır, oturum `OK` | PASS, el sıkışma 94 ms | PASS, 75 ms | PASS, 195 ms |
| (b) yanlış `fp` el sıkışmada reddedilir | PASS, 79 ms | PASS, 77 ms | PASS, 224 ms |
| (c) 3 × 1 MiB uni stream, SHA-256 eşit | PASS, 90 ms | PASS, 103 ms | PASS, 463 ms |
| (d) 64 KiB bidi echo, bayt eşit | PASS, 1 ms | PASS, 1 ms | PASS, 219 ms |
| (f) sunucu başlatan bidi stream (Mac → telefon yönü) | PASS (bkz. tuhaflık 4) | PASS | PASS |
| (g) yanlış `tok` reddedilir | PASS, **protokol içi** `NO` (bkz. tuhaflık 5) | PASS | PASS |

(b): quinn hatası `the cryptographic handshake failed: error 49: invalid peer certificate: ApplicationVerificationFailure`; sunucu çökmedi, sonraki bağlantıları kabul etti. (f) 8 sn sürüyor: istemci veri taşımayan stream'in okuma zaman aşımını (4 sn) bekliyor, bu da tuhaflık 4'ün sonucu.

**Ek doğrulamalar.** `webpki::EndEntityCert::try_from` elle yazılmış sertifikamızı ayrıştırıyor (`tests/pin.rs`), yani rustls'ın TLS imza doğrulama yolu onu kabul ediyor; gerçek pozitif durum bu koşuda: Network.framework'ün sunduğu kimlikle imzalı el sıkışması quinn'de doğrulandı. Pin doğrulayıcısı birim testleri: 10/10; toplam Rust testi 20/20, `clippy --all-targets -D warnings` temiz.

**Tuhaflıklar (numaralı).**
1. **Dinleyici başlangıcı:** `NWListener`'a hem `newConnectionHandler` hem `newConnectionGroupHandler` atamak, dinleyiciyi `POSIX 22 (EINVAL)` ile başlatamaz hale getirir. QUIC için yalnız `newConnectionGroupHandler` kullanılmalı. Bisect: sebep kimlik, sınırlar ya da TLS sürümü değildi; standart bir openssl kimliği (SAN + keyUsage + EKU) aynı hatayı verdi, yani **elle yazılmış sertifika suçlu değildi**.
2. **Grup yaşam döngüsü:** yeni grup milisaniyeler içinde `waiting(ENETDOWN 50)` sonra `ready` olur (zararsız); karşı taraf kapatınca grup `failed(EINVAL 22)` olur (zararsız, "bağlantı bitti" olarak ele alınmalı).
3. **Stream metadata:** `NWProtocolQUIC.Metadata.streamIdentifier` stream `.ready` olunca okunabilir (`start` sonrası hemen değil). Kimlikler RFC 9000 numaralandırmasıyla: istemci bidi 0, 4; istemci uni 2, 6, 10; yön ve başlatan kimliğin alt iki bitinden çıkar (Swift API'sinde `isUnidirectional` yok).
4. **Sunucu başlatan stream'ler:** ilk `NWConnection(from: group)` stream 1 değil **5** numarasını alır; stream 1'i çerçeve grup için kendisi tutar ve karşı taraf onu **veri taşımayan fazladan bir sunucu başlatan bidi stream** olarak görür (quinn `accept_bi` onu ilk sırada verir). Alıcı, kabul ettiği ilk stream'in kendisinin olduğunu varsaymamalı: stream'ler ilk bayttaki tipten tanınmalı, boş olanlar yok sayılmalı. (İlk (f) denemesi tam bunun yüzünden 20 sn zaman aşımına uğradı.) Ayrıca sunucu stream'ine FIN'li ya da FIN'siz yazmak sonucu değiştirmedi.
5. **Bağlantı kapatma:** `group.cancel()` karşı tarafın gözünde bağlantıyı **kapatmıyor**: grup `cancelled` olsa, grubun `NWProtocolQUIC.Metadata.applicationError`'ı ayarlansa (metadata nesnesi bulunup atanabildi) ve oturum stream'i önce iptal edilse bile istemci **45 sn sonra bile** bağlantıyı açık gördü (idle timeout 30 sn, keep-alive 5 sn; Network.framework taşıma düzeyinde yanıt vermeye devam ediyor). Bu yüzden reddetme **protokol içinde** taşınır: oturum stream'inde `NO` + FIN yazılır, karşı taraf kendisi kapatır (senaryo (g) böyle geçti). Faz 1.6'daki "geçersiz token'da bağlantı kapanır" maddesi buna göre yazılmalı.
6. **Parametre kurulumu:** `NWParameters.quic(alpn:)` ile `defaultProtocolStack.applicationProtocols.first as! NWProtocolQUIC.Options` düşürür (seçenekler orada değil); `NWParameters(quic: options)` (plandaki yol) çalışır.
7. **Kimlik ve TLS:** elle yazılmış P-256 kimliği Network.framework tarafından sunuluyor (dinleyici `ready`, TLS 1.3 el sıkışması tamam) ve quinn'in sabitleyen doğrulayıcısından geçiyor; yanlış parmak izi 80 ms içinde `ApplicationVerificationFailure` ile reddediliyor.
8. **Süreç hijyeni:** spike sunucusu bir kez (teşhis amaçlı `--params-alpn` yolu) çöktü ve tek kullanımlık kimliklerini Keychain'de bıraktı (3 sertifika, hash'leriyle/`--clean-leftovers` ile temizlendi). Betik bu yüzden başlangıçta `--clean-leftovers` çalıştırır ve çıkışta koşulsuz temizler.

**Plan sapmaları (spike içinde, ölçüm amaçlı).** (g) senaryosu "sunucu bağlantıyı kapatır" yerine "yanlış token reddedilir" olarak tanımlandı: ya taşıma düzeyinde kapatma ya da protokol içi `NO`; Network.framework'te yalnız ikincisi çalıştığı için bu böyle raporlandı. İstemcinin (f) kabul döngüsü fazladan stream'i tolere edecek şekilde genişletildi. Spike protokolünde her stream'in ilk baytı tipidir (`0x00` oturum, `0x01` dosya, `0x7E` echo); oturum stream'i `0x00 ‖ tok` ile açılır.

**Kapsam dışı (sonraki aşamalar).** DATAGRAM (0.4), stream maliyeti (0.5), 10 GB throughput (0.6), QoS (0.7). Bu koşuda ölçülen süreler yalnız el sıkışma/echo gecikmesi göstergesidir, throughput ölçümü değildir.

**Kalıcı / atılabilir.** Kalıcı: `quic-core/src/pin.rs` ve testleri (`tests/pin.rs`). Atılabilir: `examples/interop_client.rs`, `spikes/quic/mac-server/main.swift`, `spikes/quic/run-interop.sh` (Faz 1'e taşınmaz; yalnız bulgular ve yeniden kullanılacak parçalar elle alınır).

---

## 0.4 Mac DATAGRAM (Swift API hatası var mı?)

**Karar: GEÇTİ, Swift API yeterli, C/Obj-C shim gerekmedi (yazılmadı).** Ses DATAGRAM ile gidebilir.

**Sürümler.** macOS 27.2.1 (26B131), Xcode 27.2, quinn 0.11.12, telefon SM-S928B (S24, Wi-Fi). Mac `en0` 192.168.1.10, telefon `wlan0` 192.168.1.20.

**Yol.** Dinleyici seçeneklerinde `maxDatagramFrameSize = 1200`; grup `ready` olunca `NWProtocolQUIC.Options` (`isDatagram = true`) ile **`group.extract(connectionTo: nil, using:)`** çağrılıp datagram akışı alınır, `start(queue:)` edilir; alma `receiveMessage` döngüsüyle (çağrı başına tek datagram), gönderme `send(content:contentContext: .defaultMessage, isComplete: true)` ile. r. 149070093'ün belirtisi bu yolda **gözlenmedi** (hata yok, paket kaybı yok); hatanın tam belirtisini ayrıca doğrulamadım, yalnız "bu macOS'ta bu yol çalışıyor" demek doğru.

**Ölçüm.** Her yönde 3000 paket, 50 paket/sn (20 ms), 350 bayt (`D ‖ u32 BE seq ‖ 345 B` deterministik yük, her paket alıcıda yeniden üretilip bayt bayt karşılaştırılır), ~61 sn/yön:

| Ortam | h-up (istemci → Mac) | h-down (Mac → istemci) |
|---|---|---|
| Mac localhost | 3000/3000, bozuk 0, yinelenen 0, sırasız 0, en büyük boşluk 0 | 3000/3000, aynı |
| Mac LAN IP'si (192.168.1.10) | 3000/3000, aynı | 3000/3000, aynı |
| **Telefon (S24 Wi-Fi → Mac)** | **3000/3000**, aynı | **3000/3000**, aynı |

Telefon koşusunda 0.3 senaryoları da aynı koşuda PASS: (a) el sıkışma 127 ms, (c) 3 × 1 MiB 353 ms, (d) echo 42 ms, (g), (b). Kapı ölçütü (LAN'da her iki yön ≥ %99,9) %100 ile sağlandı. Not: bu, hafif yük altında (17,5 kB/sn) ölçümdür; ses + video aynı anda akarken kayıp oranı Faz 4/5 testlerinde yeniden ölçülür.

**Boyutlar.** Mac'in bildirdiği `usableDatagramFrameSize` = **1440** (hem localhost hem LAN), quinn `max_datagram_size()` = **1191** (Mac'in ilan ettiği 1200 sınırından). Yani telefon → Mac yönünde sınır bizim `maxDatagramFrameSize` ayarımızdır (artırılabilir), Mac → telefon yönünde 1440 ile Network.framework sınırlar. ~350 baytlık ses paketi iki sınırın çok altında.

**Tuhaflıklar (numaralı; 0.3'ün 1–8'inin devamı).**
9. **Datagram için `isDatagram` akışı şart.** Grup düzeyindeki `group.send(content:to:message:)` ve `setReceiveHandler` ile deneme **sessizce kaybolur**: gönderen 0 hata alır ("gönderildi"), karşıya hiçbir paket ulaşmaz (0/100, iki yönde de), alma işleyicisi hiç tetiklenmez, `usableDatagramFrameSize` okunamaz (-1). Hata vermemesi tehlikeli: Faz 4'te "gönderildi" geri bildirimi teslim kanıtı sayılmaz.
10. **`extract(connectionTo:using:)` ile `NWConnection(from: group, using:)` eşdeğer** (ikisi de 100/100, aynı `usable`). Faz 4'te `extract` kullanılır. Bağlantı başına tek datagram akışı kuralı gereği ikinci akış açılmaz.
11. **Datagram, ona eşlik eden stream komutunu geçebilir.** İstemci `DUP` komutunu stream'e yazıp hemen 0 numaralı datagramı yolladığında datagram, komuttan **önce** işlendi (localhost'ta bir kez, `before-DUP=1`). Faz 4 için kural: kontrol (başlat/durdur) stream'de yapılır, medya datagramı ancak karşı taraf kontrol mesajını **onayladıktan sonra** gönderilir; alıcı, bağlama oturmadan gelen datagramı sessizce atabilmelidir.
12. **Bağlantı kapanınca datagram akışı `failed(ENOTCONN 57)` olur** ve sonraki `send`'ler paket başına `ENOTCONN` döner; zararsız, "bağlantı bitti" olarak ele alınır (0.3/tuhaflık 2'nin datagram karşılığı). Zamanlayıcı ile gönderen taraf bunu sayıp ilk hatadan sonra durmalıdır.
13. **Spike düzeneği hataları (ürün bulgusu değil).** Sunucu, sunucu başlatan stream kapanırken oturuma geç bir `F bad` yazıyordu (sonuç zaten `F ok` iken); bu satır sonraki senaryoyu bozdu. Düzeltildi: sonuç bir kez bildirilir. Aynı ders Faz 1 için: oturum stream'inde "bir kez, sonra sus" kuralı.

**Ortam notları (ölçüm sürecinden).** İlk tam koşu telefon Wi-Fi'ı kapalı olduğundan (`Wi-Fi is disabled`, yalnız mobil veri) telefona bağlanamadı: 30 sn `connect: timed out`; Wi-Fi `adb shell svc wifi enable` ile açılıp yeniden koşuldu. Wi-Fi açılınca telefon `adb`'de iki kez görünür (USB + mDNS kablosuz hata ayıklama), betik `adb`'yi seri numarasız çağırdığından `ANDROID_SERIAL=<usb seri>` verilmelidir.

**Test kayıtları.** `cargo test --all-targets` 25 test (3 lib + 7 mac_cert + 10 pin + 5 örnek), `cargo clippy --all-targets -- -D warnings` temiz, `mac-server --self-test` ok (Rust ve Swift paket üreteçleri Python'da bağımsız hesaplanan golden değerlerle eşit: seq 0 ve 2999), `build-so.sh` .so üretiyor, Mac 142 test geçti. Temizlik: süreç yok, UDP 53125 boş, `LinkToMac-spike-*` sertifikası yok, `pairing` öğesi dokunulmadı, telefonda `/data/local/tmp/interop_client` yok.

**Kalıcı / atılabilir.** Kalıcı bilgi: yukarıdaki bulgular (özellikle 9, 11, 12) Faz 4/5'e girdi. Atılabilir: spike kodu (Swift sunucudaki datagram bölümü, `interop_client.rs` datagram senaryosu). `QuicDatagramShim` yazılmadı, `project.yml` değişmedi.

---

## 0.5 Stream maliyeti (Mac): saniyede 60 ve ~110 gelen uni stream

**Sonuç (özet).** **s-60 (yalnız video): GEÇTİ** (telefon ve Mac host). **s-110 (video + ses): Mac host GEÇTİ, telefon KALDI, yalnız gecikmeden** (p99 video 30,5 ms, ses 34,4 ms; eşik 20 ms). Kayıp, CPU, bellek ve serbest bırakma s-110'da da eşiklerin içinde. Plan kuralı gereği s-110 kararı kullanıcıya soruldu; kullanıcı kararı (2026-11-15): **KALDI olarak kaydedilir**, eşik ve yol seçimi değişmez.

**Ortam.** macOS 27.2.1 (26B131), Xcode 27.2, quinn 0.11.12, S24 (SM-S928B), Wi-Fi 192.168.1.x, telefon ekranı açık. Koşu başına 2 faz × 300 sn (s-60: 60 video stream/sn × 30 KiB; s-110: 60 video + 50 ses stream/sn × 350 B; fazlar arası 10 sn). Sunucu: `initialMaxStreamsUnidirectional = 1000` + kredi yükseltmesi (bulgu 14), bitince `cancel()` (bulgu 15). Mac'i uyutmamak için `caffeinate`, koşu sırasında başka iş yok.

**Ölçüm tanımları (planda onaylı).** Gecikme = stream açılışından uygulamaya ilk bayt tesliminin, gönderen ve Mac saati ortak olmadığı için 10 sn'lik pencere tabanının (kind başına en küçük fark) üstündeki fazlası; karar bu değerle. Çapraz kontrol: NTP tarzı mutlak tahmin ("abs", belirsizlik RTT/2). CPU: sunucunun `getrusage` farkı (5 sn örnek, faz sonu boşta bekleme örneği hariç). Bellek: `phys_footprint`. Serbest bırakma: `StreamProbe` deinit sayacı.

| Ölçüt (eşik) | Mac host s-60 | Mac host s-110 | **Telefon s-60** | **Telefon s-110** |
|---|---|---|---|---|
| Stream kaybı / yarım / bozuk / yinelenen (0) | 0 / 18000 | 0 / 33000 | 0 / 18000 | 0 / 33000 |
| Gecikme p99, video (< 20 ms) | 1,6 ms | 2,0 ms | **11,9 ms** | **30,5 ms ✗** |
| Gecikme p99, ses (< 20 ms) | — | 1,8 ms | — | **34,4 ms ✗** |
| p50 / p95 / max, video | 0,86 / 1,4 / 19,4 ms | 0,84 / 1,6 / 11,3 ms | 1,8 / 7,0 / 113 ms | 2,2 / 10,4 / 208 ms |
| p50 / p95 / max, ses | — | 0,64 / 1,4 / 8,7 ms | — | 8,0 / 14,3 / 198 ms |
| 20 ms'yi aşan stream | 0 | 0 | 49 (%0,27) | video 340 (%1,89), ses 335 (%2,23) |
| 20 ms aşılan 10 sn'lik pencere | 0/31 | 0/31 | 17/31 | 27/31 |
| Mutlak p99 tahmini, video | 1,8 ms (±0,05) | 2,2 ms (±0,05) | 16,1 ms (±2,5) | 35,5 ms (±2,5) |
| CPU ort / p95 (< %25) | %8,0 / %9,2 | %11,7 / %13,7 | %9,9 / %11,8 | %12,6 / %14,0 |
| Bellek büyümesi (≤ 10 MB, ≤ 2 MB/dk) | −0,3 MB, −0,02 MB/dk | +1,5 MB, 0,44 MB/dk | −0,3 MB, −0,04 MB/dk | −0,1 MB, −0,04 MB/dk |
| Canlı stream en çok / faz sonu (≤ 50 / ≤ 5) | 0 / 0 | 0 / 0 | 1 / 0 | 2 / 0 |
| Gönderici: planlanan = gönderilen, hata | 18000, 0 | 33000, 0 | 18000, 0 | 33000, 0 |
| Gönderici en büyük çizelge kayması / `open_uni` bekleme p99 | 8,8 ms / 4 µs | 18,3 ms / 5 µs | 10,2 ms / 6 µs | 12,3 ms / 6 µs |
| quinn kayıp paket / tıkanıklık olayı (bağlantı boyunca birikimli) | 0 / 0 | 0 / 0 | 0 / 0 | **41 (58 kB) / 7** |
| **Karar** | **GEÇTİ** | **GEÇTİ** | **GEÇTİ** | **KALDI (gecikme)** |

Saat kalibrasyonu: Mac host koşusunda RTT 0,1–0,4 ms ve ofset kayması 0 µs; telefon koşusunda RTT 5–10 ms ve ofset kayması 0,9 ms (mutlak tahminin belirsizliği RTT/2). `top` çapraz kontrolü (15 sn aralık, 1 sn'lik anlık değer): host ortalama %6,5, telefon %7,5; sunucunun kendi ölçümüyle aynı büyüklük, hepsi %25'in çok altında.

**Neden analizi (s-110, telefon; kanıt, kesin hüküm değil).**
- Mac maliyeti küçük: aynı sunucu kodu ve aynı yük loopback'te p99 ≈ 2 ms, 0 stream 20 ms'yi aşıyor; sunucu CPU'su telefon koşusunda da %12,6.
- Kuyruk yolun telefon/Wi-Fi tarafında doğuyor: s-60'ta quinn 0 kayıp paket / 0 tıkanıklık olayı bildirirken, s-110'dan sonra birikimli 41 kayıp paket ve 7 tıkanıklık olayı görünüyor; yani hepsi 110 stream/sn fazında. Kayıp paketlerin yeniden iletimi ve tıkanıklık penceresinin küçülmesi gecikme kuyruğuyla uyumlu.
- Ses stream'leri aynı fazda video'dan yavaş: ses p50 = 8,0 ms, video p50 = 2,2 ms. 350 baytlık ses stream'i, aynı bağlantıda giden 30 KiB'lik video karelerinin arkasında bekliyor (göndericide stream sıralaması). Bu, sesin neden DATAGRAM'a gitmesi gerektiğini ayrıca destekliyor.
- Wi-Fi boştayken bile yavaş: koşu öncesi telefondan Mac'e ping 34–119 ms (ortalama 73 ms), Wi-Fi güç tasarrufu şüpheli.
- **Sınırlar:** tek koşu (tekrarlanabilirlik ölçülmedi); telsiz, güç tasarrufu ve gönderici sıralamasının payı ayrıştırılmadı.

**Karar (kullanıcı, 2026-11-15): s-110 KALDI olarak kaydedildi** (telsiz kaynaklı yorumu kanıtla birlikte yukarıda; eşik değiştirilmedi). s-110 telefonda kaldı; Faz 3/4 için sonucu şudur: s-60 geçtiği için Faz 3.4'te kare başına uni stream tasarımı geçerli (yedek "tek uzun ömürlü stream" maddesi 0.12'de plandan silinir). Faz 4.5 zaten koşulludur ("DATAGRAM kalırsa ve ~110 geçerse"); 0.4'te DATAGRAM geçtiği için ses DATAGRAM'a gider ve 4.5 uygulanmaz, yani s-110 sonucu yol seçimini değiştirmez.

**Tuhaflıklar (numaralı; 0.4'ün 13'ünden devam).**
14. **Network.framework yeni stream kredisini (MAX_STREAMS) kendiliğinden vermez.** `initialMaxStreamsUnidirectional = 100` iken gönderici tam 100 uni stream sonra `open_uni()`'de sonsuza dek bekler (100 stream'in hepsi okunup serbest bırakılmış olsa bile). 2⁶⁰ verilince değer sessizce kırpılıyor gibi: bağlantı tam **4096** stream'de tıkanır (yalnızca 3400 stream'lik kısa koşular bunu göstermedi; ilk 300 sn'lik tam koşu 4096'da düştü: `sent 4096 of 18000`). **Çözüm (ölçüldü):** alıcı, grubun `NWProtocolQUIC.Metadata.localMaxStreamsUnidirectional` değerini tamamlanan sayıya göre yükseltir (`group.metadata(definition: NWProtocolQUIC.definition)`; denenen: her 10 tamamlanan stream'de `tamamlanan + 1000`, başlangıç 1000); bununla 51 000 stream (s-60 + s-110, Mac host ve telefon) tıkanmadan geçti. 60/sn ile 4096 sınırı ~68 sn'de, 110/sn ile ~37 sn'de dolar. Karar planın 1.6 madde 8, 3.4 madde 6 ve 4.5 metinlerine yazıldı (onay 2026-11-15).
15. **Biten stream'de `cancel()` zorunlu.** `--stream-close none` teşhis koşusunda (Mac host, 15 sn faz) Network.framework FIN'i alınmış stream bağlantılarını hiç bırakmadı: canlı sayısı stream sayısıyla 1:1 büyüdü (900, ardından 1650; `released=0`) ve bellek stream başına ~6–7 KB arttı (10,1 → 16,0 MB, 900 stream). 110 stream/sn ile bir saatte ~2,6 GB. `cancel()` çağrılınca bağlantı hemen bırakılıyor (canlı ≤ 2).
16. **Stream maliyeti Mac'te küçük.** 110 stream/sn (51 000 stream) için sunucu CPU'su tek çekirdeğin ~%12'si, bellek sabit, stream başına gecikme loopback'te p99 ≈ 2 ms. Alıcı tüm stream'leri tek seri kuyrukta işledi.
17. **Gönderici tarafı:** 60 + 50 stream/sn, görev başına stream, `current_thread` çalışma zamanı telefonda yeterli (çizelge kayması ≤ 18 ms, `open_uni` beklemesi µs düzeyinde, en çok 13 eşzamanlı açık stream).
18. **Ölçüm düzeneği dersleri.** (a) Sunucunun stream başına log yazması 110 satır/sn'dir ve ölçümü bozar; faz süresince susturuldu. (b) Kısa koşular uzun koşuların tıkandığı sınırı (4096) göstermez: ömür boyu sayaçlar en az 4096'yı aşan bir koşuyla sınanmalı. (c) Faz sonundaki boşta bekleme örneği CPU ortalamasını sulandırıyordu, hariç tutuldu.

**Test kayıtları.** `cargo test --all-targets` 3 + 7 + 10 + 9 = 29 test, `cargo clippy --all-targets -- -D warnings` temiz, `mac-server --self-test` ok (başlık ve gövde golden değerleri Python'da bağımsız hesaplandı; Rust ve Swift aynı; karar sınır değerleri dahil), `build-so.sh` `.so` üretiyor, Mac 142 test geçti. 0.3/0.4 gerilemesi yok: a–g ve h-up/h-down localhost, LAN ve telefonda PASS (datagram sayısı 300'e kısaltılmış). Temizlik: süreç yok, UDP 53125 boş, `LinkToMac-spike-*` sertifikası yok, `pairing` öğesi dokunulmadı, telefonda `/data/local/tmp/interop_client` yok.

**Kalıcı / atılabilir.** Kalıcı bilgi: bulgular 14–16 (Faz 1.6, 3.4, 4.5'e işlendi) ve eşik sayıları. Atılabilir: spike kodu (sunucudaki stream-maliyeti bölümü, `streams` senaryosu, betik seçenekleri).

---

## 0.6 Throughput: 10 GB iki yönde

**Karar: GEÇTİ.** Kapı "10 GB, LAN WS'den yavaş değil": aynı koşullarda 1 GiB × 3 ölçümün medyanında QUIC, WS'nin iki yönde de üstünde: **telefon → Mac 22,5 vs 11,1 MB/sn (2,0×), Mac → telefon 22,5 vs 16,5 MB/sn (1,4×)**. Alınan her dosyanın SHA-256'sı gönderilenle eşit (QUIC'te alıcı akarken hesaplayıp karşılaştırdı, WS'de dosya ayrıca `shasum`/`sha256sum` ile doğrulandı). **Sınırlamalar:** WS ile 10 GB gönderilemediği için karar 1 GiB medyanlarıyla verildi (aşağıda); 10 GiB'ta QUIC'in sürekli hızı telefon ısındıkça düşüyor (ortalama 14,0 / 14,5 MB/sn) ve WS'nin aynı koşuldaki davranışı ölçülemedi.

**Ortam.** macOS 27.2.1, Xcode 27.2, quinn 0.11.12, S24 (SM-S928B), Wi-Fi `<campus Wi-Fi>` (bağlantı 780–866 Mbps, sinyal −31…−48 dBm), Mac `en0` 192.168.1.10, telefon 192.168.1.20. Telefon USB'de (şarjda), ekran açık, her 10 sn ayrı eğri. Mac dahili diskinde yalnız 4–5 GiB boş; harici SSD USB 2.0 (480 Mb/s) hızında bağlı çıktı ve yazma hızı ~40 MB/sn, bu yüzden **kullanılmadı** (kullanıcı kararı, 2026-11-15).

**Ölçüm yöntemi.**
- *QUIC:* alıcının (Swift sunucu ya da Rust istemci) ilk bayttan son baytın dosyaya yazılıp SHA-256'nın kapanmasına kadar süresi; 1 GiB koşularında iki uçta gerçek disk G/Ç'si (Mac dahili disk, telefon `/data/local/tmp`); 10 GiB'ta Mac disksiz (16 MiB'lık sahte rastgele bölgeyi döngüyle gönderir / yalnız hash'ler), telefon gerçek disk. Dosya içeriği 16 MiB'lık bölgenin döngüsü; Rust ve Swift üreteçleri Python'da bağımsız hesaplanan SHA-256 ile eşit.
- *WS:* uygulamaların kendi tetikleyicileriyle elle (aşağıda neden); süre ve veri, **telefonun `wlan0` bayt sayaçlarından** (`/proc/net/dev`, saniyede bir): trafik 2 MB/sn üstünde 2 sn kalınca başlar, 0,3 MB/sn altında 3 sn kalınca biter. Bu, alıcının geçici dosyayı yerine kopyalaması gibi uygulama içi adımlardan bağımsızdır. Her turda Mac tarafında `netstat` ile Link to Mac LAN sunucusuna (`:53124`) kurulmuş TCP bağlantısı kanıtlandı.
- *Sıra:* QUIC × 3 → WS × 3 (ABABAB değil, bloklar) → QUIC kontrol × 1. Kontrol koşusu Wi-Fi'ın WS'den sonra kaymadığını gösterdi (aşağıda).

**1 GiB karşılaştırması (her yön 3 ölçüm).**

| Yön | Yol | Ölçümler (MB/sn) | **Medyan** | Mbps | Süre | Telefon CPU | Mac CPU | Telde geçen bayt |
|---|---|---|---|---|---|---|---|---|
| Telefon → Mac | **QUIC** | 23,4 / 22,5 / 19,0 | **22,5** | 180 | 46 / 48 / 57 sn | 37,3 / 34,6 / 39,1 sn | 11,6 / 11,6 / 12,5 sn | ~1 GiB |
| Telefon → Mac | WS | 11,1 / 10,8 / 13,2 | **11,1** | 89 | 97,0 / 99,6 / 81,1 sn | 132,9 / 122,5 / 103,2 sn (iki paket) | — | 1377–1395 MiB |
| Mac → telefon | **QUIC** | 25,3 / 20,6 / 22,5 | **22,5** | 180 | 43 / 52 / 48 sn | 29,4 / 29,8 / 30,4 sn | 12,0 / 12,9 / 13,0 sn | ~1 GiB |
| Mac → telefon | WS | 13,2 / 16,5 / 16,7 | **16,5** | 132 | 81,4 / 65,0 / 64,4 sn | 100,9 / 80,4 / 80,7 sn (iki paket) | — | 1414–1457 MiB |

Kontrol (WS bloğundan sonra, aynı QUIC düzeneği): yukarı 18,6 MB/sn (149 Mbps), aşağı 26,3 MB/sn (210 Mbps). Dört QUIC örneğiyle medyanlar yukarı 20,8, aşağı 23,9 MB/sn; kural yine sağlanıyor. Yukarı yönde küçük bir düşüş eğilimi görüldü (23,4 → 22,5 → 19,0 → 18,6) ve telefon bu sürede 34 → 37 °C ısındı; nedeni ayrıştırılmadı. WS toplam telde geçen veri, yük + base64 + çerçeveleme nedeniyle 1,34–1,42×; QUIC ~1,0×.

**10 GiB (her yön bir kez, Mac bellek kipinde, telefon gerçek disk).**

| Yön | Süre | Ortalama | Telefon CPU | Mac CPU | Sıcaklık | SHA-256 |
|---|---|---|---|---|---|---|
| Telefon → Mac | 765,5 sn | 14,0 MB/sn (112 Mbps) | 369 sn (~%48 bir çekirdek) | 91 sn | 37,0 → 40,5 °C | eşit |
| Mac → telefon | 738,1 sn | 14,5 MB/sn (116 Mbps) | 304 sn (~%41) | 122 sn | 40,5 → 39,3 °C | eşit |

Eğri sabit değil. Yukarı: ilk ~120 sn 23–25 MB/sn, sonra çoğunlukla 11–16 MB/sn (arada 9,0); Wi-Fi bu koşuda zayıfladı (sinyal −39 → −48 dBm, gönderme bağlantı hızı 866 → 360 Mbps). Aşağı: ilk ~230 sn 22–25 MB/sn, sonra 10–15, sonlarda 8–9 MB/sn; koşu sonunda sinyal −34 dBm ve bağlantı 780–866 Mbps'e dönmüştü, yani düşüş yalnız Wi-Fi ile açıklanamıyor. Isınma kısılması akla yakın bir aday, doğrulayan bir ölçüm yok. Pil: telefon USB'de şarj olduğundan yüzde 92 → 100 arttı, **boşalma ölçülemedi**.

**Mac host tavanı (loopback, hepsi SHA-256 eşit).**

| | İstemci → Mac | Mac → istemci |
|---|---|---|
| 1 GiB, disk dahil (dahili disk) | 303 MB/sn | 397 MB/sn |
| 10 GiB, bellek kipi | 311 MB/sn (eğri sabit 309–315) | 412 MB/sn |

Network.framework + SHA-256 tavanı ~300–410 MB/sn (2,4–3,3 Gbps); bu telefon ve Wi-Fi'ın çok üstünde, yani Mac tarafı darboğaz değil. Mac CPU maliyeti 1 GiB için 9–13 sn.

**Ayar denemeleri yapılmadı.** Aşama metnindeki UDP segmentation, `SO_RCVBUF/SO_SNDBUF` ve BBR denemeleri "düşükse" koşulluydu; QUIC WS'nin üstünde çıktığı için koşulmadı. Faz 2'de hız hedeflenirse ilk adaylar aşağıdaki bulgu 22'de.

**Tuhaflıklar (numaralı; 0.5'in 18'inden devam).**
19. **Network.framework: veri taşıyan `.finalMessage` gönderimi sonunu teslim etmiyor.** Mac'in açtığı stream'e, uçuşta başka gönderimler varken son veri parçasını `contentContext: .finalMessage, isComplete: true` ile göndermek, akışın son ~1–2 MB'ını karşıya ulaştırmadı ve o gönderimin tamamlanma bildirimi istemci bağlantıyı bırakana kadar (86 sn sonra) gelmedi. **Çözüm:** veri hep `.defaultMessage, isComplete: false` ile, FIN ise hemen ardından ayrı, boş bir `.finalMessage` gönderimiyle (`content: nil`) gidiyor (0.3'te FIN'i bu şekilde göndermiştik). Faz 2.x'in Mac gönderici tasarımına girdi.
20. **quinn her paketi ayrı küçük parça verir (~1,4 kB).** Her parça için iş parçacığı değiştirmek (disk yazma + hash için `spawn_blocking`) paket başına ~1 ms'e mal oldu ve hızı ~1 MB/sn'ye düşürdü. Çözüm: `read_chunks` ile bir çağrıda 64 parça okuyup ≥ 1 MiB biriktirdikten sonra tek seferde yazıp hash'lemek (tavan ~200+ MB/sn'ye çıktı). Faz 1.7'deki Android alıcı tasarımına girdi (JNI/disk yazımı toplu olmalı).
21. **Mac'in başlattığı ilk stream'de boş fazladan stream hâlâ var** (0.3/bulgu 4). Spike istemcisi, başlığı 500 ms içinde gelmeyen stream'i kenara alıyor; bu yüzden Mac → telefon yönünde sabit ~0,5 sn'lik bekleme var (hız hesabına dahil edilmedi).
22. **Telefon darboğaz.** Bağlantı 780–866 Mbps, sinyal −31…−39 dBm iken QUIC ~180–210 Mbps'te kalıyor ve telefon istemcisi 1 GiB için 26–39 sn CPU harcıyor (aktarım süresinin ~%70–80'i bir çekirdek); Mac aynı yükte 9–13 sn. CPU'nun nerede harcandığı (şifreleme, per-paket UDP sistem çağrıları, yazılım SHA-256, iş parçacığı geçişleri, disk) ölçülmedi; bu bir hipotez. **Faz 2 için ayar adayları (denenmedi):** GSO/GRO kullanılıp kullanılmadığının doğrulanması, SHA-256'nın donanım (`sha2` için aarch64 asm) kullanması, BBR, daha büyük alma/gönderme penceresi, daha büyük chunk.
23. **10 GiB'ta sürekli hız düşüyor** (22–25 → 8–15 MB/sn; bkz. yukarıdaki eğriler). Isınma kısılması, Wi-Fi bağlantı değişimi ve telefon CPU'sunun payı ayrıştırılmadı. Yani "ilk dakikalardaki hız" ile "sürekli hız" farklı sayılardır ve Faz 2 beklentisi sürekli hıza göre konmalı.
24. **WS yolu tetikleyicileri otomatikleştirilemiyor.** Mac'in gönderme tetikleyicisi `linktomac://send?id=…` ve bu kimlik Finder paylaşım uzantısının kendi korumalı klasörüne yazdığı tek kullanımlık kayıt (taklit edilemez, bilerek); telefonun `ShareActivity`'si içerik URI'si istiyor. WS koşuları kullanıcı tarafından elle başlatıldı (telefonda sistemin dosya yöneticisinden Paylaş → "Send as a File", Mac'te sürükle-bırak), süre dışarıdan ölçüldü.
25. **Telefonun `.dev` uygulamasında Dosyalar ekranı çöküyor:** `files.tsx` açılırken `Too many re-renders. React limits the number of renders to prevent an infinite loop.` Olası neden `useLayoutEffect(…navigation.setOptions…)` bağımlılıklarından birinin (`clear` ya da `colors.primary`) her render'da değişmesi. Ölçümle ilgisi yok; kullanıcı onayıyla ayrıca düzeltilecek (bu aşamanın kapsamı dışında).
26. **LAN-direct varsayılan olarak kurulmadı:** uygulamalar önce relay üzerinden bağlıydı; kullanıcı LAN bağlantısını kurunca (Mac `:53124` ↔ telefon) WS koşuları başladı. `lsof` Network.framework'ün sahip olduğu soketleri göstermiyor, kanıt için `netstat` kullanıldı.
27. **WS ölçümü `.dev` (hata ayıklama) derlemesiyle, Metro bağlıyken yapıldı.** Native Kotlin kodu aynı, ama debug derleme ve geliştirme sunucusu trafiği WS'yi biraz dezavantajlı yapmış olabilir; release derlemeyle tekrar ölçülmedi. İki WS paketinin CPU'su toplam olarak alındı.
28. **Ortam sorunları (süreçten).** Harici SSD USB 2.0 hızında; Mac dahili diski %98 dolu; ön kontrolde telefon başka bir Wi-Fi ağındaydı (ping %100 kayıp) ve düzeltildi; `adb` birkaç kez düştü (telefondaki istemci `nohup` ile çalıştığı için koşular etkilenmedi); WS izleyicim `tr` boru tamponu yüzünden ilk iki aktarımı ölçemedi (bütünlük doğrulandı) ve telefondaki örnekleyici döngüsünü kapatmıyordu: ikisi de düzeltildi.

**Test kayıtları.** `cargo test --all-targets` 3 + 7 + 10 + 14 = 34 test, `cargo clippy --all-targets -- -D warnings` temiz, `mac-server --self-test` ok (başlık, bölge SHA-256, döngü içeriği ve ad doğrulama altın değerleri Python'da bağımsız hesaplandı; Rust ve Swift eşit), `build-so.sh` `.so` üretiyor, Mac 142 test geçti. 0.3–0.5 gerilemesi yok: a–g ve h-up/h-down localhost, LAN ve telefonda PASS.

**Kalıcı / atılabilir.** Kalıcı bilgi: bulgular 19–23 (Faz 1.7 ve Faz 2'ye girdi) ve hız sayıları. Atılabilir: spike kodu (`gen`/`bulk-*` senaryoları, `0x42` alıcı/gönderici, `bulk-phone.sh`, `ws-watch.sh`).

---

## 0.7 Mac QoS: Mac → telefon dosya trafiğini sınırlama

**Güncel durum (2026-11-17): yeniden ölçüm yapıldı; %50 (E1) BELİRSİZ, %25 ve %10 GEÇTİ; E1 + sahte yük tekrarı kullanıcı kararıyla ertelendi, aşama açık (`[ ]`).** Aşağıdaki "Yeniden ölçüm" bölümü ilk ölçümün (2026-11-16) yerine geçer; ilk ölçüm tarihçe olarak "İlk ölçüm" başlığı altında duruyor. Yeniden ölçüm, ilk ölçümün güvenilirlik sorunlarını (gürültü tabanı, eşit olmayan dilimler, az örnek, farklı zamanlar) gideren eşleştirilmiş tasarımla yapıldı.

### Yeniden ölçüm (2026-11-17)

**Yöntem (planda onaylı, 0.7 madde 5).** Her koşu tek bağlantıda: 5 sn ölçülmeyen ısınma, sonra `KAPALI 10 sn → [AÇIK-oturma 2 sn → AÇIK 10 sn → KAPALI-oturma 1 sn → KAPALI 10 sn] × 8`, yani 9 KAPALI + 8 AÇIK ölçülen dilim (17 faz), ~3,7 dk/koşu; video 60 stream/sn × 30 KiB sürekli, AÇIK diliminde o koşulun Mac → telefon dosya akışı (her döngüde `BDOWN`…`BSTOP`). **Eşleştirilmiş etki** = p95(AÇIK_i) − ortalama(p95(KAPALI_i), p95(KAPALI_{i+1})). Koşullar: **A** sahte yük (dosya yok), **B** sınırlayıcı kapalı, **E1** %50 × B0 (burst 64 KiB / parça 64 KiB), **F25** %25, **F10** %10; her biri 3 koşu (24 etki), tur başına döndürülmüş sıra. **B0 her turun başında yeniden ölçüldü** ve o turun sınırlayıcı hızları ona göre ayarlandı (aşağıda neden). İstatistik: medyan ve %90 bootstrap aralığı (10 000 yeniden örnekleme, sabit tohum 20261117).

**Ortam.** macOS 27.2.1, S24, Wi-Fi 5 GHz (802.11ac, sinyal −38…−45 dBm, bağlantı 433–866 Mbps), Mac boşta ağ trafiği 0,3–0,5 MB/sn, telefon 33–36 °C, USB'de şarjda, ekran açık, 15 koşunun hepsi geçerli (hiçbiri tekrarlanmadı, Wi-Fi bandı hiç değişmedi). **B0: tur 1 = 10,1, tur 2 = 19,7, tur 3 = 24,6 MB/sn** (önceki gün 26,1 / 28,3; ilk deneme çalıştırmasında tek B0 12,3 çıkınca koşu durduruldu ve B0 tur başına ölçülmeye geçildi).

| Koşul | n (etki) | Medyan | %90 aralık (çift bazlı, betik) | %90 aralık (koşu bazlı, iki aşamalı) | ≤ 20 ms | Koşu medyanları | Ulaşılan ON hızı (ort.) | Betiğin kararı |
|---|---|---|---|---|---|---|---|---|
| A sahte yük | 24 | **−1,0 ms** | [−2,3; 0,6] | [−2,5; 0,6] | 23/24 | −2,3 / −0,3 / −0,3 | – | geçerlilik kapısı **OK** (± 5 ms) |
| B sınırlayıcı kapalı | 24 | **44,7 ms** | [35,9; 46,7] | [21,9; 46,7] | 4/24 | 42,0 / 45,7 / **8,6** | 17,7 MB/sn | KALDI |
| **E1 %50** | 24 | **9,1 ms** | [4,7; **22,1**] | [4,5; 65,2] | 16/24 | 5,0 / **65,2** / 4,7 | 7,3 MB/sn (4,3 / 7,6 / 10,1) | **BELİRSİZ** |
| F25 %25 | 24 | **5,6 ms** | [3,0; 12,9] | [2,4; 19,9] | 18/24 | 18,5 / 5,0 / 3,0 | 3,9 MB/sn | GEÇTİ |
| F10 %10 | 24 | **3,3 ms** | [−0,7; 5,1] | [−0,7; 5,1] | 22/24 | 3,3 / 1,9 / 3,4 | 1,6 MB/sn | GEÇTİ |

Ham kayıtlar: `docs/plans/data/2026-11-17-qos-paired-runs.txt` (ve `-b0.txt`); `python3 spikes/quic/qos-analyze.py` aynı kararları üretir.

**Ne kesin.**
- **Sınırsız dosya akışı videoyu belirgin yavaşlatıyor:** medyan +44,7 ms (3 koşunun ikisinde +42,0 ve +45,7; üçüncüde +8,6). Önceki ölçümle tutarlı (+33…+57).
- **Gürültü referansı artık temiz:** sahte yük 24 çiftte medyan −1,0 ms ([−2,3; 0,6]); eski tasarımda aynı referans 9 koşunun 2'sinde +25–26 ms sıçrıyordu.
- **Etki dosya hızıyla birlikte artıyor:** ulaşılan hız 1,6 → 3,9 → 7,3 → 17,7 MB/sn iken medyan 3,3 → 5,6 → 9,1 → 44,7 ms. **İlk ölçümde yazdığım "gecikme dosya hızıyla orantılı değil" yorumunu (bulgu 32) geri çekiyorum**, gürültülü veriye dayanıyordu; "telefon tarafı işleme" hipotezi bu veriyle desteklenmiyor (ayrıca test edilmedi).
- **%10 sağlam biçimde geçiyor** (üç koşunun üçü ~2–3 ms), **%25 geçiyor ama koşu bazında sınırda** (üst sınır 19,9; koşulardan biri +18,5).

**Ne kesin değil (E1 %50 BELİRSİZ).** Medyan 9,1 ms eşiğin altında, ama çift bazlı aralığın üstü 22,1 ms ve koşu bazlı aralık [4,5; 65,2]. Neden tek bir koşu: E1'in tur 2'sinde 8 çiftin hepsi yüksek (16–417 ms), diğer iki koşu çok düşük (5,0 ve 4,7 ms). O turun sahte yük ve F25/F10 koşuları temiz çıktığı için bu, ortamdan çok o koşuya özgü bir bozulma gibi görünüyor, ama kanıtlanamadı. Karar kuralı (0.7 madde 5) bu durumda "BELİRSİZ, kullanıcıya sorulur" diyor; kullanıcı kararı: **sonuçlar olduğu gibi kaydedilsin, E1 ve sahte yük için tekrar ölçüm daha sonra yapılsın.**

**Bekleyen.** (1) E1 ve A için en az 3'er ek koşu (B0 her koşu öncesi yeniden ölçülerek, tercihen stabil bant). (2) Faz 6.1'in hız payı kararı (%50 mi %25 mi) bu tekrara bağlı; geçici öneri: **%25 × B0 (ya da daha düşük), burst 64 KiB, parça 64 KiB** güvenle geçiyor, %50 doğrulanmadı. (3) Faz 2.5 madde 5 ve Faz 6.1 metinlerine parametrelerin işlenmesi kullanıcı onayını bekliyor.

**Tuhaflıklar (numaralı; 0.7 ilk ölçümün 35'inden devam).**
36. **Eşleştirilmiş, iç içe tasarım gürültüyü işe yarar biçimde ölçüyor ve iptal ediyor:** aynı dilim dizisinde dosya yokken etki 24 çiftte medyan −1,0 ms (aralık [−2,3; 0,6]); loopback'te |etki| ≤ 0,2 ms. Eski "20 sn taban / 60 sn yük" tasarımı aynı koşulda +25 ms'ye kadar sapıyordu.
37. **Bant genişliği gün içinde ~2,5 kat oynuyor** (B0 10,1 / 19,7 / 24,6 MB/sn bu oturumda; önceki gün 26–28; 2,4 GHz'e düşünce 10): sınırlayıcı hızı sabit bir B0'la belirlenirse "%50" anlamını yitirir. B0 tur başında ölçülmeli (6.1'de çalışma zamanı kestirimi gerekecek).
38. **Etki hızla artıyor** (bulgu 32'nin düzeltmesi, yukarıda).
39. **Koşular arası heterojenlik var:** B'nin üçüncü turu yalnız +8,6 ms (diğer ikisi +42…+46), E1'in ikinci turu +65,2 ms (diğer ikisi ~+5). Çift bazlı aralık, aynı koşunun çiftlerini bağımsız sayarak iyimser kalıyor; koşu bazlı (iki aşamalı) aralık ayrıca raporlandı. Analiz betiği şimdilik yalnız çift bazlı aralık veriyor; koşu bazlı aralığı betiğe eklemek tekrar ölçümle birlikte yapılacak.
40. **Yeni kurulan bağlantının ilk saniyeleri temsili değil** (duman koşusunda ilk KAPALI diliminin p95'i 22 ve 76 ms): 5 sn'lik ölçülmeyen ısınma eklendi.
41. **burst = parça = 64 KiB iken hedefin ~%85'i** (bulgu 30'un teyidi): E1 gerçek hız 4,3 / 7,6 / 10,1 MB/sn, hedef 5,05 / 9,85 / 12,3.
42. **Süreç:** ilk tam çalıştırma, tek B0 ölçümü 12,3 MB/sn çıkınca (10,1–24,6 arasında oynuyormuş) durduruldu ve tur başına B0'a geçildi; sahte yük kapısı duman koşusunda (n=2, 6 sn dilimler) bilerek tetiklendi ve çalıştığı doğrulandı.

**Test kayıtları (yeniden ölçüm).** `cargo test --all-targets` 3 + 7 + 10 + 23 = 43 test (yeni: dilim tablosu, ısınma, `phase_at` sınırları, dilim başına örnek sayısı, eşleştirilmiş etki, medyan), `cargo clippy --all-targets -- -D warnings` temiz, `mac-server --self-test` ok (`SPHASE nosample` eklendi), `qos-analyze.py --self-test` ok (güven aralığı, karar sınırları, kayıt ayrıştırma), `build-so.sh` `.so` üretiyor, Mac 142 test geçti. Loopback düzeneği: sahte yük |etki| ≤ 0,2 ms, sınırsız +7,7 ms, %50 +0,4 ms, 8 `BDOWN`/`BSTOP` döngüsü temiz, hiçbir fazda kayıp yok. 0.3–0.6 gerilemesi yok: a–g ve h-up/h-down localhost, LAN ve telefonda PASS; kısa `s-60`/`s-110` PASS. Temizlik: süreç yok, UDP 53125 boş, `LinkToMac-spike-*` sertifikası yok, `pairing` dokunulmadı, telefonda geçici dosya yok.

### Tanı: ping + video aynı dilimlerde (2026-11-18)

**Neden.** Yeniden ölçümde %50 sınırı, iki koşuda (+54 ve +65 ms) bozulurken dördünde iyi çıktı; üç dış görüş (docs/plans/cevap1–3.md) ağ yolunun mu, QUIC/uç yığınlarının mı sorumlu olduğunun ayrılmadığını söyledi. Düzenek: aynı `qos2` KAPALI/AÇIK dilimleri, aynı anda telefondan Mac'e `ping -D` (5 Hz; ICMP yanıtı dosyanın aktığı yönde, yani videonun QUIC ACK'lerinin yolunda döner), **sabit mutlak** sınır hızları (5 / 7,5 / 10 / 12 MB/sn) ve sahte yük, her turda rastgele sırada, 2 tur = 10 koşu. İstemci `QOS2_T0`/`QOS2_SEG` satırlarıyla dilim sınırlarını telefon saatinde yazdırır, ping aynı saatte olduğundan hizalama için Mac saatine gerek yok. Betikler: `spikes/quic/qos-pair-ping.sh`, `qos-pair-ping-analyze.py`; ham veri `docs/plans/data/2026-11-18-qos-pair-ping/`. (Önce yazdığım tek-koşu ping betiği `qos-ping.sh` kirlenmiş çıktı verdi, bkz. bulgu 45, sonucu kullanılmadı.)

**Ortam.** Telefon ve Mac aynı kampüs erişim noktasında, ikisi de 802.11ac, kanal 36 (5 GHz, 80 MHz), bağlantı 650–866 Mbps (Mac: −48 / −93 dBm, MCS 8; telefon: −31…−44 dBm), `awdl0` **açık** (AWDL kapalı karşılaştırması henüz yok), her iki taraf boşta trafik ≤ 1,1 MB/sn.

| Koşul | n (AÇIK dilim) | Ping medyanı KAPALI → AÇIK | Ping p95 etkisi (medyan) | Video p95 etkisi (medyan) | Videoda > 20 ms kötüleşen AÇIK dilim |
|---|---|---|---|---|---|
| sahte yük | 16 | 7,8 → 7,6 ms | −0,3 | −0,6 | 2/16 |
| sınır 5 MB/sn (ulaşılan 4,3) | 16 | 9,2 → 12,2 | +29,7 | +14,5 | 7/16 |
| sınır 7,5 MB/sn (6,4) | 16 | 7,6 → 10,8 | +19,4 | +6,6 | 2/16 |
| sınır 10 MB/sn (8,5) | 16 | 7,4 → 12,7 | +34,5 | +32,0 | 11/16 |
| sınır 12 MB/sn (10,1) | 16 | 7,7 → 15,9 | +33,4 | +27,5 | 10/16 |

Koşu bazında en kötüler: 10 MB/sn tur 1 video +67,7 ms (ping +38), 12 MB/sn tur 2 +33,0 ms (ping +71,5); 7,5 MB/sn her iki turda +6,2 / +6,9 ms (temiz).

**Ne kesin.**
- **Her indirme dönüş yoluna kuyruk ekliyor:** ICMP (QUIC'ten bağımsız) yanıtının RTT medyanı sahte yükte değişmezken (7,8 → 7,6) indirmede +3,0 / +3,2 / +5,3 / +8,2 ms artıyor, hızla birlikte. Yani hipotez (dosya, videonun ACK yolunu geciktiriyor) ağ düzeyinde doğrulandı; telefondaki `quinn`'in kendi iç davranışı (pacing/cwnd) bu ölçümle sınanmadı.
- **Ping ve video aynı anda bozuluyor:** koşu içi ON dilimleri arasında korelasyon +0,4…+1,0 (7,5 MB/sn tur 2: +0,98). Video etkisi kabaca ping p95 etkisinin 0,5–1 katı. Dolayısıyla uygulama düzeyinde bir ping benzeri sonda, video gecikmesi için işe yarar bir tıkanıklık işareti.
- **Sabit yüzdeli sınırlayıcı kırılgan:** dünkü oturumda ~8,5 MB/sn bozuk, ~10,1 MB/sn iyiydi; bugün 8,5 ve 10,1 MB/sn ikisi de bozuk, 6,4 iyi. Kapasite oturumdan oturuma (ve içinde) kaydığı için sabit bir hız ya da "B0'ın %X'i" taşınabilir bir karar değil.
- **Ortam kaynaklı ortak sıçramalar var:** sahte yükte bile video ve ping p95 aynı dilimlerde birlikte sıçrıyor (korelasyon +0,86 / +0,92, ör. video 42 / 50 ms, ping 60 ms). Bunlar bizim trafiğimiz değil; kampüs erişim noktası/AWDL adayları. Tur 2'nin sahte yükü ve 5 MB/sn koşusunun KAPALI dilimleri bile yüksekti (video p95 20–50 ms), bu yüzden 5 MB/sn tur 2'nin +29 ms'si yalnız dosyaya yüklenemez.

**Ne kesin değil.** AWDL'nin rolü (karşılaştırma için kullanıcıdan `sudo ifconfig awdl0 down` gerekir); telefondaki `quinn` RTT/cwnd/yeniden iletim (istatistik kaydı henüz yok); Mac'in tek seri kuyruğunun payı (kuyruk gecikmesi ölçülmedi); sıçramaların bizimle ilgisi olmayan komşu trafik olup olmadığı.

**Yorum.** Dosya akışı ağ yolunda ölçülebilir bir kuyruk oluşturuyor ve bu kuyruk videoyu aynı anda yavaşlatıyor; ne kadar kötü olduğu o anki kapasiteye ve ortam gürültüsüne bağlı. Bu, sabit bir yüzde yerine **gecikme sinyaline bağlı uyumlu bir sınırlayıcıyı** (seçenek A) destekliyor; 7,5 MB/sn (≈ bugünkü kapasitenin yarısından az) video etkisini sahte yük düzeyinde tuttu.

45. **`qos-ping.sh` (ayrı boş/yüklü koşular) kullanılamaz:** ortam ilk koşudan sonra bozuldu (yük başlamadan RTT 30–65 ms, sınırsız indirme 5,9–8,7 MB/sn). Ayrı koşuları karşılaştırmak gürültüye açık; çözüm eşleştirilmiş iç içe dilimlerdi (yukarıdaki düzenek).
46. **Mac'ten telefona atılan ping güvenilmez:** boşta telefon Wi-Fi güç tasarrufuna girdiği için 5–44 ms (arada 110 ms) okunuyor; telefondan Mac'e 6–9 ms. Sondalar telefondan atılmalı.
47. **İstemci `QOS2_T0`/`QOS2_SEG` satırları** (spike) dış sondaları hizalamak için eklendi; sunucunun "stream-cost phase N started" satırları dilim zamanını göstermez (istemci tüm `SPHASE`'leri başta toplu gönderir).
48. **Boru hattında çalışan sunucu `kill` ile ölmez:** zaman damgası boru hattında alt kabuk öldürülünce `mac-server` portu tutmaya devam ediyordu; `pkill -f "<server> --tok"` eklendi.

**AWDL kapalı karşılaştırması (aynı gün).** Kullanıcı `sudo ifconfig awdl0 down` çalıştırdı; `awdl0` tüm ölçüm boyunca `inactive` kaldı (147 örnek, `docs/plans/data/2026-11-18-qos-pair-ping-awdl-off/awdl-status.txt`). Aynı düzenek, aynı 2 tur; ham veri aynı dizinde. Koşullar: telefon erişim noktasına daha yakındı (−28 dBm, önceki geçişte −44…−31), bazı koşularda telefon bağlantı hızı 468–526 Mbps'e düştü.

| Koşul | AWDL açık: ping medyanı KAPALI → AÇIK / video etkisi / kötü dilim / koşu medyanları | AWDL kapalı: aynıları |
|---|---|---|
| sahte yük | 7,8 → 7,6 / −0,6 / 2/16 / −3, 0 | 8,6 → 8,9 / +0,7 / 1/16 / 2, 0 |
| 5 MB/sn | 9,2 → 12,2 / +14,5 / 7/16 / 2, 29 | 8,7 → 12,2 / +5,1 / 3/16 / 5, 15 |
| 7,5 MB/sn | 7,6 → 10,8 / +6,6 / 2/16 / 6, 7 | 8,9 → 15,9 / **+29,8** / **11/16** / **48**, 19 |
| 10 MB/sn | 7,4 → 12,7 / +32,0 / 11/16 / 68, 27 | 9,0 → 18,1 / +15,5 / 6/16 / 15, 37 |
| 12 MB/sn | 7,7 → 15,9 / +27,5 / 10/16 / 10, 33 | 9,4 → **31,1** / +21,6 / 8/16 / 22, 23 |

49. **AWDL ana neden değil:** kapatınca dosyaya bağlı etki kalkmadı. 7,5 MB/sn (AWDL açıkken iki turda da temiz, +6/+7) bu kez bozuldu (+48 / +19); 12 MB/sn'de dönüş yolunun ping medyanı 31 ms'ye çıktı (15,9'dan), yani kuyruk daha da derinleşti. Sahte yükün KAPALI video p95 en kötüsü 42 → 18 ms'ye indi (zayıf bir ipucu: AWDL seyrek sıçramalara katkıda bulunuyor olabilir; her biri tek geçiş, n küçük).
50. **Sabit hızda etkinin büyüklüğü geçişten geçişe 3–8 kat değişiyor** (7,5 MB/sn: 6–7 ms → 19–48 ms; 5 MB/sn: 29 → 15/5 ms). Kapasite (kampüs erişim noktasındaki diğer istemciler, telefon bağlantı hızı 468–780 Mbps arası oynuyor) kaydığı için hiçbir sabit hız, ve B0'ın sabit bir yüzdesi, güvenli bir tasarım parametresi değil. Dönüş yolunun kuyruğu (ping medyanı artışı: +3 ile +22 ms) hızla birlikte artıyor ve video etkisiyle aynı yönde. Bu, sınırlayıcının **o anki gecikme sinyaline** bağlanmasını (seçenek A) tek tutarlı yol haline getiriyor.
51. **Kullanıcı notu:** AWDL deneyi için `sudo` terminal gerektirir (oturum içi `!` ile parola sorulamadı); ölçüm sonrası `sudo ifconfig awdl0 up` ile geri açılır.

### Uyumlu (gecikmeye bağlı) dosya sınırlayıcı prototipi (2026-11-18)

**Karar ve kapsam.** Tanı (bulgular 36–51) sabit hızlı sınırlayıcının güvenilir olmadığını gösterince, kullanıcı onaylı plana göre (`~/.claude/plans/ethereal-watching-taco.md`) Mac tarafında video gecikmesini izleyip dosya hızını ayarlayan bir denetleyici yazıldı. **Çekirdek üretim kalitesinde ve saf** (`mac/Sources/LinkToMac/Quic/DelayRateController.swift`, Foundation yalnız, `LinkToMacTests`'e dahil); spike bağlantısı atılabilir (`BDOWN … auto=<yüksek ms>,<düşük ms>` + `--auto` istemci bayrağı).

**Durum:** çekirdek, `TokenBucket.setRate`, sunucu ve istemci bağlantısı, loopback ve telefon duman koşuları, regresyon, **ilk karşılaştırma** (güvenli ama verim ölçütü geçmedi) ve kullanıcı onaylı **ayar turu** tamam (aşağıda). **Ayar turu sonucu: ölçütler 1–4 geçti (güvenlik, verim, ping, sahte yük kapısı havuzlu), ölçüt 5 (uyumun sabit hıza üstünlüğü) bu oturumda yine kanıtlanamadı.**

**Yapılar ve testler.** `DelayRateControllerTests`: 27 test (her kural elle hazırlanmış örneklerle; ayrıca 1 MiB'lık Mac gönderim tamponu olan akışkan darboğaz simülasyonu: sabit kapasite, 12→4 düşüş, 4→12 yükseliş, sessiz video). Mutasyon kontrolü: azaltma çarpanlarını 0,99 yapınca testler kırılıyor (5 sorun), dosya geri alındı. `mac-server --self-test` (`setRate` ve `auto=` alanı ayrıştırıcısı dahil) ok, Rust 46 test (3+7+10+26), clippy temiz, Mac 169 test.

52. **Sinyalin ilk tanımı gerçek ağda çöktü, simülasyon göstermemişti.** İlk sürüm `q = (son 0,6 sn örneklerinin p75'i) − (son 30 sn'nin en küçük ham gecikmesi)` kullandı ve simülasyonda gürültü 0–1,5 ms varsayıldı. Telefonda **yük yokken bile** q 6–14 ms (medyan 7,5) çıktı; denetleyici ortam gürültüsünü tıkanıklık sayıp hızı tabanda (0,5 MB/sn) tuttu (16 saniyenin 16'sı `hold`/`decrease`). Gerçek tek yönlü video gecikmesi tabanın 0–12 ms üstüne yayılıyor.
53. **Sinyal gerçek izlerle yeniden tasarlandı** (`spikes/quic/qos-signal-calibrate.py`; sunucu `DELAY_DUMP=<dosya>` ile her video akışının gecikmesini döker; ham veri `docs/plans/data/2026-11-18-delay-signal-calibration/`, 59 700 akış, 5 koşu: sahte yük + sabit 5 / 7,5 / 10 / 12 MB/sn). Dört tanım, KAPALI (yük yok) dilimlerde q ve AÇIK dilimlerde (video etkisi ≤ 20 ms "iyi" / > 20 ms "kötü") q medyanı:

| Tanım (pencere 0,6 sn, 30 sn tabanı) | KAPALI q p50 / p90 / p99 (ms) | iyi AÇIK dilim q | kötü AÇIK dilim q |
|---|---|---|---|
| p75 − ham en küçük (ilk denetleyici) | **7,1** / 10,3 / 45,4 | 9,8 | 15,8 |
| medyan − en küçük pencere medyanı | 1,7 / 3,5 / 13,2 | 3,1 | 7,1 |
| p75 − en küçük pencere p75'i | 2,5 / 5,6 / 40,8 | 4,5 | 10,6 |
| **medyan − pencere medyanlarının p10'u** (seçilen) | **0,8 / 2,6** / 12,4 | **2,0** | **5,9** |

Tek tek dilimlere bakınca q ≥ ~5–6 olan AÇIK dilimlerde video etkisi çoğunlukla > 20 ms (10 MB/sn: q 6 → +62, q 9 → +51, q 19 → +186; 12 MB/sn: q 25 → +104); q ≈ 3–4 olanlar temiz. Eşikler: **yüksek 5 ms, düşük 2 ms** (hysteresis bandı OFF gürültüsünün üstünde, kötü dilimlerin altında). Not: dilim medyanı kuyruk kuyruğunu (p95) hafife alıyor (q 6'lı bazı dilimlerde etki +80), bu yüzden eşik düşük tutuldu.
54. **Simülasyonun zaman çizelgesi iki zayıflık gösterdi, düzeltildi.** (a) Kapasite 12→4 düşünce kuyruk ~1 sn 245 ms'ye çıkıyor ve kuyruk yavaş boşalırken "boşalıyor" kuralı (%20 düşüş) tetiklenmediği için üst üste kesiliyordu (8,6 → 3,2 → 1,1 → 0,5 MB/sn, ~9 sn'de toparlama): boşalma artık mutlak düşüşle tanımlı (≥ 1 ms/tik). (b) Kapasiteye yaklaşınca artış çok hızlıydı, her ~5 sn'de 15–23 ms'lik kuyruk tepeleri: son kesintinin hızı "diz" olarak hatırlanıyor, dizin %85'inden yukarısı 0,15 MB/sn²'de denenir, 10 sn kesinti olmazsa diz unutulur. Sonuç (gürültü 0–12 ms): sabit 10 MB/sn kapasitede hız 8,2 MB/sn (%82), kuyruk q95 0,1 / en çok 8,6 ms; düşüşte tek kesinti, kuyruk ~1,5 sn'de sönüyor, 3,6 MB/sn'ye (kapasitenin %89'u) oturuyor; sonraki tepeler 6–11 ms.
55. **Bilinen sınır ("geç gelen"):** ~30 sn süren sürekli bir kuyruk sakin seviye olur (p10 tabanı kuyruğa kayar); testte 24 sn'lik kesintisiz 200 ms kuyruk `q`'yu sıfıra indirdi. Gerçekte denetleyici kuyruğun kalıcı olmasına izin vermemeli, ama ortam kaynaklı 30 sn+ gecikme artışı yeni normal sayılır (istenen). Periyodik sonda ayrı bir sonraki adım.
56. **15:22 civarı ortam bozulması:** boşta telefon→Mac ping ort. 36–58 ms (tepe 138–177 ms; sabah 8 ms), KAPALI video p95 32–80 ms; denetleyici bu ortamda hızı tabanda tuttu (güvenli ama işe yaramaz). Karşılaştırma bu yüzden ortam sakinleşene kadar bekletildi (boşta ort. < 12 ms ve tepe < 80 ms, 3 ardışık ölçüm).
57. **Regresyon:** a–g ve h-up/h-down localhost, LAN ve telefonda PASS; tek istisna telefonda `h-down` bir kez 299/300 (bir DATAGRAM kaybı, `max-gap=1`, gürültülü pencerede); aynı senaryo tek başına 3 kez 300/300 PASS (ortam kaynaklı, güvenilmez kanalda beklenir, sunucunun datagram yoluna dokunulmadı). Ayrıca `qos-pair-ping.sh` ve bütün spike betikleri sunucuyu `DelayRateController.swift` ile derliyor.

**Karşılaştırma deneyi (2026-11-18, 16:15–16:57).** 3 tur × {sahte yük, `auto` 5/2 ms, `auto` 7/3 ms, sabit 7,5 MB/sn}, her turda rastgele sırada, 12 koşunun hepsi geçerli, ping yanda. Ortam: telefon + Mac aynı kampüs erişim noktasında 5 GHz (−30…−43 dBm), AWDL kapalı, telefonda UWB / yakın cihaz taraması / Wi-Fi ve Bluetooth taraması kapalı, Quick Share "kimse" (bkz. bulgu 58). Ham veri: `docs/plans/data/2026-11-18-auto-controller-comparison/`.

| Koşul | Koşu medyanları (video etkisi, ms) | En kötü dilim | > 20 ms kötü AÇIK dilim | Ortalama AÇIK hızı | Ping medyanı KAPALI → AÇIK |
|---|---|---|---|---|---|
| sahte yük | −1 / −1 / +1 | 194 | 2/24 | – | 8,9 → 9,1 |
| sabit 7,5 MB/sn | 9 / 3 / 2 | 114 | 2/24 | 6,0 MB/sn | 9,6 → 16,5 (+6,9) |
| `auto` 5/2 ms | −9 / 7 / 1 | 29 | 3/24 | **1,5 MB/sn** | 10,1 → 12,5 (+2,4) |
| `auto` 7/3 ms | 8 / 5 / −3 | 61 | 3/24 | **3,7 MB/sn** | 10,6 → 14,5 (+3,9) |

Denetleyici izleri (1 sn örnekleri, ortalama hız): `auto` 5/2: 0,9 / 1,6 / 2,8 MB/sn (r1'de 8 AÇIK dilimin 6'sında 0,5 MB/sn tabanı); `auto` 7/3: 3,4 / 4,3 / 6,1 MB/sn (r3'te tavan 13,1 MB/sn, video etkisi −3,5 ms).

**Başarı ölçütlerine karşı (planın "öneri" ölçütleri):**

| # | Ölçüt | `auto` 5/2 | `auto` 7/3 |
|---|---|---|---|
| 1 | her koşu medyanı ≤ 20 ms ve hiçbiri > 30 ms; kötü AÇIK dilim ≤ %25 | geçti (3/24 = %12,5) | geçti (%12,5) |
| 2 | ortalama AÇIK hızı ≥ 4 MB/sn **ve** aynı oturumdaki sabit 7,5'in ≥ %60'ı (≥ 3,6) | **kaldı** (1,5) | **kaldı** (3,7: ikinci koşul geçti, ilki 4'ün altında) |
| 3 | ping medyan artışı ≤ +6 ms | geçti (+2,4) | geçti (+3,9) |
| 4 | sahte yük kapısı \|medyan\| ≤ 5 ms | geçti | geçti |
| 5 | sabit 7,5 oturumda bozulur, `auto` bozulmaz | tetiklenmedi: sabit 7,5 bu oturumda bozulmadı (9 / 3 / 2) | tetiklenmedi |

58. **Gürültünün kaynağı hakkında (kampüs ağı, 2026-11-18 öğleden sonra):** (a) Mac 43 komşu ağ görüyor, bizim 80 MHz'lik bloğumuzda (kanal 36–48) en az 6'sı var; öğleden sonra yoğunluk sabahtan yüksek (boşta ping ort. sabah 8 ms, 15:22'de 36–58 ms, tepe 177). (b) Aynı anda erişim noktasına ping: Mac bacağı ort. 4,6 / tepe 24 ms, **telefon bacağı 9,9 / 60 ms** (2–3 kat oynak): kanal yoğunluğu tek açıklama değil. (c) Telefonda Google Play Hizmetleri (Nearby Connections / Quick Share) bir Wi-Fi çoklu yayın kilidi tutuyordu; kullanıcı UWB, yakın cihaz taraması, Wi-Fi ve Bluetooth taramasını kapatıp Quick Share'i "kimse"ye alınca kilit bırakıldı, ama 4 tekrarda telefon bacağı hâlâ Mac'inkinin 3–5 katı (sapma 9,5–15,2 ms; ilk "iyileşmiş" tek ölçüm şanslıydı). (d) Telefonun boşta ping'lerdeki oynaklığı büyük ölçüde Wi-Fi güç tasarrufu (bkz. 61). Mac'te Bluetooth kapalı, Link to Mac uygulaması çalışmıyordu; telefonda bizim uygulamalarımız yalnız bildirim dinleyici olarak duruyordu (ön plan servisi yok).
59. **Güvenli ama verimsiz:** her iki varyant da video etkisini sahte yük ve sabit 7,5 düzeyinde tuttu (hatta ping artışı sabitin yarısından az), ama dosyaya verdiği hız ölçütün altında. `auto` 5/2 gürültüye aşırı duyarlı (r1'de çoğu dilimde tabanda), `auto` 7/3 sınırda (3,7 MB/sn). Neden: ortam kaynaklı kısa sıçramalar (`q` tepe 25–88 ms, sahte yükte de var) kesinti tetikliyor, toparlanma yavaş (+0,5 MB/sn², dize yakınken +0,15) ve alt sınır 0,5 MB/sn.
60. **Uyum görüldü:** `auto` 7/3 r3'te hızı 13,1 MB/sn'ye çıkarabildi ve video etkisi −3,5 ms kaldı; r1'de aynı ayarla 0,9–6,9 MB/sn. Yani denetleyici koşula göre hızı gerçekten ayarlıyor; sabit hız bu oturumda tesadüfen sorunsuzdu (önceki geçişlerde aynı 7,5 MB/sn +19…+48 ms vermişti), bu yüzden bu deney uyumun değerini kanıtlamıyor, yalnız güvenli olduğunu gösteriyor.
61. **Ölçüm kuralları:** boşta-ping ile "ortam sakin mi" kapısı yanlış sinyal çıktı: telefon boşta Wi-Fi güç tasarrufuna girip her 0,2 sn'lik ping'e 10–60 ms ekliyor, gerçek akış sırasında (60 video/sn) ping medyanı KAPALI'da 9–10 ms. Gerçek kapı her turdaki sahte yük koşusu; kapı bu deneyde temiz (|medyan| ≤ 1 ms), ama 3 sahte koşudan ikisinde tek bir dilimde +186/+194 ms'lik sıçrama var (ortam).

**Ayar turu (2026-11-18, 17:45–18:30; kullanıcı onaylı).** Değişiklikler: hız alt sınırı 0,5 → **2 MB/sn**; hız tabandayken yüksek kuyruk **ortam payı** sayılıyor (1 sn sonra, en çok 20 ms, yarı ömür 8 sn); toparlanma +0,5 → **+1 MB/sn²** (dize yakınken 0,15 → 0,3); eşikler **7 / 3 ms**. Simülasyon (gürültü 0–12 ms): sabit 10 MB/sn'de ortalama 8,9 MB/sn, q95 5,7 ms; +30 ms'lik bizimle ilgisiz ortam sıçramasında hız tabanda (2 MB/sn), sıçrama bitince ~12 sn'de 9,7 MB/sn. Deney: 3 tur × {sahte yük, `auto`, sabit 7,5 MB/sn}, rastgele sıra, ping yanda; **bu sefer AWDL açıktı** (macOS kapatılan AWDL'yi yeniden açmıştı; gerçek kullanım durumuna daha yakın, önceki karşılaştırmayla doğrudan kıyas bu farkla yapılmalı). Telefon ayarları öncekiyle aynı. Ham veri: `docs/plans/data/2026-11-18-auto-controller-tuned/`.

| Koşul | Koşu medyanları (video etkisi, ms) | En kötü geçerli çift | > 20 ms kötü AÇIK dilim | Ortalama AÇIK hızı (koşu bazında) | Ping medyanı KAPALI → AÇIK |
|---|---|---|---|---|---|
| sahte yük | r1 **geçersiz**, r2 +0,1, r3 **+6,8** | 36 | 3/16 (hepsi r3) | – | 10,4 → 10,8 |
| sabit 7,5 MB/sn | 0,1 / 3,0 / 0,3 | 11 | 0/24 | 6,1 (6,1 / 6,3 / 6,0) | 12,9 → 16,7 (+3,8) |
| `auto` (ayarlı) | −6,1 / 3,5 / **13,7** | 28 | 2/24 (r3'te) | **4,5** (4,4 / 5,0 / 3,9) | 11,9 → 15,8 (+3,9) |

Denetleyici izleri (ortalama hız): 5,4 / 7,7 / 4,6 MB/sn, tavan 10,6–13,5 MB/sn, alt sınır 2,0.

| # | Ölçüt | `auto` (ayarlı) |
|---|---|---|
| 1 | her koşu medyanı ≤ 20 ms, hiçbiri > 30 ms; kötü AÇIK dilim ≤ %25 | **geçti** (−6 / 4 / 14; en kötü dilim 28; 2/24 = %8) |
| 2 | ortalama AÇIK hızı ≥ 4 MB/sn **ve** sabit 7,5'in ≥ %60'ı | **geçti** (4,5; sabitin %74'ü; ilk sürüm 3,7 idi). Not: r3 tek başına 3,9 |
| 3 | ping medyan artışı ≤ +6 ms | **geçti** (+3,9; sabit 7,5: +3,8) |
| 4 | sahte yük kapısı \|medyan\| ≤ 5 ms | **havuzlu geçti** (geçerli 16 çiftin medyanı +1,5), ama r1 geçersiz ve r3 +6,8: aşağıya bakın |
| 5 | sabit 7,5 oturumda bozulur, `auto` bozulmaz | **kanıtlanamadı**: sabit 7,5 bu oturumda yine bozulmadı (0,1 / 3,0 / 0,3) |

63. **Ayar işe yaradı:** ortalama dosya hızı 3,7 → 4,5 MB/sn (+%22) ve video etkisi sabit 7,5 MB/sn ile aynı düzeyde (koşu medyanları −6 / 4 / 14 ile 0 / 3 / 0); en iyi koşuda (r2) 5,0 MB/sn ve +3,5 ms, tavan 13,5 MB/sn. Alt sınır 2 MB/sn ile hiçbir koşu tabanda sıkışıp kalmadı (önceki turda 5/2 varyantı 8 dilimin 6'sında 0,5 MB/sn'deydi). **Dikkat:** bu iyileşme AWDL açıkken ölçüldü, öncekiyle birebir kıyas değil.
64. **Tur 3 ortam sıçramasıyla kirlendi:** sahte yük koşusunun kendisinde art arda üç dilimde +29 / +36 / +34 ms etki var (dosya yokken); aynı penceredeki `auto` koşusu +13,7 ms (2 kötü dilim) verdi, yani bu sonucun büyük kısmı ortam. Sahte yük kapısı tek tek r3'te kaldı (+6,8 > 5), havuzlu geçti.
65. **Geçerlilik kapısı bir bağlantı kopmasını yakaladı:** `r1_A` (sahte yük) başında ~35 sn bağlantı kesildi (video p95 34 s / 7,8 s / 6,4 s, 325 akış başarısız, 11 615/11 940 gönderildi) ve koşu geçersiz sayıldı (`RESULT q2 FAIL`); sahte yük tablosuna girmedi.
66. **Uyumun değeri hâlâ doğrudan kanıtlanmadı:** sabit 7,5 MB/sn iki oturumdur (AWDL kapalı 3/3, açık 3/3; önceki geçişlerde +19…+48 ms vermişti) sorunsuz çıkıyor, denetleyici sabit hızdan ~%25 daha yavaş ama aynı güvenlikte. Denetleyicinin gerçek kazancı kapasite düştüğünde ortaya çıkar; bunu doğrudan sınamak için sabit hızın bozulduğu bir oturum (ya da kapasiteyi bilerek düşüren bir koşul) gerekir. Mevcut kanıt: simülasyon (kapasite düşüşü / yükselişi / ortam sıçraması) + ölçülen güvenlik + ölçülen uyum (hız 2–13,5 MB/sn arasında oynadı, video etkisi sabit kaldı).

### İlk ölçüm (2026-11-16, tarihçe)

**Karar: KALDI (sınırda, kanıt zayıf), kullanıcı kararı 2026-11-16.** Eşik (%50 sınırda video p95 artışı ≤ 20 ms) güvenilir biçimde sağlanamadı: en iyi ayarda (burst 64 KiB, parça 64 KiB) aynı koşullar iki ayrı 3'lü blokta 20,7 ms (eşiği 0,7 ms aşıyor) ve 15,2 ms verdi; dört bloğu birleştiren 7 koşunun medyanı 15,2 ms ama 3'ü eşiğin üstünde. Ölçümün gürültü tabanı da eşiğe yakın: yalnız-video referansı 9 koşunun 2'sinde 20 ms'yi aştı (+25,1 ve +26,1 ms). Çekirdek ölçümdeki ilk "geçti" (9,5 ms) bir artefaktı (bulgu 33). **Kesin olan:** sınırlayıcı, sınırsız duruma göre gecikmeyi belirgin biçimde azaltıyor (sınırsızda 9/9 koşuda eşik aşıldı, medyan +46 ms), ve küçük burst daha iyi. Önerilen parametreler Faz 6.1'e **geçici** olarak aktarıldı; 6.1'in uçtan uca cihaz testi (gerçek kodlanmış video, hedef ≤ 120 ms) belirleyici olacak.

**Ortam.** macOS 27.2.1, quinn 0.11.12, S24, Wi-Fi `<campus Wi-Fi>` **5 GHz** (BSSID `…:47`, 802.11ac, bağlantı 780–866 Mbps, sinyal −34…−48 dBm, boşta ping ortalaması 7,4 ms). Telefon USB'de şarjda, ekran açık (betik `KEYCODE_WAKEUP` ile uyandırıyor), sıcaklık 30–37 °C (ısınma kısılması yok). **Not:** aşamanın başında telefon 2,4 GHz'e (802.11n, ~140 Mbps) düşmüştü (duman koşusu B0 = 10 MB/sn çıkardı); kullanıcı 5 GHz'e döndürdü, bütün sonuçlar 5 GHz'dedir. Duman koşusu (2,4 GHz, 5 sn'lik dilimler) yalnız düzenek doğrulaması içindi, sonuç sayılmadı.

**Düzenek.** Her koşu tek QUIC bağlantısında üç dilim: 20 sn yalnız video (taban), 60 sn video + Mac'in açık uçlu dosya akışı (bellek kipi, `BDOWN` ... `BSTOP`), 20 sn yalnız video (toparlanma). Video: 60 stream/sn × 30 KiB, telefon → Mac, stream başlığında `phase` baytı dilimi taşır. Gecikme = ham fark − **taban diliminin en küçük ham farkı** (tek referans; 0.5'teki pencere tabanı kalıcı kuyruğu gizlerdi, bu yüzden değiştirildi; self-test'te ikisinin farkı gösteriliyor). Artış = p95(yük) − p95(taban), aynı koşuda. Telefon dosyayı gerçek dosyaya yazıyor, aynı süreçte video gönderiyor. B0 = video kapalıyken sınırsız dosya akışının 30 sn'deki hızı: **26,1 MB/sn** (blok sonunda 28,3). Sınırlayıcı: Mac sunucusunda saf `TokenBucket` (hız, burst) + gönderim pompası (`asyncAfter` ile yeniden kurma).

**Sınırlayıcı doğruluğu (loopback, B0 ≈ 478 MB/sn):** hedef 10 / 50 / 200 MB/sn → ulaşılan 10,0 / 49,9 / 200,0 MB/sn (%0,2 içinde). Telefonda burst ≥ 4 × parça iken hedefin %98–100'ü (12,8–13,0 / 13,05); **burst = parça iken hedefin ~%85–87'si** (bulgu 30).

**Dört bloğun birleşik sonucu** (tek süzgeç: taban p95 ≤ 15 ms olmayan koşular elendi, 13 koşu; B0 çoğunlukla 26,1 sabit):

| Ayar | n | p95 artışı medyan | min..max | ≤ 20 ms | ulaşılan dosya hızı |
|---|---|---|---|---|---|
| A: yalnız video (gürültü tabanı) | 9 | 1,2 ms | −1,9..26,1 | 7/9 | – |
| B: sınırlayıcı kapalı | 9 | **46,0 ms** | 32,8..57,2 | **0/9** | 15,6–25,0 MB/sn |
| C: %100 × B0, 256K/64K | 2 | 30,5 | 23,8..37,2 | 0/2 | 20,3–25,9 |
| %50, burst 256K / parça 64K | 5 | 30,3 | 9,5..56,6 | 1/5 | 12,6–13,0 |
| **%50, burst 64K / parça 64K** | 7 | **15,2** | 1,5..40,5 | **4/7** | 7,3–11,2 (hedefin ~%85'i) |
| %50, 64K / 16K | 4 | 29,1 | 10,8..47,0 | 2/4 | 11,9–13,0 |
| %50, 256K / 16K | 1 | 33,2 | – | 0/1 | 13,0 |
| %50, 1 MiB / 64K ve 1 MiB / 16K | 1 + 1 | 45,4 / 53,5 | – | 0/2 | 12,3–13,0 |
| %25 (6,5 MB/sn), 64K / 64K | 3 | 7,6 | 1,8..36,7 | 2/3 | 5,6–5,7 (hedefin ~%87'si) |
| %10 (2,6 MB/sn), 64K / 64K | 3 | 21,0 | 3,2..48,3 | 1/3 | 2,2–2,4 |

Blok bazında ham sonuçlar: çekirdek (A/B/C/D × 3, B0 26,1 → 28,3): A −1,9 / 2,2 / 1,2; B 46,0 / 47,2 / 32,8; C 37,2 / 41,2 / 23,8; D 30,3 / −27,5 (taban 76,2 ms, elendi) / 9,5. Tarama (6 ayar × 2): ayar başına medyanlar yukarıdaki tabloda, ortam 8 ardışık koşuda bozuldu (taban p95 28–98 ms). Doğrulama (A, B, E1 64K/64K, E2 64K/16K, E3 256K/64K × 3, 1 gürültülü koşu otomatik tekrarlandı): A 0,0; B 38,2; E1 20,7; E2 42,3; E3 38,4. Eğri (A, B, %50, %25, %10 × 3, 3 gürültülü koşu tekrarlandı): A 25,1 (!); B 56,9; %50 15,2; %25 7,6; %10 21,0. Telefon CPU: yalnız video ~10 sn / 100 sn koşu; dosya akışı eklenince sınırsızda 22–27 sn, sınırlıda 14–25 sn.

**Önerilen parametreler (Faz 6.1'e geçici).** Hız payı: B0'ın %50'si (B0 aynı oturumda video kapalıyken ölçülür; bu telefonda 26–28 MB/sn). Burst: **64 KiB**. Gönderim parçası: **64 KiB**. Zamanlayıcı: `DispatchQueue.asyncAfter`, eksik jeton süresi kadar. Uyarılar: (1) burst = parça iken gerçek hız hedefin ~%85'i (gecikme kazancının bir kısmı bundan), (2) 256 KiB burst hızı tam veriyor ama gecikme artışı ~30 ms'ye çıkıyor, (3) %25 ve %10 anlamlı biçimde daha iyi çıkmadı, bu yüzden Faz 6.1'in %50 kararı korunur, (4) etki bant payıyla orantılı olmadığından (bulgu 32) yalnız Mac tarafı hız sınırının yeterli olduğu garanti edilmez.

**Tuhaflıklar (numaralı; 0.6'nın 28'inden devam).**
29. **Sınırsız eşzamanlı dosya akışı videoyu belirgin yavaşlatıyor:** 5 GHz'de yalnız video p95 ≈ 6–11 ms iken Mac → telefon dosya akışı eklenince p95 +33…+57 ms (9/9 koşu, medyan +46 ms; mutlak ~45–66 ms). Sınırlayıcı kapalıyken ekran/kamera yayını için kabul edilemez.
30. **Sınırlayıcı hızı burst = parça iken tutturamıyor** (telefonda hedefin ~%85–87'si): kovanın kapasitesi tek parçaya eşitken `asyncAfter` gecikmesi (1–2 ms) telafi edilemiyor. Burst ≥ 4 × parça hedefin %98–100'ünü veriyor. Faz 6.1'de ya burst ≥ 2–4 × parça ya da zamanlayıcı gecikmesini hesaba katan jeton ekleme gerekir.
31. **Küçük burst daha iyi, büyük burst kötü:** 64 KiB < 256 KiB < 1 MiB; 16 KiB'lık parça 64 KiB'dan iyi değil (daha fazla uyandırma, daha düzensiz gönderim).
32. **Gecikme artışı dosya hızıyla orantılı değil:** %10'da (2,3 MB/sn) medyan +21,0 ms (3,2..48,3), %50'den iyi değil. Telefon CPU'su da hızla orantılı değil (13 ve 20 MB/sn'de 22–27 sn). **Hipotez (ölçülmedi):** telefondaki spike istemcisi tek iş parçacıklı çalışma zamanında video gönderimini, QUIC uç noktası paket işlemeyi (gelen dosya akışının şifre çözümü) ve dosya yazımını birlikte yürütüyor; asıl darboğaz Mac'in bant payı değil telefon tarafı olabilir.
33. **Ölçümün çözünürlüğü eşiğe yakın.** Ortamda periyodik gecikme sıçramaları var: yalnız-video referansı 9 koşunun 2'sinde +25–26 ms "artış" verdi (içinde hiç dosya akışı yokken). 20 sn'lik tabanı 60 sn'lik yük dilimiyle karşılaştırmak, periyodik sıçramaları uzun dilimin yakalama ihtimalini artırarak "artışı" yukarı çekiyor; tersine tabanın sıçramasıyla "artış" aşağı gidiyor (çekirdekte D: taban 76,2 ms → −27,5 ms, ilk "geçti" bu artefakttı). Çözüm olarak sonradan "taban p95 > 15 ms ise gürültülü, tekrarla" süzgeci eklendi (temiz ortamda taban 6–10 ms); yine de 20 ms'lik eşik bu düzenekle ± birkaç ms değil, ± ~25 ms çözünürlükte.
34. **Wi-Fi bandı kaymış:** aşama başında telefon 2,4 GHz'e düşmüştü (802.11n, 130–144 Mbps, ping ort. 22 ms, B0 10 MB/sn). Bant, ölçümün doğrudan belirleyicisi; sonuçlarda her koşunun öncesi/sonrası bağlantı hızı ve sinyal kayıtlı.
35. **Düzenek dersleri:** (a) `tokio::select!` yok, video üreteci zamanlama fonksiyonuyla (`qos_phase_at`) dilimi kendisi belirliyor; (b) `BSTOP` açık uçlu akışı temiz bitiriyor (FIN ayrı boş mesajla, 0.6/bulgu 19); (c) Mac'in başlattığı akışta ilk boş akış 0,5 sn'lik bekleme getirmeye devam ediyor (bulgu 21), dosya hızından düşüldü; (d) `column` boş hücreleri kaydırıyor, tabloyu Python ile okumak gerekti.

**Test kayıtları.** `cargo test --all-targets` 3 + 7 + 10 + 17 = 37 test, `cargo clippy --all-targets -- -D warnings` temiz, `mac-server --self-test` ok (token-bucket sınırları, uzun süreli hız, referans taban ve "pencere tabanı kalıcı kuyruğu gizler / sabit taban gösterir" testleri dahil), `build-so.sh` `.so` üretiyor, Mac 142 test geçti. 0.3–0.6 gerilemesi yok: a–g ve h-up/h-down localhost, LAN ve telefonda PASS; `s-60`/`s-110` kısa koşusu (localhost) PASS.

**Kalıcı / atılabilir.** Kalıcı: `TokenBucket` tasarımı ve test vektörleri (Faz 2.5/6.1'e taşınır), önerilen parametreler ve bulgular 29–33. Atılabilir: spike kodu (`qos` senaryosu, `BDOWN` limiter alanları, `qos-bench.sh`).


---

## 0.8 Android: encoder gecikmesi

**Karar: GEÇTİ.** Üç senaryonun hepsinde kodlama gecikmesi **medyan ≤ 30 ms** (hedef ≤ 30): S1 hareketli içerik **22,2 ms**, S2 seyrek güncelleme **22,0 ms**, S3 gerçek video **20,7 ms**; kare düşmesi yok, sunum damgaları monoton, negatif gecikme yok, ısınma yok. 2026-11-18, Galaxy S24 Ultra (SM-S928B, Snapdragon 8 Gen 3), **Android 17 / API 37**, ekran 1440×3120 @ 120 Hz, donanım kodlayıcı `c2.qti.avc.encoder`.

**Düzenek.** Bağımsız, atılabilir test uygulaması `spikes/android-encoder/` (paket `dev.grkn.linktomac.spike.encoder`; Gradle 9.3.1, AGP 8.12.0, Kotlin 2.1.20, compileSdk/targetSdk 36): MediaProjection → VirtualDisplay → MediaCodec (Surface girişi, H.264 High, 1080×2340 @ 60 fps, CBR 12 Mbps, B-kare yok, I-kare aralığı 2 sn, `KEY_LOW_LATENCY=1`, `KEY_PRIORITY=0`). Gecikme = çıkış tamponunun geldiği an (`System.nanoTime()`) − tamponun `presentationTimeUs`'u (SurfaceFlinger damgası), kare başına; ilk 3 sn (S3'te 12 sn) ölçüm dışı. `run.sh` derler, kurar, başlatır, kullanıcının izin penceresine dokunmasını bekler ve sonucu çeker. Saf istatistik (`EncodeStats`) 17 JVM testiyle sınandı (iki mutasyon yakalandı). Ham veri: `docs/plans/data/2026-11-18-android-encoder-latency/` (`result-*.json`, kare başına `lat-*.csv`).

**Senaryolar.** S1: uygulama tam ekranda her karede kayan rastgele 8×8 renk blokları çizer (tekrarlanabilir, kodlayıcı için zor). S2: ekran saniyede bir değişir (her kare, ~1 sn boşluktan sonraki ilk kare: boştan uyanma gecikmesi). S3: kullanıcı başka bir uygulamada tam ekran video oynatır. (S2R: tam statik ekran + tekrar kare, yalnız bilgi amaçlı, bkz. bulgu 71.)

| Yapılandırma × senaryo | Süre | Kare | Efektif fps | Düşen | Medyan | p95 | p99 | En büyük | Anahtar kare medyanı | Sıcaklık |
|---|---|---|---|---|---|---|---|---|---|---|
| **H.264 1080×2340 @60, S1 hareketli** | 180 sn | 10 796 | 60,0 | 0 | **22,2** | 34,9 | 42,9 | 55,1 | 34,2 | 36,3 → 36,3 °C |
| **H.264, S2 seyrek (1 Hz)** | 180 sn | 181 | 1,0 | 0 | **22,0** | 25,4 | 26,4 | 27,7 | 24,0 | 36,3 → 36,3 |
| **H.264, S3 gerçek video** | 180 sn | 7 032 | 39,2 (içerik) | – | **20,7** | 33,1 | 42,1 | 50,4 | 27,7 | 33,9 → 33,9 |
| HEVC, S1 (isteğe bağlı) | 180 sn | 10 797 | 60,0 | 0 | 21,7 | 34,8 | 42,5 | 60,0 | 39,4 | 33,9 → 35,1 |
| H.264, S1, `lowLatency` + öncelik **kapalı** | 90 sn | 5 397 | 60,0 | 0 | 20,6 | 32,5 | 41,7 | 56,6 | 34,0 | 35,1 → 35,1 |

Karelerin eşik üstü payı (S1): > 30 ms %8,5, > 40 ms %2,5, > 50 ms %0; S3: %6,5 / %1,9 / %0; S2: hiçbiri. İlk dakika ile son dakika medyanı aynı (S1 22,2 → 22,2; S3 21,3 → 21,2): zamanla kayma yok. Termal durum her koşuda 0.

67. **Kapı geçti, ve sayılar tutarlı:** medyan 20,7–22,2 ms; p99 ≈ 42–43 ms (hareketli içerik), seyrek güncellemede p99 26,4 ms. **120 ms'lik uçtan uca bütçenin** kodlama payı medyanda ~%18, p99'da ~%36; kalan ~98 ms (p99 için ~77 ms) yakalama öncesi, ağ, çözme ve çizime kalır.
68. **Saat tuzağı (planı düzelttim):** `CLOCK_BOOTTIME − CLOCK_MONOTONIC` = **531 561 sn (6,15 gün)** (telefonun açıldığından beri toplam uyku). Planın yazdığı `elapsedRealtimeNanos` kullanılsaydı her gecikme 6 gün yanlış çıkardı; Surface damgası CLOCK_MONOTONIC olduğundan `System.nanoTime()` kullanıldı, fark her sonuçta `clockOffsetMs` olarak kayıtlı. Faz 4'te telefon damgalarını Mac'e taşırken de monotonik saat kullanılmalı.
69. **Kare hızı sınırı:** ekran 120 Hz üretiyor. `max-fps-to-encoder` **kayan noktalı (`setFloat`)** verilmeli; `setInteger` ile yok sayılıyor ve kodlayıcıya **120,1 fps** giriyor (o durumda medyan 25,7 ms, p99 33,3). Float ile **60,0 fps**, medyan 21,5. Faz 4'te yansıtma kare hızı bu anahtarla sınırlanabilir.
70. **Giriş yüzeyinin kare seçimi oynak:** 120 Hz kaynaktan 60 fps seçerken komşu kareler 8,3 / 16,7 / en çok 27,1 ms arayla gelir (20 sn'de 1196 karenin 63'ü 25–27 ms); gerçek bir kayıp kare ise 33,3 ms'lik boşluk demek. Düşen kare eşiği buna göre **1,8 aralık** (30 ms) seçildi (ilk denemede 1,5 ile "17 düşen kare" gösteriyordu, bunlar kare seçim oynaklığıydı, gerçek düşüş yoktu).
71. **Tam statik ekran:** `KEY_REPEAT_PREVIOUS_FRAME_AFTER=100 ms` ile tekrar kareler 100 ms arayla gelir ama **yaklaşık 1,2 sn (10 tekrar) sonra kare akışı durur**; kodlayıcı sessizleşir (S2R duman koşusu: ilk 22 kare, sonra hiç). Yani statik ekranda 3 dk'lık süreklilik ölçülemez ve alıcıda "son kare" kalır. Tekrar karelerin gecikmesi 14–47 ms (çoğu 29–31) görünür ama damgaları yapay (tekrar anı), boştan uyanmayı yansıtmaz; gerçek boştan uyanma S2'de ölçüldü (medyan 22,0, en büyük 27,7). **S2 bu yüzden "saniyede bir değişen ekran" olarak yeniden tanımlandı** (plan: "statik ekran").
72. **Kodlayıcı özellikleri:** `c2.qti.avc.encoder` ve `c2.qti.hevc.encoder` (donanım) `FEATURE_LowLatency` **desteklemiyor**; `KEY_LOW_LATENCY` + `KEY_PRIORITY=0` açık/kapalı medyan 22,2 vs 20,6 ms: ölçülebilir etkisi yok (süre farkı 180/90 sn, gürültü içinde). Faz 4'te bu ayarlar zararsız ama gecikmeyi azaltmaz.
73. **HEVC, H.264 ile aynı gecikmede:** medyan 21,7 vs 22,2, p99 42,5 vs 42,9 (en büyük 60,0 vs 55,1). HEVC aynı kalitede daha az bit demek (Faz 4 bant tasarrufu), gecikme maliyeti kodlamada yok; çözme tarafı 0.12'de.
74. **Anahtar kareler yüksek ama kuyruğun nedeni değil:** anahtar kare medyanı 34,2 ms (H.264 S1; 90 kare, %0,8) vs 22,2; anahtar kareleri çıkarınca p95 34,1 / p99 42,8 (hepsiyle 34,9 / 42,9). Yani kuyruk (karelerin %8,5'i > 30 ms) kodlayıcının genel dağılımı; ilk tahminim ("kuyruk anahtar kareler") yanlıştı.
75. **Android 17 / API 37'de MediaProjection akışı sorunsuz:** `mediaProjection` türünde ön plan servisi önce başlatılıp ardından `getMediaProjection`, `registerCallback`, `createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())` ("Tüm ekran") çalıştı. **Her ölçümde kullanıcı onayı gerekiyor** (otomatikleştirilemez); `getMediaProjection` nullable dönebiliyor.
76. **Yöntem notu:** S3'ün ilk denemesinde video başlamadığı için kare gelmedi (12 kare); tekrarında test uygulaması izin sonrası kendini arka plana alıp kullanıcıyı videoya döndürüyor ve ilk 12 sn ölçüm dışı. Gerçek video gibi içerik kare hızı farklı olan senaryolarda "düşen kare" sayılmaz (efektif fps raporlanır).

**Kalıcı / atılabilir.** Kalıcı: kapı kararı ve sayılar, bulgular 67–76, Faz 4 için öneriler (60 fps sınırı float anahtarla, HEVC gecikme maliyeti yok, monotonik saat). Atılabilir: `spikes/android-encoder/` (uygulama ve betik; `EncodeStats` fikri Faz 4'te telemetri için tekrar kullanılabilir).


---

## 0.9 Android: ses yakalama testi

**Karar: GEÇTİ (4 test edilen uygulamadan 3'ü yakalanıyor), önemli bir istisnayla: Spotify yakalanamıyor.** 2026-11-18, Galaxy S24 Ultra, Android 17 / API 37. Yakalanan: **YouTube, Chrome, Samsung Müzik**. Yakalanamayan: **Spotify** (çalıyor, ama yakalama dijital sessizlik görüyor). **YouTube Music test edilemedi** (oturum yok, oynatılamadı). Pozitif kontrol (uygulamanın kendi tonu) üç oturumda da yakalandı, yani düzenek geçerli.

**Düzenek.** Bağımsız, atılabilir test uygulaması `spikes/android-audio/` (paket `dev.grkn.linktomac.spike.audio`; Gradle 9.3.1, AGP 8.12.0, Kotlin 2.1.20, compileSdk/targetSdk 36): MediaProjection → `AudioPlaybackCaptureConfiguration` (`USAGE_MEDIA` + `USAGE_GAME` + `USAGE_UNKNOWN`) → `AudioRecord`, 48 kHz stereo PCM16, **yalnız `mediaProjection` türünde ön plan servisiyle**; her 100 ms bir seviye satırı (dBFS), **ses hiçbir yerde saklanmaz**. `run.sh` uygulamaları sırayla sürer (derin bağlantı / başlatıcı + oynat dokunuşu), oynadığını `dumpsys media_session` durumundan doğrular, medya sesini %100 → %20 → %100 yapar ve her olayı telefon saatiyle seviye dosyasına işaretler; `analyze.py` iki oturumu birleştirir. Saf ses istatistiği (`AudioStats`) 15 JVM testiyle sınandı (üç mutasyon yakalandı), analiz betiği kendi testinden geçiyor. Ham veri: `docs/plans/data/2026-11-18-android-audio-capture/`.

**Karar kuralı.** Sessizlik tabanından (10 sn, hiçbir şey çalmazken) +20 dB eşik; bir segment "yakalandı" = 100 ms pencerelerinin ≥ %80'i eşiğin üstünde ve ≥ 5 sn; "seviye değişti" = %100 ile %20 medyanları arasında ≥ 3 dB. Pozitif kontrol yakalanmazsa sonuç geçersiz.

| Uygulama | Oturum | Çaldı | Yakalandı | Medyan seviye (%100 ses) | %20 − %100 farkı | Not |
|---|---|---|---|---|---|---|
| **Spotify** | 2 | evet | **HAYIR** | **−120,0 dBFS (dijital sessizlik, pencerelerin %0'ı)** | 0,0 dB | oynatıcı `started` (AAudio, USAGE_MEDIA, hoparlör), yine de sessizlik |
| **YouTube** | 1 | evet | evet | −20,7 dBFS | +8,1 dB (içerik farkı, aşağıya bakın) | pencerelerin %100'ü eşiğin üstünde |
| **Chrome** (sabit ton) | 2 | evet | evet | −9,1 dBFS | **0,0 dB** | |
| **Samsung Müzik** (sabit ton) | 1 | evet | evet | −9,1 dBFS | **0,0 dB** | |
| YouTube Music | 1 | **hayır** | – | – | – | oturum yok, duraklatılmış kaldı: test edilemedi |
| *Kontrol: uygulamanın kendi tonu* | 1, 2, smoke | – | **evet** | −9,0 dBFS (82 pencere, %100) | – | düzenek geçerli |

Sessizlik tabanı −120 dBFS (dijital sessizlik), eşik −100 dBFS.

77. **Kapı geçti, ama dikkat edilmesi gereken iki nokta var:** 4 test edilen uygulamadan 3'ü yakalanıyor; ancak **Spotify (en yaygın müzik uygulaması) yakalanamıyor** ve **YouTube Music bilinmiyor** (test edilemedi). Faz 4.7'de "telefonun sesi Mac'e gider" vaadi uygulama bazlıdır.
78. **Spotify yakalamayı kapatıyor:** iki ayrı doğrulama: (a) medya oturumu `PLAYING(3)`; (b) ses sistemi dökümünde Spotify'ın kullanıcı kimliğine (10438) ait tek `state:started` oynatıcı: `type:AAudio`, `usage=USAGE_MEDIA`, `deviceIds:[3]` (hoparlör), 44,1 kHz stereo, `mutedState:none`. Buna rağmen yakalama üç segmentte (%100 / %20 / %100, toplam ~40 sn, 359 pencere) tam **−120 dBFS** gördü. Yakalama kapalıysa bu sessizlik biçimi güvenilir bir işaret: eşik üstü pencere oranı %0. Spotify sürümü `versionCode=148387875` (targetSdk 37).
79. **Yakalama telefonun ses seviyesinden bağımsız:** iki sabit tonlu kaynakta (Samsung Müzik, Chrome) seviye %100 → %20 → %100'de **−9,1 → −9,1 → −9,1 dBFS** (fark 0,0 dB). YouTube'da +8,1 dB'lik fark **ses değişikliğinden değil içerikten**: aynı %100 sesle ilk segment −20,7, üçüncü −14,0 dBFS (6,7 dB fark). Dolayısıyla "seviye değişti" bayrağı içeriği değişken uygulamalarda güvenilmez; karar sabit tonlu kaynaklarla verildi. Faz 4.7: telefonun medya sesi kısılsa da Mac'e tam seviyede gider (sesi Mac tarafında ayarlamak gerekir).
80. **Android 17'de yalnız `mediaProjection` türü yeterli:** `FOREGROUND_SERVICE_TYPE_MICROPHONE` eklemeye gerek olmadı; `recordingState=3`, kayıt başka uygulamalar öndeyken de kesintisiz sürdü (sessize alınmadı). Gerekli: `RECORD_AUDIO` çalışma zamanı izni (testte `adb install -g` ile), oturum başına bir MediaProjection onayı ("Tüm ekran" + "Şimdi başlat"), servisin önce başlaması ve `registerCallback`.
81. **Pozitif kontrol:** uygulamanın kendi `USAGE_MEDIA` tonu aynı uygulamanın yakalamasında duyuluyor (−9,0 dBFS, yarı genlikli sinüs için beklenen −9,03): kendi sesini yakalamak mümkün; düzenek her oturumda doğrulandı.
82. **Oynatmayı otomatikleştirmek kırılgan, bulduklarım:** `dumpsys media_session` durumu `state=PAUSED(2)` biçiminde (ad + parantezli sayı); Spotify'a medya tuşu komutu oynatmayı başlatmıyor (mini oynatıcının oynat düğmesine dokunmak gerekti, cihaza özgü piksel); Chrome'da Wi-Fi'den sunulan ton dosyasına telefon ulaşamadı (`ERR_TOO_MANY_RETRIES`), USB `adb reverse` ile `localhost` çalıştı; Chrome doğrudan ses dosyasını otomatik oynatmıyor (oynat dokunuşu gerekti). İlk oturumda bu yüzden Spotify ve Chrome "test edilemedi" çıktı ve ikinci oturumda yeniden denendi.
83. **Faz 4.7 için öneriler:** (a) "oturum `PLAYING` ama yakalama −120 dBFS" durumu Spotify gibi kapalı uygulamaları güvenilir biçimde tanır, bu durumda Mac'te "bu uygulamanın sesi yakalanamıyor" ipucu gösterilebilir (uygulamada medya oturumu zaten izleniyor, `MediaMirror`); (b) 48 kHz stereo PCM16 yakalama sorunsuz; (c) ses seviyesi bağımsız olduğundan Mac'te ayrı ses kontrolü gerekir; (d) kendi ürün sesimiz (bildirim, vs.) yakalamayı kirletmesin diye `USAGE` seçimi gözden geçirilmeli.

**Kalıcı / atılabilir.** Kalıcı: kapı kararı ve tablo, bulgular 77–83, Faz 4.7 önerileri. Atılabilir: `spikes/android-audio/` (uygulama, `run.sh`, `analyze.py`; dokunuş pikselleri bu cihaza özgü).

---

## 0.10 Android: MediaStore'a doğrudan yazma

**Karar (kullanıcı onaylı 2026-11-19): GEÇTİ. Hız, resume, hash ve görünürlük ölçütleri sağlandı; "süre sonu 6 saatlik saklamayla uyumlu" ölçütü planda yazıldığı gibi sağlanamadığı için "7 gün sabit + uygulama kendi bekleyen girdilerini temizler" olarak değiştirildi.** 2026-11-19, Galaxy S24 Ultra, Android 17 / API 37, `/storage/emulated` (FUSE) 109 GB boş. Doğrudan yazma bugünkü kopyalama yolundan çok daha ucuz ve resume bayt bayt doğru çalışıyor; ancak `DATE_EXPIRES` bu cihazda uygulamadan **değiştirilemiyor** (her zaman oluşturma anından +7 gün). Bu, planın 6 saatlik saklama varsayımını geçersiz kıldı; kullanıcı onayıyla Faz 2.3 ve 2.7 yeniden yazıldı (plan kararı 9), 2.6'nın Android yorumu ise sondaki "Açık plan netleştirmeleri"nde onay bekliyor.

**Düzenek.** Bağımsız, atılabilir test uygulaması `spikes/android-mediastore/` (paket `dev.grkn.linktomac.spike.mediastore`; Gradle 9.3.1, AGP 8.12.0, Kotlin 2.1.20, compileSdk/targetSdk 36; izin gerekmedi). Deterministik, sıkıştırılamaz test verisi (`PatternStream`: tohumlu 16 MiB bölge, ofsetten bağımsız aynı baytlar, beklenen SHA-256 her zaman yeniden hesaplanır) ve saf istatistik (`BenchStats`) **19 JVM testiyle** sınandı (üç mutasyon altı testi kırdı). Test dosyaları gerçek klasöre değil `Download/Link to Mac spike/` altına yazıldı, iş bitince silindi. Koşullar (hepsi 10 GiB, 1 MiB bloklar, sonunda `force()` dahil süre): **A** bekleyen MediaStore girdisine `openFileDescriptor(uri,"rw")` ile doğrudan yazma; **B** aynı yazıcıyla `noBackupFilesDir`'e yerel yazma; **C** bugünkü yol: B'nin dosyasını `openOutputStream` + kopyalama ile yeni bir MediaStore girdisine. Sıra A, B, A, B, C; koşular arası 30 sn. Ham veri: `docs/plans/data/2026-11-19-android-mediastore/`.

| Koşul | Koşu | Süre | Ortalama hız | Boyut sonra | Not |
|---|---|---|---|---|---|
| A: MediaStore `"rw"` | a1 | 5,2 sn | **2071 MB/s** | 10 GiB tam | SHA-256 geri okuma: **eşit** |
| B: yerel | b1 | 4,9 sn | 2175 MB/s | 10 GiB tam | |
| A: MediaStore `"rw"` | a2 | 5,1 sn | **2119 MB/s** | 10 GiB tam | |
| B: yerel | b2 | 4,6 sn | 2323 MB/s | 10 GiB tam | |
| C: bugünkü kopya | c1 | **25,3 sn** | 424 MB/s (387 / 440 / 465) | 10 GiB tam | boş yer 106,3 → 95,5 GB |

**A / B oranı: 0,93** (a1/b1 = 0,95, a2/b2 = 0,91); onaylı eşik 0,80, **geçti**.

| Resume testi | Değer |
|---|---|
| Dosya | 3 GiB, 3 çalıştırma, 2 `kill -9` (ilerleme 1024 ve 2067 MiB'ta) |
| Devam ofsetleri | 1 127 219 200 B (1075 MiB), 2 214 592 512 B (2112 MiB) |
| Sonuç | boyut tam 3 221 225 472 B, **SHA-256 eşit**, `IS_PENDING=0`, **artık bekleyen girdi yok** |
| Duman koşusu (256 MiB, tek öldürme) | dosya uzunluğu 146 485 248 B (1 MiB'ın katı değil, yani **yırtık blok vardı**), 145 752 064 B'ten devam, hash eşit |

84. **Doğrudan MediaStore yazması yerel yazmaya yakın:** A ortalaması 2095, B ortalaması 2249 MB/s, oran 0,93 (iki koşu çifti 0,95 ve 0,91). 10 GiB her koşuda 5 sn'den kısa sürdü, bu yüzden planlanan 10 sn'lik pencere serisi oluşmadı (tek pencere); "en düşük pencere" analizi yapılamadı, yalnız tüm koşu ortalaması var. Yazılan her şey `force()` ile diske gitti (dirty sayfa 136 kB). Pratik anlam: disk (~2 GB/s) ağdan (Wi-Fi ~birkaç on MB/s) 20 kat ve fazlası hızlı; alıcıda disk darboğaz olmayacak.
85. **Bugünkü kopya yolunun bedeli ölçüldü:** 10 GiB için bitişte **ek 25,3 sn** (424 MB/s; okuma + yazma) ve **ek 10,7 GB alan**: her 10 GiB yazma boş yeri 10,7 GB düşürdü, kopya yerel dosyanın üstüne 10,7 GB daha yedi, yani bitişte 2× disk doğrulandı. Doğrudan yazmada ikisi de yok.
86. **Resume Android 17'de çalışıyor:** bekleyen girdi, `MediaStore.QUERY_ARG_MATCH_PENDING = MATCH_INCLUDE` + `OWNER_PACKAGE_NAME` (kendi paketimiz) + `IS_PENDING=1` ile bulunuyor (başka uygulamanın girdisi görünmüyor/eşleşmiyor); gerçek dosya uzunluğu `statSize` ile alınıyor (SIZE sütununa güvenilmedi); `"rw"` fd + `FileChannel.position(offset)` ile `floor(uzunluk / 1 MiB) × 1 MiB`'den devam, yırtık son blok yeniden yazılıyor. **Kapsam dışı / doğrulanmadı:** güç kesilmesi veya sistem çökmesi (sayfa önbelleği kaybı) denenmedi; `kill -9` yalnız uygulama sürecini öldürür, çekirdek sayfaları yine diske yazar.
87. **Görünürlük:** `IS_PENDING=0` sonrası dosya normal dizin listesinde gerçek adıyla görünüyor (gizli `.pending…` adı kalmıyor) ve bekleyen filtresiz MediaStore sorgusu tam boyutuyla döndürüyor (`is_pending=0`, `_size=16777216`).
88. **`DATE_EXPIRES` bu cihazda uygulamadan ayarlanamıyor:** `DATE_EXPIRES` verilmeden eklenen bekleyen girdinin değeri **tam +604800 sn (7 gün)**. Açıkça verilen değer **ne ekleme ne `update` sırasında** korunuyor: 9 değer (60 sn, 1 sa, **6 sa**, 1 g, 3 g, 6 g, 7 g, 8 g, 30 g) hem ayrı `update` ile hem `IS_PENDING=1` ile birlikte `update` ile denendi, hepsinde geri okunan değer oluşturma anından +7 gün. Sonraki güncellemeler süreyi **yenilemiyor** (resume sırasında "süreyi uzat" yapılamaz). Cihaz: Samsung, Android 17; başka cihazlarda/AOSP'de davranışın aynı olduğu doğrulanmadı.
89. **Süre sonu silmesi gözlenemedi:** MediaProvider modülünün günlük bakım işi (`IdleService`, iş no −200) kabuktan `cmd jobscheduler run -f` ile **tetiklenebildi** (`Running job [FORCED]`); süresi dolmamış iki bekleyen girdi (küçük dosyalı) bu işten **sağ çıktı**. Süresi dolmuş bir girdi üretilemedi: kabuğun `content query/update` komutları bekleyen satırları görmüyor, saati değiştirmek geri alınması zor olduğundan denenmedi. Yani "7 gün sonra girdi + dosya silinir" **doğrulanmadı**.
90. **Faz 2 için sonuç:** (a) doğrudan MediaStore yazmasıyla bitiş kopyası ve **2× alan rezervasyonu kalkabilir**: gereken boş yer yalnız `size − have` (+ pay); (b) bekleyen girdi **7 gün** yaşıyor, ayarlanamıyor ve yenilenemiyor: bu resume penceresi için cömert (planın 10 dk / 6 sa varsayımlarından uzun), ama terk edilmiş 10 GB'lık bekleyen bir dosya Dosyalar'da görünmeden 7 güne kadar yer kaplayabilir; bu yüzden uygulama **kendi bekleyen girdilerini kendisi temizlemeli** (başlangıçta ve bir aktarım kesin başarısız / iptal olunca, izlenmeyen kendi `IS_PENDING=1` girdilerini sil; kullanıcıya tek tıkla "yarım kalanları sil" yolu).

**Kalıcı / atılabilir.** Kalıcı: kapı kararı, tablolar, bulgular 84–90 ve Faz 2 kararı (2.3/2.7 yeniden yazıldı). Atılabilir: `spikes/android-mediastore/` (uygulama, `run.sh`).

---

## 0.11 Mac: boş CMIO Camera Extension

**Karar: GEÇTİ.** 2026-11-19, MacBook Air (Apple Silicon), macOS 27.2.1, SIP açık, Xcode 27.2. Hesaptan System Extension yetenekli bir **Developer ID profili alınabildi**, imzalı paket **notarize edildi (Accepted)**, uzantı `/Applications`'tan **kuruldu ve etkinleşti**, "Link To Mac Kamera" kamera listesinde göründü, frame'ler **doğru renkte ve 30 fps akıyor** (komutla ölçüm + sizin FaceTime onayınız), kaldırma çalıştı. Faz 5 donmuyor.

**Düzenek.** Bağımsız, atılabilir spike `spikes/mac-camera-ext/` (XcodeGen; paket `dev.grkn.LinkToMac.CameraSpike`, uzantı `dev.grkn.LinkToMac.CameraSpike.Extension`; gerçek `LinkToMac.app`'ten ayrı kimlikler). Saf mantık `ColorCycle` (altı doygun renk, saniyede bir değişir; BGRA doldurma; kayma yapmayan zaman damgası; yakalanan rengi palete eşleme) **17 swift-testing testiyle** sınandı (üç mutasyon 23 sorunla yakalandı). Uzantı: `CMIOExtensionProvider` + aygıt + tek source stream (1280×720, 30 fps, `32BGRA`, sabit UUID). Ana uygulama: `--install`, `--uninstall`, `--grab <png> [sn]` (AVFoundation ile frame okur, ortalama rengi paletle karşılaştırır). `build.sh` içten dışa imza + notarize (repodaki `build-release.sh` kalıbı), `run.sh` kurulum/durum/ölçüm/kaldırma/temizlik. Doğrulama ölçütü: ≥ 30 frame, karelerin ≥ %95'i palet rengine ≤ 40 RGB uzaklıkta, ≥ 2 renk, renk sırası palet sırasında. Ham veri: `docs/plans/data/2026-11-19-mac-camera-extension/`.

| Adım | Sonuç |
|---|---|
| Profil | **alındı** (portalda elle): Developer ID, platform OSX, `ProvisionsAllDevices`, bitiş 2044-11-14; yetkiler `application-identifier`, `system-extension.install`, `team-identifier`, `keychain-access-groups` |
| Derleme + imza | Release, imzasız derleme + içten dışa `codesign` (`--options runtime --timestamp`); `codesign --verify --deep --strict` temiz; yetkiler ve hardened runtime (`flags=0x10000(runtime)`) iki pakette doğrulandı |
| Notarize | `notarytool` **Accepted** (id `<submission-id>`), `stapler` ve `spctl` ("Notarized Developer ID") kabul |
| Etkinleştirme | `/Applications`'tan `--install` → `NEEDS_USER_APPROVAL` → siz Sistem Ayarları ▸ Kamera Uzantıları'nda açınca `RESULT completed`; `systemextensionsctl`: `[activated waiting for user]` → `[activated enabled]` |
| Görünürlük | `system_profiler SPCameraDataType` ve AVFoundation "Link To Mac Kamera"yı listeledi (Model ID "Link To Mac Camera Spike", Unique ID = sabit UUID) |
| Piksel ölçümü (`--grab 6`) | **188 frame / 6 sn (30,5 fps), karelerin %100'ü eşleşti, en büyük sapma 0,0**; renk sırası 0→1→2→3→4→5→0, her renk tam 30 frame (ilk koşu 28: akış saniyenin ortasında başladı) |
| FaceTime | kullanıcı onayı: renkler beklenen düzende görünüyor (kamera izni sorulmadı: FaceTime'a daha önce verilmişti) |
| Kaldırma | `--uninstall` ~4 sn'de, parolasız `completed`; kamera listeden **hemen** çıktı; sistem kaydı `[terminated waiting to uninstall on reboot]` |

91. **Profil alma yolu ve gerekenler:** (a) portalda **explicit App ID** + yetenek **System Extension**; (b) Profiles ▸ Distribution ▸ **Developer ID**, bu App ID ve mevcut `Developer ID Application` sertifikası; (c) indirilen `.provisionprofile` yalnız **ana uygulamanın** `Contents/embedded.provisionprofile` yerine gömülür. Uygulama kimliği `<TEAMID>.<bundle id>`. Profil `build.sh` içinde derlemeden önce `security cms -D` ile denetlenir (kimlik, `system-extension.install`, `ProvisionsAllDevices`, geçerlilik); ilgisiz bir iOS profili üç gerekçeyle ve derleme başlamadan reddedildi (olumsuz test).
92. **OBS düzeni birebir işledi:** **uzantıda profil yok**; uzantı yalnız Developer ID + hardened runtime + `app-sandbox` + takım önekli `application-groups [<TEAMID>.dev.grkn.LinkToMac.CameraSpike]` ile imzalı; Mach servis adı (`CMIOExtensionMachServiceName`) bu grubun öneki ile başlıyor (`<TEAMID>.dev.grkn.LinkToMac.CameraSpike.Extension`). Ana uygulama yetkileri: `system-extension.install`, `com.apple.application-identifier`, `com.apple.developer.team-identifier` (ikisi profille eşleşmeli), `device.camera` (yalnız `--grab` için). Uzantı için ikinci profil gerekmedi.
93. **Araç zinciri:** XcodeGen `type: system-extension` bağımlılığı `embed: true` ile uzantıyı doğrudan `Contents/Library/SystemExtensions/` altına koyuyor (yedek aşama gerekmedi). `PRODUCT_NAME` bundle id'ye eşit olmalı (paket `<id>.systemextension` adlı). İmzalı derleme **Release** ve `ENABLE_DEBUG_DYLIB=NO ENABLE_PREVIEWS=NO` olmalı (Debug'da `__preview.dylib` ve `.debug.dylib` giriyor). Host ve uzantı **Swift 5 modunda** derlendi (CoreMediaIO, SystemExtensions ve AVFoundation delege protokolleri Sendable değil); plandaki "uyarısız Swift 6" bu iki hedef için uygulanmadı, saf mantık Swift 6 strict'te test edildi. Tek derleme uyarısı bilerek bırakılan `AVCaptureDevice.devices(for:)` yedeği.
94. **İki tuzak (Faz 5.4 `build-release.sh` için):** (a) entitlements plist'inde **XML yorumunun içinde `--` varsa AMFI ayrıştırması reddediyor** (`AMFIUnserializeXML: syntax error`), `plutil -lint` ise kabul ediyor; (b) `codesign … | grep -q` `set -o pipefail` altında yarışıyor (SIGPIPE), çıktı önce değişkene alınmalı (`build-release.sh` yorumu aynı şeyi söylüyor).
95. **Etkinleştirme akışı:** host `/Applications/…/Contents/MacOS/…` ikilisi terminalden doğrudan çalıştırıldı (`open` gerekmedi). İstek `requestNeedsUserApproval` ile bekler; Sistem Ayarları'nda "Kamera Uzantıları" altında anahtar açılınca tamamlandı (insan süresi ~1,5 dk), **parola istenmedi**. `systemextensionsctl developer on` SIP açıkken kullanılamıyor; Developer ID + notarize + `/Applications` yolu tek seçenek ve çalışıyor.
96. **Kamera okuma izni** yalnız host için gerekti (`--grab` ilk çalışmada TCC istemi, "İzin Ver"); FaceTime gibi uygulamalar uzantıyı ayrı bir izin olmadan gördü (izin zaten vardı).
97. **Kaldırma davranışı:** `deactivationRequest` hızlı ve parolasız; kamera aygıtı hemen kayboluyor; ama uzantı kaydı **yeniden başlatmaya kadar** `[terminated waiting to uninstall on reboot]` kalıyor. Kaldırma sırasında FaceTime açıktı ve kamerayı kullanabilirdi; bu durumun nedeni **ayırt edilmedi** (FaceTime kapalıyken kaldırma denenmedi). Yeniden başlatma yapılmadı (sizden istemeden yapmam).
98. **Faz 5.3 / 5.4 için çıkarılan kurallar:** (a) gerçek `dev.grkn.LinkToMac` için ayrı bir **explicit App ID + System Extension yeteneği + Developer ID profili** gerekir (bu spike ayrı kimlikle yapıldı; hesabın yetkisini kanıtlar, gerçek kimlik henüz kaydedilmedi); (b) `mac/Resources/LinkToMac.entitlements` bugün yalnız Bluetooth içeriyor, `build-release.sh` profili gömmeli ve `system-extension.install`, `com.apple.application-identifier`, `com.apple.developer.team-identifier` yetkilerini eklemeli; uzantı kendi yetkileriyle, profilsiz ve **uygulamadan önce** imzalanmalı; (c) gerçek uygulamanın bugünkü gömülü Share uzantısı ve Sparkle ile imza sırası korunmalı (içten dışa, `--deep` yok); (d) kullanıcıya "kamera kapatıldı, kayıt yeniden başlatmada silinir" durumu açıkça gösterilmeli; (e) kamera kimliği için sabit UUID kullanılmalı.
99. **Doğrulanmayanlar:** `/Applications` **dışından** etkinleştirme; kaldırma beklerken (yeniden başlatmadan) aynı kimliği yeniden kurma; macOS 27.2.1 dışındaki sürümler (planın minimumu 14.0); FaceTime ve AVFoundation dışındaki istemciler (Zoom, Meet, Chrome); sink stream, ağsız sandbox altında uzun süreli çalışma ve bellek/CPU maliyeti; başka bir Mac'te (temiz, farklı hesap) kurulum.

**Kalıcı / atılabilir.** Kalıcı: kapı kararı, tablo, bulgular 91–99 ve Faz 5.3/5.4 kuralları. Atılabilir: `spikes/mac-camera-ext/` (kod, `build.sh`, `run.sh`); Apple hesabındaki `dev.grkn.LinkToMac.CameraSpike` App ID'si ve "Link To Mac Camera Spike DevID" profili isteğe bağlı olarak portaldan silinebilir; `~/Downloads/Link_To_Mac_Camera_Spike_DevID.provisionprofile` dosyası yerinde duruyor.

---

## Karar kapıları

| Kapı | Sonuç | Sayı / gerekçe |
|---|---|---|
| Interop + kalıcı kimlik | **GEÇTİ** | 0.1 quinn build zinciri (cargo-ndk, JNI ping); 0.2 elle DER self-signed P-256 sertifika (295 bayt) Keychain'de kalıcı, parmak izi CryptoKit = Rust = openssl; 0.3 üç ortamda (localhost, LAN, telefon Wi-Fi) senaryolar PASS, el sıkışma 94 / 75 / 195 ms, yanlış `fp` reddedilir, 3 × 1 MiB SHA-256 eşit; 8 tuhaflık, hiçbiri engelleyici değil. Mac'te quinn + uniffi yedeği gerekmedi |
| Mac'te DATAGRAM | **GEÇTİ** | Swift API yeterli, C/Obj-C shim gerekmedi: `group.extract(connectionTo: nil, using: isDatagram)`; her yönde 3000/3000, bozuk/yinelenen/sırasız 0, üç ortamda (telefon dahil); `usableDatagramFrameSize` 1440, quinn `max_datagram_size` 1191. **Sınırlama:** hafif yükte (17,5 kB/sn) ölçüldü; ses + video birlikte yük altında Faz 4'te yeniden ölçülür (0.4 bulgu 9: `group.send` ile deneme sessizce kaybolur) |
| stream/sn (60 yalnız video; ~110 video + ses) | **s-60 GEÇTİ, s-110 KALDI** | Telefon s-60: p99 video 11,9 ms (< 20), kayıp 0. Telefon s-110: p99 video 30,5 ms, ses 34,4 ms (eşik 20 ms ✗); Mac host s-110 geçti, CPU/bellek/kayıp s-110'da da eşiklerin içinde. Kullanıcı kararı 2026-11-15: **KALDI olarak kaydedilir**, eşik değişmez |
| 10 GB hız | **GEÇTİ** | 1 GiB × 3 medyan: telefon → Mac QUIC 22,5 vs WS 11,1 MB/sn (2,0×), Mac → telefon 22,5 vs 16,5 (1,4×); tüm SHA-256 eşit. **Sınırlama:** WS ile 10 GB gönderilemediği için karar 1 GiB medyanlarıyla; 10 GiB'ta QUIC ortalama 14,0 / 14,5 MB/sn (telefon ısındıkça düşüyor) |
| Mac QoS (0.7) | **KABUL (uyumlu denetleyici); kriter 5 kanıtsız** | Sabit sınırlayıcı güvenilmez (aynı hız bir koşuda +6 ms, ötekinde +48 ms); gecikmeye bağlı `DelayRateController` (taban 2 MB/sn) seçildi (plan kararı 8); ayarlı turda video etkisi sabit 7,5 MB/sn sınırlayıcıya benziyor, **ama kriter 5 (uzun süreli etki) kanıtsız**; Faz 6.1'de ölçülecek; 0.7 bulgular 36–66 |
| Encode ≤ 30 ms | **GEÇTİ** | medyan 22,2 / 22,0 / 20,7 ms (hareketli / seyrek / gerçek video), p95 25–35, p99 26–43, düşen kare 0; HEVC aynı (21,7); 0.8 bulgular 67–76 |
| Popüler uygulama ses yakalama | **GEÇTİ (3/4)** | YouTube, Chrome, Samsung Müzik yakalandı; **Spotify yakalanamıyor** (çalıyor ama −120 dBFS); YouTube Music test edilemedi (oturum yok); yakalama ses seviyesinden bağımsız (0,0 dB); yalnız `mediaProjection` FGS türü yeterli; 0.9 bulgular 77–83 |
| MediaStore doğrudan yazma | **GEÇTİ** (6 saatlik saklama ayarlanamıyor; ölçüt kullanıcı onayıyla "7 gün sabit + uygulama kendi temizliği" oldu) | A/B = 0,93 (2095 / 2249 MB/s, eşik 0,80); bugünkü kopya 10 GiB'ta +25,3 sn ve +10,7 GB; resume 3 GiB, 2 öldürme, SHA-256 eşit; `DATE_EXPIRES` her zaman +7 gün, ayarlanamaz/yenilenemez; 0.10 bulgular 84–90 |
| Camera Extension | **GEÇTİ** | Developer ID profili alındı (System Extension), `notarytool` Accepted, uzantı etkinleşti, "Link To Mac Kamera" listelendi; 188 frame / 6 sn (30,5 fps), %100 renk eşleşmesi, sapma 0,0; FaceTime'da renkler doğru sırada; kaldırma çalıştı (kayıt yeniden başlatmaya kadar kalır); 0.11 bulgular 91–99 |
