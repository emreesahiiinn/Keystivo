<p align="center">
  <img src="docs/images/icon.png" width="132" alt="Keystivo simgesi">
</p>

<h1 align="center">Keystivo</h1>

<p align="center">
  <b>Mac'inizde eksik olan bütün güç araçları, tek bir hızlı ve yerel uygulamada.</b><br>
  Başlatıcı · Pano · Parçacıklar · Pencere yönetimi · Pencere değiştirici · Klavyeyle gezinme · Hareketler · Widget'lar · Otomasyon
</p>

<p align="center">
  <a href="https://github.com/emreesahiiinn/Keystivo/releases/latest"><b>İndir</b></a> ·
  <a href="#özellikler">Özellikler</a> ·
  <a href="#kurulum">Kurulum</a> ·
  <a href="#kaynaktan-derleme">Derleme</a> ·
  <a href="README.md">English</a>
</p>

<p align="center"><img src="docs/images/hero.png" alt="Keystivo: menü çubuğu paneli, widget'lar"></p>

Keystivo, ileri düzey Mac kullanıcılarının tek tek topladığı araçları bir araya getiriyor:
- başlatıcı, pano geçmişi ve metin genişletme,
- pencere yaslama ve pencere değiştirme,
- klavyeyle tıklama, izleme dörtgeni ve fare hareketleri,
- menü çubuğu araçları ve masaüstü widget'ları,
- ekran yakalama ve iş akışı motoru.

Hepsi tek bir yerel Swift uygulamasında; belleği yormuyor, verilerinizi Mac'inizde tutuyor ve siz çağırana kadar ortalıkta görünmüyor.

- **Yerel ve hızlı.** SwiftUI ve AppKit ile yazıldı; Electron ya da arka planda web görünümü yok. Kullanmadığınız özellikler kaynak tüketmez.
- **Gizlilik esaslı.** Hesap, telemetri ve bulut yok. Pano geçmişiniz, parçacıklarınız ve ayarlarınız Mac'inizden çıkmaz.
- **Size göre şekillenir.** Her özellik kapatılabilir, her kısayol değiştirilebilir, menü çubuğu paneli yeniden düzenlenebilir.
- **12 dil.** Türkçe, English, Deutsch, Français, Español, Italiano, Português (Brasil), Русский, 简体中文, 繁體中文, 日本語 ve 한국어.

## Özellikler

### Başlatıcı
<img src="docs/images/launcher.png" alt="Keystivo başlatıcı">

<kbd>⌥</kbd> <kbd>Boşluk</kbd> tuşlarına basıp yazın. Tek bir arama kutusunda şunları bulursunuz:
- uygulamalar ve dosyalar,
- Keystivo komutları ve açık pencereler,
- öndeki uygulamanın menü öğeleri,
- hesap makinesi, birim, döviz ve saat dilimi dönüşümleri,
- emoji ve simgeler, sözlük, hızlı bağlantılar, takma adlar ve çalışan işlemler.

Herhangi bir sonuçta <kbd>⌘</kbd> <kbd>K</kbd> ile o sonuçla yapabileceğiniz her şeyi görürsünüz.

### Menü çubuğu paneli ve ses mikseri
<img src="docs/images/control-center.png" alt="Keystivo menü çubuğu paneli ve ses mikseri">

Menü çubuğundan buzlu cam arka planlı bir panel açılır. İçinde şunlar var:
- hızlı anahtarlar: Odak, Uyanık Tut, mikrofon, Karanlık Mod ve diğerleri,
- uygulama başına ses seviyesi ve çıkış cihazı,
- harici ekran parlaklığı,
- pencere yerleşimleri ve hızlı işlemler.

Panelde neyin, hangi sırayla ve ne kadar saydam görüneceğini siz seçersiniz. Ses mikseri isterseniz menü çubuğunda ayrı bir simge olarak da durur.

