# /tmp Maintenance Script

**Version:** 2.3  
**Author:** Eren Kesdi  
**Last Updated:** 25-05-2025

---

## Açıklama

Bu Bash script, Linux sistemlerde `/tmp` dizininin bağlı olduğu dosya sistemini kontrol eder, gerekirse tamir eder ve işlem öncesinde `/tmp`'yi kullanan kritik servisleri (nginx, apache2, mysql, redis, vb.) güvenli şekilde durdurup, işlem sonrası tekrar başlatır.

Script şu adımları gerçekleştirir:

- Root yetkisi ve gerekli komutların varlığını doğrular  
- Kullanıcıdan işlem onayı alır  
- Kritik servislerin durumlarını kontrol eder ve aktif olanları kaydeder  
- Bu servisleri sırasıyla durdurur  
- `/tmp` mount noktasını analiz eder ve eğer ayrı bir dosya sistemi ise `fsck` ile dosya sistemi tutarlılık kontrolü yapar  
- `fsck` sonrası `/tmp` yeniden mount edilir (başarısız olursa tmpfs fallback’i devreye girer)  
- Durduğunda servisler tekrar başlatılır ve kritik servislerin çalıştığı doğrulanır  
- 30 günden eski log dosyalarını temizler  
- İşlem sonunda başarılı veya hata durumu raporlanır

---

## Kullanım

```bash
sudo ./tmp_maintenance.sh
