# /tmp Maintenance Script
**Version:** 2.4  
**Author:** Eren Kesdi  
**Last Updated:** 25-05-2025

> Güvenli, servis-bilinçli ve günlük log'lu /tmp dosya sistemi bakım aracı

## 📌 Hakkında

Bu script, `/tmp` dizini ayrı bir disk bölümü (örneğin `ext4`, `xfs`) olarak mount edilmiş sistemlerde, dosya sistemini kontrol etmek ve gerektiğinde onarmak için kullanılır. Sistemde bu dizini kullanan servisleri otomatik olarak tespit eder, güvenli bir şekilde durdurur, fsck çalıştırır ve sonrasında servisleri yeniden başlatır. 

Servis kesintisi gereken durumlarda minimum etki ve maksimum kontrol sağlamak için tasarlanmıştır.

## ⚙️ Özellikler

- Sistem servislerinin durumunu otomatik algılar ve durdurur/başlatır
- `/tmp` mount edilmişse kontrol eder ve dosya sistemi hatalarını düzeltir
- `tmpfs` kullanılıyorsa fsck adımı atlanır
- Hatalı mount durumunda `tmpfs` fallback ile sistem kararlılığı korunur
- Güvenli sinyal yakalama (SIGINT/SIGTERM)
- Tüm işlemler loglanır
- Eski log dosyaları otomatik silinir (`30 gün`)

## 🚀 Nasıl Kullanılır

```bash
sudo ./tmp_maintenance.sh
```
Gereksinimler
Aşağıdaki komut satırı araçlarının sistemde kurulu olması gerekir:

lsof

fsck

fuser

mountpoint

timeout

tee

blockdev

Debian/Ubuntu için yüklemek:

bash
Kopyala
Düzenle
sudo apt install lsof util-linux coreutils procps
🧠 Dikkat Edilmesi Gerekenler
Script sadece root yetkisiyle çalışır.

/tmp ayrı bir disk bölümü değilse, fsck yapılmaz ve çıkılır.

Kritik servisler (nginx, apache, mysql, redis) yeniden başlatılamazsa log uyarıları verir.

Script tamamlandığında log dosyasının konumu belirtilir.

📂 Loglama
Tüm çıktılar /var/log/tmp_maintenance/ dizinine tarihli olarak kaydedilir. Örnek:

bash
Kopyala
Düzenle
/var/log/tmp_maintenance/tmp_maintenance_20250525_141530.log
30 günden eski log dosyaları otomatik olarak silinir.

📦 Desteklenen Servisler
Aşağıdaki servislerin durumları otomatik olarak yönetilir (aktifse durdurulur ve işlem sonrası yeniden başlatılır):

nginx

apache2

php-fpm

mysql

redis

postgresql

mongod

docker

cassandra

elasticsearch

rabbitmq-server

🧪 Test Edilmiş Platformlar
Debian 11

Ubuntu 22.04

Proxmox 7.x

AlmaLinux 9.x

Diğer Linux dağıtımlarında da çalışması beklenir. Test ettiyseniz lütfen katkı sağlayın!