### Widget'lar
<img src="docs/images/widgets.png" alt="Keystivo widget'ları">

Üç boyutta 11 canlı widget var:
- saat ve dünya saatleri,
- takvim ve geri sayım,
- hava durumu ve zamanlayıcı,
- sistem durumu ve piller,
- not, kısayollar ve pano.

Widget'ları masaüstüne (pencerelerin altına ya da her zaman üste) veya menü çubuğu paneline yerleştirebilirsiniz. Sürükleyerek taşınır, sağ tıklayarak boyutlandırılır.

### Ekran koruyucular
<img src="docs/images/screen-saver.png" alt="Keystivo Cam ekran koruyucusu">

Saat ve ortam tasarımlı 11 ekran koruyucu, gerçek macOS ekran koruyucusu olarak kurulur. Keystivo isterseniz siz boştayken kendi ekran koruyucusunu da başlatır; bu, masaüstünüzün üzerinde şeffaf, karartılmış ya da buzlu cam arka planla durur.

### Hepsi bir arada

| Alan | Neler var |
| --- | --- |
| **Pano** | Metin, bağlantı, görsel, dosya ve renklerden oluşan aranabilir geçmiş. Sabitleme, düz metin olarak yapıştırma, hariç tutulan uygulamalar ve tek tıkla temizleme. |
| **Parçacıklar** | Bir anahtar kelimeyi herhangi bir yere yazınca metin genişler; tarih, pano ve imleç yer tutucuları kullanılabilir. Başka araçlardan içe aktarılabilir. |
| **Pencere yönetimi** | Kısayolla ya da ekran kenarına sürükleyerek yarım, üçte bir ve çeyrek yaslama. Pencereleri ekranlar arasında taşıma, masa düzenlerini kaydedip geri yükleme. Değiştirici tuşla her pencereyi sürükleme veya boyutlandırma. |
| **Pencere tuşları** | Kırmızı, sarı ve yeşil tuşların ne yapacağını siz belirlersiniz: örneğin uygulamadan çık, ekranı doldur ya da simge durumuna küçült. |
| **Odak fareyi takip eder** | İmlecin altındaki pencere etkinleşir. Aynı ekran içinde ve ekran değişirken ayrı gecikmeler ayarlanabilir. |
| **Pencere değiştirici** | Canlı önizlemelerle, en son kullanılan önde olacak şekilde tek tek pencereler arasında geçiş. İsterseniz <kbd>⌘</kbd> <kbd>⇥</kbd> yerine geçer. |
| **Klavyeyle gezinme** | İpucu etiketleriyle ekrandaki her şeye fareye dokunmadan tıklama, arama ve kaydırma. |
| **Hareketler** | Özel izleme dörtgeni dokunma, kaydırma ve tutup dokunma hareketleri, fare çizgileri. Hareketler belirli uygulamalarla sınırlanabilir; hazır önerilerle başlanabilir. |
| **Fare ve klavye** | Hyper tuşu, tuş eşleme, yan düğme eylemleri; fare ve izleme dörtgeni için ayrı kaydırma yönü ve yumuşatma. |
| **Menü çubuğu** | Simgeleri bir ayırıcının arkasına gizleme. İşlemci, bellek, ağ, disk, GPU ve sensörler için farklı stillerde sistem göstergeleri. |
| **Ses** | Uygulama başına ses seviyesi, sessize alma ve çıkış cihazı. Hızlı cihaz değiştirme ve yeniden kullanılabilir ses profilleri. |
| **Ekranlar** | DDC ile harici monitörlerde donanım parlaklığı ve her ekran için çözünürlük seçimi. |
| **Ekran araçları** | Alan, pencere veya ekran yakalama. Açıklama ekleme, sabitleme, metin ve QR kod okuma, renk seçme, MP4 veya GIF olarak kayıt. |
| **Dosyalar** | Otomatik klasör kuralları, sürükle-bırak rafı ve temiz bir uygulama kaldırıcı. |
| **Bağlantılar** | Her bağlantıyı doğru tarayıcıda açma: iş siteleri birinde, kişisel siteler diğerinde. |
| **Otomasyon** | Tetikleyici → koşul → eylem iş akışları; kütüphaneden ya da sıfırdan kurulur. Tetikleyiciler arasında kısayol, uygulama, saat, Wi-Fi, boşta kalma, disk, görünüm ve `keystivo://` adresleri var. Adımlarda değişken, betik ve Kestirmeler kullanılabilir. |
| **Eklentiler** | İstediğiniz betik diliyle kendi komutlarınızı ekleme. |
| **Pil** | Pilin yıpranmasını yavaşlatan şarj sınırı ve ayrıntılı pil bilgisi. |
| **Sunum** | Sunum yaparken ya da kayıt alırken tuş vuruşlarını, tıklamaları ve imleci gösterme. |
| **Profiller** | Kısayolları, hareketleri ve ayarları bağlama göre değiştirme: iş, ev, sunum gibi. |
| **İçe/dışa aktarma** | Kurulumunuzu Mac'ler arasında taşıma, bir kısmını paylaşma ya da önceki bir sürüme dönme. |

