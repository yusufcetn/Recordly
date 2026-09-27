# Typing zoom

Bu branch (`typing-caret`), bir metin alanına yazarken kameranın yazı imlecini
(caret) takip etmesini ekliyor. Kayıttan sonra editör, yazılan aralıklara otomatik
olarak **Typing** modunda zoom bölgesi ekliyor; bu bölgelerde kamera imleci,
imleç yoksa fareyi takip ediyor.

| Platform | Durum |
|---|---|
| macOS | Çalışıyor. Zen'de (Gecko) gerçek kayıtla doğrulandı; diğer uygulamalar için log'a bak. |
| Windows | Yazıldı, henüz gerçek bir Windows makinesinde denenmedi. Aşağıdaki "Windows'ta doğrulama" adımlarına bak. |

## Build komutları

### macOS

İlk kurulumda bir kez:

```bash
npm install
npm run setup:local-signing
```

`setup:local-signing`, anahtar zincirine "Recordly Local Code Signing" adında
kendinden imzalı bir sertifika ekler; macOS şifreni ister. Build sırasında
"codesign anahtara erişmek istiyor" diye sorarsa **Always Allow** de.

Her build'de:

```bash
npm run build:mac:local
```

Çıktı: `release-typing/Recordly-arm64.dmg`. DMG'yi açıp Recordly'yi Applications'a
sürükle. İlk kurulumda Sistem Ayarları → Gizlilik ve Güvenlik → **Erişilebilirlik**
listesinde Recordly'ye izin ver. Aynı sertifikayla imzalandığı sürece sonraki
build'lerde izin korunur.

`release-typing/mac-arm64/` klasörü build'in ara çıktısı; silinebilir, her build'de
yeniden oluşur.

### Windows: GitHub Actions ile (kurulum gerektirmez)

Windows kurulum dosyasını fork'un Actions'ı gerçek bir Windows makinesinde
derleyip üretir:

```bash
gh workflow run build.yml --repo yusufcetn/Recordly --ref typing-caret
gh run watch --repo yusufcetn/Recordly
gh run download --repo yusufcetn/Recordly --name windows-x64-release \
  "$(gh run list --repo yusufcetn/Recordly --workflow build.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

Ya da tarayıcıdan: fork'ta **Actions → Build Electron App → Run workflow**, branch
olarak `typing-caret` seç. Bitince çalıştırmanın sayfasındaki
`windows-x64-release` artifact'ını indir; içindeki `Recordly-windows-x64.exe`
kurulum dosyasıdır. Bu iş macOS ve Linux build'lerini de paralel çalıştırır;
Windows için sadece `build-windows` işine bakman yeterli.

### Windows: kendi bilgisayarında

Gereken: Node 22+, Git ve Visual Studio 2022 Build Tools ("Desktop development
with C++" iş yükü, CMake bileşeniyle).

```bash
git clone -b typing-caret https://github.com/yusufcetn/Recordly.git
cd Recordly
npm install
npm run build:win
```

Çıktı: `release/Recordly-windows-x64.exe`.

**Dikkat:** Build Tools veya CMake yoksa `build:cursor-monitor` hata vermeden
repodaki eski `cursor-monitor.exe`'yi kullanır ve typing takibi çalışmaz. Build
çıktısında `[build-cursor-monitor] Built successfully` satırını gör.

Geliştirme sırasında `npm run dev`, testler için `npm test`.

### Her iki platformda

- `package.json` sürümü `1.4.0-typing.1`. Bu sürümde otomatik güncelleme kapalı
  (`electron/updater.ts`); resmi güncelleme bu build'in üstüne yazmaz.
- appId `dev.recordly.app`, resmi Recordly ile aynı. Resmi Recordly kurulu bir
  makinede bu build onun yerine geçer.
- Windows build'i imzasız, SmartScreen uyarı verir: "Ek bilgi → Yine de çalıştır".

## Nasıl çalışıyor

```
native helper ──stdout──▶ electron/ipc/cursor/monitor.ts
  "CARET:<x>:<y>"            ├─ caret.ts: ekran koordinatı → kayıt kaynağına göre 0–1
  "CARET:none"               │   (Windows: fiziksel piksel → DIP)
  "CARET_DEBUG:..."          ├─ telemetry.ts: her örneğe `caret: {cx, cy} | null`
                             └─ <userData>/caret-debug.log

