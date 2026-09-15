# Typing zoom: Windows'a taşıma notları

Bu branch (`typing-caret`), kullanıcı bir metin alanına yazarken kameranın yazı
imlecini (caret) takip etmesini ekliyor. **macOS'ta çalışıyor ve gerçek kayıtla
doğrulandı. Windows'ta caret verisi henüz üretilmiyor.** Windows'ta uygulamanın
geri kalanı (tıklama tabanlı otomatik zoom, tıklama efektleri, imleç tipi)
değişmeden çalışır, ama "Typing" modu bir şey yapmaz.

## Sistem nasıl çalışıyor

```
native cursor monitor ──stdout──▶ electron/ipc/cursor/monitor.ts
  "CARET:<x>:<y>"                   └─ caret.ts: acceptCaretMessage / getCapturedCaret
  "CARET:none"                           (ekran koordinatı → kayıt kaynağına göre 0–1)
                                     └─ telemetry.ts: her örneğe `caret: {cx, cy} | null`
                                          └─ <video>.cursor.json

editör:
  zoomSuggestionUtils.ts  caret olan örneklerden "typing" modunda zoom bölgesi önerir
  sceneMotion.ts          typing bölgesinde kamera caretAtTime() konumunu takip eder,
                          caret yoksa fareyi takip eder
```

Electron ve editör tarafı platformdan bağımsız. **Windows için sadece native
helper'ın `CARET:` satırlarını basması gerekiyor.**

## Yapılacak iş: `electron/native/cursor-monitor/src/main.cpp`

Şu an 50 ms'lik döngüde sadece `STATE:<tip>` basıyor. Aynı döngüye şunu ekle:

1. **Caret konumunu oku** (ekran koordinatı, caret dikdörtgeninin ortası):
   - Önce `GetGUIThreadInfo(GetWindowThreadProcessId(GetForegroundWindow()))`:
     `hwndCaret` doluysa `rcCaret`'i `ClientToScreen` ile ekran koordinatına çevir.
     Klasik Win32 metin kutuları (Not Defteri, çoğu native uygulama) için yeterli.
   - Olmazsa `AccessibleObjectFromWindow(hwndFocus, OBJID_CARET, IID_IAccessible)` →
     `accLocation(CHILDID_SELF)`. Chrome ve Edge'in adres çubuğu ve arama kutuları
     burada. `oleacc` kütüphanesini `CMakeLists.txt`'e ekle, `CoInitialize` çağır.
   - Parola alanlarını atla. macOS helper'ı yalnızca geometriyi okuyor, metin
     içeriğini asla okumuyor. Aynısını koru.
   - Genişliği 32 px'den büyük veya yüksekliği 0 / 200 px üstü olan dikdörtgenleri
     geçersiz say (seçim aralıkları, bozuk değerler).

2. **"Yazıyor" algılaması**, macOS'takiyle aynı mantık
   (`electron/native/NativeCursorMonitor.swift` → `emitTextCaret`):
   - Odaktaki eleman aynı kalıp caret 0.2 px'den fazla hareket ettiyse "yazıyor" say.
   - Odak değişirse, caret kaybolursa ya da fare tıklanırsa sıfırla.
   - Son hareketten sonraki 1 saniye boyunca `CARET:<x>:<y>`, geri kalan her döngüde
     `CARET:none` bas. Yazmayan kullanıcıda kamera caret'e kilitlenmesin diye bu şart.

3. **DPI: en kolay hata kaynağı.** `caret.ts`, koordinatları Electron'un
   `display.bounds` değerine (DIP) göre normalize ediyor. %125 / %150 ölçekli
   ekranda helper fiziksel piksel basarsa caret yanlış yere düşer. Önerilen:
   helper'da `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)`,
   fiziksel piksel bas, `caret.ts` içinde `process.platform === "win32"` iken
   `screen.screenToDipPoint()` ile çevir. Birden fazla, farklı ölçekli ekranda test et.

## Diğer küçük işler

- `src/components/video-editor/SettingsPanel.tsx`: Typing açıklaması "new macOS
  recordings" diyor. Windows desteği gelince metni güncelle.
- `electron/ipc/cursor/helperPermissions.ts`: Windows'ta izin kontrolü her zaman
  `true` dönüyor. Windows'ta Erişilebilirlik izni gerekmediği için bu doğru.
- Testler: `electron/ipc/cursor/caret.test.ts` için Windows DPI çevirisi testi ekle.

## Windows'ta derleme

Gereken: Node 22 veya üstü, Git, Visual Studio 2022 Build Tools (C++ ve CMake
bileşenleriyle).

```bash
npm install
npm run build:cursor-monitor   # main.cpp'yi derler, helpers-manifest.json'u günceller
npm test
npm run dev                    # geliştirme
npm run build:win              # release/ altına NSIS kurulum dosyası
```

Notlar:
- `package.json` sürümü `1.4.0-typing.1`. Bu sürümde otomatik güncelleme kapalı
  (`electron/updater.ts`), resmi güncelleme bu build'in üstüne yazmaz.
- appId `dev.recordly.app`, yani resmi Recordly ile aynı. Resmi Recordly kurulu
  bir makineye kurulum onun yerine geçer.
- Build imzasız olduğu için Windows SmartScreen uyarı verir
  ("Ek bilgi → Yine de çalıştır").

## Nasıl doğrulanır

1. Yeni bir kayıt al, tarayıcıda bir arama kutusuna birkaç saniye yaz.
2. `%APPDATA%\Recordly\recordings\<kayıt>.mp4.cursor.json` dosyasında yazma
   aralığındaki örneklerde `caret` alanının dolu olduğunu kontrol et.
3. Editörde o aralıkta otomatik **Typing** zoom bölgesi oluşmalı, önizlemede kamera
   caret'i takip etmeli.

## macOS tarafı (referans)

- İzin: macOS, helper sürecini uygulamanın imzasıyla eşleştiriyor. Ad-hoc imzalı
  build'de helper reddedilir. Yerel build için `npm run setup:local-signing`
  (bir kez), ardından `npm run build:mac:local`.
- Kayıttan önce helper'ın kendi izni kontrol ediliyor
  (`get-cursor-helper-permission-status`), eksikse kullanıcı uyarılıyor.
