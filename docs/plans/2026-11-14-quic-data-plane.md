# QUIC veri düzlemi: aşama aşama uygulama planı

> **Durum (2026-11-19):** **Faz 0 tamamlandı** (ölçümler 0.1–0.11, kapı kararları 0.12, spike arşivi ve regresyon 0.13; sonuç: `2026-11-14-quic-faz0-sonuclar.md`); kalıcı parçalar `feat/quic-foundation` dalında, spike kodu `archive/quic-faz0` etiketinde; Faz 1'e başlanabilir. Plan netleştirmeleri onaylandı (sondaki "Onaylanan plan kararları"). Kaynak: Claude Docs "Link To Mac — QUIC geçiş ve uygulama planı"
> (rev 140). Bu dosya o planın uygulanabilir, aşamalara bölünmüş hâli. Çalışma kuralları kökteki
> [`CLAUDE.md`](../../CLAUDE.md) ▸ "QUIC veri düzlemi: plan tabanlı çalışma" bölümünde; **her aşamada uygulanır.**

## Nasıl okunur, kutucuklar

- `## [ ] Faz N` = faz, `### [ ] N.M` = aşama. `[ ]` = bitmedi, `[x]` = bitti **ve testleri geçti**.
- Aşama bitince kendi kutucuğu, faz bitince (faz genel testi geçince) faz başlığındaki kutucuk `[x]` yapılır.
- Her aşama şu başlıkları taşır: **Amaç · Yapılacaklar · Dosyalar · Testler (beklenen sonuç) · Bitti ölçütü.**
  Aşama, işi yapmak için gereken her ayrıntıyı kendi içinde barındırır; başka aşamaya yalnız bağımlılık için atıf yapar.
- **Okuma kuralı:** `[x]` olan aşamalar yalnız başlıklarıyla okunur. Başlanmamış aşamalardan yalnız sıradaki ayrıntılı
  okunur, sonrakilere bakılmaz.
- Plan dışına çıkmak yalnız kullanıcı onayıyla olur; onaydan sonra önce ilgili aşama bu dosyada yeniden yazılır.

## Referans: hedef ve mimari (bir kez okunur)

**Hedef.** Mevcut WebSocket katmanı (relay + LAN-direct) kontrol düzlemi olarak aynen kalır. QUIC yalnız LAN'da ağır veri
taşıyan ek bir veri düzlemidir: büyük dosya, ekran, ses, kamera, mikrofon. QUIC oturumu mevcut E2E şifreli kanaldan giden
bir `cmd` ile açılır; ikinci pairing, QR ya da mDNS yoktur. Relay kalıcıdır.