## Kurulum

1. [Releases](https://github.com/emreesahiiinn/Keystivo/releases/latest) sayfasından en son **Keystivo-x.y.z.dmg** dosyasını indirin.
2. Açın ve **Keystivo**'yu **Uygulamalar** klasörüne sürükleyin.
3. Keystivo'yu açın. GitHub sürümleri henüz Apple tarafından onaylanmadığı için macOS ilk açılışta geliştiriciyi doğrulayamadığını söyler. **Sistem Ayarları › Gizlilik ve Güvenlik** bölümünden **Yine de Aç**'a tıklayın ya da şunu çalıştırın:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Keystivo.app
   ```
4. Karşılama ekranı gereken izinlerde size yol gösterir. Asıl gereken izin Erişilebilirlik; Ekran Kaydı yalnızca önizlemeler ve ekran yakalama için gerekir.

**Gereksinimler:** macOS 15 Sequoia veya üzeri, Apple silicon ya da Intel.

> İmzalı bir **Mac App Store** sürümü planlanıyor. Projeyi desteklemenin en kolay yolu o sürümü satın almak olacak. GitHub sürümü ücretsiz kalacak.

## Kaynaktan derleme

Xcode 26 veya üzeri gerekir.

```bash
git clone https://github.com/emreesahiiinn/Keystivo.git
cd Keystivo
make signing-cert   # isteğe bağlı: izinlerin yeniden derlemelerde korunması için yerel sertifika
make run            # debug derleyip başlatır
make test           # bütün modüllerin birim testleri
make dmg            # dist/Keystivo-<sürüm>.dmg olarak release paketi
```

Mimari, imzalama ve izinler, eklentiler ve teknik notlar için **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)** dosyasına bakın.

## Gizlilik

Keystivo çevrimdışı çalışır. Yaptığı ağ istekleri yalnızca şunlar:
- **Hava durumu widget'ları:** [Open-Meteo](https://open-meteo.com) tahminleri,
- **Döviz dönüştürme:** Avrupa Merkez Bankası kurları.

Bu isteklerde sizinle ilgili hiçbir bilgi gönderilmez. Analiz, çökme raporu gönderimi ya da hesap yok.

## Katkıda bulunma

Hata bildirimleri ve öneriler için [Issues](https://github.com/emreesahiiinn/Keystivo/issues) sayfasını kullanabilirsiniz. Pull request'lerde:
- değişiklikleri odaklı tutun ve çevredeki kod stiline uyun,
- yeni metinleri 12 dilin hepsine çevirin,
- göndermeden önce `make test` çalıştırın.

## Lisans

Keystivo, [GNU Genel Kamu Lisansı v3.0](LICENSE) altında özgür bir yazılımdır.