editör:
  zoomSuggestionUtils.ts  caret olan örneklerden "typing" zoom bölgesi önerir
  sceneMotion.ts          typing bölgesinde kamera caretAtTime() konumunu takip eder
```

Helper'lar: macOS'ta `electron/native/NativeCursorMonitor.swift`, Windows'ta
`electron/native/cursor-monitor/src/main.cpp`. İkisi de aynı mantığı izler:

1. **Yazma algılaması:** klavyeden (sadece bir tuşa basıldığı, hangi tuş olduğu
   asla; Cmd/Ctrl/Win kısayolları sayılmaz, AltGr sayılır) ve imlecin hareketinden
   (yapıştırmayı yakalar). Tıklama ikisini de sıfırlar. Son tuştan 1 saniye sonra
   takip biter.
2. **Konum**, en hassastan başlayarak:

   | Sıra | macOS | Windows |
   |---|---|---|
   | 1 | `text-range`: AXBoundsForRange (native metin kutuları) | `win32-caret`: GetGUIThreadInfo (klasik Win32) |
   | 2 | `text-marker`: AXBoundsForTextMarkerRange (web içeriği) | `msaa-caret`: MSAA OBJID_CARET (Chrome, Edge, Firefox) |
   | 3 | | `uia-caret`: UI Automation TextPattern2 (WinUI, WPF) |
   | 4 | `element`: odaktaki metin kutusunun ortası | `element`: aynısı, UI Automation ile |
   | 5 | `pointer`: öndeki uygulamaya yapılmış son tıklama | aynısı |

   Konum bilinmiyorsa zoom yapılmaz; yanlış yere zoom yapmaktan iyidir. Şifre
   alanları ve metin olmayan kontroller (buton, liste, bağlantı...) atlanır.
3. **Erişilebilirlik ağacı (macOS):** Chromium/Electron için `AXManualAccessibility`,
   Gecko (Firefox, Zen) için `AXEnhancedUserInterface` açılır; ikincisi kayıt bitince
   geri kapatılır.

Metin içeriği hiçbir yerde okunmaz; her kaynak sadece geometri döndürür.

## Sorun giderme

Hangi uygulamada hangi kaynağın çalıştığı, değiştiği anda log'a yazılır
(uygulama adı, rol ve kaynak; metin yok):

- macOS: `~/Library/Application Support/Recordly/caret-debug.log`
- Windows: `%APPDATA%\Recordly\caret-debug.log`

Örnek: `app.zen-browser.zen:AXComboBox:text-range` iyi, `...:none` o uygulamada
konum okunamadığı anlamına gelir.

Kayıt telemetrisi: `<userData>/recordings/<kayıt>.mp4.cursor.json`; yazılan
aralıktaki örneklerde `caret` alanı dolu olmalı.

## Windows'ta doğrulama

Windows helper'ı henüz gerçek bir makinede denenmedi. İlk denemede:

1. Kurulumdan sonra yeni bir kayıt al; Not Defteri'nde, Chrome'da ve Edge'de bir
   arama kutusuna birkaç saniye yaz.
2. `%APPDATA%\Recordly\caret-debug.log` dosyasına bak: hangi uygulamada hangi
   kaynağın (`win32-caret`, `msaa-caret`, `uia-caret`...) geldiğini gösterir.
3. Editörde yazılan aralıkta **Typing** zoom bölgesi oluşmalı, kamera imleci
   takip etmeli.
4. Ekran ölçeklemesi %100 olmayan (%125, %150) bir ekranda da dene. Kamera imlecin
   yanına değil de kaymış bir yere gidiyorsa sorun DPI çevirisindedir
   (`main.cpp` → `clientToPhysicalScreen`, `caret.ts` → `toDipPoint`).