**Kapsam dışı.** Yeni özellikler shell UID kullanmaz (mevcut ClipboardAgent aynen kalır). Kontrol düzlemi protobuf'a
taşınmaz. Ertelenenler: arama sesini Mac'e taşımak (Bluetooth HFP), LAN dışında ekran yansıtma, Samsung'da arama
bildirimini gönderen paketin doğrulanması (Faz 7'ye başlarken).

**Başarı kriterleri (S24 Ultra ↔ MacBook Air M4).** Dosya: LAN'da boyut sınırı yok, resume, Files ekranı ve geçmiş aynen
(LAN: QUIC, relay: mevcut WS yolu ve 1 GiB sınırı). Ekran: 1080p 60 fps, uçtan uca ≤ 120 ms (yalnız LAN). Ses: ≤ 150 ms,
%2 kayıpta duyulur kopma yok (yalnız LAN). Kamera/mikrofon: Mac'te sistem cihazı olarak görünür (yalnız LAN). Arama:
başlat/cevapla/kapat, ses telefonda (LAN + relay). Mevcut özellikler değişmez. Gecikme hedefleri Faz 0 ölçümlerinden sonra **değişmedi** (0.12): kodlama payı medyanda ~%18 (22 ms), telefonda s-60 p99 11,9 ms; ses hedefi DATAGRAM'ın ses + video birlikte yük altındaki ölçümüne bağlı, Faz 4'te doğrulanır.

**Oturum açılışı.** Bir taraf `cmd` ile `q.req {kind: cast|file|audio|cam, sid}` gönderir. Aktif link LAN-direct değilse
istek reddedilir (1 GiB'a kadar dosya WS'ye düşer, daha büyüğü LAN'ı bekler, medya "aynı Wi-Fi gerekli" der). Mac UDP
dinleyicisini açar (Mac isteyen taraf ise önce telefon kullanıcı onayıyla `q.accept` gönderir; telefon isteyen taraf ise Mac doğrudan devam eder; varsayılan port 53125), Keychain'deki kalıcı self-signed kimlikle `q.offer {sid, port, fp, tok}` döner. IP
gönderilmez; telefon LAN-direct bağlantısının adresini kullanır. Telefon bağlanır, sertifikayı `fp` ile doğrular, ilk
stream'de `tok`'u gönderir. Oturum bitince ya da 30 sn boşta kalınca bağlantı ve dinleyici kapanır. Güven mevcut E2E
kanaldan gelir (ChaCha20-Poly1305 + AAD + ±120 sn tazelik + nonce cache); QUIC verisini TLS 1.3 şifreler.

**Uygulama.** Mac: Network.framework `NWProtocolQUIC` (`NWConnectionGroup`, `sec_protocol_options`), yeni bağımlılık yok.
Android: Rust `quinn`, JNI ile `selfadb` modülüne bağlı. Yedek: Network.framework ↔ quinn uyumu tutmazsa Mac'te de quinn +
uniffi. Network.framework kısıtları (Apple DTS forum yanıtları): QUIC stream önceliği yok (thread 766697); istatistik
olarak yalnız RTT ve yeniden iletilen bayt (cwnd yok); Swift API'sinde DATAGRAM'ı engelleyen bir hata bildirildi (r.
149070093, thread 780379); her stream ayrı bir `NWConnection`. Son üçü Faz 0'da ölçülür.

**Kanallar.** Her veri stream'i ilk varint ile tipini bildirir: `0x01` dosya (bidi), `0x02` ekran (uni), `0x03` kamera (uni). Keyframe isteği, bitrate
ve oturum sonu için tek bir bidi oturum stream'i vardır. Ses taşıması Faz 0 sonucuna göre seçilir (Faz 4). Network.framework bulguları (0.3): Mac bağlantıyı karşı tarafa kapattıramaz (sonlandırma ve reddetme protokol içinde, 1.6/3.2); Mac'in başlattığı stream'lerde çerçevenin boş stream'i vardır (2.2). **Pil:** oturum
yokken QUIC bağlantısı yok, WS'nin 50 sn ping'i değişmez; oturum boyunca keep-alive 5 sn. **RN sınırı:** RN yalnız UI ve
olayları görür; medya ve dosya baytları Kotlin ↔ Rust arasında kalır.

**Yerleşim.** Mac: `mac/Sources/LinkToMac/Quic/`. Android: `selfadb` modülünde `quic/` Kotlin paketi, Rust crate'i
`mobile/native-src/quic-core/` (mevcut `clipboard-agent/` düzenine uyar; karar 0.1'de netleşir). Vektörler:
`protocol-vectors/`. Faz 0 sonuç kaydı: `docs/plans/2026-11-14-quic-faz0-sonuclar.md`.

**Test komutları (her aşamada ilgili olanlar çalışır).**

| Bileşen | Komut |
|---|---|
| Mac | `cd mac && xcodegen generate && xcodebuild -project LinkToMac.xcodeproj -scheme LinkToMac -destination 'platform=macOS' test` |
| Android JVM | `cd mobile/android && ./gradlew :selfadb:testDebugUnitTest` |
| Mobil JS | `cd mobile && bun run lint && npx tsc --noEmit && bun run test` |
| Rust çekirdek | `cd mobile/native-src/quic-core && cargo test && cargo clippy -- -D warnings` |
| Relay (yalnız dokunulursa) | `cd server && npm run typecheck`, `npm run dev` açıkken `npm run smoke` |
| Cihaz | S24 dev client: `cd mobile && bun run android`; Mac: Xcode Run |

**Faz sırası.** 0 Spike'lar (S–M) → 1 QUIC iskeleti ve iki yönlü `cmd` (M) → 2 LAN'da sınırsız dosya (M) → 3 Ekran
yansıtma (L) → 4 Android sesi (M) → 5 Sanal kamera 5a + mikrofon 5b (L + L) → 6 Sağlamlaştırma (S–M) → 7 Mac'ten arama
kontrolü (S–M). Faz 1, QUIC kullanan tüm fazlardan (2–5) ve `cmd` kullanan Faz 7'den önce gelir. Faz 4, Faz 3'ün
MediaProjection oturumunu kullanır. 5a Faz 3'e, 5b Faz 4'e dayanır. Faz 7 yalnız Faz 1'e bağlıdır.

---

## [x] Faz 0 — Spike'lar ve karar kapıları

En riskli varsayımlar, mimarinin üzerine inşa edilmeden önce çalışan kodla doğrulanır. Büyüklük: **S–M**. Spike kodu
atılabilirdi ve **`archive/quic-faz0` etiketinde** arşivlendi; ana dala giden (`feat/quic-foundation`, 0.13) **ölçüm sonuçları** (sonuç dosyası ve ham veri) ile üretim
kalitesindeki parçalardır: `quic-core` crate'i, `QuicCore.kt`, 0.2'nin kimliği ve DER yazıcısı (Faz 1.6'ya taşınır), `DelayRateController`. Her aşamanın sonucu `docs/plans/2026-11-14-quic-faz0-sonuclar.md` dosyasına tarih,
cihaz/macOS/Android sürümü ve ham sayılarla yazılır.

### [x] 0.1 Android: quinn build zinciri (cargo-ndk + JNI "ping")

**Amaç.** quinn'i arm64-v8a için derleyip `selfadb` modülünden çağırabildiğimizi göstermek; sonraki tüm Android spike'larının
ve Faz 1.7'nin zemini. Ağ trafiği yok; yalnız "derlenir, paketlenir, cihazda yüklenir ve çağrılır" kanıtı.

**Kararlar (kullanıcı onaylı, 2026-11-14).** `libquic_core.so` **commit edilmez**; `build-so.sh` ile üretilir (`jniLibs/` ve cargo
`target/` gitignore'a girer). Gradle eksik `.so` için **uyarı** basar, derlemeyi başarısız yapmaz (Rust'sız dev client derlenebilsin;
QUIC o derlemede yok sayılır). Spike kodu `spike/quic-faz0` dalında çalışılır. Release almadan önce `build-so.sh` çalıştırılır.

**Yapılacaklar.**
1. `rustup target add aarch64-linux-android`, `cargo install cargo-ndk --locked`. NDK sürümü Gradle'ınkiyle aynı olmalı:
   `node_modules/react-native/gradle/libs.versions.toml` içindeki `ndkVersion` (27.1.12297006); `build-so.sh` bunu oradan okur ve
   `ANDROID_NDK_HOME`'u ayarlar. Sürümler sonuç dosyasına yazılır.
2. Crate: `mobile/native-src/quic-core/` (mevcut `clipboard-agent/` düzenine uyar). `crate-type = ["cdylib", "rlib"]`; bağımlılıklar:
   `quinn` (`default-features = false`, `runtime-tokio` + `rustls-ring`; **`aws-lc-rs` kullanılmaz**, NDK'da cmake/NASM ister),
   `rustls` (ring, quinn'in sürümüyle aynı), `tokio` (`rt`, `net`, `time`), `jni`, `sha2`, `subtle`. Release profili: `lto = "thin"`,
   `codegen-units = 1`, `strip = true`, `panic = "unwind"` (JNI sınırında `catch_unwind`). `Cargo.lock` commit edilir.
3. `src/lib.rs`: `pub fn ping() -> String` ("pong quic-core <sürüm> quinn <sürüm>"); **`pub fn probe() -> Result<String, String>`**:
   tokio runtime kurup `quinn::Endpoint::client` ile bir UDP soketi açıp kapatır (quinn + ring + tokio'nun cihazda gerçekten
   çalıştığını kanıtlar; hata metni adres/port içermez). JNI girişleri `Java_expo_modules_selfadb_quic_QuicCore_nativePing` ve
   `..._nativeProbe` (`extern "system"`, `catch_unwind` ile sarılı).
4. `build-so.sh` (`build-dex.sh` biçimi, tek komut): ön kontroller (`cargo`, `cargo-ndk`, `aarch64-linux-android` hedefi), `cargo ndk
   -t arm64-v8a --platform 30 -o ../../modules/selfadb/android/src/main/jniLibs build --release` (`--platform 30` = minSdk; **minSdk
   artık dört yerde eşleşmeli**), bitişte `.so` boyutu ve `llvm-nm -D` ile iki JNI sembolünün doğrulanması.
5. Kotlin: `.../selfadb/quic/QuicCore.kt` (saf `object`): `isAvailable()` (lazy `System.loadLibrary("quic_core")`,
   `UnsatisfiedLinkError` yakalanır → `false`), `ping()`/`probe()` (`String?`), `@JvmStatic private external` yerel girişler.
   Geçici debug çağrısı: `SelfAdbModule`'de yalnız `FLAG_DEBUGGABLE` derlemede `quicPing`; JS tarafında `__DEV__` Settings ▸ Developer
   altında geçici "QUIC core ping" satırı.
6. **`abiFilters` eklenmez** (önceki taslağın aksine): kütüphane modüllerinde `ndk.abiFilters` etkisizdir, filtre uygulama düzeyindedir
   ve oraya dokunmak React Native'in tüm ABI'lerini etkilerdi. Yalnız `arm64-v8a/libquic_core.so` üretilir; korumalı yükleme (madde 5)
   x86_64 emülatörde ve `.so`'suz derlemede çökmeyi önler. `checkQuicCoreSo` Gradle görevi `.so` yoksa uyarı basar (`preBuild`'e bağlı).
7. Aynı değişiklikte dokümantasyon: `mobile/CLAUDE.md` (Commands, Layout, minSdk notu, "`.so` commit edilmez").

**Dosyalar.** `mobile/native-src/quic-core/{Cargo.toml,Cargo.lock,src/lib.rs,build-so.sh}`, `.gitignore`,
`mobile/modules/selfadb/android/build.gradle`, `.../quic/QuicCore.kt`, `.../SelfAdbModule.kt` (debug), `modules/selfadb/src/SelfAdb.ts`,
`mobile/src/app/settings.tsx` (geçici), `.../src/test/.../QuicCoreFallbackTest.kt`, `docs/plans/2026-11-14-quic-faz0-sonuclar.md`.
**Kalıcı olanlar** (Faz 1.7'nin temeli, spike dalıyla ana dala alınır): crate iskeleti, `build-so.sh`, `QuicCore.kt`, Gradle uyarısı,
`.gitignore` satırları. **Atılabilir olanlar:** `quicPing` AsyncFunction'ı ve Settings'teki geçici satır.

**Testler (beklenen sonuç).**
- `.so` yokken `./gradlew :selfadb:checkQuicCoreSo` uyarı basar ve başarılı olur.
- `cargo test` geçer (`ping` ve `probe` birim testleri); `cargo clippy -- -D warnings` temiz.
- `./build-so.sh` hatasız biter; `.so` oluşur; `llvm-nm -D` iki JNI sembolünü gösterir; boyut ve sürümler sonuç dosyasında.
- `./gradlew :selfadb:testDebugUnitTest` yeşil (`QuicCoreFallbackTest`: JVM'de yerel kütüphane yok → `isAvailable() == false`,
  `ping()`/`probe()` `null`, istisna yok).
- Debug APK'da `unzip -l` ile `lib/arm64-v8a/libquic_core.so` görülür.
- S24 dev client'ta "QUIC core ping" **"pong quic-core ... quinn ..." ve "probe ok"** gösterir (çökme ve `UnsatisfiedLinkError` yok).
  Cihaz yoksa bu adım beklemede kalır, aşama `[x]` olmaz.
- `bun run lint`, `npx tsc --noEmit`, `bun run test` temiz; mevcut özellikler regresyonsuz.

**Bitti ölçütü.** S24'te JNI üzerinden Rust fonksiyonu çalışıyor (`ping` + `probe`); build komutu, NDK/sürüm bilgisi ve `.so` kararı yazılı.

### [x] 0.2 Mac: kalıcı kimlik (P-256 + elle DER self-signed + SecIdentity)

**Amaç.** Network.framework sunucusunun ihtiyaç duyduğu `SecIdentity`'yi, yeni bağımlılık eklemeden üretebildiğimizi göstermek.
macOS'ta X.509 üretmek için public API yok (yalnız ayrıştırma var) ve `SecIdentity` anahtarın Keychain'de olmasını ister.
TLS/ağ yok; kimlik 0.3 (interop) ve Faz 1.6'da (`QuicListener`) kullanılacak.

**Yapılacaklar.**
1. `mac/Sources/LinkToMac/Quic/DERWriter.swift` (kalıcı kod; spike dalında başlar, Faz 1.6'ya taşınır): `enum DER` (uzunluk, INTEGER,
   OID, UTF8String, UTCTime, BIT STRING, SET/SEQUENCE, `[n] EXPLICIT`) ve `enum SelfSignedCertificate` (`tbs`, `make`). **Sertifika yapımı
   Keychain'den ayrıdır:** imza bir kapanışla (`sign: (Data) throws -> Data`) verilir, böylece CryptoKit ya da kalıcı olmayan `SecKey`
   ile hermetik test edilir.
2. `mac/Sources/LinkToMac/Quic/QuicIdentity.swift`: anahtar, Keychain, kimlik, parmak izi. Anahtar: `SecKeyCreateRandomKey` ile P-256,
   Keychain'de kalıcı (`kSecAttrIsPermanent`), etiket `dev.grkn.LinkToMac/quic-identity`.
3. Sertifika (elle DER): TBSCertificate (v3, rastgele pozitif 16 bayt seri numarası, imza algoritması ecdsa-with-SHA256 (parametre yok),
   issuer = subject `CN=LinkToMac`, geçerlilik now−1 gün … +10 yıl, SPKI = `SecKeyCopyExternalRepresentation` çıktısı (X9.63 nokta)
   id-ecPublicKey + prime256v1 OID ile sarılmış, uzantı yok). İmza: `SecKeyCreateSignature(.ecdsaSignatureMessageX962SHA256)`
   (çıktı zaten DER ECDSA-Sig-Value). `swift-certificates` **eklenmez**.
4. `SecCertificateCreateWithData` → `SecItemAdd` → `SecIdentity` geri okuma. **Bulgu (2026-11-14, testlerle bulundu, kullanıcı onaylı):** macOS dosya tabanlı
   keychain'de sertifikanın etiketi konu CN'inden türetilir (`kSecAttrLabel` yok sayılır) ve `kSecClassIdentity` sorgusu etiketi hiç dikkate almaz
   (keychain'deki ilk kimliği, örn. bir Apple Development sertifikasını döndürür; QUIC kimliği sanılırdı). Bu yüzden arama: özel anahtar
   `kSecAttrApplicationTag` ile bulunur, onun public-key hash'iyle (`kSecAttrApplicationLabel` = `kSecAttrPublicKeyHash`) sertifika bulunur,
   `SecIdentityCreateWithCertificate` kimliği kurar. CN `LinkToMac` kalır.
5. Parmak izi: sertifika DER'inin SHA-256'sı (küçük harf hex, 64 karakter).
6. İlk açılışta bir kez üretilir; sonraki açılışlarda yüklenir (yeniden üretilmez). `loadOrCreate` kilit altında (çift üretim yarışı yok);
   anahtar var ama sertifika yok (ya da tersi) → artıklar silinip temiz üretilir. Anahtarı olmayan artık sertifikalar (CN'e göre bulunur, kimliğe dönüşemeyenler) temizlenir. API: `loadOrCreate(label:commonName:now:)`, `load(label:)`,
   `reset(label:commonName:)` (Unpair için hazırlanır; bağlantısı Faz 1.6/6.9).
7. Hardened runtime altında (`codesign --options runtime`, atılabilir bir CLI ile) kimlik üretimi ve okuma denenir; sonuç sonuç dosyasına.
8. Rust çaprazı: fixture üretici (`mac/scripts/gen-quic-cert-fixture/main.swift`) ile `mac-cert.der` + `mac-cert.sha256`; Rust'ta
   `x509-parser` (dev-dependency) ile ayrıştırma testi ve **Swift (CryptoKit) ↔ Rust (sha2) parmak izi eşitliği**.

**Dosyalar.** `mac/Sources/LinkToMac/Quic/{DERWriter,QuicIdentity}.swift`, `mac/Tests/{DERWriterTests,QuicIdentityTests}.swift`,
`mac/project.yml` (test hedefine iki kaynak), `mac/scripts/gen-quic-cert-fixture/main.swift`,
`mobile/native-src/quic-core/{Cargo.toml (dev-dependency), tests/mac_cert.rs, tests/fixtures/{mac-cert.der,mac-cert.sha256,README.md}}`.

**Testler (beklenen sonuç).**
- `DERWriterTests`: uzunluk biçimleri (0, 127, 128, 255, 256, 65535), INTEGER kuralları, OID kodlamaları, UTCTime, BIT STRING, `[0] EXPLICIT`.
  **Sabit vektör:** ECDSA imzası rastgele olduğu için tam sertifika sabitlenemez; **imzasız TBSCertificate** sabit girdilerle (RFC 6979
  A.2.5 P-256 genel noktası, sabit seri ve zamanlar) sabitlenir. Beklenen hex, kendi yazıcımızdan değil **`openssl asn1parse -genconf`**
  (bağımsız kodlayıcı) ile üretilir.
- Sertifika yapısı (Keychain'siz): `SecCertificateCreateWithData` nil değil; `SecCertificateCopySubjectSummary == "LinkToMac"`; issuer == subject;
  seri 16 bayt ve pozitif; imza `SecKeyVerifySignature` ile doğrulanır, yanlış imza reddedilir; parmak izi 64 küçük hex ve CryptoKit SHA-256 ile eşit;
  geçersiz genel anahtar `throws`.
- `QuicIdentityTests` (benzersiz etiket **ve benzersiz CN** + `defer reset`; testler gerçek login keychain'e yazar, bu yüzden hem birbirinden hem gerçek kimlikten
  yalıtılır ve sonunda `security find-certificate -a -c LinkToMac` artık göstermemelidir): ikinci çağrı aynı kimliği/parmak izini döner (etiketle tam 1 sertifika + 1 anahtar);
  `SecIdentityCopyCertificate` DER'i eşit; `SecIdentityCopyPrivateKey` ile imzalanan veri sertifika anahtarıyla doğrulanır; `load` hiç üretmez;
  `reset` ikisini de siler; yarım artık onarılır; eşzamanlı iki çağrı tek kimlik üretir.
- Tüm Mac paketi (`xcodegen generate` + `xcodebuild … test`) yeşil; uygulama hedefi Swift 6 strict concurrency ile derlenir.
- `openssl x509 -inform DER` ve `openssl verify` ile fixture bağımsız ayrıştırılır (v3, CN=LinkToMac, ecdsa-with-SHA256, prime256v1, kendi kendine OK).
- Rust: `cargo test` ve `cargo clippy --all-targets -- -D warnings`: `x509-parser` ile ayrışır, imza doğrulanır, sha2 parmak izi `mac-cert.sha256` ile eşit.
- Hardened runtime altında üretim/okuma hatasız (elle, sonuç kaydı); Keychain izin istemi çıkarsa not edilir.

**Bilinen risk.** Ad-hoc imzalı Debug derlemeleri her yeniden derlemede cdhash değiştirdiğinden dosya tabanlı Keychain, eski anahtarı kullanırken
ACL izin istemi çıkarabilir (Developer ID'li release'te kod gereksinimi sabit). Gözlenirse sonuç dosyasına yazılır. Sertifika süresi dolunca yenileme
(10 yıllık) bu aşamanın dışında (Faz 6.9).

**Bitti ölçütü.** Mac, ilk açılışta kalıcı P-256 kimlik üretip Keychain'den `SecIdentity` olarak okuyabiliyor; Rust bu sertifikayı ayrıştırabiliyor
ve parmak izi iki dilde aynı.

### [x] 0.3 Interop: Network.framework QUIC sunucusu ↔ quinn istemcisi

**Amaç.** Planın en büyük teknik riskini ölçmek: Mac'te `NWProtocolQUIC` sunucusu, quinn istemcisiyle `fp` doğrulamalı bağlantı,
çoklu uni stream ve bidi stream. **Başarısızlık da geçerli bir sonuçtur:** kapı geçmezse 0.12'de yedek plana (Mac'te quinn + uniffi)
geçilir; bu aşamada Network.framework "düzeltilmeye çalışılmaz", yalnız ölçülüp kaydedilir.

**Kararlar (kullanıcı onaylı, 2026-11-14).**
- Network.framework'ün SDK'sında iki QUIC API'si var: klasik (`NWProtocolQUIC.Options`, `NWListener.newConnectionGroupHandler` →
  `NWConnectionGroup.newConnectionHandler`) ve macOS 26+ yeni API'si (`QUIC`, `QUICStream`). Dağıtım hedefimiz macOS 14 → **klasik API**.
- Rust istemci `quic-core` crate'inde: kalıcı **`src/pin.rs`** (parmak izi sabitleyen `ServerCertVerifier` + `client_config`, birim testli;
  Faz 1.7'nin temeli) ve atılabilir **`examples/interop_client.rs`**. Aynı kaynak Mac'te (host) ve telefonda (cargo-ndk ile arm64 ikili,
  `adb push` + `adb shell`; UI gerekmez) çalışır. Mac sunucusu `spikes/quic/mac-server/`, orkestrasyon `spikes/quic/run-interop.sh`.
- Swift sunucu `swiftc` ile derlenir (`QuicIdentity.swift` + `DERWriter.swift` + `main.swift`), spike için Swift 5 dil modu. **Spike kimliği
  tek kullanımlık:** kendi etiketi/CN'iyle sıfırdan üretilir, çıkışta silinir; gerçek `quic-identity` öğesine dokunulmaz.
- **Ek senaryolar:** (f) sunucu başlatan bidi stream (Faz 2: Mac → telefon dosya gönderimi Mac'in stream açmasını ister); (g) yanlış `tok`
  → sunucu bağlantıyı kapatır (Faz 1.6 davranışı).

**Spike protokolü (yalnız bu aşamaya ait; kalıcı biçim Faz 1'de vektörle sabitlenir).** ALPN `ltm/1`, TLS 1.3. İstemci oturum bidi
stream'i açıp 32 bayt `tok` yazar, sunucu `OK\n` döner. Sonra: **(c)** 3 × uni stream, her biri `0x01 ‖ u32 BE indeks ‖ 1 MiB` (indekse
tohumlu deterministik içerik); sunucu FIN'e kadar okur, SHA-256'yı oturum stream'inde `U <indeks> <sha256>` olarak bildirir, istemci
karşılaştırır. **(d)** bidi echo: `0x7E ‖ 64 KiB`, FIN; sunucu aynen geri yazar; ≤ 5 sn. **(f)** istemci istek yazınca sunucu bidi stream
açıp 16 KiB yazar; quinn `accept_bi` ile okuyup yansıtır. **(b)** yanlış `fp`: el sıkışma ≤ 5 sn'de reddedilmeli, sunucu çökmemeli.
**(e)** tuhaflıklar (gözlem): ilk stream'in gruba ait olması, grup başına tek stream yönü ayarı, `streamID`/yön metadata, uni stream'lerin
hangi handler'dan geldiği, istemci `RESET_STREAM`'inin sunucuda görünümü. İstemci çıktısı: `RESULT <ad> PASS|FAIL <ayrıntı> <ms>`.

**Yapılacaklar.**
1. `quic-core/src/pin.rs` (TDD): `fingerprint_hex`, `PinnedFingerprintVerifier` (yalnız `SHA-256(uç sertifika DER) == fp`, sabit zamanlı
   karşılaştırma; imza doğrulamasını ring sağlayıcısına devreder; yalnız TLS 1.3), `client_config(fp, alpn)` (keep-alive 5 sn, idle 30 sn).
2. `examples/interop_client.rs`: `--addr --fp --tok --scenario all|wrong-fp|wrong-tok`, sunucu adı `link-to-mac`.
3. `spikes/quic/mac-server/main.swift`: `NWProtocolQUIC.Options(alpn:)`, `sec_identity_create` + `sec_protocol_options_set_local_identity`,
   `sec_protocol_options_set_min_tls_protocol_version(.TLSv13)`, cömert `initialMaxStreams*`/`initialMaxStreamData*`, `NWListener` UDP 53125,
   `newConnectionGroupHandler` → `group.newConnectionHandler`; stream metadata loglanır; `FP <hex>` ve `PORT <n>` stdout'a yazılır.
4. `spikes/quic/run-interop.sh`: sunucuyu derle/başlat, istemciyi Mac localhost, Mac LAN IP'si ve telefondan (arm64 ikili) çalıştır, sonuç
   tablosu bas; `trap` ile sunucuyu öldür, kimliği sil, telefondaki ikiliyi kaldır.
5. Sonuçlar `docs/plans/2026-11-14-quic-faz0-sonuclar.md` 0.3 bölümüne: senaryo tablosu, numaralı tuhaflıklar, süreler, sürümler, kapı kararı.

**Dosyalar.** `mobile/native-src/quic-core/{src/pin.rs,src/lib.rs,examples/interop_client.rs,tests/pin.rs}`, `spikes/quic/mac-server/main.swift`,
`spikes/quic/run-interop.sh`, yerel `mobile/CLAUDE.md` (`pin.rs` satırı), sonuç dosyası. **Kalıcı:** `pin.rs` ve testleri. **Atılabilir:**
istemci örneği, Swift sunucu, betik.

**Testler (beklenen sonuç).**
- Rust birim: `fingerprint_hex(mac-cert.der)` = `mac-cert.sha256`; doğrulayıcı eşleşen `fp`'yi kabul eder, tek bit farklıyı reddeder, 32 bayt
  olmayan `fp` yapıcıda reddedilir; Mac sertifikası üzerinde bozuk imzalı `verify_tls13_signature` **`BadSignature`** döner (`BadEncoding`
  değil: elle yazılmış DER rustls/webpki tarafından ayrıştırılabilir). `cargo test` ve `cargo clippy --all-targets -- -D warnings` temiz.
- Senaryolar Mac localhost, Mac LAN IP'si ve telefonda: (a) doğru `fp`+`tok` bağlanır, oturum `OK`; (b) yanlış `fp` ≤ 5 sn'de TLS hatasıyla
  reddedilir, sunucu ayakta; (c) üç stream'in SHA-256'ları gönderilenle eşit; (d) echo bayt eşit, ≤ 5 sn; (f) sunucu başlatan bidi stream
  alınır ve yansıtılır; (g) yanlış `tok` bağlantıyı kapatır; (e) tuhaflıklar numaralı listelenir.
- Temizlik: sunucu süreci yok, spike kimliği silinmiş, gerçek `quic-identity` dokunulmamış, telefonda ikili yok. Mac testleri (142) ve
  `build-so.sh` yeşil kalır.

**Bitti ölçütü.** Kapı "Interop + kalıcı kimlik" için geçti/kaldı kararı ve gerekçesi sonuç dosyasında; senaryo sonuçları üç ortamda kayıtlı.

### [x] 0.4 Mac DATAGRAM (Swift API hatası var mı?)

**Amaç.** Ses için varsayılan taşıma olan QUIC DATAGRAM'ın Mac tarafında kullanılabilir olduğunu doğrulamak.

**Yapılacaklar.**
1. Swift API ile DATAGRAM gönder/al (`maxDatagramFrameSize` ayarı); bildirilen hatayı (r. 149070093) güncel macOS'ta yeniden üret.
2. Hata varsa: aynı target içinde küçük bir C/Obj-C sarmalayıcı (`nw_quic_*` C API'si; kaynak dosyası, üçüncü parti bağımlılık değil).
   `project.yml`'de bridging header/module map eklenir.
3. Telefon → Mac yönünde 60 sn boyunca 50 paket/sn × ~350 bayt, ardından Mac → telefon yönünde aynısı. Paketlerde `seq` vardır.
4. Test edilen macOS sürümü sonuç dosyasına yazılır.

**Dosyalar.** Spike dalı; hata varsa kalıcı olacak sarmalayıcı `mac/Sources/LinkToMac/Quic/QuicDatagramShim.{h,m}`.

**Testler (beklenen sonuç).** Her yönde 3000 paket gönderilir; LAN'da ≥ %99,9'u alınır, `seq` ile sıra/kayıp hesaplanır, yük bütünlüğü doğrulanır.
Geçerse ses DATAGRAM ile gider; geçmezse Faz 4'teki yedek taşımalar devreye girer.

**Bitti ölçütü.** Kapı "Mac'te DATAGRAM" için karar ve (varsa) çalışan sarmalayıcı.

### [x] 0.5 Stream maliyeti (Mac): saniyede 60 ve ~110 gelen uni stream

**Amaç.** "Video frame başına stream" ve "ses kısa stream'lerle" tasarımlarının Mac'te taşınabilir olduğunu ölçmek (her stream ayrı bir `NWConnection`).

**Yapılacaklar.**
1. Android, 5 dk boyunca saniyede 60 uni stream gönderir (her biri ~30 KB; video frame benzeri).
2. Ardından 5 dk boyunca ~110 stream/sn: 60 × ~30 KB + 50 × ~350 B (video + ses birlikte).
3. Mac ölçer: stream açılışından uygulamaya ilk bayt teslimine gecikme (p50/p95/p99), CPU (`top -pid`), bellek büyümesi (nesne sızıntısı).
4. Stream sayısı ve kapanma davranışı (kapanan `NWConnection`'ların serbest bırakılması) gözlenir.
5. **Ölçüm tanımları (2026-11-15'te onaylandı; 1–4'ü somutlaştırır).**
   - *Gecikme:* ortak saat yoktur. Gönderen, stream açılmadan hemen önceki monoton saatini (ns) stream başlığına yazar; Mac ilk baytın uygulamaya teslimini kendi monoton saatiyle damgalar. Gecikme = ham fark − aynı 10 sn'lik pencerenin en küçük ham farkı ("tabanın üstündeki gecikme"; saat ofsetini ve kristal kaymasını atar). Karar bu değer üzerinden verilir; çapraz kontrol olarak oturum başı/sonu NTP tarzı ofset ölçümüyle (30 çift, en düşük RTT, belirsizlik RTT/2) mutlak gecikme noktası tahmini de raporlanır (karar kuralı değildir).
   - *CPU:* sunucu sürecinin `getrusage` farkı, 5 sn örnekleme, tek çekirdek yüzdesi; faz başına ortalama < %25 **ve** örneklerin p95'i < %25. Çapraz kontrol: betikte `top -l 2 -s 1 -pid`.
   - *Bellek:* `phys_footprint`, 5 sn örnekleme, ilk 30 sn ısınma atılır; faz sonu 60 sn ortalaması − ısınma sonrası ilk 60 sn ortalaması ≤ 10 MB ve doğrusal eğim ≤ 2 MB/dk ise "sabit".
   - *Serbest bırakma:* her stream için bir `StreamProbe` nesnesi (`deinit` sayacı); faz boyunca en büyük canlı ≤ 50, faz bitiminden 3 sn sonra canlı ≤ 5. Ayrı 30 sn teşhis koşusu (`--stream-close none`, bitince `cancel()` yok) yalnız bulgudur.
   - *Kayıp:* gönderilen her `seq` tam (FIN'li, uzunluk doğru, gövde baytları örüntüyle eşit) alınmış; eksik/yarım/bozuk/yinelenen = 0.
   - *Ortamlar:* Mac host istemcisi (loopback; Mac'in kendi alım maliyeti) ve telefon (asıl karar koşusu). İkisi aynı eşiklerle değerlendirilir; host geçip telefon yalnız gecikmeden kalırsa neden kanıtıyla yazılır ve karar kullanıcıya sorulur.
   - *Geçersiz koşu:* gönderen hızı tutturamazsa (gönderilen < planlananın %99'u) koşu FAIL (hız tutturulamadı) sayılır.
   - Spike başlığı: `0x53 ‖ phase u8 ‖ kind u8 ('V'|'A') ‖ seq u32 BE ‖ send_ns u64 BE ‖ len u32 BE` + sabit örüntülü gövde (video 30 720 B, ses 350 B); aralıklar 16,67 ms (video) ve 20 ms (ses); fazlar arası 10 sn.

**Testler (beklenen sonuç).** Geçme ölçütü (onaylı eşik): hiç stream kaybı yok, p99 gecikme < 20 ms, bellek 5 dk boyunca sabit,
CPU tek çekirdeğin %25'inin altında. İki ayrı sonuç üretilir: **60 stream/sn** (yalnız video) ve **~110 stream/sn** (video + ses).
Her sonuç hem Mac host hem telefon koşusunda ölçülür; kısa (20 sn) düzenek koşusu ve birim testler (başlık golden, yüzdelik, pencere tabanı, eğim, karar sınırları) gerçek koşudan önce geçmelidir.

**Bitti ölçütü.** İki eşik için ayrı geçti/kaldı; kapı satırı buna göre doldurulur.

### [x] 0.6 Throughput: 10 GB iki yönde

**Amaç.** QUIC dosya yolunun mevcut LAN-direct WS dosya yolundan yavaş olmadığını doğrulamak; darboğaz Network.framework tarafında da olabilir.

**Yapılacaklar.**
1. 10 GB'lık dosya QUIC ile Mac → telefon ve telefon → Mac gönderilir; iki tarafın CPU'su, sürekli hız (Mbps) ve telefonun pil/sıcaklık değişimi kaydedilir.
2. Aynı dosya mevcut LAN-direct WS yoluyla (mevcut `FileSender`/`sendAsFile`) gönderilip hız karşılaştırılır.
3. Düşükse ayar denemeleri: UDP segmentation (GSO/GRO), `SO_RCVBUF/SO_SNDBUF` büyütme, quinn congestion controller (varsayılan Cubic; BBR denemesi).
4. **Ölçüm tanımları (2026-11-15'te onaylandı; 1–3'ü somutlaştırır).**
   - *WS sınırı:* mevcut WS yolunda dosya başına 1 GiB sınırı vardır (`FileFrame.maxTransferBytes`), bu yüzden 10 GB'lık dosya WS ile gönderilemez. **Karşılaştırma 1 GiB'lık dosyayla** yapılır: her yönde QUIC 3 ölçüm ve WS 3 ölçüm, ABABAB sırasıyla, medyanlar karşılaştırılır. **10 GiB** her yönde QUIC ile bir kez koşulur (sürekli hız, CPU, sıcaklık, SHA-256); WS ile 10 GB karşılaştırması yoktur.
   - *Geçme kuralı:* her yönde QUIC medyanı ≥ WS medyanı (eşik değişmez); 3 ölçümün min/max dağılımı raporlanır.
   - *Dosya konumu ve disk (2026-11-15, kullanıcı kararı):* ön kontrolde harici SSD'nin USB 2.0 hızında (480 Mb/s) bağlı olduğu ve yazma hızının ~40 MB/sn olduğu görüldü (dahili diskte yalnız 4,6 GiB boş). Bu yüzden **10 GiB koşularında Mac tarafı diske dokunmaz** (bellek kipi): Mac gönderirken 16 MiB'lık sahte rastgele bir bölgeyi döngüyle yollar ve akarken SHA-256 hesaplar, alırken yalnızca SHA-256 hesaplar; telefon tarafı gerçek disk G/Ç'si ile (`/data/local/tmp/`; `MediaStore` yazma hızı 0.9'da). **1 GiB karşılaştırması** (QUIC ve WS) Mac'in **dahili diskinde**, gerçek disk G/Ç'si ile yapılır (WS yolunun yaptığıyla aynı); her koşudan sonra dosyalar silinir ve boş alan < 2,5 GiB ise koşu başlamaz. Harici SSD hiç kullanılmaz. Dosyalar deterministik üreteçle yerinde üretilir, üretici SHA-256 basar, alıcı akarken SHA-256 hesaplayıp karşılaştırır; WS koşularında alınan dosya `shasum`/`sha256sum` ile doğrulanır. Mac'in 10 GiB'ta diski kullanmaması sonuç dosyasında sınırlama olarak yazılır.
   - *Pil:* telefon USB'de şarj olduğundan pil boşalması ölçülemez; sıcaklık ve pil yüzdesi 10 GiB koşuları öncesi/sonrası kaydedilir, boşalma hakkında sonuç çıkarılmaz (sınırlama sonuç dosyasında).
   - *CPU:* QUIC: Mac sunucu `getrusage`, telefon `/proc/self/stat`; WS: Mac uygulaması `top -l 2 -pid`, telefon uygulaması `/proc/<pid>/stat` (2 sn aralıkla). WS hızı dışarıdan, hedef dosyanın büyümesinden ölçülür (uygulamalar süre kaydetmiyor); WS koşuları LAN-direct olmalıdır (`lsof` ile doğrulanır).
   - *Ek ölçüm:* Mac host (loopback) 1 GiB ve 10 GiB koşusu Network.framework + disk tavanını gösterir.

**Testler (beklenen sonuç).** QUIC ≥ WS hızı, her iki yönde, aynı koşullarda (aynı Wi-Fi, aynı mesafe) en az 3 ölçümün medyanı. Alınan dosyanın SHA-256'sı gönderilenle eşit.

**Bitti ölçütü.** Kapı "10 GB, LAN WS'den yavaş değil" için karar; geçmezse dosya LAN'da WS'de kalır, QUIC yalnız medya için.

### [x] 0.7 Mac QoS: Mac → telefon dosya trafiğini sınırlama

**Amaç.** Network.framework stream önceliği vermediği için Mac → telefon dosya trafiğinin uygulama seviyesinde sınırlanabildiğini ve eş zamanlı telefon → Mac video gecikmesine etkisini ölçmek.

**Yapılacaklar.**
1. Mac'te basit token-bucket hız sınırlayıcı; Mac → telefon dosya gönderimine uygulanır.
2. Eş zamanlı telefon → Mac, 60 fps × ~30 KB video benzeri stream akar.
3. Sınırlayıcı kapalı, %100 ve %50 tahmini bant genişliğinde video frame gecikmesi (p95) ölçülür.
4. **Ölçüm tanımları (2026-11-16'da onaylandı; 1–3'ü somutlaştırır).**
   - *Dilimler ve gecikme:* her koşu tek bağlantıda üç ardışık dilimdir: **20 sn yalnız video (taban) → 60 sn video + Mac → telefon dosya akışı (yük) → 20 sn yalnız video (toparlanma)**. Video sürekli akar, her stream başlığındaki `phase` baytı dilimi taşır. Gecikme = ham fark (varış − gönderim) − **taban diliminin en küçük ham farkı** (tek referans; 0.5'teki pencere tabanı kalıcı gecikmeyi gizleyeceği için burada kullanılmaz). Saat kayması (≈ 2 ms / 100 sn) koşu sonu kalibrasyonuyla raporlanır. **Artış = p95(yük) − p95(taban)**, aynı koşunun içinde; geçme: %50 sınırda 3 koşunun medyanı ≤ 20 ms.
   - *Tahmini bant genişliği (B0):* aynı oturumda, video kapalıyken Mac → telefon dosya akışının sınırsız 30 sn'de ulaştığı hız; sınırlayıcı hızları %100 × B0 ve %50 × B0. B0 her bloğun başında ve sonunda ölçülür, sapma raporlanır (telefon ısınınca düşüyor).
   - *Koşullar:* (A) yalnız video, (B) video + dosya, sınırlayıcı kapalı, (C) %100 × B0, (D) %50 × B0; her biri 3 koşu, sıra her turda döndürülür, koşular arası 30 sn dinlenme.
   - *Parametre taraması:* %50'de burst ∈ {64 KiB, 256 KiB, 1 MiB} × gönderim parçası ∈ {16 KiB, 64 KiB}, ikişer koşu; %50 geçmezse %25 × B0 ve daha küçük burst de denenir. Çıktı: Faz 6.1'e hız payı, burst, parça boyutu, zamanlayıcı yöntemi.
   - *Konum:* sınırlayıcı Mac sunucusunun gönderim pompasında (spike), saf bir `TokenBucket` türü olarak yazılır ve test edilir; Mac dosya akışı bellek kipinde (diske dokunmaz), telefon gerçek dosyaya yazar; bütünlük (SHA-256) bu aşamada kontrol edilmez (0.6'da doğrulandı; akış `BSTOP` ile kesilir). Video gönderen ve dosya alıcı aynı QUIC bağlantısını ve aynı telefon sürecini paylaşır; telefon CPU'su ve sıcaklığı her koşuda kaydedilir.
   - Spike protokolü: `BDOWN … [rate burst sendchunk]`, `BSTOP`, `SPHASE … [ref=<m>]`, istemci senaryosu `qos`.
5. **Yeniden ölçüm (2026-11-17, kullanıcı isteği ve onayı; madde 4'ün ilk ölçümü "KALDI (sınırda, kanıt zayıf)" kaldı, çünkü veri güvenilir değildi).** Sorunlar: gürültü tabanı eşik kadar büyüktü (dosya yokken bile 9 koşunun 2'sinde +25–26 ms "artış"), dilimler eşit uzunlukta değildi (20 sn taban vs 60 sn yük, periyodik sıçramalar uzun dilimde daha çok yakalanıyor), ayar başına yalnız 2–3 karşılaştırma vardı ve koşular farklı zamanlarda ölçüldü. Yeni tasarım madde 4'ün dilim tanımının yerine geçer; eşik (≤ 20 ms) değişmez:
   - *İç içe dilimler:* tek bağlantıda video sürekli; `KAPALI 10 sn → AÇIK-oturma 2 sn → AÇIK 10 sn → KAPALI-oturma 1 sn → KAPALI 10 sn → …`, 8 AÇIK dilim, KAPALI ile başlar ve biter (9 KAPALI + 8 AÇIK, ~3,5 dk/koşu). AÇIK = o koşulun dosya akışı (her döngüde `BDOWN`…`BSTOP`), KAPALI = dosya yok; oturma dilimleri ölçülmez.
   - *Eşleştirilmiş etki:* `etki_i = p95(AÇIK_i) − ortalama(p95(KAPALI_i), p95(KAPALI_{i+1}))`; dilimler eşit uzunlukta (10 sn ≈ 600 örnek), yavaş kayma ve periyodik sıçramalar iki yanın ortalamasıyla iptal olur.
   - *Örnek sayısı:* koşul başına 3 koşu × 8 = 24 eşleştirilmiş etki. Koşullar döndürülür ve iç içe geçer.
   - *Gürültü referansı (sahte yük):* koşul A aynı dilim dizisini dosya akışı olmadan yürütür; etkisi ≈ 0 olmalı (|medyan| ≤ 5 ms), değilse koşu tekrarlanır ve bu raporlanır.
   - *Koşullar:* A sahte yük, B sınırlayıcı kapalı, E1 %50 × B0 (burst 64 KiB / parça 64 KiB), F25 %25 × B0, F10 %10 × B0; hepsi 3 koşu (15 koşu, ~1 saat).
   - *İstatistik ve karar:* her koşul için eşleştirilmiş etkilerin medyanı ve %90 bootstrap güven aralığı (10 000 yeniden örnekleme, sabit tohum), ≤ 20 ms payı. E1 için **GEÇTİ** = aralığın üst sınırı ≤ 20 ms; **KALDI** = medyan > 20 ms (ya da alt sınır > 20 ms); aksi halde **BELİRSİZ** (kullanıcıya sorulur). Her dilimin p95'i ham zaman serisi olarak saklanır.
   - *Ortam:* telefon sabit yerde, 5 GHz, ekran açık, USB'de; bant ya da sinyal bozulursa koşu durdurulur.
   - *B0 tur başına (ölçüm sırasında eklendi):* bant genişliği gün içinde ~2,5 kat oynadığı için (10–25 MB/sn) B0 her turun başında yeniden ölçülür ve o turun sınırlayıcı hızları ona göre ayarlanır. Koşunun başına 5 sn ölçülmeyen ısınma eklendi (yeni bağlantının ilk saniyeleri temsili değil).
   - *Durum (2026-11-17, kullanıcı kararı):* 15 koşunun hepsi geçerli. Sahte yük kapısı **OK** (−1,0 ms); **E1 %50: BELİRSİZ** (medyan 9,1 ms, %90 aralık [4,7; 22,1]); **%25: GEÇTİ** (5,6 ms, [3,0; 12,9]); **%10: GEÇTİ** (3,3 ms, [−0,7; 5,1]); sınırlayıcı kapalı: KALDI (44,7 ms). Sonuçlar olduğu gibi kaydedildi (`2026-11-14-quic-faz0-sonuclar.md` §0.7, ham veri `docs/plans/data/`); **E1 ve sahte yük için en az 3'er ek koşu daha sonra yapılacak, aşama o zamana kadar açık.** Faz 6.1'in %50 / %25 kararı bu tekrara bağlı.
   - *Tanı (2026-11-18):* E1 tekrarında bozulma yeniden üretildi (6 koşunun 2'si); ping + video eşleştirilmiş dilimlerle (sabit mutlak hızlar, sahte yük, 2 tur, bir de AWDL kapalı geçişi) bakıldı. Sonuç: dosya akışı dönüş yolunda ölçülebilir kuyruk oluşturuyor (ping medyanı +3…+22 ms), video aynı anda bozuluyor; etkinin büyüklüğü sabit hızda geçişten geçişe 3–8 kat değişiyor; AWDL kapatmak etkiyi kaldırmıyor. **Sabit yüzdeli/sabit hızlı sınırlayıcı güvenilir değil; sınırlayıcı gecikme sinyaline bağlanmalı (seçenek A).** Ayrıntı: `2026-11-14-quic-faz0-sonuclar.md` §0.7 "Tanı", bulgular 45–51. Sonrası madde 6.

6. **Uyumlu (gecikmeye bağlı) denetleyici (2026-11-18, kullanıcı onayı: sabit sınırlayıcı yerine; ayar turu ve aşamanın kapatılması da onaylı).** Sabit hız ya da "B0'ın %X'i" taşınabilir bir parametre olmadığı için (aynı hız bir oturumda +6 ms, ötekinde +48 ms; kapasite 3 kat oynuyor) Mac → telefon dosya hızı, Mac'e gelen video stream'lerinin gecikmesinden yönetilir. Çekirdek **üretim kalitesinde ve saf** yazıldı: `mac/Sources/LinkToMac/Quic/DelayRateController.swift` + `DelayRateControllerTests` (32 test: her kural, mutasyon kontrolü, akışkan darboğaz simülasyonları). Sinyal: pencere (0,6 sn) medyanı − sakin seviye (30 sn'lik pencere medyanlarının p10'u), `d = Mac varış − telefon damgası` (saat senkronizasyonu gerekmez); eşikler 7 / 3 ms, çarpımsal kesinti ×0,7 / ×0,5 / ×0,35 (7 / 40 / 100 ms), toplamsal artış +1 MB/sn² (dize yakınken +0,3), hız tabanı **2 MB/sn**, ortam payı kuralı (tabandayken yüksek kuyruk ortam sayılır). Ölçülen (ayar turu, kampüs ağı, 9 koşu): video etkisi koşu medyanları −6 / 4 / 14 ms (sabit 7,5 MB/sn: 0 / 3 / 0), ortalama dosya hızı 4,5 MB/sn (sabit 7,5: 6,1; hız 2–13,5 MB/sn arası oynadı), ping artışı +3,9 ms; sahte yük kapısı havuzlu geçti. **Bilinen sınırlar:** uyumun sabit hıza üstünlüğü doğrudan kanıtlanamadı (sabit 7,5 iki oturumdur sorunsuz), tur 3 ortam sıçramasıyla kirlendi, eşikler tek kampüs ağında ayarlı, 30 sn+ süren kesintisiz kuyruk sakin seviye olur ("geç gelen"). Ayrıntı ve ham veri: `2026-11-14-quic-faz0-sonuclar.md` §0.7, bulgular 36–66, `docs/plans/data/`.

**Testler (beklenen sonuç).** %50 sınırda video p95 gecikme artışı ≤ 20 ms (onaylı eşik; yeniden ölçümde karar kuralı madde 5; **madde 6'daki denetleyici bu aşamanın yerine geçen çözümdür, aynı eşik ona uygulandı**). Önerilen sınırlayıcı parametreleri sonuç dosyasına yazılır. Birim testleri (token-bucket sınırları, referans tabanlı gecikme hesabı, dilim zamanlayıcısı, dilim tablosu, eşleştirilmiş etki, güven aralığı) ve loopback düzenek koşusu (sınırlayıcı hedef hızı ± %5'te tutuyor; sahte yük etkisi |medyan| ≤ 2 ms) gerçek koşudan önce geçmelidir.

**Bitti ölçütü.** Faz 6.1 (QoS) için kullanılacak sınırlayıcı parametreleri belirlendi (madde 6: uyumlu denetleyici, parametreleri ve ölçülmüş davranışı sonuç dosyasında; sabit %50 kararı kalktı).

### [x] 0.8 Android: encoder gecikmesi

**Amaç.** Ekran yansıtma hedefinin (≤ 120 ms uçtan uca) encode payını doğrulamak.

**Yapılacaklar.**
1. Test uygulamasında MediaProjection → VirtualDisplay → MediaCodec (H.264 High, Surface girişi, `KEY_LOW_LATENCY=1`, `KEY_PRIORITY=0`), 1080p, 60 fps.
2. Encode süresi = çıkış tamponunun alındığı an (**`System.nanoTime()`**, CLOCK_MONOTONIC) − tamponun `presentationTimeUs`'u (Surface zaman damgası). *(Düzeltme, 0.8 bulgu 68: ilk planda `SystemClock.elapsedRealtimeNanos` yazılıydı; o saat CLOCK_BOOTTIME'dır ve telefonda monotonik saatten 6,15 gün farklıydı, her gecikme yanlış çıkardı.)*
3. İki senaryo: video oynatılırken ve statik ekranda (`KEY_REPEAT_PREVIOUS_FRAME_AFTER`). *(Uygulama, 0.8 bulguları 70–71: video senaryosu iki türlü yapıldı, tekrarlanabilir hareketli içerik S1 + gerçek video S3; statik ekran, giriş yüzeyi son kareyi en çok ~10 kez tekrarlayıp sustuğu için "saniyede bir değişen ekran" S2 olarak ölçüldü, tam statik + tekrar kare S2R yalnız bilgi amaçlı.)*
4. İsteğe bağlı: HEVC ile aynı ölçüm (M4 donanımsal decode edebilir).
5. **Sonuç (2026-11-18, Galaxy S24 Ultra, Android 17, 1080×2340 @ 60 fps, donanım kodlayıcı):** H.264 medyan **22,2 ms (S1) / 22,0 ms (S2) / 20,7 ms (S3)**, p95 25–35, p99 26–43, düşen kare 0, ısınma yok; **kapı GEÇTİ**. HEVC aynı (21,7 ms). `KEY_LOW_LATENCY`/öncelik ölçülebilir etki yapmıyor (kodlayıcı `FEATURE_LowLatency` desteklemiyor). `max-fps-to-encoder` kayan noktalı verilmeli (yoksa 120 fps girer). Ayrıntı, tablo ve ham veri: `2026-11-14-quic-faz0-sonuclar.md` §0.8, bulgular 67–76, `docs/plans/data/2026-11-18-android-encoder-latency/`.

**Testler (beklenen sonuç).** En az 3 dk ölçüm; medyan ≤ 30 ms, p95 kaydedilir. Frame düşmesi/kararsız zaman damgası yok. *(Sonuç: tümü sağlandı; yapılan testler: 17 JVM birim testi, duman koşuları, her senaryo için 3 dk ölçüm.)*

**Bitti ölçütü.** Kapı "Encode ≤ 30 ms" için karar; geçmezse hedef 1080p 30 fps / 720p'ye iner. *(Karar: GEÇTİ, hedef 1080p/60 fps korunur; Faz 4 için uçtan uca bütçede kodlama payı medyanda ~22 ms, p99'da ~43 ms.)*

### [x] 0.9 Android: ses yakalama testi

**Amaç.** AudioPlaybackCapture'ın hangi popüler uygulamalarda çalıştığını ve telefon sesini kısmanın yakalanan sesi etkileyip etkilemediğini bilmek.

**Yapılacaklar.**
1. Test uygulaması: `AudioPlaybackCaptureConfiguration` (`USAGE_MEDIA`, `USAGE_GAME`, `USAGE_UNKNOWN`), 48 kHz stereo PCM16, `RECORD_AUDIO` izni, MediaProjection onayı.
2. Uygulamalar: Spotify, YouTube, YouTube Music, Chrome (tarayıcı sesi). Her biri için yakalanan sesin RMS'i (sessiz mi değil mi) kaydedilir. *(Uygulama, kullanıcı onaylı 2026-11-18: YouTube Music'te oturum olmadığı için denendi ama test edilemedi, yerine Samsung Müzik (yerel ton) kullanıldı; oynatma `dumpsys media_session`'dan doğrulandı, Spotify/Chrome için cihaza özgü oynat dokunuşu gerekti.)*
3. Telefon medya sesi %100 ve %20 iken yakalama seviyesi karşılaştırılır.
4. **Sonuç (2026-11-18, Galaxy S24 Ultra, Android 17):** YouTube, Chrome ve Samsung Müzik **yakalandı**; **Spotify yakalanamıyor** (oynatıcı `started` ama yakalama −120 dBFS, dijital sessizlik); YouTube Music test edilemedi. Yakalama **ses seviyesinden bağımsız** (sabit tonda %100 / %20 / %100: −9,1 / −9,1 / −9,1 dBFS). Yalnız `mediaProjection` türünde ön plan servisi yeterli (`microphone` türü gerekmedi). **Kapı GEÇTİ (4 test edilen uygulamadan 3'ü).** Ayrıntı: `2026-11-14-quic-faz0-sonuclar.md` §0.9, bulgular 77–83, `docs/plans/data/2026-11-18-android-audio-capture/`.

**Testler (beklenen sonuç).** Tablo: uygulama × (yakalandı/yakalanmadı) × (ses kısınca seviye değişti/değişmedi). Kapı: popüler uygulamaların en az 3'ü yakalanıyor. *(Sonuç: sağlandı, 3/4; yapılan testler: 15 JVM birim testi, analiz betiği kendi testi, duman koşuları, iki tam oturum.)*

**Bitti ölçütü.** Kapı "Popüler uygulamalar ses yakalamaya izin veriyor" için karar; Faz 4.7'nin (telefon tarafındaki ses) kararı için veri. *(Karar: GEÇTİ ama Spotify yakalanamıyor; Faz 4.7'de "oturum PLAYING ama yakalama dijital sessizlik" durumu tanınıp kullanıcıya gösterilmeli, ses seviyesi Mac'te ayrıca ayarlanmalı.)*

### [x] 0.10 Android: MediaStore'a doğrudan yazma (IS_PENDING + "rw")

**Amaç.** Bugün biten dosya Downloads'a **kopyalanıyor** (`FileInbox.kt:208`), bu da bitişte 2× disk demek. Kopyayı kaldıracak doğrudan MediaStore yazımının hızını ve resume'unu ölçmek. Sonuç Faz 2'deki Android disk kuralını belirler.

**Yapılacaklar.**
1. `MediaStore.Downloads` altında `RELATIVE_PATH = Download/Link to Mac`, `IS_PENDING=1` girdisi oluştur; `DATE_EXPIRES`'ı açıkça `şimdi + 6 saat` olarak ayarla (varsayılan ~7 gün; doğrulanır). *(Sonuç: varsayılan tam 7 gün doğrulandı; açık değer ne ekleme ne `update` ile korunuyor, `DATE_EXPIRES` ayarlanamıyor. Kullanıcı onaylı 2026-11-19: ölçüt "7 gün sabit + uygulama kendi bekleyen girdilerini temizler" olarak değişti.)*
2. `openFileDescriptor(uri, "rw")` ile 10 GB'ı 1 MiB bloklarla ardışık yaz; hızı `noBackupFilesDir`'e yazmayla karşılaştır.
3. Yazarken süreci öldür; yeniden başladıktan sonra bekleyen girdiyi bul (kendi bekleyen girdilerini sorgulama: `QUERY_ARG_MATCH_PENDING`), fd'yi aç, `FileChannel.position(offset)` ile kaldığı yerden devam et.
4. Sonuç dosyasının SHA-256'sı gönderilenle eşit olmalı; `IS_PENDING=0` sonrası galeride/Files'ta görünür.
5. Bekleyen girdinin süre sonunda silinip silinmediği (`DATE_EXPIRES` davranışı) gözlenir. *(Sonuç: MediaProvider bakım işi tetiklenebildi ve süresi dolmamış girdiler sağ çıktı; süresi dolmuş girdi üretilemediği için 7. gün silmesi gözlenemedi, doğrulanmadı.)*
6. **Sonuç (2026-11-19, Galaxy S24 Ultra, Android 17):** doğrudan `"rw"` yazma yerel yazmanın **%93'ü** (2095 / 2249 MB/s, 10 GiB ≈ 5 sn); bugünkü kopya yolu 10 GiB'ta bitişte **+25,3 sn ve +10,7 GB**; resume (3 GiB, 2 `kill -9`) bayt bayt doğru, SHA-256 eşit, artık bekleyen girdi yok; `IS_PENDING=0` sonrası dosya normal listede görünür; `DATE_EXPIRES` her zaman +7 gün, ayarlanamaz ve yenilenemez. **Kapı GEÇTİ; 6 saatlik saklama ölçütü kullanıcı onayıyla değiştirildi.** Ayrıntı: `2026-11-14-quic-faz0-sonuclar.md` §0.10, bulgular 84–90, `docs/plans/data/2026-11-19-android-mediastore/`.

**Testler (beklenen sonuç).** Yazma hızı yerel yazmanın ≥ %80'i (onaylı eşik); öldürme sonrası resume bayt-bayt doğru; hash eşit; süre sonu davranışı **bilinir** (kullanıcı onaylı 2026-11-19: eski ölçüt "6 saatlik saklamayla uyumlu" idi; `DATE_EXPIRES` ayarlanamadığı için yerine "7 gün sabit, uygulama kendi bekleyen girdilerini temizler" kondu). Olumluysa Faz 2'de Android bitiş kopyası ve 2× alan rezervasyonu kalkar (bu durumda 2.3/2.7 yeniden yazılır, kullanıcı onayıyla). Olumsuzsa ara kural `(size − have) + size` sürer. *(Sonuç: olumlu; 2.3 ve 2.7 kullanıcı onayıyla 2026-11-19'da yeniden yazıldı; yapılan testler: 19 JVM birim testi (üç mutasyon yakalandı), duman koşusu, 10 GiB × 5 koşu, 3 GiB resume.)*

**Bitti ölçütü.** "MediaStore'a doğrudan yazma" için karar ve sayılar sonuç dosyasında. *(Karar: GEÇTİ; 6 saatlik saklama ayarlanamıyor, yerine uygulamanın kendi bekleyen girdi temizliği kondu.)*

### [x] 0.11 Mac: boş CMIO Camera Extension (System Extension profili)

**Amaç.** Faz 5a'nın ön koşulunu erken doğrulamak: System Extension yeteneği olan provisioning profile alınabiliyor mu ve boş bir kamera uzantısı FaceTime'da görünüyor mu.

**Yapılacaklar.**
1. Apple Developer hesabında uygulama kimliği için System Extension yeteneği ve provisioning profile; `com.apple.developer.system-extension.install` entitlement'ı.
2. Spike projesinde boş bir CMIO Camera Extension hedefi (tek renkli frame üreten).
3. Developer ID ile imzala, notarize et, `/Applications` altına kopyala; `OSSystemExtensionRequest` ile etkinleştir; Sistem Ayarları'ndan onayla.
4. FaceTime'da kamera listesinde ve görüntüde gör.
5. **Sonuç (2026-11-19, macOS 27.2.1, SIP açık):** profil portalda elle alındı (explicit App ID `dev.grkn.LinkToMac.CameraSpike` + System Extension + Developer ID profili, yalnız ana uygulamaya gömülü; uzantı profilsiz, OBS düzeni); `notarytool` **Accepted**; `/Applications`'tan etkinleşti (Sistem Ayarları onayı, parolasız); "Link To Mac Kamera" `system_profiler` ve AVFoundation'da göründü; `--grab`: **188 frame / 6 sn (30,5 fps), %100 renk eşleşmesi, sapma 0,0**; FaceTime'da renkler doğru sırada; kaldırma çalıştı (kayıt yeniden başlatmaya kadar `terminated waiting to uninstall on reboot`). **Kapı GEÇTİ, Faz 5 donmuyor.** Ayrıntı: `2026-11-14-quic-faz0-sonuclar.md` §0.11, bulgular 91–99, `docs/plans/data/2026-11-19-mac-camera-extension/`.

**Testler (beklenen sonuç).** Uzantı kurulur, onay sonrası "Link To Mac Kamera" FaceTime'da seçilebilir ve renkli frame görünür; `notarytool` başarılı. *(Sonuç: sağlandı; yapılan testler: 17 birim testi (üç mutasyon yakalandı), profil denetimi (olumlu ve olumsuz), imza/yetki/hardened runtime doğrulaması, notarize + staple + `spctl`, `systemextensionsctl` durumları, `system_profiler`, `--grab` piksel ölçümü, FaceTime'da görsel doğrulama, kaldırma.)*

**Bitti ölçütü.** Kapı "Camera Extension çalışıyor" için karar; geçmezse Faz 5 donar (diğer fazlar etkilenmez). *(Karar: GEÇTİ. Faz 5.3/5.4 için kurallar sonuç dosyasında, bulgu 98: gerçek `dev.grkn.LinkToMac` için ayrı App ID + profil gerekir, `build-release.sh` profili gömmeli, uzantı profilsiz ve uygulamadan önce imzalanmalı.)*

### [x] 0.12 Karar kapılarını değerlendir ve planı güncelle

**Amaç.** Faz 0 sonuçlarını kapılara bağlamak, yedek yollara geçilecekse ilgili aşamaları bu dosyada yeniden yazmak.

**Yapılacaklar.**
1. Her kapı için geçti/kaldı, sayı ve gerekçe: Interop + kalıcı kimlik · Mac'te DATAGRAM · stream/sn (60 yalnız video; ~110 video + ses) · 10 GB hız · encode ≤ 30 ms · popüler uygulama ses yakalama · Camera Extension · MediaStore doğrudan yazma.
2. Sayısal eşikler (0.5, 0.7, 0.8, 0.10 ve plandaki diğerleri) 2026-11-14'te kullanıcı tarafından onaylandı; ölçümler sapmayı gerektiriyorsa yalnız kullanıcı onayıyla güncellenir ve ilgili aşama yeniden yazılır.
3. Kapıya göre plan düzenlemesi **kullanıcı onayıyla**: kaldıysa yedek aşamalar eklenir/koşullu aşamalar silinir (Faz 3.4 "yedek akış", Faz 4.4 ses taşıma yolları, Faz 2 kapsamı, Faz 5 durumu); özet tablosundaki hedefler (gecikme) güncellenir.
4. Sonuç dosyası ve bu dosya birlikte commit edilir.
5. **Sonuç (2026-11-19, kullanıcı onaylı):** kapı tablosu doldu (9 satır): Interop + kimlik, DATAGRAM, 10 GB hız, encode, MediaStore, Camera Extension **geçti**; ses yakalama **3/4 geçti** (Spotify yok); stream/sn **s-60 geçti, s-110 kaldı**; Mac QoS **kabul, kriter 5 kanıtsız**. Plan düzenlemeleri uygulandı: 3.4'teki tek akışlı yedek silindi; 4.5 silindi (mezar taşı), 4.6 koşulu yeniden hedeflendi, ses yolu DATAGRAM; 3.3/3.4/3.6/4.1/4.4/4.9/4.11/5.3/5.4/2.6 Faz 0 bulgularına göre güncellendi; risk tablosu ve plan kararı (10) işlendi. Ayrıntı: `2026-11-14-quic-faz0-sonuclar.md` "Karar kapıları".

**Testler (beklenen sonuç).** Sonuç dosyasında her kapının satırı dolu; bu dosyada artık geçerli olmayan koşullu aşama kalmamış; kullanıcı onayı kayıtlı.

**Bitti ölçütü.** Faz 1'e başlanabilir: Mac QUIC yolu (Network.framework mı quinn mi) ve ses/video taşıma kararları kesin. *(Karar: Mac yolu Network.framework (quinn + uniffi gerekmedi); ses DATAGRAM ile; video kare başına uni stream ile. Faz 1'e başlanabilir.)*

### [x] 0.13 Faz 0 genel testi

**Yapılacaklar ve beklenen sonuç.**
- Sonuç dosyasındaki 0.1–0.11 sonuçları eksiksiz ve tarihli; spike dalı `spike/quic-faz0` etiketlenip arşivlendi, ana dala yalnız kalıcı parçalar girecek: 0.1'in çıktısı (crate iskeleti, `build-so.sh`, `QuicCore.kt`, Gradle uyarısı, `.gitignore` satırları), DER yazıcı ve olası DATAGRAM sarmalayıcı; `quicPing` ve Settings'teki geçici satır atılır.
- Regresyon: ana dalda Mac testleri, Android JVM testleri, `bun run lint && npx tsc --noEmit && bun run test` geçer (Faz 0 ana dalı bozmamış).
- Kapı kararları kullanıcı tarafından onaylı.
- **Sonuç (2026-11-19, kullanıcı onaylı kapsam):** spike kodu tek commit olarak arşivlendi (`04b309b`, etiket `archive/quic-faz0`); kalıcı dal `feat/quic-foundation` (`d9812fc` belgeler, `dab3d39` Rust crate + Android build zinciri, `2adbe73` Mac kimliği + hız denetleyicisi) `main`'e birleştirilmedi ve push edilmedi (yerel dal kararı); `files.tsx` düzeltmesi ayrı dalda (`fix/files-too-many-renders`, `955ef9e`, cihazda doğrulanmadı). Regresyon temiz dalda: Mac **174**, Rust **20** + clippy temiz, `:selfadb:testDebugUnitTest` **79 test / 0 hata**, lint + log-gizliliği + `tsc` + bun **59** yeşil. `quicPing`, Settings satırı, `interop_client` ve `spikes/` kalıcı dala girmedi. Ayrıntı: `2026-11-14-quic-faz0-sonuclar.md` "Faz 0 kapanışı".

---

## [ ] Faz 1 — QUIC iskeleti ve iki yönlü `cmd`

Faz 1 sonunda iki uygulama birbirine `cmd` gönderebilir ve bu kanal üzerinden QUIC oturumu açıp kapatabilir; **henüz hiçbir
özellik QUIC kullanmaz.** Büyüklük: **M**. Kontrol düzlemine (`clip`, `note`, `sms`, `file`, `stat`, BLE, LAN HMAC el
sıkışması) dokunulmaz; sunucu (`server/`) değişmez.

### [ ] 1.1 Mac `cmd` göndericisi

**Amaç.** Bugün `cmd` yalnız telefon → Mac yönünde çalışıyor (Mac yalnız çözüyor: `RelayClient.swift:1294`, `LanServer.swift:263`).
Mac → telefon yönünü eklemek.

**Yapılacaklar.**
1. Foundation-only saf yardımcı `CommandFrame` (örn. `mac/Sources/LinkToMac/RelayProtocol.swift` içinde ya da `Quic/QuicControl.swift`):
   `static func make(action: String, keyBase64: String) -> [String: Any]?` → `ClipCodec.encode(action, key, type: "cmd")` ile mühürler,
   `{"t":"cmd","nonce":…,"ct":…}` döner. Test hedefinin derleyebilmesi için dosya `project.yml`'de `LinkToMacTests` kaynaklarına eklenir.
2. `RelayClient.swift`: `func sendCommand(_ action: String) -> Bool` — relay joined ise WS'ye yazar.
3. `LanServer.swift`: `func sendCommand(_ action: String) -> Bool` — auth'lu tek peer'e aynı frame şekliyle yazar.
4. Yönlendirme: tek link üzerinden gider (`lanPeerConnected` ise LAN, değilse relay; dosyadaki "tek taşıma" mantığıyla aynı). İki linke birden
   gönderilmez (çift teslimi önlemek için). Link yoksa `false` döner; kuyruğa alınmaz (`q.req` taze olmalı).
5. Saat farkı: ClipCodec ±120 sn tazelik penceresi geçerli; saat farkı büyükse cmd reddedilir (mevcut davranış, değişmez).

**Dosyalar.** `RelayProtocol.swift` veya `Quic/QuicControl.swift`, `RelayClient.swift`, `LanServer.swift`, `mac/project.yml`, `mac/Tests/CommandFrameTests.swift`.

**Testler (beklenen sonuç).** swift-testing: sabit anahtarla üretilen frame'i telefonun kullandığı `ClipCodec.decode(type:"cmd")` karşılığı çözer ve eylem eşittir;
yanlış anahtar → nil; `type:"clip"` ile çözme → nil (tip bağlama); eski zaman damgası → nil. `xcodebuild … test` geçer, uygulama derlenir.

**Bitti ölçütü.** Mac her iki linke `cmd` yazabiliyor; saf yardımcı testli.

### [ ] 1.2 Android `cmd` alıcısı

**Amaç.** `RelayClient.kt` ve `LanClient.kt` bugün gelen `cmd`'yi dağıtmıyor (yalnız `stat`, `sms`, `file` vb.). Alıcı eklemek.

**Yapılacaklar.**
1. `RelayClient.kt` ve `LanClient.kt`: gelen `"t":"cmd"` frame'i `ClipCodec.decode(nonce, ct, key, "cmd")` ile çözülür → `onCmdReceived(action: String)`.
2. `ConnectionManager.kt`: iki istemciyi tek `onCmd` çıkışında birleştirir (mevcut `onSmsReceived` kalıbı).
3. `ClipForegroundService.kt`: `handleInboundCmd(action)` — `{` ile başlıyorsa JSON dağıtıcıya (1.3) gider; diğer düz string'ler bilinmeyen eylem olarak loglanıp yok sayılır.
4. Log kuralı: yalnız uzunluk ve durum loglanır; eylem metni, sid, port, fp, tok asla (`check-log-privacy.mjs`).

**Dosyalar.** `RelayClient.kt`, `LanClient.kt`, `ConnectionManager.kt`, `ClipForegroundService.kt`, `src/test/.../CmdReceiveTest.kt`.

**Testler (beklenen sonuç).** JVM: ClipCodec ile mühürlenmiş JSON string'in alıcıdan doğru çıktığı; bozuk/yanlış anahtarlı/eski zaman damgalı frame'in istisnasız yok sayıldığı; bilinmeyen düz string'in dağıtıcıya gitmediği.
`./gradlew :selfadb:testDebugUnitTest` ve `bun run lint` (log gizliliği) geçer.

**Bitti ölçütü.** Telefon Mac'ten gelen `cmd`'yi alıp tek noktada dağıtıyor; relay ve LAN'da aynı yol.

### [ ] 1.3 JSON eylemler: `q.req`, `q.accept`, `q.offer`, `q.reject`, `q.end`

**Amaç.** `cmd` eylemi bugün düz string (`"lock"`). Yeni eylemler JSON string olarak gider; eski Mac bunları yok sayar, kırılmaz.

**Yapılacaklar.**
1. Biçimler (hepsi JSON object, string olarak mühürlenir):
   - `{"a":"q.req","sid":"<uuid>","kind":"cast|file|audio|cam", …kind'a özgü alanlar}`
   - `{"a":"q.accept","sid":…}` (isteği alan taraf kabulünü bildirir; telefon, kullanıcı onayından sonra)
   - `{"a":"q.offer","sid":…,"port":<int 1024–65535>,"fp":"<64 küçük hex>","tok":"<base64url, 32 bayt>"}`
   - `{"a":"q.reject","sid":…,"reason":"relay|busy|denied|unsupported|timeout"}`
   - `{"a":"q.end","sid":…}`
2. **Kabul akışı (onaylandı, 2026-11-14):** `q.accept` ile isteği alan taraf kabulünü bildirir. İstek Mac'ten gelirse (cast, cam; kullanıcı onayı gerektirenler) `q.req` → telefon kullanıcı onayı → `q.accept` → `q.offer`. İstek telefondan gelirse (file) kabul adımı yoktur: `q.req` → Mac doğrudan `q.offer` (ya da `q.reject busy|denied`). Mac isteyen taraf iken `q.accept` olmadan `q.offer` gönderilmez; `q.accept` gelmezse oturum `timeout` ile düşer.
3. Mac `handleCommand(_:)` (`RelayClient.swift:1335`): `"lock"` aynen; `{` ile başlıyorsa JSON ayrıştırılıp QUIC denetleyicisine (1.6) verilir; ayrıştırılamayan/bilinmeyen `a` değeri `ignoring unknown action` olarak loglanıp yok sayılır.
4. Android dağıtıcı (1.2) aynı şemayı ayrıştırır.
5. Sınırlar: eylem string'i ≤ 4 KiB; `sid` yalnız UUID; `kind` yalnız dört değer (debug derlemede ek `echo`); bilinmeyen alanlar yok sayılır (ileri uyum).
6. Eski sürüm uyumu: eski Mac JSON eylemi "bilinmeyen eylem" olarak yok sayar, kilitlemez, çökmez.

**Dosyalar.** `mac/Sources/LinkToMac/Quic/QuicControl.swift`, `RelayClient.swift`, `.../quic/QuicControl.kt`, `ClipForegroundService.kt`.

**Testler (beklenen sonuç).** Swift ve Kotlin aynı girdilerle: her eylem doğru ayrışır; geçersiz `sid`/`kind`/`port`/`fp`/`tok` reddedilir; 4 KiB üstü reddedilir; `"lock"` hâlâ kilit eylemi olarak sınıflanır; bilinmeyen JSON eylemi yok sayılır; bozuk JSON istisna fırlatmaz.
Eski Mac sürümüyle elle deneme: yeni eylem gönderildiğinde log satırı çıkar, davranış değişmez.

**Bitti ölçütü.** Her iki uç da yeni eylemleri ayrıştırıyor; `q.accept` akışı (iki istek yönü) ve zaman aşımı testli.

### [ ] 1.4 `stat.caps` (iki yönde)

**Amaç.** Karşı tarafın QUIC desteğini öğrenmek; desteklemiyorsa özellikleri UI'da gizlemek.

**Yapılacaklar.**
1. `stat`'a opsiyonel `caps: ["q1"]` alanı eklenir. Alanlar zaten eklemeli; alıcı yalnız mevcut alanları günceller (batarya/yakınlık frame'lerini ezmez).
2. Mac: `currentStatPayload()` `caps`'i birleştirir; `RelayClient`'ta `peerCaps` saklanır. Telefon: stat üreticisi `caps`'i ekler; `macCaps` saklanır.
3. Peer çevrimdışı olunca `caps` sıfırlanır; sonraki `stat` ile yeniden kurulur. Henüz `stat` gelmediyse "desteklenmiyor" sayılır.
4. `quicAvailable` türetilmiş değeri (LAN-direct link + karşı taraf `q1`) 2. fazdan itibaren UI'ın kullanacağı tek kapı olur.

**Dosyalar.** `RelayClient.swift`, `.../ClipForegroundService.kt`, `.../quic/QuicControl.{swift,kt}`, `protocol-vectors/quic-control.json` (stat bölümü).

**Testler (beklenen sonuç).** Vektör: `caps` içeren stat ayrışır; `caps` içermeyen stat mevcut `caps`'i değiştirmez; peer çevrimdışı olayı `caps`'i sıfırlar; bilinmeyen kapasite adları yok sayılır. Swift ve Kotlin aynı vektörleri geçer.

**Bitti ölçütü.** İki uç birbirinin QUIC desteğini `stat` ile öğreniyor; eski peer'de özellikler kapalı.

### [ ] 1.5 Vektörler: `protocol-vectors/quic-control.json`

**Amaç.** Elle yansıtılan yeni biçimlerin (Swift ↔ Kotlin) kaymasını testle engellemek (mevcut `file-frame.json` yaklaşımı).

**Yapılacaklar.**
1. `quic-control.json`: (a) eylem örnekleri ve geçerli/geçersiz kabul kuralları (1.3), (b) `q.offer` alan doğrulamaları (`fp` 64 küçük hex, `tok` 43 karakter base64url, `port` aralığı), (c) uni stream tip başlığı (varint `0x01/0x02/0x03`), (d) `caps` stat örnekleri (1.4), (e) ALPN değeri (0.3 kararı).
2. `protocol-vectors/README.md` yeni dosyayı anlatır.
3. Swift `QuicControlVectorTests` (`FileFrameVectorTests` kalıbı) ve Kotlin `QuicControlVectorTest` aynı dosyayı `../protocol-vectors/` yolundan okur.

**Dosyalar.** `protocol-vectors/quic-control.json`, `protocol-vectors/README.md`, `mac/Tests/QuicControlVectorTests.swift`, `.../src/test/.../QuicControlVectorTest.kt`.

**Testler (beklenen sonuç).** İki test paketi aynı dosyada geçer. Sağlık denemesi: bir vektör bilerek bozulunca iki paket de kırmızıya döner; geri alınınca yeşil.

**Bitti ölçütü.** Yeni biçimler vektörle sabit, iki platform aynı dosyayı koşuyor.

### [ ] 1.6 Mac `QuicListener` (kimlik, offer, token, zaman aşımları)

**Amaç.** Mac sunucu tarafı: istek gelince UDP dinleyiciyi açmak, `q.offer` göndermek, token'ı doğrulamak, oturumu sonlandırmak.
Bu aşama **0.3 bulgularına** (`docs/plans/2026-11-14-quic-faz0-sonuclar.md`, kullanıcı onaylı 2026-11-14) göre yazıldı: Network.framework'te Mac tarafı bağlantıyı karşı tarafa kapattıramaz, reddetme ve sonlandırma protokol içinde taşınır.

**Yapılacaklar.**
1. 0.2'deki `QuicIdentity` ve DER yazıcı kalıcı koda taşınır (yoksa ilk kullanımda bir kez üretilir); Unpair'de kimlik silinip yeniden üretilir.
2. `Quic/QuicListener.swift`: `NWListener` (UDP, varsayılan 53125; doluysa boş bir port seçilir ve offer'da bildirilir), QUIC seçenekleri (ALPN, TLS 1.3, kalıcı kimlik). Parametreler `NWParameters(quic: options)` ile kurulur. **Dinleyiciye yalnız `newConnectionGroupHandler` atanır** (`newConnectionHandler` de atanırsa dinleyici `EINVAL` ile başlamaz); stream'ler `group.newConnectionHandler` ile alınır ve stream kimliği (`streamIdentifier`) stream `.ready` olunca okunur.
3. Oturum durum makinesi (`Quic/QuicSession.swift`, saf Swift, test edilebilir): `idle → requested → accepted → offered → connected → ended` (telefon isteyen taraf ise `accepted` atlanır); aynı anda tek oturum; ikinci `q.req` → `q.reject busy`.
4. `tok`: `SecRandomCopyBytes` ile 32 bayt, oturum başına; ilk stream'in ilk baytları `tok`; sabit zamanlı karşılaştırma. 5 sn içinde gelmezse ya da eşleşmezse **protokol içinde reddedilir**: oturum stream'inde `NO\n` + FIN yazılır ve karşı taraf bağlantıyı kendisi kapatır. **Bulgu (0.3):** `group.cancel()`, uygulama hata kodu ayarlansa ve oturum stream'i önce iptal edilse bile, karşı tarafa bağlantıyı kapattırmıyor (45 sn sonra bile açık göründü). Reddedilen bağlantı 5 sn içinde kapanmazsa Mac kendi kaynaklarını yine de grubu iptal ederek serbest bırakır.
5. Süreler: oturumu Mac sonlandırırken **önce karşı tarafa söyler** (`q.end` `cmd` + oturum stream'inde `END\n`) ve karşı taraf bağlantıyı kapatır; Mac yerel kaynaklarını (grup, dinleyici) kendi tarafında serbest bırakır ama bunun karşı tarafa kapanış sinyali vermediği (0.3 bulgu 5) hesaba katılır. `q.end` alan ya da 30 sn boşta kalan oturumda dinleyici kapanır (port serbest kalır).
6. Debug derlemede `kind:"echo"`: oturum stream'inde ve DATAGRAM'da gelen baytları geri yazar (0.4 geçti). Release'te yoktur. **Mac DATAGRAM yöntemi (0.4, bulgu 9):** dinleyicide `maxDatagramFrameSize = 1200` (Mac `usableDatagramFrameSize` 1440, quinn `max_datagram_size` 1191); grup `ready` olunca `NWProtocolQUIC.Options` (`isDatagram = true`) ile `group.extract(connectionTo: nil, using:)` çağrılıp datagram akışı alınır, `receiveMessage` döngüsüyle okunur. **Grup düzeyindeki `group.send(content:to:message:)` ve `setReceiveHandler` ile deneme hata vermeden sessizce kaybolur; kullanılmaz.**
7. `NSLocalNetworkUsageDescription` (`Info.plist:55`) yeterli; UDP dinleyici yeni Bonjour girişi istemez. Hardened runtime altındaki davranış Faz 6.8'de ayrıca denenir.
8. **Stream kredisi alıcıda yönetilir (0.5 bulgusu, kullanıcı onaylı 2026-11-15).** Network.framework yeni stream kredisini (MAX_STREAMS) **kendiliğinden vermez**: `initialMaxStreamsUnidirectional = 100` iken gönderici tam 100 uni stream sonra `open_uni()`'de sonsuza dek bekler (stream'ler okunup serbest bırakılmış olsa bile); 2⁶⁰ verilse bile bağlantı tam 4096 stream'de tıkanır (değer kırpılıyor). Çözüm: dinleyici makul bir başlangıç verir (`initialMaxStreamsUnidirectional = 1000`) ve her 10 tamamlanan stream'de grubun `NWProtocolQUIC.Metadata.localMaxStreamsUnidirectional` değerini `tamamlanan + 1000` yapar (`group.metadata(definition: NWProtocolQUIC.definition)`). Hesap saf bir fonksiyondur (`StreamCredit.limit(completed:headroom:)`) ve testlidir. Aynı kural bidi stream'ler için `localMaxStreamsBidirectional` ile yapılır.

**Dosyalar.** `mac/Sources/LinkToMac/Quic/{QuicListener,QuicSession,QuicIdentity,DERWriter}.swift`, `mac/Tests/QuicSessionTests.swift`.

**Testler (beklenen sonuç).**
- swift-testing (saf durum makinesi, enjekte edilen saatle): geçişler; ikinci istek `busy`; 30 sn boşta kapanma; geçersiz token'da kapanma; `q.offer` alanları vektörle uyumlu; token karşılaştırması sabit zamanlı yardımcıyla.
- Telefon olmadan entegrasyon: `quic-core/examples/echo_client.rs` (0.3'teki atılabilir `interop_client.rs`'ten türetilir) Mac üzerinde localhost'a bağlanır — doğru `fp`+`tok` ile echo çalışır; yanlış `tok` ile ilk stream'den ≤ 1 s içinde oturum stream'inde `NO` döner ve istemci bağlantıyı kapatır; yanlış `fp` ile el sıkışma reddedilir; 30 sn sonra `lsof -iUDP:53125` boş.
- Stream kredisi: `StreamCredit` saf birim testi (tamamlanan + pay, sınır değerleri); entegrasyon: istemci localhost'a 5000'den fazla (4096 sınırını aşan) kısa uni stream açar, hiçbiri tıkanmaz ve hepsi alınır (kredi yükseltmesi kapatılınca 4096'da tıkandığı da bir kez doğrulanır).

**Bitti ölçütü.** Mac, istek üzerine dinleyici açıp offer verebiliyor; token/süre kuralları ve stream kredisi yönetimi testli.

### [ ] 1.7 Android quinn çekirdeği + JNI

**Amaç.** Android istemci tarafı: `fp` doğrulamalı bağlantı, stream ve DATAGRAM işlemleri, istatistik, Kotlin arayüzü.

**Yapılacaklar.**
1. Rust API (`quic-core/src/`): `connect(host, port, fp_hex, tok_b64) -> handle`; özel `ServerCertVerifier` yalnız `SHA-256(end-entity DER) == fp` kabul eder (sabit zamanlı karşılaştırma), diğer her şeyi reddeder; yalnız TLS 1.3; ALPN (0.3'te sabitlenen).
2. Transport: keep-alive 5 sn (oturum boyunca), idle timeout 30 sn, DATAGRAM açık, congestion controller varsayılan (0.6 sonucuna göre BBR denenir).
3. İşlemler: oturum bidi stream'i açma (ilk baytlar `tok`), `open_uni(type)`, `accept_uni()`, `send_datagram`, `recv_datagram`, `close(code)`, her 500 ms `stats()` (RTT, cwnd, kayıp).
4. JNI: `quic/QuicCore.kt` (handle `Long`), olaylar Rust iş parçacığından tek bir Kotlin executor'üne aktarılır; RN köprüsünden medya baytı geçmez.
5. `quic/QuicManager.kt`: `q.offer` alınca LAN-direct bağlantının eş adresine (yalnız bellekte, loglanmaz, saklanmaz; `LanClient` bu adresi açığa çıkarır) bağlanır.
6. Hata kodları: `FpMismatch`, `TokenRejected` (oturum stream'inde `NO` alınınca; bağlantıyı Mac kapatmaz, telefon kendisi kapatır, 1.6), `Timeout`, `LinkLost` (Kotlin enum), loglarda yalnız kod adı.
7. **Dosya akışı okuması toplu yapılır (0.6 bulgusu, kullanıcı onaylı 2026-11-15).** quinn her paketi ayrı küçük parça (~1,4 kB) olarak verir; parça başına iş parçacığı geçişi (diske yazma, hash) paket başına ~1 ms'e mal oldu ve hızı ~1 MB/sn'ye düşürdü. Dosya akışlarını okuyan Rust kodu `RecvStream::read_chunks` ile bir çağrıda en çok 64 parça alır, ≥ 1 MiB biriktirdikten sonra tek seferde yazma/hash iş parçacığına verir ve akış bitince (FIN) kalanı atmadan boşaltır. **Medya akışlarına (video/ses) bu birikim uygulanmaz**, orada parça gelir gelmez teslim edilir (gecikme).

**Dosyalar.** `mobile/native-src/quic-core/src/*.rs`, `examples/echo_client.rs`, `.../quic/{QuicCore,QuicManager,QuicSession}.kt`, `LanClient.kt` (adres erişimi), `src/test/.../QuicSessionStateTest.kt`.

**Testler (beklenen sonuç).**
- `cargo test`: doğrulayıcı (eşleşen `fp` geçer; tek bit farklı reddedilir); süreç içi loopback quinn sunucu/istemci echo; token çerçevelemesi; dosya akışı toplayıcısı (≥ 1 MiB'ta ve FIN'de boşaltır, baytlar eksiksiz ve sıralı, medya akışı toplamadan teslim eder). `cargo clippy -- -D warnings` temiz.
- JVM: `QuicSessionStateTest` (durumlar, zaman aşımları saf Kotlin).
- Cihaz: S24 → Mac listener (1.6): doğru `fp`+`tok` → echo; yanlış `fp` → `FpMismatch`; yanlış `tok` → `TokenRejected`; log'larda IP, port, `fp`, `tok` aranır, **bulunmaz**.
- `bun run lint` (log gizliliği) ve `npx tsc --noEmit` temiz.

**Bitti ölçütü.** Telefon, Mac'in offer'ına bağlanıp stream ve DATAGRAM ile echo yapabiliyor; yanlış `fp`/`tok` bağlantı kuramıyor.

### [ ] 1.8 Oturum yaşam döngüsü, link izleme, UI kapısı

**Amaç.** Oturumun link durumuna bağlı güvenli açılıp kapanması ve özelliklerin `caps`'e göre görünmesi.

**Yapılacaklar.**
1. `q.req` geldiğinde aktif link LAN-direct değilse yanıt `q.reject {reason:"relay"}`; isteği yapan taraf kullanıcıya açık mesaj gösterir ("aynı Wi-Fi gerekli" ya da dosya için WS'ye düşme bilgisi — Faz 2 kuralı).
2. Telefonda `ConnectionManager` link değişimi (LAN → relay/yok): tüm QUIC oturumları kapatılır, en iyi çaba `q.end` gönderilir. Mac'te LAN peer düşünce dinleyici kapanır.
3. Mac tarafı debug menü: "QUIC test oturumu" (yalnız `#if DEBUG`); telefon tarafı `__DEV__` ekranında aynı test.
4. UI kapısı: `quicAvailable` (1.4) yoksa QUIC'e bağlı kontroller gösterilmez. Faz 1'de bu yalnız Diagnostics/dev ekranı.

**Dosyalar.** `ConnectionManager.kt`, `QuicManager.kt`, `RelayClient.swift`/`LanServer.swift` (link olayları), `Quic/QuicListener.swift`, dev ekranı.

**Testler (beklenen sonuç).**
- Birim: istek/link durum kombinasyonlarının tablosu (LAN+q1 → devam; relay → `q.reject relay`; `q1` yok → özellik gizli).
- Cihaz (elle): oturum sürerken telefonun Wi-Fi'ı kapatılır → iki uç ≤ 5 sn içinde kapanır, `lsof -iUDP:53125` boş; yalnız-relay yapılandırmada `q.req` açık mesajla reddedilir; **eski Mac sürümü** yeni JSON eylemleri hatasız yok sayar (log satırı, kilitleme yok).

**Bitti ölçütü.** Oturum link kopunca temiz kapanıyor, relay'de açık red mesajı veriyor, eski peer bozulmuyor.

### [ ] 1.9 Tanılama ve log gizliliği

**Amaç.** QUIC durumunu Diagnostics raporuna eklemek; log gizliliği kuralını bozmamak.

**Yapılacaklar.**
1. `use-diagnostics.ts` / `build-report.ts`: QUIC bölümü (oturum açık/kapalı, RTT, kayıp). IP, port, token, fingerprint, `sid` yok.
2. `sanitize.ts`: IP:port ve 64 hex (fp) kalıplarını temizler; `KnownValues`'e QUIC değerleri gerekmiyor (zaten loglanmaz).
3. `scripts/check-log-privacy.mjs`: yasaklı enterpolasyon adlarına `tok`, `fp`, `port`, `sid` eklenir; `check-log-privacy.test.mjs` bunlar için olumsuz test içerir.

**Dosyalar.** `mobile/src/features/diagnostics/{build-report,use-diagnostics,sanitize}.ts`, ilgili `*.test.ts`, `mobile/scripts/check-log-privacy.{mjs,test.mjs}`.

**Testler (beklenen sonuç).** `bun run test`: raporda QUIC bölümü var ve hassas değer içermiyor; sanitizer örnek satırdaki IP:port/fp'yi temizliyor; kötü bir log satırı (`${tok}`) `check-log-privacy` tarafından yakalanıyor. `bun run lint` ve `npx tsc --noEmit` temiz.

**Bitti ölçütü.** Rapor QUIC durumunu gösteriyor, hassas veri sızmıyor, kural otomatik denetleniyor.

### [ ] 1.10 Dokümantasyon güncellemesi (Faz 1)

**Yapılacaklar.** `mobile/CLAUDE.md` (modül dosya tablosu: `QuicCore`, `QuicManager`, `QuicControl`; `cmd` artık iki yönlü), `mac/CLAUDE.md` (`Quic/` dosyaları, `RelayClient.sendCommand`, `handleCommand` JSON eylemleri), kök `CLAUDE.md` (invariants: `cmd` iki yönlü ve JSON eylemler, `caps`), `protocol-vectors/README.md`, `TECHNICAL.md` §5 (kontrol eklemeleri; tam bölüm §5.6 Faz 6.11'de).

**Testler (beklenen sonuç).** Değişen her kod yoluna karşılık gelen CLAUDE.md satırı güncel; dosya adı/satır atıfları gerçek (grep ile doğrulanır).

**Bitti ölçütü.** Dokümanlar kodla uyumlu.

### [ ] 1.11 Faz 1 genel testi

**Beklenen sonuç.** Tüm bileşen testleri (tabloda) geçer. Uçtan uca senaryo: (1) Mac → telefon ve telefon → Mac `cmd` relay'de ve LAN'da çalışır; (2) Mac test oturumu ister, telefon offer ile bağlanır, stream ve DATAGRAM echo geçer;
(3) relay'deyken istek açık mesajla reddedilir; (4) yanlış `fp` ya da `tok` ile bağlantı kurulamaz; (5) eski sürüm uygulama yeni eylemleri hatasız yok sayar; (6) mevcut özellikler (pano, bildirim, SMS, kilit, pil, medya, dosya) regresyonsuz.

---

## [ ] Faz 2 — LAN'da sınırsız dosya transferi

Dosya özelliğinin kullanıcıya görünen her şeyi (Files ekranı, geçmiş, bildirimler, dürüst alındı bilgisi, klasörler, resume)
aynen kalır; yalnızca LAN'da taşıma katmanı değişir. Büyüklük: **M**. Bağımlılık: Faz 0 kapıları ("10 GB hız", "MediaStore
doğrudan yazma", "kalıcı kimlik") ve Faz 1. Bu üç kapı **geçti** (0.12); "10 GB, LAN WS'den yavaş değil" 1 GiB medyanlarıyla doğrulandı (QUIC 2,0× ve 1,4×), 10 GB'ta WS ölçülemedi.

### [ ] 2.1 Taşıma seçimi

**Amaç.** Her dosya için hangi yoldan gideceğini tek yerde, saf bir fonksiyonla belirlemek.

**Yapılacaklar.** Karar tablosu (Swift ve Kotlin'de aynı mantık, vektörle sabit):

| Durum | Yol | Boyut sınırı |
|---|---|---|
| LAN-direct + karşı taraf `q1` bildiriyor | QUIC, dosya başına bir bidi stream | Yok (boş alan kontrolü) |
| Relay ya da eski peer | Mevcut WS `file` yolu (§5.4) | 1 GiB, değişmez |
| Pano görselleri | Her zaman mevcut WS yolu | Tek frame |

Ek durum: relay'deyken 1 GiB'tan büyük dosya → "LAN bekleniyor" (2.8). Fonksiyon: `FileTransportChoice.choose(link:, peerCaps:, size:, isClipboardImage:) -> .quic | .ws | .waitForLan | .tooLarge`.
Mevcut gönderici giriş noktaları (Mac `FileSender`, Android `sendAsFile`) dosya başına bu fonksiyonu çağırır; WS yolu **değişmez**.

**Dosyalar.** `mac/Sources/LinkToMac/Quic/FileTransportChoice.swift`, `.../quic/FileTransportChoice.kt`, `protocol-vectors/quic-control.json` (karar tablosu bölümü), iki platformda test.

**Testler (beklenen sonuç).** Aynı vektörle Swift ve Kotlin: tüm kombinasyonlar (link × caps × boyut × pano) tablodaki sonucu verir; 1 GiB sınırı tam eşikte (1 GiB WS, 1 GiB+1 bayt `waitForLan`) doğru. Mevcut `FileSender`/`AckWindow`/`FileFrame` testleri değişmeden geçer.

**Bitti ölçütü.** Yol seçimi tek fonksiyonda, iki platformda eş.

### [ ] 2.2 QUIC dosya akış protokolü + vektörler

**Amaç.** Dosya başına bir bidi stream üzerinden başlık → `have` → ham bayt → sonuç.

**Yapılacaklar.**
1. **Karar (onaylandı, 2026-11-14):** dosya bidi stream'i de aynı tip varint'iyle (`0x01`) başlar; `0x02` ekran ve `0x03` kamera uni stream'lerdir. Referanstaki "Kanallar" bu karara göre yazıldı.
2. Gönderen bidi stream açar: `varint 0x01`, ardından başlık: `u16 BE uzunluk ‖ JSON` — §5.4 başlığının aynısı (`name`, `dir`, `mime`, `id`) + `size` + `mtime`.
3. Alıcı başlığı doğrular (2.3/2.4 kuralları) ve aynı stream'de `u16 BE ‖ {"have": <bayt>}` ile cevap verir (yeni dosyada 0); reddederse `{"ok":false,"err":"space|busy|bad-id|write|too-many"}` yazıp stream'i kapatır.
4. Gönderen `have` kadar atlayıp ham baytları yazar ve gönderme yönünü kapatır. QUIC güvenilir ve sıralı olduğundan chunk, ack penceresi ve pacing yoktur.
5. Alıcı dosya son yerine taşındıktan **sonra** `{"ok":true}` yazar; ancak o zaman "gönderildi" gösterilir. Yazılamazsa `{"ok":false,"err":…}`.
6. Alan sınırları: `name` ≤ 200 bayt (mevcut sanitizer), `dir` mevcut `sanitizeDir`, `id` tam 8 küçük harf hex (`^[0-9a-f]{8}$`), `size` ≥ 0.
7. **Mac gönderirken sunucu başlatan stream (0.3 bulgu 4, kullanıcı onaylı):** Network.framework sunucusunun ilk `NWConnection(from: group)` stream'i kimlik 1 değil **5** alır; kimlik 1'i çerçeve grup için kendisi tutar ve karşı taraf onu **veri taşımayan fazladan bir sunucu başlatan bidi stream** olarak görür (quinn `accept_bi` onu ilk sırada verir). Telefon (alıcı) kabul ettiği her sunucu başlatan stream'i ilk bayt tipinden (`0x01`) tanır; bayt taşımayan stream'leri **yok sayar** ve onların zaman aşımını beklemez (stream başına kısa bir ilk-bayt süresi, öneri 2 sn, o sırada gerçek stream'ler paralel işlenir). Bu, yalnız Mac'in başlattığı stream'leri etkiler; telefonun başlattığı stream'ler (ekran, ses, kamera, telefon → Mac dosya) etkilenmez.

**Dosyalar.** `Quic/QuicFileStream.swift`, `.../quic/QuicFileStream.kt`, `quic-core/src/file.rs`, `protocol-vectors/quic-control.json` (dosya akışı bölümü).

**Testler (beklenen sonuç).** Vektörler (başlık/`have`/sonuç baytları, geçersiz `id`, taşan `name`, `size` uyuşmazlığı) Swift, Kotlin ve Rust testlerinde aynı sonuçları verir.
Süreç içi quinn loopback testi: küçük dosya, `have` ile atlayan dosya, reddedilen dosya (hash ve bayt sayıları doğrulanır). Fazladan boş sunucu başlatan stream'i simüle eden test: boş stream yok sayılır, ardından gelen gerçek dosya stream'i doğru işlenir ve boş stream gerçek stream'i geciktirmez.

**Bitti ölçütü.** Dosya akışının her baytı vektörle sabit, üç uç tutarlı.

### [ ] 2.3 Android alıcı: doğrudan MediaStore yazımı, id doğrulama, boş alan, bitiş

**Amaç.** Android'de QUIC ile gelen dosyayı güvenle yazmak ve bitirmek. *(Yeniden yazıldı, kullanıcı onaylı 2026-11-19, 0.10 sonucu: eskiden dosya önce `noBackupFilesDir/inbox/<id>.qpart`'a yazılıp bitişte Downloads'a kopyalanacaktı (`FileInbox.kt:208`, 2× disk, 10 GiB'ta +25 sn). Artık veri baştan sona **doğrudan** `IS_PENDING=1` MediaStore girdisine yazılır; bitiş kopyası ve 2× alan rezervasyonu yoktur.)*

**Yapılacaklar.**
1. **Yarım dosya = MediaStore bekleyen girdisi.** `MediaStore.Downloads` altında `RELATIVE_PATH = Download/Link to Mac[/<dir>]`, `IS_PENDING=1`, `DISPLAY_NAME` = temizlenmiş **son ad** (ad çakışmasını MediaStore çözer). Yazma `openFileDescriptor(uri, "rw")` + `FileChannel.position(offset)` ile ≥ 1 MiB bloklarla yapılır (0.10'da ölçülen yol). `cacheDir`'e ve `noBackupFilesDir`'e **veri yazılmaz**; WS yolu (`in-<id>` temp, `cacheDir`) bugünkü gibi kalır.
2. **Kayıt defteri (`PendingJournal`).** `id → {MediaStore satır no, ad, dir, size, başlangıç, son etkinlik}`, `noBackupFilesDir/inbox/journal.json` (Auto Backup dışı), atomik yazım (tmp + yeniden adlandırma). Düz Kotlin sınıfı, JVM'de test edilir. `id` yazılmadan önce `^[0-9a-f]{8}$` ile doğrulanır, uymayan reddedilir (`bad-id`); bu kez `id` dosya adı olmadığı için doğrulama yalnız kayıt defteri anahtarını korur.
3. **Resume (`have`).** Aynı `id` için kayıt defteri kaydı varsa satır **doğrulanır**: satır var, `IS_PENDING=1`, `OWNER_PACKAGE_NAME` bizim paket (başka uygulamanın satırı eşleşmez). Gerçek uzunluk `statSize`'tan alınır (SIZE sütununa güvenilmez). `have = floor(uzunluk / 1 MiB) × 1 MiB` (0.10: yırtık son blok yeniden yazılır, aşağı yuvarlamayla resume bayt bayt doğru). Satır yoksa ya da bekleyen değilse kayıt silinir, `have = 0` ile yeni girdi açılır.
4. **Boş alan:** `size − have` + sabit pay (**64 MiB**; 0.10'da her 10 GiB yazma boş yeri tam 10,7 GB düşürdü, sapma görülmedi, pay ayarlanabilir). Yetmezse stream `{"ok":false,"err":"space"}` ile kapanır. Eski ara kural `(size − have) + size` **kalktı**.
5. **Bitiş:** veri tam yazılıp `force(false)` yapıldıktan sonra `IS_PENDING=0` güncellemesi (0.10'da ~anında); dosya boyutu başlıktaki `size`'a eşit olmalı. Başarılıysa kayıt defteri kaydı silinir ve `{"ok":true}` **yalnız bundan sonra** yazılır. Başarısızsa `{"ok":false,"err":"write"}`, bekleyen girdi ve kayıt **korunur** (resume için). Geçmiş ve bildirimler mevcut yoldan (`FileHistory`, `postReceivedNotification`), URI olarak bitmiş satırın URI'si.
6. **Kendi bekleyen girdilerini temizleme (0.10 bulgu 88–90).** MediaStore `DATE_EXPIRES`'ı bu cihazda ayarlanamaz ve yenilenemez (**sabit 7 gün**), terk edilmiş bir bekleyen girdi Dosyalar'da görünmeden 7 güne kadar yer kaplayabilir. Bu yüzden uygulama kendisi temizler: (a) servis açılışında ve her kesin başarısız / iptal sonrasında sorgu `QUERY_ARG_MATCH_PENDING` + `OWNER_PACKAGE_NAME` = bizim paket + `IS_PENDING=1` + `RELATIVE_PATH` `Download/Link to Mac%`; (b) kayıt defterinde **olmayan** veya son etkinliği **6 saatten eski** olan satırlar silinir (6 saat = 2.6'daki QUIC yarım dosya süresi; süre sahipliği artık `DATE_EXPIRES`'ta değil bizde); (c) başkasının satırlarına ve bekleyen olmayan dosyalara dokunulmaz. (2.6 madde 6'daki "yarım dosyalar sessizce silinmez" kuralının Android karşılığı 2.6'da yeniden ele alınır; bkz. sondaki "Açık plan netleştirmeleri".)
7. Alıcı sınırları: en fazla 2 eş zamanlı transfer (aşılırsa `too-many`), mevcut ad ve klasör temizleyicileri.
8. **Yazma toplu yapılır (0.6 bulgusu, onaylı 2026-11-15):** gelen veri 1.7 madde 7'deki toplayıcıdan ≥ 1 MiB'lık bloklarla bekleyen girdinin fd'sine yazılır ve akarken SHA-256 hesaplanıyorsa aynı bloklar üzerinden hesaplanır; paket başına ayrı yazma/iş parçacığı geçişi yapılmaz. (Resume sonrası SHA-256 için önek yeniden okunur; 0.10'da geri okuma 10 GiB'ı sorunsuz doğruladı.)

**Dosyalar.** `FileInbox.kt` (QUIC alıcı yolu), `ClipForegroundService.kt`, `quic/QuicFileReceiver.kt`, `quic/PendingJournal.kt`, `quic/MediaStorePending.kt` (MediaStore işlemleri, 0.10 spike'ındaki `MediaStoreOps` temel alınır), `src/test/.../QuicFileReceiverTest.kt`, `PendingJournalTest.kt`.

**Testler (beklenen sonuç).** JVM (geçici dizinle, sahte MediaStore ve boş alan sağlayıcısıyla): geçersiz `id` reddedilir; kayıt defteri atomik yazılır ve yeni örnekte geri kurulur; `size − have` + pay kuralı sınırda doğru (yetmeyen reddedilir, yeten geçer; eski `+ size` kuralı artık gerekmez); `have` 1 MiB'a **aşağı** yuvarlanır (0, tam blok, blok−1, blok+1); bitişte `IS_PENDING=0` çağrılır, kayıt silinir ve `{"ok":true}` yalnız bundan sonra döner; bitiş güncellemesi başarısızsa `{"ok":false,"err":"write"}` ve girdi korunur; satır silinmiş / bekleyen değil / başka paketin ise kayıt düşer ve `have = 0`; temizleyici yalnız kendi, kayıt defterinde olmayan ya da 6 saatten eski bekleyen satırları siler (enjekte saat; başkasının ve bekleyen olmayan satıra dokunmaz); üçüncü eş zamanlı transfer `too-many`; Mac'in başlattığı stream'de önce gelen boş (kimlik 1) stream yok sayılır ve gerçek dosya stream'i işlenir (2.2 madde 7). Mevcut `FileInboxTest`/`FileSinkTest` değişmeden geçer.
Cihaz: 2 GB dosya telefona gelir, **bitişte ek kopya süresi yok**, Downloads'ta görünür, SHA-256 eşit, aktarım sırasında telefonun boş yeri yalnız dosya boyu kadar düşer (2× değil); aktarım ortasında uygulama `kill -9` ile öldürülür, yeniden başlayınca bekleyen girdi bulunur ve devam edilir. Rust birim: parça parça gelen veri ≥ 1 MiB'lık toplu yazmalara dönüşür, son kalan FIN'de yazılır, dosya baytları eşit.

**Bitti ölçütü.** Android alıcı QUIC dosyasını doğrudan MediaStore'a yazıp doğru ve güvenli bitiriyor; yarım dosyalar 2× alan ve bitiş kopyası olmadan resume ediliyor; terk edilmiş bekleyen girdiler uygulama tarafından temizleniyor.

### [ ] 2.4 Mac alıcı: dizin, yedekleme dışı, id doğrulama, boş alan, bitiş

**Amaç.** Mac'te QUIC ile gelen dosyayı güvenle yazmak; Kaydetme klasörü başka bir diskteyse kopya maliyetini hesaba katmak.

**Yapılacaklar.**
1. Yarım dosya dizini: `~/Library/Application Support/LinkToMac/inbox/` (`FileDrop.swift:237` bugün `temporaryDirectory` kullanır; macOS orayı temizleyebilir). Dizine `isExcludedFromBackup = true` (Time Machine'e girmez). Yalnız QUIC yolu yeni dizini kullanır.
2. Dosya adı `<id>.qpart`; **Mac bugün temp adlarını bilerek rastgele UUID veriyor** (`FileDrop.swift:339`) ki güvenilmeyen `id` dosya yolunu yönlendiremesin. `id` dosya adı olacağı için `^[0-9a-f]{8}$` doğrulaması zorunlu, uymayan `bad-id` ile reddedilir.
3. Boş alan: yarım dosya diskinde `size − have`; Kaydetme klasörü (`FileDropStore.folder`) **başka bir diskteyse** (`volumeIdentifierKey` farklı → yeniden adlandırma kopyaya dönüşür) o diskte ayrıca `size`.
4. Bitiş: mevcut `moveIn` (yeniden adlandırma/taşıma) → `{"ok":true}`; `FileDropStore` çakışma kuralları (ad 2, ad 3 …) ve `MacNotifier` özet bildirimi mevcut yolla.
5. Sınırlar: en fazla 2 eş zamanlı transfer; mevcut sanitizer'lar.

**Dosyalar.** `FileDrop.swift`, `Quic/QuicFileReceiver.swift`, `mac/Tests/QuicFileReceiverTests.swift`.

**Testler (beklenen sonuç).** swift-testing (geçici dizin, sahte hacim kimliği ve boş alan): geçersiz `id` (`../x`, büyük harf, 7/9 karakter) reddedilir; farklı hacimde `size − have` + `size` gerekir, aynı hacimde yalnız `size − have`; dizin `isExcludedFromBackup` değerini taşır; bitişte `{"ok":true}` yalnız taşımadan sonra. Mevcut `FileInboxTests` değişmeden geçer.
Cihaz: 2 GB dosya Mac'e gelir, Kaydetme klasöründe görünür, SHA-256 eşit; Kaydetme klasörü harici diskte iken de çalışır.

**Bitti ölçütü.** Mac alıcı QUIC dosyasını kalıcı ve yedekleme dışı dizine yazıp doğru bitiriyor.

### [ ] 2.5 Gönderen taraflar

**Amaç.** Her iki yönde QUIC ile dosya göndermek; mevcut toplu gönderim, ilerleme ve iptal giriş noktalarına bağlanmak.

**Yapılacaklar.**
1. Transfer `id`: mevcut deterministik formül `SHA-256(name|size|mtime|dir)` ilk 8 hex (değişmez). Aynı dosya tekrar gönderilince resume çalışır.
2. Android gönderen: paylaşım/seçici URI'sinden `openFileDescriptor` ile alınan fd `detachFd()` ile doğrudan Rust'a verilir (JNI üzerinden bayt kopyalanmaz); Rust fd'den okur, `have` kadar atlar (seek), akıtır. Mevcut `SendItem`/`FolderWalker`/`FileHistory` korunur.
3. Mac gönderen: `FileHandle` → QUIC stream; gönderim tamamlanma geri çağrılarıyla geri basınç; mevcut `FileBatchPlanner`/`BatchProgress`/`cancelOutgoing()` korunur. **FIN ayrı gönderilir (0.6 bulgusu, kullanıcı onaylı 2026-11-15):** veri hep `contentContext: .defaultMessage, isComplete: false` ile gider; FIN, son veri parçasından hemen sonra ayrı, boş bir `.finalMessage` gönderimiyle (`content: nil, isComplete: true`) verilir. Veri taşıyan bir `.finalMessage`, uçuşta başka gönderimler varken sonunu karşıya teslim etmedi (son ~1–2 MB eksik kaldı) ve gönderimin tamamlanma bildirimi gelmedi. Aynı anda en çok 4 gönderim uçuştadır (0.6'da ölçülen). Bu kural Mac'in başlattığı her stream için geçerlidir.
4. Alıcıdan `{ok:true}` gelmeden transfer "gönderildi" sayılmaz (dürüst alındı bilgisi); `{ok:false, err}` kullanıcıya anlamlı hata olarak gösterilir.
5. Hız sınırı hazırlığı (0.7 sonucu, kullanıcı onaylı 2026-11-18): Mac → telefon gönderimi, hızı **çalışma sırasında değiştirilebilen** bir token-bucket'tan geçer (spike'taki `TokenBucket`: hız B/sn, 0 = sınırsız, burst 64 KiB, gönderim parçası 64 KiB, `setRate(_:nowNs:)` önce birikmiş jetonları eski hızla işler, sonra yeni hızı uygular). Sınırlıyken uçuştaki veri en çok 1 MiB'dır (`inFlightMax`); sınırsızken 0.6'daki gibi en çok 4 gönderim. Varsayılan sınırsız; hızı Faz 6.1'in `DelayRateController`'ı (`Quic/DelayRateController.swift`, 0.7'de yazılıp test edildi) 100 ms'de bir ayarlar. Sabit bir "%50" hızı yoktur.

**Dosyalar.** `FileTransfer.swift`/`Quic/QuicFileSender.swift`, `ClipForegroundService.kt`/`quic/QuicFileSender.kt`, `quic-core/src/file.rs`.

**Testler (beklenen sonuç).** Birim: `id` formülü iki platformda aynı vektörle; `have` kadar atlama (gönderilen bayt sayısı = `size − have`); `{ok:false}` hata eşlemesi. Cihaz: 200 MB dosya her yönde gider, alıcıda SHA-256 eşit; çok dosyalı bırakma tek toplu ilerleme/özet gösterir; 2.1'e göre eski peer'e WS yolu kullanılır. Mac göndericisi için ayrıca localhost'ta 64 MiB: son bayt teslim edilir, FIN gelir, gönderim tamamlanma bildirimi alınır ve SHA-256 eşit (veri taşıyan `.finalMessage` ile bu test başarısız olurdu). Referans sayılar (0.6, bilgi amaçlı, eşik değil): 1 GiB ilk dakikalarda ~22 MB/sn, 10 GiB'ta telefon ısındıkça ortalama ~14 MB/sn.

**Bitti ölçütü.** İki yönlü QUIC dosya gönderimi mevcut arayüzlerle çalışıyor.

### [ ] 2.6 Saklama süresi, açılışta tarama, kalıcı dizin

**Amaç.** Yarım dosyaların uygulama yeniden başlayınca da kullanılabilmesi. Bugün iki alıcı da yarım dosya dizinini **bellekte** tutuyor ve açılışta 1 saatten eski temp dosyalarını siliyor (`FileInbox.kt` `init`, Mac `FileInbox` açılışı); yeniden başlayan süreç yarım dosyayı tanımaz (TECHNICAL.md §5.4).

**Yapılacaklar.**
1. Süre aktarım başına tutulur: yalnız WS'den gelen yarım dosya **10 dk** (bugünkü değer; Android `FileInbox.TTL_MS`, Mac `FileInbox`'ın `ttl` parametresi), QUIC'e bir kez değmiş olan **6 saat**. Süre bugün global; transfer kaydına alan olarak taşınır.
2. Açılışta QUIC dizininde temizlik yerine **tarama**: yalnız `^[0-9a-f]{8}\.qpart$` kalıbına uyan dosyalar tanınır (başkaları yok sayılır/silinir). Bellekteki kayıt dosyalardan geri kurulur: `id` = dosya adı, boyut = dosya uzunluğu, son yazma = dosyanın `mtime`'ı. Süresi dolanlar silinir. **Android (0.12, 0.10 sonrası):** QUIC yarım dosyası `.qpart` değil MediaStore bekleyen girdisidir (2.3); tarama `PendingJournal` kayıtlarını okur: `id` = kayıt anahtarı (`^[0-9a-f]{8}$`), boyut = `statSize` (SIZE sütununa güvenilmez), son etkinlik = kayıt alanı; her kayıt için satır doğrulanır (var, `IS_PENDING=1`, sahibi bizim paket), doğrulanamayan kayıt düşer; süresi dolan satır silinir (2.3 madde 6).
3. WS yarım dosyaları bugünkü kuralla kalır (açılışta 1 saatten eskiler silinir).
4. Yeniden başlamadan sonra dosyanın kuyruğu bozuk olabileceği için resume noktası son chunk sınırına aşağı yuvarlanır: `floor(bayt / 640 KiB) × 640 KiB`, dosya o sınıra kısaltılır (truncate); `have` bu değerden bildirilir. **Android:** QUIC `have` = `floor(uzunluk / 1 MiB) × 1 MiB` (2.3 madde 3; yazma bloğu 1 MiB, yırtık blok 0.10'da denendi) ve **kısaltma yapılmaz** (MediaStore fd'sinde `truncate` ölçülmedi; fazlalık yeniden yazımla ezilir); 640 KiB yuvarlaması yalnız WS devrinde (2.7).
5. Mac'in 15 sn'lik `sweep()` zamanlayıcısı ve Android'in boşta çıkarma kuralı transfer başına süreyi kullanır. Android'de süre kayıt defterindeki son etkinliğe göredir; MediaStore'un kendi `DATE_EXPIRES`'ı (7 gün) ayarlanamaz, bu yüzden süreyi temizleyici uygular (2.3 madde 6).
6. Yarım dosyalar sessizce silinmez; süreleri dolunca ya da Files ekranından temizlenir (Android'de "temizlenir" = bekleyen satırın silinmesi).

**Dosyalar.** `FileInbox.kt`, `FileDrop.swift` (`FileInbox`), `quic/PartialStore.kt` (Android: 2.3'teki `PendingJournal` + `MediaStorePending` üzerinde), `Quic/PartialStore.swift`.

**Testler (beklenen sonuç).** Birim (geçici dizin, enjekte saat): yeni `FileInbox` örneği (süreç yeniden başlangıcı simülasyonu) yarım dosyayı kayıt olarak geri kurar (Mac: `.qpart`; Android: `PendingJournal` kaydı + sahte MediaStore satırı) ve `have` doğru döner; 6 saat dolmuş dosya silinir, dolmamışı kalır; kalıba uymayan dosya adı yok sayılır; WS yarım dosyası 1 saatten eskiyse açılışta silinir (davranış değişmedi); son chunk sınırına yuvarlama ve kısaltma doğru (Mac: 640 KiB, ör. 1,6 chunk → 1 chunk; Android: `have` 1 MiB'a aşağı, kısaltma çağrılmaz).
Cihaz: 3 GB transferin ortasında uygulamayı öldür (Android: One UI öldürme benzetimi `adb shell am kill`; Mac: uygulamayı sonlandır), yeniden aç, aynı dosyayı gönder → kaldığı yerden sürer.

**Bitti ölçütü.** Yeniden başlatmadan sonra QUIC yarım dosyası 6 saat boyunca devam ettirilebiliyor.

### [ ] 2.7 Çapraz resume (WS ↔ QUIC)

**Amaç.** Aynı dosyanın bir bölümü bir yoldan, kalanı diğerinden gelebilsin (link relay'e düşünce ya da LAN'a dönünce). *(Android tarafı yeniden yazıldı, kullanıcı onaylı 2026-11-19, 0.10 sonucu: QUIC'e değen yarım dosya artık `.qpart` değil, 2.3'teki MediaStore bekleyen girdisidir.)*

**Yapılacaklar.**
1. Tek `PartialStore` soyutlaması (id → yarım dosya). **Mac:** QUIC'e değen yarım dosya `<id>.qpart` olarak kalıcı dizine alınır (WS-only `.part`'tan atomik yeniden adlandırma; hacim farklıysa kopya) — değişmedi. **Android:** QUIC'e değen yarım dosya 2.3'teki MediaStore bekleyen girdisi + `PendingJournal` kaydıdır. WS-only `.part` (`cacheDir`), QUIC `have` isteğinde bekleyen girdiye **kopyalanarak** devredilir (en çok 1 GiB, yalnız link değişiminde bir kez; kopya bitince `.part` silinir). QUIC'e bir kez değince 6 saatlik süre geçerlidir; süre **uygulamanın kendi kuralıdır** (2.3 madde 6), MediaStore `DATE_EXPIRES`'ı ayarlanamaz ve 7 gün sabittir.
2. WS yolu, `id` için kayıt defterinde (Android) ya da kalıcı dizinde `.qpart` (Mac) varsa onu açar ve chunk'ları `seq × 640 KiB` konumuna yazar (WS'in mevcut konumlama kuralı). Android'de açma, 2.3 madde 3'teki doğrulamadan geçen bekleyen girdinin `"rw"` fd'siyle olur. WS yoluyla biten böyle bir transfer **kopyalanmaz**: `IS_PENDING=0` yapılır ve kayıt silinir.
3. Formüller (vektörle sabit): WS → QUIC: `have_bytes = have_chunks × 640 KiB`. QUIC → WS: `have_chunks = floor(have_bytes / 640 KiB)`; yarım kalan son chunk yeniden gelir. Mac'te temp dosya bu sınıra kısaltılır (truncate). **Android'de kısaltma gerekmez:** bekleyen girdideki fazlalık, yeniden gelen chunk'ların üzerine yazılır ve dosya uzunluğu `size`'ı aşamaz; MediaStore fd'sinde `FileChannel.truncate` 0.10'da **ölçülmedi**, bu yüzden kullanılmaz.
4. Yalnız 1 GiB altı dosyalar WS'e düşebilir; üstü 2.8'e gider.

**Dosyalar.** `PartialStore.{kt,swift}`, `quic/PendingJournal.kt`, `FileInbox.kt`, `FileDrop.swift`, `protocol-vectors/quic-control.json` (çapraz resume formülleri).

**Testler (beklenen sonuç).** Vektör: iki formül, sınır değerleri (0, tam chunk, chunk−1, chunk+1, 1 GiB) iki platformda aynı. Birim: Mac'te WS-only `.part` QUIC `have` isteğinde `.qpart`'a devredilir; Android'de WS-only `.part` bekleyen girdiye kopyalanır, önek bayt bayt eşit ve `.part` silinir; QUIC yarım dosyası (Mac `.qpart`, Android bekleyen girdi) WS chunk'ıyla devam eder ve fazlalık üzerine yazılır (Android'de kısaltma çağrılmaz); WS yoluyla biten Android transferi `IS_PENDING=0` yapar, kopya oluşturmaz; devir sırasında veri kaybı yok (hash).
Cihaz: 500 MB dosya QUIC ile başlar, Wi-Fi → mobil veri geçişinde relay'den biter, SHA-256 eşit; tersi (WS başlar, LAN'da QUIC bitirir) de eşit.

**Bitti ölçütü.** Link değişiminde 1 GiB altı dosya iki taşıma arasında bozulmadan devam ediyor.

### [ ] 2.8 Link değişimi: "LAN bekleniyor"

**Amaç.** 1 GiB'tan büyük dosyanın relay'e düşünce nasıl davranacağını netleştirmek (WS sınırı yüzünden devam edemez).

**Yapılacaklar.**
1. LAN'da süren transfer sırasında link relay'e geçerse: 1 GiB'a kadar dosya WS'den devam eder (2.7); daha büyüğü "LAN bekleniyor" durumunda **duraklar** (hata değil).
2. Files ekranı bu durumu gösterir (uygulama dili İngilizce: örn. "Waiting for local network") ve **otomatik** yeniden dener: LAN-direct link geri gelince aynı dosya aynı `id` ile gönderilir, `have` ile kaldığı yerden sürer.
3. Mevcut `Interrupted` davranışı (öldürülmüş süreçteki `active` satır) korunur; "LAN bekleniyor" yeni bir durum olarak `FileHistory`'de saklanır.
4. Mac tarafı gönderici için aynı mantık (`FileSender` durumu + sürükle-bırak toplu ilerleme etiketi).

**Dosyalar.** `FileHistory.kt`, `files.tsx`/`use-file-history.ts`, `ConnectionManager.kt` (link olayı), Mac `FileSender`/`BatchProgress`, ilgili testler.

**Testler (beklenen sonuç).** Durum makinesi birim testi (sahte link olayları): `active → waitForLan → active/resumed`; 1 GiB altı `waitForLan`'a girmez; otomatik yeniden deneme yalnız LAN dönünce olur. Cihaz: 3 GB QUIC transferi sırasında telefon Wi-Fi → mobil veri: Files "bekleniyor" gösterir; Wi-Fi dönünce kendiliğinden devam eder, hash eşit.

**Bitti ölçütü.** Büyük dosya relay'de hata vermeden bekliyor ve LAN'a dönünce sürüyor.

### [ ] 2.9 İptal, eş zamanlılık, bildirim/ilerleme, geçmiş uyumu

**Amaç.** Kullanıcıya görünen davranışı QUIC yolunda da aynı tutmak.

**Yapılacaklar.**
1. İptal QUIC yolunda iki taraflı: `RESET_STREAM` / `STOP_SENDING`. `caps` ile kapılandığı için eski peer bozulmaz; WS yolundaki tek taraflı iptal aynen kalır. İptalde alıcı yarım dosyayı süresi boyunca korur (resume mümkün).
2. Eş zamanlı transfer: alıcı başına en fazla 2 (mevcut); aşan `too-many`.
3. Bildirim ve ilerleme: mevcut toplu bildirim mantığı (tek güncellenen bildirim, 30 sn sessizlikte yeni küme); RN'e saniyede en fazla 4 ilerleme olayı (`PROGRESS_THROTTLE_MS` kuralıyla uyumlu).
4. Files geçmişi: QUIC satırları mevcut durumları kullanır (`queued/active/done/failed/cancelled` + 2.8'in yeni durumu); "gönderildi" yalnız `{"ok":true}` ile.

**Dosyalar.** `ClipForegroundService.kt`, `FileHistory.kt`, `RelayClient.swift` (bildirim/ilerleme yolu), `Quic/QuicFileSender.swift`.

**Testler (beklenen sonuç).** Birim: iptal sonrası yarım dosya korunur ve aynı `id` ile devam eder; ilerleme olayı hız sınırı (1 sn'de ≤ 4); üçüncü eş zamanlı transfer reddedilir. Cihaz: iptal iki yönde de karşı tarafı temiz bırakır (stream kapanır, bildirim kalkar); 50 dosyalık klasör tek bildirim ve tek özetle biter.

**Bitti ölçütü.** Kullanıcı arayüzü ve bildirimler WS yoluyla birebir aynı hissettiriyor.

### [ ] 2.10 Dokümantasyon güncellemesi (Faz 2)

**Yapılacaklar.** `mobile/CLAUDE.md` (FileInbox/PartialStore, `noBackupFilesDir`, QUIC alıcı/gönderen dosyaları), `mac/CLAUDE.md` (`Quic/QuicFile*`, yarım dosya dizini, `isExcludedFromBackup`), kök `CLAUDE.md` ("files" invariant'ına QUIC yolu), `TECHNICAL.md` §5.4 (QUIC dosya yolu, saklama kuralları), `protocol-vectors/README.md`. Dokümanlardaki "1 GiB" ve "10 dk" ifadeleri QUIC istisnasıyla netleştirilir.

**Testler (beklenen sonuç).** Atıf yapılan dosya/satır adları gerçek (grep); eski ve yeni kural birbirini çelişmiyor.

**Bitti ölçütü.** Dokümanlar kodla uyumlu.

### [ ] 2.11 Faz 2 genel testi

**Beklenen sonuç.** Tüm bileşen testleri geçer ve şu senaryolar birlikte doğrulanır: (1) LAN'da **10 GB** dosya iki yönde de gider, Files geçmişinde normal görünür, SHA-256 eşit, iki tarafta bellek sabit; (2) transfer sırasında Wi-Fi kesilip geri gelince aynı dosyayı yeniden göndermek kaldığı yerden sürer; (3) **3 GB** transfer sırasında Mac 30 dk uyuyup uyanınca sürer; (4) alıcı uygulama (Android One UI öldürme benzetimi, Mac yeniden başlatma) yeniden başlayınca QUIC yarım dosyası devam eder; (5) relay'deyken 1 GiB sınırı ve mevcut davranış değişmez, 1 GiB üstü "bekleniyor"; (6) disk dolu/yetersiz alan durumları (Android 2× kuralı, Mac farklı hacim) doğru reddedilir; (7) geçersiz `id` reddedilir; (8) yarım dosyalar yedekleme dışı dizinde; (9) mevcut dosya/pano/bildirim özellikleri regresyonsuz.

---

## [ ] Faz 3 — Ekran yansıtma (video pipeline)

Bu fazda kurulan video pipeline'ı (encoder → framing → stream → decoder) Faz 5'teki kamera da aynen kullanır. Büyüklük: **L**.
Bağımlılık: Faz 1; Faz 0 kapıları ("60 stream/sn", "encode ≤ 30 ms"), ikisi de **geçti** (0.12). Yalnız LAN-direct.

### [ ] 3.1 Servis kararı ve manifest

**Amaç.** Ekran yakalama için gereken foreground service tipini ve izinleri eklemek (mevcut servis `specialUse|connectedDevice`).

**Yapılacaklar.**
1. Karar (bu aşamada verilir, plana yazılır): medya oturumları için **ayrı bir servis** (`MediaSessionService`) — onay olmadan medya tipinin başlatılamaması kuralını ve oturum bitince tipin bırakılmasını sadeleştirir (ilk tercih). Alternatif: mevcut servise `startForeground(..., type)` ile tip eklemek.
2. Manifest: `foregroundServiceType="mediaProjection"` servisi; izinler `FOREGROUND_SERVICE_MEDIA_PROJECTION` (kamera/mikrofon tipleri ve izinleri Faz 5'te eklenir).
3. Android 14+: önce onay (`createScreenCaptureIntent` sonucu), sonra servisin `startForeground(MEDIA_PROJECTION)` çağrısı; sırayı bozan çağrı reddedilir.
4. `ClipForegroundService`'in mevcut tipi ve ömrü değişmez.

**Dosyalar.** `modules/selfadb/android/src/main/AndroidManifest.xml`, `quic/MediaSessionService.kt`.

**Testler (beklenen sonuç).** `./gradlew :selfadb:assembleDebug` ve uygulama manifest birleştirmesi hatasız; cihazda onay vermeden servis başlatma denemesi uygulamayı çökertmez (kontrollü hata); mevcut FGS davranışı (yeniden başlama, bildirim) regresyonsuz.

**Bitti ölçütü.** Medya servisi manifestte ve doğru sırayla başlatılabilir; karar yazılı.

### [ ] 3.2 Oturum ve izin akışı

**Amaç.** Mac'in ekran yansıtma isteği → telefonda bildirim → kullanıcı onayı → oturum.

**Yapılacaklar.**
1. Mac `cmd` ile `q.req {kind:"cast", max_res, fps, codecs[]}` gönderir. Aktif link LAN-direct değilse telefon `q.reject {reason:"relay"}` döner; Mac "aynı Wi-Fi gerekli" der.
2. Telefon bir bildirim gösterir; dokununca `createScreenCaptureIntent()` onay penceresi (şeffaf activity) açılır. Onaydan sonra telefon isteği kabul eder (`q.accept`), Mac `q.offer` gönderir, QUIC oturumu açılır. Arka plandan activity açma kısıtı nedeniyle bildirim dokunuşu zorunlu.
3. Onaydan sonra `mediaProjection` tipli servis başlatılır; `createVirtualDisplay`'den **önce** `MediaProjection.Callback` kaydedilir; kullanıcı durum çubuğundan durdurursa `onStop` → `q.end`.
4. Onay penceresinde "tek uygulama" seçilirse çözünürlük/oran değişir; pipeline buna dayanıklı olmalı (3.7).
5. Mac, telefon 5 sn içinde cevap vermezse "Telefonda Link To Mac'i aç" ipucunu gösterir; toplam bekleme 60 sn sonra `timeout` ile bırakılır.
6. **Sonlandırma yönü (0.3 bulgu 5):** Mac yayını kapattığında (pencere, düğme, Unpair) bağlantıyı kendisi kapatmaya güvenmez; `q.end` `cmd` + oturum stream'inde `END\n` ile telefona söyler ve **telefon** bağlantıyı kapatıp yakalamayı durdurur. Telefon yönündeki sonlandırma (durum çubuğu, `onStop`) zaten telefonun kendi kapatmasıdır. Yayın stream'leri hep telefon tarafından başlatıldığı için 0.3'teki fazladan sunucu stream'inden etkilenmez.

**Dosyalar.** `quic/CastConsentActivity.kt`, `quic/MediaSessionService.kt`, `quic/QuicManager.kt`, Mac `Quic/CastController.swift`, Mac "Cast screen" düğmesi (dashboard).

**Testler (beklenen sonuç).** Durum makinesi birim testi (Kotlin ve Swift): `idle → requested → consent → accepted → offered → streaming → ended`, `reject relay`, 5 sn ipucu, 60 sn zaman aşımı, onay verilmeden `q.end`. Cihaz: bildirim → onay → bağlantı kurulur; durum çubuğundan durdurma Mac'te "yayın durdu" gösterir; onay verilmezse Mac zaman aşımı mesajı gösterir; Mac penceresi kapatılınca telefon ≤ 2 sn içinde yakalamayı durdurur ve QUIC bağlantısını kapatır.

**Bitti ölçütü.** İstek → onay → QUIC oturumu zinciri çalışıyor; durdurma iki yönde temiz.

### [ ] 3.3 Encoder (Android)

**Amaç.** Düşük gecikmeli H.264 üretmek.

**Yapılacaklar.**
1. MediaCodec H.264 High, Surface girişi. `KEY_LOW_LATENCY=1`, `KEY_PRIORITY=0`, `KEY_PREPEND_HEADER_TO_SYNC_FRAMES=1`. *(0.12, 0.8 bulgu 72: bu kodlayıcılarda `FEATURE_LowLatency` desteklenmiyor, `KEY_LOW_LATENCY`/`KEY_PRIORITY` ölçülebilir etki yaratmıyor; zararsız.)* Kare hızı sınırı `max-fps-to-encoder` **`setFloat`** ile verilir: ekran 120 Hz üretir, `setInteger` yok sayılır ve kodlayıcıya 120,1 fps girer (medyan 25,7 vs 21,5 ms; bulgu 69).
2. Uzun I-frame aralığı (10 sn); gerektiğinde `PARAMETER_KEY_REQUEST_SYNC_FRAME` ile anında keyframe.
3. Statik ekran: `KEY_REPEAT_PREVIOUS_FRAME_AFTER=100 ms` tekrar kareleri yalnız **~1,2 sn (10 tekrar) boyunca** üretir, sonra akış durur (0.8 bulgu 71). Alıcı son kareyi tutar, oturum canlılığını QUIC keep-alive (5 sn) sağlar; ekran değişince akış kendiliğinden sürer (S2 ölçümü: boştan uyanma medyan 22,0 ms, en büyük 27,7). Tam statik ekrandan ani harekete geçiş Faz 3 cihaz testinde doğrulanır.
4. Ekran döndüğünde ya da boyut değiştiğinde VirtualDisplay ve encoder yeniden kurulur; Mac'e `ConfigChange` gider (yeni çözünürlük/oran).
5. HEVC opsiyonu **açık** (`codecs[]` ile pazarlık): Faz 0'da kodlama gecikmesi H.264 ile aynı (medyan 21,7 vs 22,2 ms, p99 42,5 vs 42,9; bulgu 73). HEVC **çözme** gecikmesi ölçülmedi (3.6'da ölçülür).

**Dosyalar.** `quic/ScreenEncoder.kt`, `src/test/.../ScreenEncoderConfigTest.kt` (yalnız konfigürasyon üretimi saf Kotlin).

**Testler (beklenen sonuç).** Birim: verilen `max_res/fps/codecs` için üretilen `MediaFormat` anahtarları doğru; yeniden kurulum durum makinesi. Cihaz: 1080p60'ta 3 dk encode, medyan encode süresi 0.8'deki ölçümle uyumlu (medyan ≈ 22 ms, p99 ≈ 43 ms; kapı: medyan ≤ 30 ms), frame düşmesi yok; döndürme sonrası yeni `ConfigChange` üretilir.

**Bitti ölçütü.** Encoder kararlı, anahtar kare isteğine anında cevap veriyor.

### [ ] 3.4 Framing ve akış kontrolü

**Amaç.** Frame'leri QUIC stream'leriyle taşımak, kuyruk büyüyünce gecikmeyi sınırlamak.

**Yapılacaklar.**
1. Her frame tip `0x02` olan ayrı bir uni stream: başlık `{session_id, frame_no, pts_us, flags(key, config)}` + NAL verisi (başlık biçimi vektörle sabit). `pts_us` **monotonik saatten** gelir (`System.nanoTime()`: Surface damgası CLOCK_MONOTONIC; `elapsedRealtimeNanos` bu cihazda 6,15 gün farklı, 0.8 bulgu 68).
2. Gönderen: uçuştaki frame sayısı eşiği aşarsa keyframe olmayan frame'leri bir sonraki keyframe'e kadar düşürür; eski stream'leri `RESET` eder.
3. *(Silindi, 0.12, kullanıcı onaylı 2026-11-19: Faz 0'da "60 stream/sn" kapısı geçti, tek akışlı yedek yol gerekmedi.)*
4. Alıcı: decode hatası ya da kayıp referans frame'de oturum stream'inden `RequestKeyframe` gönderir; gönderen anında keyframe üretir.
5. Oturum stream'i (bidi): `RequestKeyframe`, `Bitrate`, `ConfigChange` ack, oturum sonu mesajları (biçim vektörle sabit).
6. **Stream kredisi (0.5 bulgusu, onaylı 2026-11-15).** Kare başına stream, bağlantı ömrü boyunca on binlerce stream demektir (60/sn ile saatte 216 000) ve Network.framework yeni kredi vermez; Mac alıcısı 1.6 madde 8'deki kredi yükseltmesini kullanır (`VideoReceiver` kendi başına kredi yönetmez, 1.6'daki `StreamCredit`'i çağırır). Gönderen `open_uni()` çağrısını **zaman aşımıyla** sarar (örn. 2 sn); aşılırsa bunu "alıcı kredi vermiyor" hatası sayıp oturumu sonlandırır, sessizce beklemez.

**Dosyalar.** `quic-core/src/video.rs`, `quic/VideoSender.kt`, Mac `Quic/VideoReceiver.swift`, `protocol-vectors/quic-control.json` (video başlığı bölümü).

**Testler (beklenen sonuç).** Vektör: frame başlığı ve oturum stream mesajları iki platformda aynı. Rust birim: düşürme politikası (eşik aşılınca delta frame düşer, keyframe düşmez, sonraki keyframe'e kadar delta yok); `open_uni()` zaman aşımı kredi hatası olarak raporlanır. Cihaz/localhost: 10 000'den fazla frame (4096 sınırını aşan) kredi tıkanması olmadan akar. UDP proxy ile %2 yapay kayıp: görüntü ≤ 1 sn içinde toparlanır (3.10'da ölçülür; burada politika testi).

**Bitti ölçütü.** Frame taşıma ve düşürme politikası testli; keyframe isteği çalışıyor.

### [ ] 3.5 Adaptif bitrate

**Amaç.** Ağ koşuluna göre bitrate'i ayarlamak.

**Yapılacaklar.**
1. Rust çekirdeği her 500 ms'de RTT, cwnd ve kayıp istatistiğini verir (`stats()`, 1.7).
2. Kotlin denetleyicisi (saf Kotlin) bitrate'i `PARAMETER_KEY_VIDEO_BITRATE` ile ayarlar: kayıp/RTT artışında azaltır, sakin dönemde kademeli artırır. Başlangıç değeri ve alt/üst sınırlar 3.10'daki ölçümle ayarlanır (başlangıç önerisi 8 Mbps).
3. Mac, Network.framework cwnd vermediği için yalnız gönderen (Android) tarafı karar verir.

**Dosyalar.** `quic/BitrateController.kt`, `src/test/.../BitrateControllerTest.kt`.

**Testler (beklenen sonuç).** Birim: sentetik istatistik dizileriyle — kayıp %2 üstü → azaltma, sakin 5 sn → artış, sınırlar aşılmaz, salınım yok (ardışık yön değişimi sınırı). Cihaz: `tc`/Network Link Conditioner ile bant daraltılınca bitrate düşer, açılınca yükselir.

**Bitti ölçütü.** Bitrate ağa uyum sağlıyor, testli ve sınırlı.

### [ ] 3.6 Mac decoder ve pencere

**Amaç.** Gelen H.264'ü düşük gecikmeyle göstermek.

**Yapılacaklar.**
1. İlk sürümde `AVSampleBufferDisplayLayer` (decode ve gösterimi kendisi yapar), `kCMSampleAttachmentKey_DisplayImmediately` ile. NAL (Annex-B/AVCC dönüşümü) → `CMSampleBuffer`; `config` bayrağıyla gelen SPS/PPS'ten `CMVideoFormatDescription`.
2. Gerekirse sonra `VTDecompressionSession` + Metal.
3. Pencere: en-boy oranını koruyan, yeniden boyutlanabilen, tam ekran destekli. `ConfigChange`'de format ve oran güncellenir.
4. Dashboard'daki "Cast screen" karosu (mevcut "Soon" yer tutucusu) oturumu başlatır/durdurur.
5. HEVC açıksa (3.3 madde 5) Mac **çözme + gösterim** gecikmesi H.264 ile karşılaştırmalı ölçülür; Faz 0 yalnız kodlama tarafını ölçtü (0.8 bulgu 73).

**Dosyalar.** `Quic/VideoReceiver.swift`, `Quic/CastWindow.swift`, `DashboardWindow.swift`/`FeaturePanel.swift`.

**Testler (beklenen sonuç).** Birim: NAL ayrıştırma ve `CMVideoFormatDescription` kurulumu (örnek SPS/PPS vektörüyle); `ConfigChange` sonrası oran hesabı. Cihaz: pencere yeniden boyutlanır, oran korunur, tam ekran çalışır; keyframe kaybında görüntü `RequestKeyframe` ile toparlanır; HEVC açıksa çözme gecikmesi H.264'ünkiyle birlikte kaydedilir.

**Bitti ölçütü.** Mac'te telefon ekranı akıcı görünüyor; pencere davranışı doğru.

### [ ] 3.7 Dayanıklılık: döndürme, tek uygulama, FLAG_SECURE

**Yapılacaklar.**
1. Ekran döndürmede yayın kopmaz: VirtualDisplay + encoder yeniden kurulur, `ConfigChange` ile Mac'te format/oran güncellenir.
2. "Tek uygulama" paylaşımı: çözünürlük/oran değişimi aynı yolla ele alınır.
3. `FLAG_SECURE` kullanan uygulamalar (bankacılık, bazı video servisleri) siyah görünür: **beklenen davranış, hata değil**; Mac penceresinde açıklayıcı not ya da tek seferlik ipucu.
4. Kullanıcı yayını durdurunca (durum çubuğu, bildirim) iki uç temiz kapanır.

**Testler (beklenen sonuç).** Cihaz: dikey ↔ yatay döndürme sırasında yayın kopmaz, Mac oranı günceller; tek uygulama seçimi çalışır; `FLAG_SECURE` uygulaması siyah görünür ve uygulama çökmez; durdurma iki uçta temiz.

**Bitti ölçütü.** Pipeline ekran değişimlerine dayanıklı.

### [ ] 3.8 Doze ve ekran kapalı başlatma

**Amaç.** Başlatma isteğinin telefon uyurken de ulaştığını doğrulamak. İstek, foreground service'in tuttuğu WS bağlantısından gelir ve pil optimizasyonu muafiyetiyle Doze'da da ulaşır (Mac → telefon `mediaCmd` bugün böyle çalışıyor). FCM push-wake ön koşul değil; One UI'ın servisi öldürmesi (#29–#31) ayrı bir güvenilirlik işi.

**Yapılacaklar.** Telefon ekranı kapalı, 30 dk bekletilir; Mac'ten `q.req cast` gönderilir; bildirim gelmesi doğrulanır. Muafiyet kapalı/açık iki durumda sonuç kaydedilir.

**Testler (beklenen sonuç).** Muafiyet açıkken 30 dk sonra bildirim ≤ 5 sn içinde gelir; muafiyet kapalıyken sonuç kaydedilir (başarısız olması riskler tablosundaki #29–#31 kaydıyla uyumlu).

**Bitti ölçütü.** Davranış ölçüldü ve belgelendi.

### [ ] 3.9 Dokümantasyon güncellemesi (Faz 3)

**Yapılacaklar.** `mobile/CLAUDE.md` (MediaSessionService, ScreenEncoder, VideoSender, BitrateController), `mac/CLAUDE.md` (`Quic/Video*`, `CastWindow`, Cast karosu), kök `CLAUDE.md`, `TECHNICAL.md` (video başlığı, oturum stream'i), `protocol-vectors/README.md`, `RoadMap.md` ("Mirror your Android screen to Mac" maddesi).

**Testler (beklenen sonuç).** Atıflar gerçek; RoadMap maddesi durumu yansıtıyor.

**Bitti ölçütü.** Dokümanlar kodla uyumlu.

### [ ] 3.10 Faz 3 genel testi

**Beklenen sonuç.** Tüm bileşen testleri geçer; cihazda: (1) 1080p 60 fps yayın, **uçtan uca gecikme ≤ 120 ms** (iki ekran aynı karede kronometreyle çekilerek ölçülür); (2) %2 yapay paket kaybında görüntü 1 sn içinde toparlanır; (3) ekran dönünce yayın kopmaz; (4) telefon 30 dk ekranı kapalı bekledikten sonra Mac'ten başlatma isteği bildirimi gelir; (5) `FLAG_SECURE` siyah, çökme yok; (6) bitrate ağa uyum sağlar; (7) mevcut özellikler regresyonsuz. Hedefe ulaşılamazsa (0.8 kapısına göre) hedef 1080p 30 fps / 720p'ye iner — bu değişiklik kullanıcı onayıyla plana yazılır.

---

## [ ] Faz 4 — Android ses çıkışını Mac'e yönlendirme

Ses MediaProjection oturumu üzerinden yakalanır; ekran yansıtma açıksa aynı onay ve aynı QUIC oturumu kullanılır. Yalnız LAN-direct;
oturum `q.req {kind:"audio"}` ile açılır. Büyüklük: **M**. Bağımlılık: Faz 3 (MediaProjection oturum yönetimi). Faz 0 kapıları değerlendirildi (0.12): "Mac'te DATAGRAM" **geçti** (ses yolu 4.4), "stream/sn ~110" telefonda **kaldı** (4.5 silindi), "popüler uygulamalar ses yakalamaya izin veriyor" **3/4 geçti, Spotify yakalanamıyor** (4.9). **4.4 uygulanır; 4.6 yalnız 4.4'ün ses + video birlikte yük testi kalırsa.**

### [ ] 4.1 Ses taşıma soyutlaması ve seçim

**Amaç.** Ses paketini taşıyan yolu, çekirdek mantığı değiştirmeden değiştirilebilir kılmak.

**Yapılacaklar.**
1. Taşıma arayüzü (Rust çekirdeği ve Swift tarafı): `send(packet)`, `recv() -> packet`, `close()`; paket başlığı `channel_id (1 B) · seq (2 B) · timestamp_us (4 B)` + Opus yükü (~350 bayt; MTU sorunu yok). `timestamp_us` **monotonik saatten** gelir (`System.nanoTime()`, 0.8 bulgu 68).
2. Seçim sırası (Faz 0 kapıları değerlendirildi, 0.12): **QUIC DATAGRAM** (varsayılan) → **ayrı UDP soketi** (yalnız 4.4'ün ses + video yük testi kalırsa). Kısa uni stream yolu plandan çıktı: ~110 stream/sn telefonda kaldı (p99 video 30,5 ms, ses 34,4 ms; eşik 20 ms).
3. Seçilen yol `q.offer` içinde isteğe bağlı `audio` alanıyla bildirilir (`{"t":"dgram"|"udp","port"?,"key"?}`); alan vektörle sabitlenir, eski peer yok sayar.
4. Ses yolu anahtar/port bilgisi asla loglanmaz.

**Dosyalar.** `quic-core/src/audio_transport.rs`, `Quic/AudioTransport.swift`, `protocol-vectors/quic-control.json` (ses başlığı ve `q.offer.audio`).

**Testler (beklenen sonuç).** Vektör: ses paketi başlığı ve `q.offer.audio` biçimi Swift/Kotlin/Rust'ta aynı; geçersiz `t` reddedilir. Birim: arayüze sahte bir taşıma takılır, sıra dışı/kayıp paket üretir, çekirdek mantığı bunlarla çalışır.

**Bitti ölçütü.** Ses mantığı taşımadan bağımsız ve vektörle sabit.

### [ ] 4.2 Android yakalama (AudioPlaybackCapture)

**Yapılacaklar.**
1. `AudioPlaybackCaptureConfiguration`: `USAGE_MEDIA`, `USAGE_GAME`, `USAGE_UNKNOWN`; 48 kHz stereo PCM16; `RECORD_AUDIO` izni (çalışma zamanında, lazily, SMS gönderme izni kalıbıyla; `blocked` durumu açıklaması dahil).
2. Ekran yansıtma aktifse **aynı** `MediaProjection` örneği kullanılır; ikinci onay istenmez. Yalnız ses istense bile Android ekran paylaşımı onay penceresini gösterir (AudioPlaybackCapture bir MediaProjection ister): bildirim metni bunu açıklar.
3. PCM, 20 ms'lik bloklar halinde çekirdeğe verilir.

**Dosyalar.** `quic/AudioCapture.kt`, `quic/MediaSessionService.kt`, Mac `Quic/CastController.swift` (ses isteği).

**Testler (beklenen sonuç).** Birim: 20 ms blok bölücü (verilen PCM akışı tam 960 örnekli bloklara bölünür, artık bir sonrakine taşınır). Cihaz: ses isteği onay penceresini açar; ekran yansıtma açıkken ikinci onay istenmez; `RECORD_AUDIO` reddedilince anlaşılır mesaj.

**Bitti ölçütü.** Android sesi 20 ms bloklar hâlinde çekirdeğe ulaşıyor.

### [ ] 4.3 Opus kodlama (çekirdek)

**Yapılacaklar.** Opus (libopus binding'i, arm64'e statik): 20 ms frame, 128 kbps stereo, in-band FEC açık, sessizlikte DTX. Paket başlığı 4.1'e göre; `seq` 16 bit sarar, `timestamp_us` oturum başından itibaren monotonik.

**Dosyalar.** `quic-core/src/opus.rs`, `quic-core/Cargo.toml`.

**Testler (beklenen sonuç).** Rust: kodla→çöz gidiş-dönüşte sinüs testinde SNR eşiği (≥ 20 dB, onaylı eşik); DTX'te sessizlik paketleri boyut olarak küçük; `seq` sarma sınırı doğru; yanlış boyutlu PCM hata verir.

**Bitti ölçütü.** Opus paketleri üretiliyor ve çözülüyor.

### [ ] 4.4 Taşıma yolu A: QUIC DATAGRAM (varsayılan)

**Yapılacaklar.** Paket quinn DATAGRAM'ı ile gönderilir; Mac, 0.4'te doğrulanan Swift API ile alır (`group.extract` + `isDatagram`, shim yok). Gönderme tamponu doluysa en eski paket atılır (gecikme birikmesin). Oturum ses stream'i yoktur; kontrol (başlat/durdur) oturum stream'indedir.

**Dosyalar.** `quic-core/src/audio_dgram.rs`, `Quic/AudioDatagramReceiver.swift`.

**Testler (beklenen sonuç).** Süreç içi loopback testi: 1000 paket sıralı gelir; yapay %2 kayıpta alınan sayı ≈ %98; tampon doluluğunda eski paket atılır. Cihaz: 60 sn akış, Mac tarafı paket sayacı ≥ %99,9 (LAN) ve **ses + video birlikte yük altında** (60 video stream/sn + 50 ses paketi/sn) aynı eşik; 0.4 DATAGRAM'ı yalnız hafif yükte (17,5 kB/sn) ölçtü. Eşik kaçarsa 4.6 devreye girer.

**Bitti ölçütü.** Ses paketleri DATAGRAM ile Mac'e ulaşıyor.

### 4.5 (silindi, 0.12) Taşıma yolu B: kısa uni stream'ler

**0.12'de silindi (kullanıcı onaylı 2026-11-19).** Koşulu ("~110 stream/sn kapısı geçtiyse **ve** DATAGRAM kaldıysa") hiçbir durumda sağlanamaz: DATAGRAM kapısı geçti, ~110 stream/sn kapısı telefonda kaldı (p99 video 30,5 ms, ses 34,4 ms; eşik 20 ms). 4.6–4.11 başka yerlerden atıflı olduğu için numaralar kaymasın diye başlık kalır; bu aşama uygulanmaz ve faz tamamlanma sayımına girmez.

### [ ] 4.6 Taşıma yolu C (koşullu): ayrı UDP soketi + AEAD

**Koşul (0.12'de yeniden hedeflendi, kullanıcı onaylı 2026-11-19).** Yalnız 4.4'ün **ses + video birlikte yük** testi (≥ %99,9, LAN) kalırsa uygulanır. Eskiden "DATAGRAM ve stream yolları kaldıysa" idi; stream yolu zaten kapalı (4.5 silindi). 0.4 DATAGRAM'ı yalnız hafif yükte (17,5 kB/sn) ölçtü.

**Yapılacaklar.**
1. Port ve anahtar `q.offer.audio` ile E2E kanaldan gelir; Mac ayrı bir UDP dinleyici açar, Android `DatagramSocket` ile gönderir.
2. Şifreleme: oturum anahtarından yön ve kanal etiketiyle türetilmiş **yön başına ayrı anahtar**, sayaç nonce'lu ChaCha20-Poly1305. **`ClipCodec` kullanılamaz:** nonce cache tüm frame tiplerince paylaşılıyor (4096 sınır, 240 sn ufuk); 50 paket/sn bu cache'i doldurup `cmd` replay korumasını zayıflatır.
3. Sıra dışı paketler için WireGuard tarzı kayan replay penceresi (2048 bit); pencere dışı/tekrar eden paket atılır.
4. Anahtar ve port loglanmaz; AEAD vektörleri `quic-control.json`'a yazılır.

**Dosyalar.** `quic-core/src/audio_udp.rs`, `Quic/AudioUDPReceiver.swift`, vektörler.

**Testler (beklenen sonuç).** Vektör: sabit anahtar/sayaç/yük → sabit şifreli bayt (Swift/Rust eşit); replay penceresi birim testleri (tekrar, çok eski, ileri atlama, sarma); bozulmuş paket doğrulamada reddedilir; `ClipCodec` nonce cache'ine ses paketi **girmez** (test: 10.000 ses paketi sonrası `cmd` replay koruması hâlâ çalışıyor).

**Bitti ölçütü.** Ayrı UDP yolu güvenli ve vektörle sabit (4.4 yük testi geçerse bu aşama, 4.4 kapanırken kullanıcı onayıyla plandan silinir).

### [ ] 4.7 Mac çalma: jitter buffer, FEC/PLC, saat kayması, çıkış

**Yapılacaklar.**
1. Adaptif jitter buffer: hedef 40 ms, aralık 20–120 ms; `seq` ile yeniden sıralama.
2. Kayıp paket: önce bir sonraki paketteki in-band FEC, yoksa Opus PLC.
3. Saat kayması: iki cihazın ses saati birebir aynı değil; buffer doluluğuna göre çok küçük oranlı yeniden örnekleme, yoksa dakikalar içinde buffer taşar ya da boşalır.
4. Çıkış `AVAudioEngine` source node ile; kullanıcı Mac'teki çıkış cihazını seçebilir (ayarlarda).

**Dosyalar.** `Quic/AudioPlayer.swift`, `Quic/JitterBuffer.swift` (saf Swift), `mac/Tests/JitterBufferTests.swift`.

**Testler (beklenen sonuç).** Saf Swift birim testleri sentetik akışlarla: sıra dışı paketler doğru sıraya girer; %2 kayıpta FEC/PLC çağrılır ve boşluk kalmaz; +%0,01 saat kayması 10 dk simülasyonda buffer taşmaz/boşalmaz (resampling oranı sınırlı); hedef aralığı aşan jitter'da buffer 120 ms'e kadar büyür ve geri küçülür. Cihaz: çıkış cihazı seçimi çalışır.

**Bitti ölçütü.** Mac'te kesintisiz, sınırlı gecikmeli ses çalıyor.

### [ ] 4.8 Ses–video senkronu

**Yapılacaklar.** Ekran yansıtma da açıksa ses ve görüntü aynı saatten gelen `pts` ile senkronlanır: Android'de ses ve video zaman damgaları aynı monotonik kaynaktan (`SystemClock.elapsedRealtimeNanos`) türetilir; Mac, video gösterim zamanını ses saatine göre ayarlar (fark eşiği aşarsa video frame düşürür/bekletir).

**Testler (beklenen sonuç).** Birim: iki akış için zaman damgası eşleştirme (sabit ofset, kayma); fark eşiği aşılınca doğru düzeltme. Cihaz: tık/flaş test videosunda ses–görüntü farkı ≤ 40 ms (onaylı eşik).

**Bitti ölçütü.** Ses ve görüntü birlikte akarken senkron.

### [ ] 4.9 Telefon tarafındaki ses, opt-out uyarısı, UX

**Yapılacaklar.**
1. Telefon tarafındaki ses, **0.9 sonucuna göre** karara bağlanır: yakalama telefon ses seviyesinden bağımsızsa oturum başlayınca medya sesini kısmayı öner ya da otomatik kıs ve bitince geri al; değilse ses iki cihazda birden çalar ve bu bilinen sınır olarak belgelenir.
2. Yakalamayı kapatan (opt-out) uygulamada kullanıcıya açıklayıcı uyarı (sessiz kalma nedeni): Mac'te ve telefon bildiriminde.
3. UX notu: yalnız ses istense bile ekran paylaşımı onayı çıkar; bildirim metni bunu söyler.

**Testler (beklenen sonuç).** Birim: opt-out tespiti (uzun süre sıfır RMS + bilinen uygulama) uyarı üretir; ses kısma/geri alma durum makinesi oturum sonunda önceki ses seviyesini geri yükler. Cihaz: YouTube ve Chrome/Samsung Müzik (sabit ton) yakalanır; **Spotify yakalanamaz** (0.9: çalıyor, oturum PLAYING, yakalama −120 dBFS) ve açıklayıcı uyarı görünür (bulgu 83).

**Bitti ölçütü.** Kullanıcı sessizliğin ve çift sesin nedenini biliyor.

### [ ] 4.10 Dokümantasyon güncellemesi (Faz 4)

**Yapılacaklar.** `mobile/CLAUDE.md`, `mac/CLAUDE.md` (`AudioPlayer`, `JitterBuffer`), kök `CLAUDE.md` (ses yolu ve `ClipCodec` kısıtı), `TECHNICAL.md`, `protocol-vectors/README.md`, `RoadMap.md`.

**Testler (beklenen sonuç).** Atıflar gerçek; seçilen taşıma yolu doğru anlatılmış.

**Bitti ölçütü.** Dokümanlar kodla uyumlu.

### [ ] 4.11 Faz 4 genel testi

**Beklenen sonuç.** Tüm bileşen testleri geçer; cihazda: (1) YouTube sesi (ve sabit tonlu kaynak) Mac'te **≤ 150 ms** gecikmeyle çalar (Spotify yakalanamıyor, 0.9) (ölçüm: telefon ve Mac hoparlöründen çıkan tık sesi üçüncü bir cihazla kaydedilir, iki tık arası fark); (2) %2 yapay kayıpta duyulur kopma yok; (3) 1 saatlik oturumda buffer kayması yok; (4) opt-out eden uygulamada (Spotify) açıklayıcı uyarı; (5) ekran yansıtma açıkken ses ve görüntü senkron; (6) ikinci onay istenmiyor; (7) mevcut özellikler regresyonsuz.

---

## [ ] Faz 5 — Kamera ve mikrofonu Mac'e sanal cihaz olarak verme

Faz ikiye bölünür çünkü dağıtım maliyetleri çok farklıdır: **5a** (sanal kamera, uygulamanın içinde gelen bir system extension) ve **5b**
(sanal mikrofon, yönetici yetkisiyle kurulan bir `.pkg`). Önce yalnız kamera çıkarılabilir; 5b ertelenebilir (kullanıcı onayıyla). Her ikisi de
yalnız LAN'da çalışır; Faz 3/4 pipeline'larını kullanır. Büyüklük: **L + L**. Bağımlılık: 5a → Faz 3; 5b → Faz 4. Faz 0'daki "Camera Extension çalışıyor" kapısı **geçti** (0.11), bu faz donmuyor.

### [ ] 5.1 Ortak Android başlatma (kamera ve mikrofon)

**Amaç.** Android `camera`/`microphone` tipli foreground service'leri arka plandan başlatmaya izin vermediği için kullanıcı dokunuşuyla başlatmak.

**Yapılacaklar.**
1. Akış: Mac `q.req {kind:"cam"}` → Android bildirimi → kullanıcı dokunur → şeffaf activity `camera` (5b'de `microphone`) tipli foreground service'i başlatır ve kapanır.
2. Manifest: `FOREGROUND_SERVICE_CAMERA`, `FOREGROUND_SERVICE_MICROPHONE`, `CAMERA`, `RECORD_AUDIO` (çalışma zamanı izinleri lazily, `blocked` açıklamasıyla).
3. Servis kararı Faz 3.1'deki `MediaSessionService`'e uyar (ya da ayrı servis, orada verilen karara göre).

**Dosyalar.** `quic/CamLaunchActivity.kt`, `AndroidManifest.xml`, `quic/MediaSessionService.kt`.

**Testler (beklenen sonuç).** Cihaz: bildirim dokunuşu kamera servisini başlatır; izin reddi/`blocked` anlaşılır mesajla biter; bildirim dokunulmazsa Mac zaman aşımı mesajı gösterir; servis oturum bitince durur. `bun run lint` ve JVM testleri geçer.

**Bitti ölçütü.** Kamera/mikrofon servisi kullanıcı dokunuşuyla güvenle başlıyor.

### [ ] 5.2 (5a) Android kamera akışı

**Yapılacaklar.** CameraX `Preview` → MediaCodec Surface; ön/arka kamera (oturum stream'inden anahtarlanır), 720p ya da 1080p, 30 fps. Framing Faz 3 ile aynı, stream tipi `0x03`; bitrate denetleyicisi Faz 3.5'tekiyle paylaşılır.

**Dosyalar.** `quic/CameraEncoder.kt`, `src/test/.../CameraConfigTest.kt`.

**Testler (beklenen sonuç).** Birim: seçilen çözünürlük/fps için kodlayıcı konfigürasyonu; kamera değişiminde yeniden kurulum durum makinesi. Cihaz: ön ve arka kamera 720p/1080p akar; kamera değişince `ConfigChange` gider; Mac tarafı (5.5'e kadar) paket sayacıyla doğrulanır.

**Bitti ölçütü.** Android kamera frame'leri `0x03` stream'iyle Mac'e akıyor.

### [ ] 5.3 (5a) Mac Camera Extension hedefi

**Yapılacaklar.** `mac/project.yml`'e Camera Extension hedefi. Extension iki stream sunar: diğer uygulamaların okuduğu **source** ve ana uygulamanın frame ittiği **sink**. Extension sandbox'ta ve ağsız çalışır; frame'ler ana uygulamadan sink üzerinden gelir. Aygıt adı "Link To Mac Kamera". *(0.12, 0.11 bulgu 91–93: yapı spike'ta kanıtlandı. XcodeGen `type: system-extension` + `embed: true` uzantıyı `Contents/Library/SystemExtensions/` altına koyar; `PRODUCT_NAME` bundle id'ye eşit olmalı; uzantı `app-sandbox` + takım önekli `application-groups` ile imzalanır ve `CMIOExtensionMachServiceName` bu grubun önekiyle başlar; cihaz için sabit UUID; imzalı derleme Release ve `ENABLE_DEBUG_DYLIB=NO ENABLE_PREVIEWS=NO`. Başlangıç noktası: `spikes/mac-camera-ext/` (atılabilir). Sink stream spike'ta yoktu, doğrulanmadı.)*

**Dosyalar.** `mac/CameraExtension/` (provider, device, source/sink stream), `mac/project.yml`.

**Testler (beklenen sonuç).** Hedef derlenir (`xcodegen generate` + `xcodebuild`); extension paketi uygulamanın `Contents/Library/SystemExtensions/` altına gömülür (`ls` ile doğrulanır); Info.plist anahtarları doğru. Sahte bir frame üreteciyle (etkinleştirmeden) provider birim testleri.

**Bitti ölçütü.** Extension derleniyor ve uygulama paketine gömülüyor.

### [ ] 5.4 (5a) Etkinleştirme, imzalama, dağıtım

**Yapılacaklar.**
1. `OSSystemExtensionRequest` ile etkinleştirme; kullanıcı Sistem Ayarları'ndan onaylar. Ayarlarda "Sanal kamerayı kur" düğmesi ve durum göstergesi (kurulu/onay bekliyor/hata).
2. Koşullar: uygulama `/Applications` altında, Developer ID ile imzalı ve notarize, System Extension yeteneği olan provisioning profile ve `com.apple.developer.system-extension.install` entitlement'ı. `/Applications` dışındaysa açık uyarı.
3. `mac/scripts/build-release.sh` güncellenir: profili gömer, extension'ı uygulamadan önce (içten dışa) imzalar, hardened runtime + notarize + staple.
4. **Ön koşul, sizin portal adımınız (0.11 bulgu 91, 98):** gerçek `dev.grkn.LinkToMac` için ayrı **explicit App ID + System Extension yeteneği + Developer ID profili** (spike ayrı kimlikle yapıldı, gerçek kimlik kayıtlı değil; ~5 dk). Profil **yalnız ana uygulamaya** gömülür (`Contents/embedded.provisionprofile`); uzantı **profilsiz** ve uygulamadan önce imzalanır (spike ve OBS böyle çalıştı). `LinkToMac.entitlements` (bugün yalnız Bluetooth) `com.apple.developer.system-extension.install`, `com.apple.application-identifier`, `com.apple.developer.team-identifier` ile genişler (ikisi profille eşleşmeli); uzantı için ayrı entitlements dosyası.
5. Tuzaklar (bulgu 94): entitlements plist'inde **XML yorumunun içinde `--` olmaz** (AMFI reddeder, `plutil -lint` kabul eder); `codesign … | grep -q` `pipefail` altında yarışır, çıktı önce değişkene alınır; `--deep` kullanılmaz.
6. Kaldırma (bulgu 97): `deactivationRequest` hızlı ve parolasızdır, kamera hemen kaybolur, ama kayıt **yeniden başlatmaya kadar** `terminated waiting to uninstall on reboot` kalır; Ayarlar'da bu durum açıkça gösterilir.

**Dosyalar.** `Quic/VirtualCameraInstaller.swift`, `SettingsWindow.swift`, `mac/scripts/build-release.sh`, `mac/Resources/LinkToMac.entitlements`.

**Testler (beklenen sonuç).** Birim: kurulum durum makinesi (sahte `OSSystemExtensionRequest` temsilcisi): talep → onay bekliyor → kuruldu/hata. Cihaz (imzalı build): `systemextensionsctl list` extension'ı "activated enabled" gösterir; `system_profiler SPCameraDataType` "Link To Mac Kamera"yı listeler; `/Applications` dışından çalıştırınca uyarı çıkar (0.11'de `/Applications` dışından etkinleştirme **denenmedi**: bu testte gerçek davranış ölçülür, uyarı bir varsayımdır); `notarytool` ve `spctl --assess` başarılı.

**Bitti ölçütü.** İmzalı/notarize build'de sanal kamera kurulup görünür hâle geliyor.

### [ ] 5.5 (5a) Frame köprüsü ve yer tutucu

**Yapılacaklar.** Ana uygulama H.264'ü VideoToolbox ile `CVPixelBuffer`'a çözer ve extension'ın sink stream'ine yazar. Telefon bağlı değilken (ya da yayın durunca) "Telefon bağlı değil" yer tutucu frame'i gösterilir; uygulamalar kamerayı kaybetmez, bağlantı kopunca çökmez.

**Dosyalar.** `Quic/CameraBridge.swift`, `CameraExtension/Placeholder.swift`.

**Testler (beklenen sonuç).** Birim: örnek H.264 NAL'larından `CVPixelBuffer` üretimi (boyut/format doğru); yer tutucu frame'inin boyutu aktif akışla aynı. Cihaz: FaceTime'da telefon görüntüsü akar; telefon bağlantısı kesilince görüntü yer tutucuya geçer, FaceTime kamerayı kaybetmez ve çökmez.

**Bitti ölçütü.** Telefon kamerası Mac uygulamalarında canlı, kopmada yer tutucu.

### [ ] 5.6 (5a) Sparkle güncellemesi ve extension sürümü

**Yapılacaklar.** Sparkle güncellemesi extension'ın sürümünü değiştirdiğinde yeniden etkinleştirme isteği (`replacement` akışı: `actionForReplacingExtension`); eski sürüm kaldırılırken kamera kullanan uygulamalar için davranış denenir. Build numarası extension'da uygulamayla birlikte artar.

**Testler (beklenen sonuç).** Cihaz: sürüm N → N+1 Sparkle güncellemesi sonrası kamera çalışmaya devam eder (gerekirse tek onay istemi); `systemextensionsctl list` tek (yeni) sürümü gösterir.

**Bitti ölçütü.** Güncelleme sonrası sanal kamera bozulmuyor.

### [ ] 5.7 (5a) Dokümantasyon ve 5a kabul testi

**Yapılacaklar.** `mac/CLAUDE.md` (`CameraExtension/`, kurulum akışı, `build-release.sh` değişikliği), kök `CLAUDE.md`, `TECHNICAL.md` §10 (imza/notarize/entitlement), `RoadMap.md`.

**Testler (beklenen sonuç).** FaceTime, Zoom ve Chrome'da Meet "Link To Mac Kamera"yı görür; gecikme ≤ 200 ms; bağlantı kopunca uygulama çökmez, yer tutucuya geçer; Sparkle güncellemesinden sonra kamera çalışır.

**Bitti ölçütü.** 5a kabul ölçütleri karşılanıyor.

### [ ] 5.8 (5b) Android mikrofon akışı

**Yapılacaklar.** `AudioRecord` kaynağı `VOICE_COMMUNICATION` (cihazın yankı ve gürültü bastırması devrede) → Opus 48 kHz mono 48 kbps → Faz 4'te seçilen ses taşıması. Başlatma 5.1 akışıyla (`microphone` tipli servis).

**Dosyalar.** `quic/MicCapture.kt`, çekirdekte mono/48 kbps Opus konfigürasyonu.

**Testler (beklenen sonuç).** Birim: mono 20 ms blok bölücü ve Opus konfigürasyonu; Rust gidiş-dönüş SNR eşiği. Cihaz: mikrofon paketleri Mac'e ulaşır (paket sayacı ≥ %99,9); yankı bastırma etkin (kayıt dinlenir).

**Bitti ölçütü.** Mikrofon sesi Mac'e akıyor.

### [ ] 5.9 (5b) Mac HAL plug-in (Audio Server Plug-in)

**Yapılacaklar.**
1. HAL plug-in paketi `/Library/Audio/Plug-Ins/HAL` altına kurulur, `coreaudiod` yükler. Başlangıç için libASPL ya da BlackHole kaynak kodu incelenir. Saf C/C++; uygulamanın Swift kodu ve bağımlılık kuralı etkilenmez.
2. Plug-in `coreaudiod` sandbox'ında çalışır; ana uygulamayla iletişim `Info.plist`'te tanımlanan mach servisi + paylaşımlı bellekte ring buffer.
3. Aygıt adı "Link To Mac Mikrofon"; telefon bağlı değilken sessizlik üretir.

**Dosyalar.** `mac/AudioPlugin/` (C/C++), ana uygulamada `Quic/MicBridge.swift`.

**Testler (beklenen sonuç).** Ring buffer birim testi (C/Swift; tek üretici/tek tüketici, taşma/boşalma, sarma); derleme ve imza; makinede `system_profiler SPAudioDataType` "Link To Mac Mikrofon"u listeler, Ses MIDI Kurulumu'nda görünür.

**Bitti ölçütü.** Sanal mikrofon sistemde görünüyor ve ana uygulamadan ses alıyor.

### [ ] 5.10 (5b) Saat kayması

**Yapılacaklar.** Faz 4.7'deki yöntemle (buffer doluluğuna göre küçük oranlı yeniden örnekleme) plug-in tarafı ring buffer'ının taşma/boşalmasını önlemek.

**Testler (beklenen sonuç).** Saf birim: ±%0,01 kayma simülasyonunda 1 saatlik sentetik akışta buffer taşmaz/boşalmaz. Cihaz: 1 saatlik görüşmede kayma veya kopma yok.

**Bitti ölçütü.** Uzun görüşmede ses kaymıyor.

### [ ] 5.11 (5b) `.pkg` dağıtımı, kurulum ve kaldırma

**Yapılacaklar.** Ana uygulama sürüklenip bırakılan `.app` olarak kalır. Mikrofon, uygulama içinden "Sanal mikrofonu kur" ile indirilen ve notarize edilmiş ayrı bir `.pkg` ile kurulur (yönetici şifresi ister, `coreaudiod` yeniden başlatılır). Kaldırma yolu da sunulur (plug-in ve artıkları temizler). Güncellemelerde plug-in sürümü kontrol edilir ve gerekirse yeniden kurulum istenir.

**Dosyalar.** `mac/scripts/build-virtual-mic-pkg.sh`, `Quic/VirtualMicInstaller.swift`, ayarlar arayüzü.

**Testler (beklenen sonuç).** `pkgutil --check-signature` ve `notarytool` başarılı; kurulumdan sonra `ls /Library/Audio/Plug-Ins/HAL` plug-in'i gösterir; kaldırmadan sonra aynı dizinde ve `pkgutil --pkgs` çıktısında artık yok; `coreaudiod` yeniden başlar ve sistem sesi bozulmaz.

**Bitti ölçütü.** Mikrofon kurulup tam kaldırılabiliyor.

### [ ] 5.12 (5b) Dokümantasyon ve 5b kabul testi

**Yapılacaklar.** `mac/CLAUDE.md` (`AudioPlugin/`, `.pkg` dağıtımı), kök `CLAUDE.md`, `TECHNICAL.md`, `RoadMap.md`.

**Testler (beklenen sonuç).** FaceTime, Zoom ve Meet "Link To Mac Mikrofon"u görür; 1 saatlik görüşmede ses kayması veya kopma yok; plug-in kaldırıldığında sistemde artık kalmaz.

**Bitti ölçütü.** 5b kabul ölçütleri karşılanıyor (ya da 5b kullanıcı onayıyla ertelendi ve planda öyle yazıldı).

### [ ] 5.13 Faz 5 genel testi

**Beklenen sonuç.** Tüm bileşen testleri geçer; kamera ve mikrofon birlikte aynı görüşmede çalışır; telefon bağlantısı kopup gelince ikisi de toparlanır; Sparkle güncellemesi sonrası ikisi de çalışır; ekran yansıtma/ses ile eş zamanlı kullanımda gecikme hedefleri tutar; mevcut özellikler regresyonsuz.

---

## [ ] Faz 6 — Sağlamlaştırma, QoS ve test

Maddelerin çoğu fazların içinde azar azar yapılır; Faz 6 eksikleri toplar. **Legacy kaldırma bu fazda yok: WS/relay katmanı kalıcı.**
Büyüklük: **S–M**. Bağımlılık: Faz 1–5 (Faz 7'den bağımsız).

### [ ] 6.1 QoS: bant genişliği payı ve öncelikler

**Yapılacaklar (0.7 sonucuna göre yeniden yazıldı, kullanıcı onaylı 2026-11-18; "%50 × tahmini bant genişliği" kararı kalktı, çünkü kapasite oynuyor ve sabit pay güvenilir değil).**
1. Gerçek zamanlı oturum (ekran, kamera) açıkken Mac → telefon QUIC dosya hızı `DelayRateController` ile ayarlanır (0.7 madde 6): Mac'e gelen her video stream'inden `d = varış − telefon damgası`; kuyruk tahmini = son 0,6 sn'nin medyanı − sakin seviye (30 sn'lik pencere medyanlarının p10'u); 100 ms'de bir `tick`; eşikler 7 / 3 ms; hız tabanı 2 MB/sn (ürün politikası: 1 GiB ≈ 8,5 dk; **ayar olarak değiştirilebilir**), tavan 40 MB/sn, başlangıç 2 MB/sn + yavaş başlangıç; hız tabandayken sürekli yüksek kuyruk ortam sayılır (ortam payı).
2. Telefon → Mac yönünde quinn stream öncelikleri: oturum stream'i > ses > video > dosya. Ses ayrı UDP'ye düştüyse onun için öncelik yok; dosya trafiğinin hız sınırı korur.
3. Mac → telefon yönünde Network.framework öncelik sunmadığı için uygulama seviyesinde hız sınırı: 2.5'te eklenen token-bucket arayüzü + madde 1'in denetleyicisi.
4. Denetleyici yalnız video akarken çalışır: video yoksa (oturum yok ya da 2 sn'den uzun duraklama) sinyal yoktur, hız tutulur; **oturum bitince sınırlama kalkar ve dosya tam hıza döner**. "Gerçek zamanlı oturum aktif" bayrağı denetleyiciyi açıp kapatır.
5. Bilinen sınırlar, bu fazda ele alınacak: 30 sn+ süren kesintisiz kuyruk sakin seviye olur ("geç gelen"); periyodik "hızı kısa düşür, sakin seviyeyi yenile" sondası; eşikler tek kampüs ağında ayarlı, **ev Wi-Fi'sinde ve farklı AP'lerde yeniden doğrulanır**.

**Testler (beklenen sonuç).** Birim: `DelayRateController` (32 test, 0.7'de yazıldı: her kural, akışkan darboğaz simülasyonları, ortam sıçraması) + oturum bayrağı durum makinesi; öncelik sırası yapılandırması. Cihaz: ekran yansıtma açıkken 10 GB dosya akarken video p95 gecikmesi hedefte (≤ 120 ms uçtan uca) kalır ve eşleştirilmiş ölçümde (`spikes/quic/qos-pair-ping.sh`, `auto`) video etkisi ≤ 20 ms, ortalama dosya hızı ≥ 4 MB/sn (kampüs ağında; ev Wi-Fi'sinde ayrıca kaydedilir); oturum kapanınca dosya hızı tam hıza döner.

**Bitti ölçütü.** Dosya trafiği gerçek zamanlı akışı bozmuyor.

### [ ] 6.2 WS kontrol linki ve ağır transfer

**Yapılacaklar.** WS kontrol linki aynı Wi-Fi'ı paylaşır: 10 GB transfer sırasında pano, bildirim ve medya kontrolü gecikmesi ölçülür; artarsa dosya hız sınırı her zaman açık tutulur.

**Testler (beklenen sonuç).** 10 GB transfer sürerken pano kopyası Mac'e ≤ 1 sn (onaylı eşik, mevcut gecikmenin 2 katı içinde), medya komutu ≤ 500 ms; aşılırsa her zaman açık hız sınırı devreye alınır ve ölçüm tekrarlanır.

**Bitti ölçütü.** Kontrol düzlemi gecikmesi ağır transferde de kabul edilebilir.

### [ ] 6.3 Stres testi

**Yapılacaklar.** Ekran + ses + 10 GB transfer + pano trafiği aynı anda, 30 dk.

**Testler (beklenen sonuç).** Ses gecikmesi hedefin (150 ms) altında; ekran gecikmesi hedefte; kopma/çökme yok; bellek iki tarafta sabit; transfer sonunda SHA-256 eşit; pil ve sıcaklık kaydedilir.

**Bitti ölçütü.** Üç yük bir arada kararlı.

### [ ] 6.4 Gözlemlenebilirlik

**Yapılacaklar.** Geliştirme sürümünde qlog (qvis ile incelenir), release'te kapalı. Diagnostics raporunda QUIC bölümü genişler: RTT, kayıp, aktif kanallar, bitrate. IP, port ve anahtar materyali yok; `sanitize.ts` kurallarına tabi.

**Dosyalar.** `quic-core` (qlog özelliği `cfg(debug_assertions)`), `build-report.ts`, `sanitize.ts`.

**Testler (beklenen sonuç).** Release derlemesinde qlog dosyası üretilmez (APK içinde özellik kapalı, test: yapılandırma bayrağı); debug'da qvis ile açılabilir dosya üretilir; `bun run test`: rapor yeni alanları içerir ve hassas değer taşımaz; `check-log-privacy` temiz.

**Bitti ölçütü.** Sorun giderme verisi var, gizlilik korunuyor.

### [ ] 6.5 Test altyapısı: UDP proxy ve ağ koşulları

**Yapılacaklar.** `tools/udp-proxy/`: paket düşüren ve geciktiren bir UDP proxy; iki uç arasında senaryo betikleri (kayıp %0/%2/%5, gecikme/jitter, bant daraltma). macOS Network Link Conditioner profilleri belgelenir.

**Testler (beklenen sonuç).** Proxy birim testi (belirlenen kayıp oranına ±%0,5 uyar, gecikme dağılımı doğru); senaryo betikleri tekrarlanabilir sonuç verir.

**Bitti ölçütü.** Ağ koşulları tekrarlanabilir biçimde üretilebiliyor.

### [ ] 6.6 Geçişler ve uyku

**Yapılacaklar ve testler (beklenen sonuç).**
- QUIC oturumu sürerken Wi-Fi → mobil veri: link relay'e düşer, oturum temiz kapanır; 1 GiB altı dosya WS'den devam eder, üstü duraklayıp LAN dönünce sürer.
- Mac uykuya geçip uyanma: oturum temiz kapanır, uyanınca isteğe bağlı yeniden açılır; dosya transferi kaldığı yerden sürer.
- Telefon hotspot'u üzerinden bağlantı belgelenir (kurumsal/okul Wi-Fi'ı UDP'yi ya da istemciler arası trafiği engelliyorsa LAN-direct zaten çalışmaz; relay'de dosya WS'den gider, medya "aynı Wi-Fi gerekli" der).

**Bitti ölçütü.** Geçiş senaryoları belgeli ve geçiyor.

### [ ] 6.7 Pil

**Yapılacaklar ve testler (beklenen sonuç).** QUIC oturumu yokken boştaki tüketim değişmemeli (mevcut ölçümle karşılaştır: 1 saatlik boşta, fark ölçüm hatası içinde); 1 saatlik ekran yansıtma tüketimi kaydedilir ve `docs` altında belgelenir.

**Bitti ölçütü.** Pil etkisi ölçüldü; boşta regresyon yok.

### [ ] 6.8 Hardened runtime ve notarize doğrulaması

**Yapılacaklar.** Notarize edilmiş build'de, temiz bir Mac'te: UDP dinleyici, Local Network izni, Camera Extension (5a) ve sanal mikrofon `.pkg` (5b) kontrol edilir. TECHNICAL.md §10'daki "doğrulanmamış" maddeler listesine eklenir; mevcut açık maddeler (ekran kilidi, BLE, LAN sunucu, bildirimler, Sparkle güncellemesi) aynı turda yeniden doğrulanır.

**Testler (beklenen sonuç).** Temiz Mac'te ilk açılışta yerel ağ izni istenir ve verilince QUIC oturumu açılır; kamera/mikrofon görünür; ekran kilidi (`SACLockScreenImmediate`), BLE yakınlık, bildirimler ve Sparkle güncellemesi çalışır. Başarısız her madde, `RoadMap.md`'de açık madde olarak kalır.

**Bitti ölçütü.** Notarize build'in QUIC ile birlikte tüm sistem özellikleri doğrulandı.

### [ ] 6.9 Sürüm uyumu, paketleme, güvenlik

**Yapılacaklar.**
1. Uyumluluk `caps` ile: `q1` bildirmeyen peer'e QUIC özellikleri sunulmaz, eski davranış sürer. Protokol sürümü artınca `q2` eklenir, `q1` bir süre desteklenir.
2. Dağıtım mevcut kanallarla: Mac'te Sparkle + notarize, Android'de uygulamanın kendi APK güncelleyicisi. Rust `.so` APK boyutunu büyütür; yalnız `arm64-v8a` paketlenir (boyut farkı kaydedilir).
3. Ayrı sertifika iptali gerekmez: QUIC sunucu kimliği uzun ömürlü ama fingerprint her offer'da E2E kanaldan doğrulanır; güven pairing anahtarından gelir. **Unpair'de kimlik de yeniden üretilir.** Mac'te Unpair anahtarı döndürünce eski telefon `cmd` gönderemez, dolayısıyla QUIC oturumu da açamaz.

**Testler (beklenen sonuç).** Birim: `caps` kapısı (`q1` yok → özellik kapalı); Unpair sonrası kimlik parmak izi değişir ve eski telefonun `q.req`'i `cmd` aşamasında düşer. Cihaz: APK boyutu önceki sürümle karşılaştırılır; Unpair + yeniden eşleşme sonrası QUIC oturumu açılır.

**Bitti ölçütü.** Sürüm uyumu ve Unpair güvenliği doğrulandı.

### [ ] 6.10 Dokümantasyon

**Yapılacaklar.** `TECHNICAL.md`'ye yeni bölüm **§5.6 QUIC veri düzlemi**, data paths tablosuna yeni satırlar; `RoadMap.md` güncellemesi; `mobile/CLAUDE.md`, `mac/CLAUDE.md`, kök `CLAUDE.md` ve `README.md` (kullanıcıya görünen özellikler); `docs/diagrams/build.mjs`'te QUIC oturum akışı diyagramı (SVG + PNG üretimi, repo kuralı: ASCII değil görsel).

**Testler (beklenen sonuç).** Atıflar gerçek (grep); `node docs/diagrams/build.mjs` hatasız çalışır ve üretilen `.svg` + `.png` commit edilebilir durumda.

**Bitti ölçütü.** Doküman seti kodla ve birbiriyle uyumlu.

### [ ] 6.11 Faz 6 genel testi

**Beklenen sonuç.** Tüm bileşen testleri geçer (Mac, Android JVM, JS, Rust, relay `typecheck`/`smoke`); QoS, stres, geçiş, pil ve notarize doğrulamaları tamamlanmış; **tüm mevcut özellikler** (pano metin/görsel, dosya, bildirim, SMS, kilit, pil, medya, BLE yakınlık, LAN/relay geçişi) QUIC açıkken ve kapalıyken regresyonsuz.

---

## [ ] Faz 7 — Mac'ten arama kontrolü (QUIC'siz)

Arama kontrolü birkaç küçük mesajdan ibarettir: Faz 1'deki iki yönlü `cmd` ve `stat` frame'leriyle yapılır, relay üzerinden LAN dışında da çalışır.
Arama sesi telefonda kalır. Büyüklük: **S–M**. Bağımlılık: yalnız Faz 1. Sunucu (`server/`) değişmez.

### [ ] 7.1 One UI ön doğrulaması (ertelenen madde)

**Amaç.** Faz 7'ye başlarken Samsung'da arama bildirimini kimin gönderdiğini ve neyi taşıdığını görmek; 7.4 ve 7.8'in kararı buna bağlı.

**Yapılacaklar.** S24'te bir test `NotificationListenerService` kaydı: gelen arama, aktif arama ve rehberde olmayan numara için bildirimin `packageName`, `category`, `flags` (ongoing), aksiyon sayısı/sırası/etiketleri ve metinde numara/ad olup olmadığı kaydedilir (numara/ad değerleri sonuç dosyasına yazılmaz, yalnız "var/yok"). Bildirimi gönderen paket, `TelecomManager.getDefaultDialerPackage()` ile karşılaştırılır (in-call UI ayrı bir paket olabilir).

**Testler (beklenen sonuç).** Üç senaryo için tablo dolu (paket, kategori, ongoing, aksiyonlar, numara/ad görünürlüğü); `actionIntent.send()` ile Cevapla/Reddet/Kapat aksiyonunun gerçekten çalıştığı elle doğrulanır.

**Bitti ölçütü.** 7.4 filtresinin paket kümesi ve 7.8 yedek yolun gerekliliği belli.

### [ ] 7.2 Mesaj şeması ve vektör

**Yapılacaklar.**
1. Mac → telefon, `cmd`: `call.dial {number}`, `call.answer`, `call.end`.
2. Telefon → Mac, `stat` (opsiyonel `call` alanı): `{state: idle|ringing|active, number?, name?, since?}`; `media` alanı gibi yalnız değişince gönderilir.
3. Rehber ve son aramalar (Mac → telefon → Mac): istek `cmd` (`call.contacts {q?, page}`, `call.recents {page}`); **yanıt telefon → Mac `cmd` olarak** sayfalı gelir (boyut nedeniyle `sms` batch mantığı örnek alınır; relay `cmd`'yi iki yöne olduğu gibi ilettiği için sunucu değişmez). (Karar, 2026-11-14 onaylı: kaynak plandaki "`cmd` + yeni yanıt" bu biçimde uygulanır.)
4. `cmd` E2E şifreli ve tazelik/nonce korumalı olduğu için relay ya da LAN'daki biri sahte arama başlatamaz.
5. Yeni `stat` alanı ve `cmd` eylemleri `protocol-vectors/stat-call.json` ile sabitlenir (`stat-media.json` kalıbı); Swift ve Kotlin aynı dosyayı koşar.

**Dosyalar.** `protocol-vectors/stat-call.json`, `protocol-vectors/README.md`, `Quic/CallControl.swift` (adı `Calls/` altına taşınabilir), `.../CallControl.kt`, iki platformda vektör testi.

**Testler (beklenen sonuç).** Aynı vektörle Swift ve Kotlin: eylem ve stat ayrıştırma, geçersiz `number` (rakam, `+*#` dışı) reddi, sayfa sınırları, yalnız değişince gönderme kuralı; bozuk vektör iki paketi de kırar.

**Bitti ölçütü.** Mesaj şeması vektörle sabit.

### [ ] 7.3 Android: arama başlatma

**Yapılacaklar.** `TelecomManager.placeCall()` + `CALL_PHONE` (çalışma zamanında, lazily). Arka plandan activity açma kısıtına takılmadığı 7.1/7.3 cihaz denemesiyle doğrulanır. Gelen `number` temizlenir (yalnız rakam ve `+*#`), `tel:` URI'siyle verilir; kısa sürede çok sayıda `call.dial` hız sınırıyla reddedilir. Numara loglanmaz.

**Testler (beklenen sonuç).** Birim: numara temizleme ve hız sınırı. Cihaz: Mac'ten `call.dial` telefonda aramayı başlatır; izin yokken Mac'e açıklayıcı hata döner; ekran kapalıyken de çalışır.

**Bitti ölçütü.** Mac'ten arama başlatılıyor.

### [ ] 7.4 Android: gelen arama dalı (notification listener)

**Yapılacaklar.**
1. İzin zaten var (notification access). Arama bildirimi arayanın adını ve Cevapla / Reddet aksiyonlarını, aktif arama bildirimi Kapat aksiyonunu taşır; aksiyonlar `Notification.Action.actionIntent.send()` ile tetiklenir. Ek rol, `ANSWER_PHONE_CALLS` veya `READ_CALL_LOG` gerekmez.
2. **Filtre sırası:** `NotificationListener.onNotificationPosted` mevcut koduyla aynalamadan önce per-app filtresini ve ongoing / FGS / grup özeti filtrelerini uygular. Arama dalı bu filtrelerden **önce** ayrılır: `CATEGORY_CALL` **ve** paket 7.1'de belirlenen kümeye (varsayılan telefon uygulaması; `TelecomManager.getDefaultDialerPackage()`) ait. WhatsApp gibi VoIP uygulamaları da `CATEGORY_CALL` kullanır, onlar dışarıda kalır.
3. Aynı bildirim ayrıca `note` olarak aynalanmaz (Mac'te çift banner olmasın); bildirim kaldırılınca arama durumu kapanır.
4. Per-app filtresini atladığı için arama aynalamanın Ayarlar'da **kendi açma/kapama anahtarı** olur (varsayılan kapalı; `get/setCallForwarding` PREFS_UI, "Mirror media" kalıbı); Settings'te `InlineNotice` ile izin eksikliği gösterilir. Numara ve isim loglanmaz.

**Dosyalar.** `NotificationListener.kt`, `ClipForegroundService.kt` (`get/setCallForwarding`), `SelfAdbModule.kt`, `settings.tsx`, `use-permission-settings.ts`, `src/test/.../CallNotificationTest.kt`.

**Testler (beklenen sonuç).** JVM (sahte `StatusBarNotification` verisini temsil eden saf sınıflandırıcıyla): `CATEGORY_CALL` + varsayılan telefon paketi → arama dalı; `CATEGORY_CALL` + WhatsApp paketi → arama dalı değil (normal `note` yolu); ongoing arama bildirimi arama dalına girer; aynı bildirim `note` olarak gönderilmez; anahtar kapalıyken hiçbir şey gitmez; "include" modunda telefon uygulaması seçili olmasa da arama dalı çalışır. `bun run lint` + `npx tsc --noEmit` temiz.
Cihaz: gelen arama Mac'e arayan adıyla ulaşır.

**Bitti ölçütü.** Gelen arama bilgisi ve aksiyonlar bildirimden güvenle alınıyor, çift banner yok.

### [ ] 7.5 Android: arama durumu

**Yapılacaklar.** Durum için `TelephonyCallback.CallStateListener` + `READ_PHONE_STATE` (çalışma zamanında, lazily): boşta / çalıyor / görüşmede. Bu API numara vermez; numara/ad 7.4'teki bildirimden birleştirilir. `stat.call` yalnız değişince gönderilir (`since` aktif görüşme başlangıcı); Mac peer-online kenarında anlık durum isteyince en güncel durum gönderilir.

**Testler (beklenen sonuç).** Birim: durum + bildirim bilgisinden `stat.call` üretimi (yalnız değişimde); kenar durumları (cevapsız, reddedilen, bekleyen ikinci arama). Cihaz: gerçek arama akışında Mac durumu `idle → ringing → active → idle` takip eder.

**Bitti ölçütü.** Mac arama durumunu doğru ve güncel görüyor.

### [ ] 7.6 Android: rehber ve son aramalar

**Yapılacaklar.** Rehber `READ_CONTACTS` (SMS yansıtma için zaten istenebilir; yeniden kullanılır); son aramalar listesi için `READ_CALL_LOG`, **yalnız bu özellik açılınca** istenir. Yalnız Mac istediğinde, ad + numara, istek üzerine sayfalı gönderilir (7.2). Mac önbelleğe alır. Numara ve isim asla loglanmaz.

**Testler (beklenen sonuç).** Birim: sayfalama (sınırlar, boş sayfa, arama sorgusu `q`); izin yokken boş yanıt + neden. Cihaz: Mac'te rehber araması ve son aramalar telefondakiyle eşleşir; `READ_CALL_LOG` reddedilince son aramalar bölümü gizli kalır, diğerleri çalışır.

**Bitti ölçütü.** Mac rehberi ve son aramaları görüyor.

### [ ] 7.7 Mac arayüzü

**Yapılacaklar.** Tuş takımı, rehber araması, son aramalar (dashboard'da "Calls" sekmesi); gelen arama: mevcut bildirim altyapısıyla Cevapla / Reddet aksiyonlu banner (`UNUserNotification`); aktif arama paneli: süre ve kapat butonu. Özellik Ayarlar'daki anahtara (7.4) bağlı; telefon `caps`'inde ya da `stat.call`'da destek yoksa gizli.

**Dosyalar.** `mac/Sources/LinkToMac/Calls/` (sayfa, banner, panel), `MacNotifier.swift`, `DashboardWindow.swift`, `mac/Tests/CallStateTests.swift`.

**Testler (beklenen sonuç).** Birim (Foundation-only model): `stat.call` güncellemeleri → ekran durumu; süre sayacı `since`'ten; numara biçimlendirme; geçersiz giriş reddi. Cihaz: banner'dan Cevapla/Reddet ve panelden Kapat telefonda çalışır; telefon çevrimdışıyken arayüz devre dışı.

**Bitti ölçütü.** Mac'ten tam arama deneyimi var.

### [ ] 7.8 Yedek yol (koşullu)

**Koşul.** Yalnız 7.1'de bildirim aksiyonları One UI'da çalışmıyorsa uygulanır.

**Yapılacaklar.** `TelecomManager.acceptRingingCall()` / `endCall()` + `ANSWER_PHONE_CALLS` (`endCall()` API 29'dan beri deprecated; One UI'da test edilir). Neden CallScreening değil: `ROLE_CALL_SCREENING` tek sahiplidir; almak kullanıcının mevcut spam engelleyicisini devre dışı bırakır, bu yüzden kullanılmaz.

**Testler (beklenen sonuç).** Cihaz: Mac'ten cevaplama ve kapatma çalışır; izin istemi yalnız bu yola düşülünce çıkar.

**Bitti ölçütü.** Bildirim yolu çalışmazsa da cevaplama/kapatma var (koşul sağlanmadıysa bu aşama plandan silinmiştir).

### [ ] 7.9 Dokümantasyon

**Yapılacaklar.** `mobile/CLAUDE.md` (arama dalı, `get/setCallForwarding`, izinler), `mac/CLAUDE.md` (`Calls/`), kök `CLAUDE.md` (cmd iki yönlü kullanım + `stat.call`), `TECHNICAL.md` (arama mesajları), `protocol-vectors/README.md`, `RoadMap.md` ("Make Call from Mac" maddesi).

**Testler (beklenen sonuç).** Atıflar gerçek; RoadMap durumu yansıtıyor.

**Bitti ölçütü.** Dokümanlar kodla uyumlu.

### [ ] 7.10 Faz 7 genel testi

**Beklenen sonuç.** Tüm bileşen testleri geçer; **telefon mobil veride, Mac başka bir ağdayken (relay)** Mac'ten arama başlatılır, gelen arama Mac'te arayan adıyla görünür, cevaplama ve kapatma çalışır; aynı testler LAN-direct'te de geçer; arama aynalama kapalıyken hiçbir arama verisi gitmez; çift banner yok; mevcut özellikler regresyonsuz.

---

## Riskler ve bağımlılıklar

En büyük teknik risk Mac tarafındaki Network.framework QUIC'in quinn ile uyumu ve kalıcı kimlik üretimi; ikisi de Faz 0'da önden denenir. Hibrit modelin kalıcı bedeli, uzun vadede iki protokolün birlikte yaşamasıdır.

| Risk | Etki | Önlem |
|---|---|---|
| Uzun vadede iki protokol (WS kontrol + QUIC veri) | Bakım yükü, iki yerde hata ayıklama | QUIC yalnız veri taşır, kontrol tek yerde kalır; QUIC iyi çalışırsa kontrol düzlemini sonradan taşımak mümkün |
| Network.framework ↔ quinn interop, Swift'te DATAGRAM hatası veya kalıcı kimlik üretimi sorunlu | Mac'te bağımlılıksız yol kapanır | Faz 0 kapıları; ses için Faz 4'teki yedek taşıma (4.6), interop için Mac'te quinn + uniffi. **Faz 0'da doğrulandı (0.12): interop, DATAGRAM ve kalıcı kimlik geçti, quinn + uniffi gerekmedi** |
| System Extension profili / entitlement alınamaz | Faz 5a yapılamaz | Faz 0'da doğrula; diğer fazlar etkilenmez. **Faz 0'da doğrulandı (0.11): profil alındı, uzantı kuruldu ve kamera listelendi** |
| Popüler uygulamalar ses yakalamayı kapatır | Faz 4 değeri düşer | Faz 0 testi; desteklenen uygulamalar listesi. **Gerçekleşti (0.9): Spotify yakalanamıyor; 4.9'da opt-out uyarısı** |
| One UI arama bildirimi beklenen aksiyonları taşımaz | Mac'ten cevaplama/kapatma olmaz | 7.1 ön doğrulama; TelecomManager yedek yolu (7.8) |
| One UI servisi öldürür (issue #29–#31) | Mac'ten başlatılan oturum isteği ulaşmaz | Mevcut ExitReasons tanılaması; kalıcı çözüm roadmap'teki FCM push-wake (tüm özellikler için) |
| Wi-Fi istemci izolasyonu (okul, otel) | LAN-direct zaten çalışmaz, QUIC de | Relay'de dosya WS yolundan gider; medya özellikleri "aynı Wi-Fi gerekli" der |
| Android sürüm güncellemeleri MediaProjection / FGS kurallarını sıkılaştırır | Akışlar bozulur | Her One UI güncellemesinde Faz 3–5 regresyon listesi |

**Onaylanan plan kararları (2026-11-14, kullanıcı onayı).** (1) `q.accept` eylemi eklendi; Mac'ten istenen oturumlarda telefon kabulü bununla bildirilir (1.3, 3.2). (2) Dosya bidi stream'i de `0x01` tip varint'iyle başlar (2.2; referanstaki "Kanallar" buna göre). (3) Arama rehber ve son arama yanıtları telefon → Mac `cmd` olarak taşınır (7.2). (4) Plandaki sayısal eşikler (0.5, 0.7, 0.8, 0.10; 4.3, 4.8, 6.2; 3.2'deki 60 sn bekleme) onaylandı; ölçümler sapmayı gerektirirse yalnız kullanıcı onayıyla değişir ve ilgili aşama yeniden yazılır. (5) 0.3 bulguları (Network.framework): geçersiz token ve oturum sonlandırma protokol içinde taşınır, Mac'in başlattığı stream'lerdeki boş çerçeve stream'i alıcıda yok sayılır (1.6, 1.7, 2.2, 2.3, 3.2). (6) 0.5 bulgusu (Network.framework): yeni stream kredisi kendiliğinden verilmez (başlangıç 100'de 100'üncü, 2⁶⁰'da 4096'ncı stream'de gönderici tıkanır); alıcı `localMaxStreamsUnidirectional`'ı tamamlanan sayıya göre yükseltir, gönderici `open_uni()`'yi zaman aşımıyla sarar (1.6 madde 8, 3.4 madde 6, 4.5 (0.12'de silindi); onay 2026-11-15). (7) 0.6 bulguları (Network.framework ve quinn): Mac'in başlattığı stream'lerde FIN, veri taşıyan `.finalMessage` ile değil ayrı boş bir final mesajla verilir (2.5 madde 3); dosya akışlarında quinn parçaları ≥ 1 MiB toplanıp tek seferde yazılır/hash'lenir, medya akışlarında toplanmaz (1.7 madde 7, 2.3 madde 7; onay 2026-11-15). (8) 0.7 bulguları: Mac → telefon dosya hızı sabit bir yüzdeyle değil, video gecikmesinden beslenen uyumlu bir denetleyiciyle (`DelayRateController`, hız tabanı 2 MB/sn) yönetilir; 2.5 madde 5 ve 6.1 buna göre yeniden yazıldı (onay 2026-11-18). (9) 0.10 bulguları: Android'de QUIC dosyası doğrudan MediaStore `IS_PENDING=1` girdisine yazılır (yerel yazmanın %93'ü), bitiş kopyası ve 2× alan rezervasyonu kalktı, boş alan kuralı `size − have` + 64 MiB; `DATE_EXPIRES` bu cihazda ayarlanamaz/yenilenemez (sabit 7 gün), bu yüzden 6 saatlik saklama uygulamanın kendi kuralıdır ve terk edilmiş bekleyen girdileri uygulama temizler; 2.3 ve 2.7 buna göre yeniden yazıldı (onay 2026-11-19). (10) 0.12 kapı değerlendirmesi: DATAGRAM geçti ve ~110 stream/sn telefonda kaldı → ses yolu DATAGRAM, 4.5 (kısa uni stream) silindi (numara korundu), 4.6 (UDP soketi) yalnız 4.4'ün ses + video birlikte yük testi kalırsa; s-60 geçti → 3.4'teki tek akışlı yedek silindi; Camera Extension geçti → Faz 5 donmuyor; Spotify yakalanamıyor → 4.9/4.11 kabul testleri uyarlandı; 0.8 bulguları (`max-fps-to-encoder` float, monotonik saat, repeat-previous ~1,2 sn, HEVC açık) 3.3/3.4/3.6/4.1'e, 0.10 bulguları 2.6 (Android), 0.11 bulguları 5.3/5.4'e işlendi (onay 2026-11-19).

Yeni bir belirsizlik çıkarsa bu bölümün altına "Açık plan netleştirmeleri" başlığıyla eklenir; onaylanmadan ilgili aşamaya başlanmaz.

**Açık soru.** Developer ID sertifikasının güncel durumu: TECHNICAL.md sürümlerin imzalı ve notarize olduğunu söylüyor; farklıysa Faz 5'in ilk işi bu olur.

## Açık plan netleştirmeleri

1. **[ÇÖZÜLDÜ, 0.12, kullanıcı onaylı 2026-11-19: 2.6'nın Android maddeleri yeniden yazıldı.]** ~~2.6 (Android) kararlardan sonra yeniden okunmalı — onaylanmadan 2.6'ya başlanmaz (2026-11-19, 0.10 sonrası).~~ 2.3/2.7 Android'de yarım dosyayı `<id>.qpart` yerine MediaStore bekleyen girdisi + `PendingJournal` kaydı yaptı. 2.6'nın şu Android maddeleri buna göre yorumlanmaya muhtaç: madde 2 (açılışta `.qpart` taraması, boyut = dosya uzunluğu, son yazma = `mtime`: Android'de kayıt defteri taranır, boyut `statSize`, son etkinlik kayıt alanıdır), madde 4 (resume noktası 640 KiB'a yuvarlanıp dosya kısaltılır: Android'de MediaStore fd'sinde `truncate` ölçülmediği için kısaltma yerine üzerine yazma; QUIC `have` zaten 1 MiB'a aşağı yuvarlanır), madde 5–6 (süre ve "sessizce silinmez": süre artık `DATE_EXPIRES`'ta değil kayıt defterinde, temizleyici 2.3 madde 6). Mac tarafı değişmedi. Önerilen düzeltme 2.6 başlamadan önce kullanıcıya sunulacak.

