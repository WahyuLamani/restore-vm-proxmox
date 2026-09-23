# SOP Implementasi Proxmox Backup → NAS OMV → Proxmox DR

**Versi:** 1.0  
**Jenis:** SOP Implementasi Teknis  
**Tujuan:** Panduan implementasi dari kondisi server kosong sampai sistem backup dan Disaster Recovery (DR) berjalan otomatis.

> **Catatan:** Dokumen ini berisi tata cara implementasi, urutan pekerjaan, konfigurasi, validasi, dan pengujian. Source code/script `.sh` tidak disertakan karena script sudah tersedia di server.

---

# 1. Arsitektur yang Digunakan

```text
                    PRODUCTION
                 Proxmox A
              192.168.71.202
                     |
                     | Backup VM
                     v
               Local Storage
                     |
                     | rsync + verify
                     v
                  NAS OMV
              192.168.71.211
              /export/Backup_VM
                     |
                     | NFS
                     v
                  Proxmox B
              192.168.71.205
                     |
             +-------+-------+
             |               |
          Slot 117        Slot 118
          DR VM           DR VM
```

VM production:

```text
VMID : 107
Name : ONEMDORAYA
IP   : 192.168.71.233
```

DR slot:

```text
Slot A : 117
Slot B : 118
```

---

# 2. Prasyarat

Pastikan sebelum implementasi:

### Proxmox A

- VM production sudah tersedia.
- `vzdump` dapat membuat backup.
- Storage `local` tersedia.
- NAS dapat diakses melalui network.
- Root access tersedia.

### NAS OMV

- NFS Server aktif.
- Export tersedia:

```text
/export/Backup_VM
```

- Proxmox A dapat melakukan write ke NFS.
- Proxmox B dapat melakukan read ke NFS.

### Proxmox B

- Proxmox sudah terinstall.
- Storage restore tersedia, misalnya:

```text
local-lvm
```

- Network production dapat digunakan untuk management.
- Tersedia bridge khusus DR:

```text
vmbr-dr
```

- VM production tidak boleh sudah ada pada Proxmox B.

---

# 3. Implementasi NAS OMV

## 3.1 Buat NFS Share

Pada OMV buat shared folder:

```text
Backup_VM
```

Kemudian aktifkan NFS share dengan export:

```text
/export/Backup_VM
```

Izinkan network Proxmox:

```text
192.168.71.0/24
```

Pastikan Proxmox dapat mengakses NAS:

```text
192.168.71.211
```

Tes dari Proxmox:

```bash
ping -c 4 192.168.71.211
```

Expected:

```text
64 bytes from 192.168.71.211
```

---

# 4. Mount NFS di Proxmox DR

Di Proxmox B install NFS client jika belum tersedia:

```bash
apt update
apt install nfs-common -y
```

Buat mount point:

```bash
mkdir -p /mnt/omv-backup
```

Tambahkan ke `/etc/fstab`:

```text
192.168.71.211:/export/Backup_VM /mnt/omv-backup nfs vers=3,rw,_netdev,x-systemd.automount,noauto 0 0
```

Jalankan:

```bash
mount /mnt/omv-backup
```

Kemudian cek:

```bash
mount | grep omv-backup
```

Cek isi:

```bash
ls -lah /mnt/omv-backup
```

Pastikan folder:

```text
Regional
```

dapat terlihat.

---

# 5. Struktur Folder Backup NAS

Buat struktur:

```text
/export/Backup_VM/
└── Regional/
```

Backup nantinya dibuat berdasarkan tanggal:

```text
Regional/
├── 2026-09-20/
│   └── vzdump-qemu-107-....vma.zst
├── 2026-09-21/
│   └── vzdump-qemu-107-....vma.zst
└── 2026-09-22/
    └── vzdump-qemu-107-....vma.zst
```

Jangan membuat folder retention secara manual.

Folder tanggal akan dibuat otomatis oleh proses backup.

---

# 6. Implementasi Backup Production

## 6.1 Tentukan VM yang Dibackup

Dalam contoh ini:

```text
VMID = 107
```

Pastikan VM tersedia:

```bash
qm status 107
```

Expected:

```text
status: running
```

---

# 7. Uji Backup Manual Terlebih Dahulu

Sebelum memasukkan cron, jalankan backup manual:

```bash
vzdump 107 --compress zstd --mailnotification always --quiet 1 --storage local --mode snapshot
```

Tunggu sampai selesai.

Kemudian cek:

```bash
ls -lh /var/lib/vz/dump/
```

Pastikan terdapat file seperti:

```text
vzdump-qemu-107-YYYY_MM_DD-HH_MM_SS.vma.zst
```

Jika backup manual gagal, **jangan lanjut ke tahap otomatisasi**.

---

# 8. Implementasi Script Transfer ke NAS

Pastikan script transfer tersedia:

```text
/usr/local/sbin/backup-to-nas.sh
```

Permission:

```bash
chmod 750 /usr/local/sbin/backup-to-nas.sh
```

Pastikan konfigurasi utamanya:

```text
VMID          = 107
NAS_MOUNT     = /mnt/nas-backup
NAS_BACKUP_DIR= /mnt/nas-backup/Regional
RETENTION     = 2
```

> Pada implementasi aktual Proxmox A, NFS/OMV mount yang digunakan oleh script harus sudah tersedia di `/mnt/nas-backup`.

Tes syntax:

```bash
bash -n /usr/local/sbin/backup-to-nas.sh
```

Tidak boleh menghasilkan output error.

---

# 9. Uji Script Transfer Secara Manual

Ambil salah satu file backup:

```bash
ls -1t /var/lib/vz/dump/vzdump-qemu-107-*.vma.zst | head -1
```

Kemudian jalankan:

```bash
/usr/local/sbin/backup-to-nas.sh /var/lib/vz/dump/NAMA_FILE_BACKUP.vma.zst
```

Sesuaikan `NAMA_FILE_BACKUP` dengan file aktual.

Setelah selesai:

```bash
ls -lah /mnt/nas-backup/Regional/
```

Pastikan folder tanggal terbentuk.

Kemudian:

```bash
ls -lah /mnt/nas-backup/Regional/YYYY-MM-DD/
```

Pastikan file backup tersedia.

---

# 10. Verifikasi Transfer

Periksa log:

```bash
tail -50 /var/log/backup-to-nas.log
```

Pastikan terdapat informasi:

```text
Verifikasi ukuran: OK
Backup VM 107 berhasil disalin dan diverifikasi.
Retention NAS selesai.
```

Jika ukuran source dan destination berbeda:

```text
ERROR: Ukuran source dan target berbeda!
```

maka proses dianggap gagal.

---

# 11. Implementasi Retention NAS

Retention menggunakan jumlah folder, bukan jumlah hari.

Konfigurasi:

```text
RETENTION=2
```

Contoh sebelum retention:

```text
Regional/
├── 2026-09-20/
├── 2026-09-21/
└── 2026-09-22/
```

Setelah retention:

```text
Regional/
├── 2026-09-21/
└── 2026-09-22/
```

Uji dengan membuat beberapa folder backup atau menjalankan proses backup beberapa kali.

Pastikan:

```text
Jumlah folder backup <= 2
```

Backup lokal Proxmox tidak disentuh.

---

# 12. Implementasi Vzdump Hook

Buat/letakkan hook:

```text
/usr/local/sbin/vzdump-hook.sh
```

Permission:

```bash
chmod 750 /usr/local/sbin/vzdump-hook.sh
```

Validasi:

```bash
bash -n /usr/local/sbin/vzdump-hook.sh
```

Hook harus bekerja pada phase:

```text
backup-end
```

dan hanya memproses:

```text
VMID 107
```

Konfigurasi `/etc/vzdump.conf`:

```text
script: /usr/local/sbin/vzdump-hook.sh
```

---

# 13. Uji Hook Tanpa Menjalankan Backup Besar

Pertama pastikan syntax:

```bash
bash -n /usr/local/sbin/vzdump-hook.sh
```

Kemudian cek:

```bash
grep -n "script:" /etc/vzdump.conf
```

Expected:

```text
script: /usr/local/sbin/vzdump-hook.sh
```

Jangan melakukan perubahan berikutnya sebelum syntax valid.

---

# 14. Implementasi Network DR

Pada Proxmox B terdapat dua bridge:

```text
vmbr0
vmbr-dr
```

`vmbr0` digunakan untuk management Proxmox.

Contoh:

```text
vmbr0
IP      : 192.168.71.205/24
Gateway : 192.168.71.100
```

`vmbr-dr` digunakan untuk VM DR dan tidak terhubung langsung ke physical NIC:

```text
vmbr-dr
bridge-ports none
```

Tambahkan IP management:

```text
192.168.71.253/32
```

Buat route khusus menuju IP VM DR:

```text
192.168.71.233/32 dev vmbr-dr src 192.168.71.253
```

Setelah konfigurasi, cek:

```bash
ip route get 192.168.71.233
```

Expected:

```text
192.168.71.233 dev vmbr-dr src 192.168.71.253
```

---

# 15. Verifikasi Network DR

Tes:

```bash
ping -I vmbr-dr -c 4 192.168.71.233
```

Jika VM DR sedang aktif dan terisolasi dengan benar, ping harus dapat mencapai VM DR.

Tes HTTP:

```bash
curl -I http://192.168.71.233
```

Expected:

```text
HTTP/1.1 200 OK
```

Tes SSH:

```bash
ssh regional@192.168.71.233
```

Pastikan akses menuju VM DR berhasil.

---

# 16. Buat Konfigurasi DR

Buat konfigurasi:

```text
/usr/local/etc/dr/ONEMDORAYA.conf
```

Parameter utama:

```text
VM_NAME="ONEMDORAYA"

PROD_VMID="107"

DR_SLOT_A="117"
DR_SLOT_B="118"

CURRENT_DR_VMID="118"

BACKUP_ROOT="/mnt/omv-backup/Regional"

DR_IP="192.168.71.233"
DR_BRIDGE="vmbr-dr"

DR_CORES="4"
DR_MEMORY="12000"

DR_STORAGE="local-lvm"

SSH_PORT="22"
HTTP_PORT="80"
```

Pastikan:

```text
PROD_VMID != DR_SLOT_A
PROD_VMID != DR_SLOT_B
DR_SLOT_A != DR_SLOT_B
```

---

# 17. Implementasi Helper Script DR

Pastikan helper tersedia:

```text
/usr/local/sbin/dr-prepare-vm.sh
/usr/local/sbin/dr-health-check.sh
/usr/local/sbin/dr-rollback.sh
```

Permission:

```bash
chmod 750 /usr/local/sbin/dr-prepare-vm.sh
chmod 750 /usr/local/sbin/dr-health-check.sh
chmod 750 /usr/local/sbin/dr-rollback.sh
```

Validasi syntax:

```bash
bash -n /usr/local/sbin/dr-prepare-vm.sh
bash -n /usr/local/sbin/dr-health-check.sh
bash -n /usr/local/sbin/dr-rollback.sh
```

---

# 18. Implementasi Restore Engine

Pastikan restore engine tersedia:

```text
/usr/local/sbin/dr-restore-reusable.sh
```

Permission:

```bash
chmod 750 /usr/local/sbin/dr-restore-reusable.sh
```

Validasi:

```bash
bash -n /usr/local/sbin/dr-restore-reusable.sh
```

Restore engine menggunakan pola:

```text
CURRENT
   ↓
Shutdown
   ↓
TARGET
   ↓
Restore
   ↓
Prepare
   ↓
Start
   ↓
Health Check
   ↓
Promote / Rollback
```

---

# 19. Validasi Sebelum Restore Pertama

Jalankan:

```bash
/usr/local/sbin/dr-validate.sh ONEMDORAYA
```

Validasi harus memastikan:

```text
CURRENT VM      = tersedia
TARGET VM       = belum ada
Production VM   = tidak ada di DR
Backup          = tersedia
Storage         = tersedia
Helper script   = tersedia
CURRENT health  = SUCCESS
```

Expected:

```text
SAFETY VALIDATION: PASSED
```

Jika hasil bukan `PASSED`, hentikan implementasi dan perbaiki masalah terlebih dahulu.

---

# 20. Uji Restore Pertama

Setelah validasi berhasil:

```bash
/usr/local/sbin/dr-restore-reusable.sh ONEMDORAYA
```

Misalnya:

```text
CURRENT = 118
TARGET  = 117
```

Maka engine akan:

```text
1. Shutdown 118
2. Restore backup ke 117
3. Prepare 117
4. Start 117
5. Check network
6. Check SSH
7. Check HTTP
8. Final health check
9. Promote 117
10. Delete 118
```

Jangan melakukan shutdown/delete manual selama proses berlangsung.

---

# 21. Verifikasi Setelah Restore

Cek VM:

```bash
qm list
```

Expected hanya satu current DR VM yang aktif, misalnya:

```text
117 running
```

Pastikan VM production `107` tidak ada:

```bash
qm status 107
```

Expected:

```text
VM 107 not found
```

Kemudian jalankan:

```bash
/usr/local/sbin/dr-health-check.sh /usr/local/etc/dr/ONEMDORAYA.conf
```

Expected:

```text
HEALTH CHECK: SUCCESS
```

---

# 22. Implementasi SSH Proxmox A → Proxmox B

Pada Proxmox A buat SSH key untuk root jika belum ada:

```bash
ssh-keygen -t ed25519
```

Kirim public key ke Proxmox B:

```bash
ssh-copy-id root@192.168.71.205
```

Uji:

```bash
ssh -o BatchMode=yes     -o ConnectTimeout=30     root@192.168.71.205     'echo "DR SSH TEST: OK"; hostname'
```

Expected:

```text
DR SSH TEST: OK
mdoBackupGrd
```

Tidak boleh meminta password.

---

# 23. Implementasi Asynchronous DR Trigger

Hook pada Proxmox A memanggil:

```text
root@192.168.71.205
```

dengan restore engine:

```text
/usr/local/sbin/dr-restore-reusable.sh ONEMDORAYA
```

Proses harus menggunakan asynchronous execution sehingga Proxmox A tidak menunggu restore selesai.

Konsep:

```text
Proxmox A
    |
    | SSH
    v
Proxmox B
    |
    +---- nohup restore engine ----> berjalan di background
    |
    +---- SSH selesai
    |
Proxmox A selesai
```

---

# 24. Uji Asynchronous Trigger

Sebelum menghubungkan restore engine sebenarnya, lakukan test menggunakan proses dummy.

Dari Proxmox A:

```bash
START=$(date +%s)

ssh -o BatchMode=yes     -o ConnectTimeout=30     root@192.168.71.205     "nohup bash -c 'sleep 30; date > /tmp/dr-async-test-result' >/dev/null 2>&1 </dev/null &"

END=$(date +%s)

echo "SSH elapsed: $((END-START)) seconds"
```

Expected:

```text
SSH elapsed: 0
```

atau sekitar:

```text
0–2 seconds
```

Bukan:

```text
30 seconds
```

Kemudian:

```bash
ssh -o BatchMode=yes     root@192.168.71.205     'if [ -f /tmp/dr-async-test-result ]; then echo "TEST FINISHED"; else echo "TEST STILL RUNNING"; fi'
```

Expected:

```text
TEST STILL RUNNING
```

Tunggu sekitar 30 detik kemudian:

```bash
ssh -o BatchMode=yes     root@192.168.71.205     'cat /tmp/dr-async-test-result'
```

Jika timestamp muncul, asynchronous execution berhasil.

Cleanup:

```bash
ssh -o BatchMode=yes root@192.168.71.205     'rm -f /tmp/dr-async-test-result'
```

Test ini tidak menyentuh VM production maupun VM DR.

---

# 25. Implementasi Jadwal Backup

Setelah seluruh pengujian manual berhasil, masukkan backup ke cron.

Contoh:

```text
0 5 * * * root vzdump 107 --compress zstd --mailnotification always --quiet 1 --storage local --mode snapshot
```

Pastikan cron menggunakan PATH yang benar.

Contoh:

```text
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
```

Setelah menyimpan:

```bash
crontab -l
```

Pastikan entry tersedia.

---

# 26. Uji Integrasi End-to-End

Setelah seluruh komponen diuji terpisah, lakukan satu siklus lengkap.

Urutan:

```text
1. Proxmox A menjalankan vzdump
2. Backup lokal selesai
3. Hook backup-end berjalan
4. Backup dikirim ke NAS
5. Ukuran source/target diverifikasi
6. Retention NAS dijalankan
7. SSH trigger dikirim ke Proxmox B
8. Proxmox A selesai
9. Proxmox B menjalankan restore
10. Current DR shutdown
11. Target DR restore
12. Target prepare
13. Target start
14. Network check
15. SSH check
16. HTTP check
17. Final health check
18. Target promote
19. Current lama dihapus
```

---

# 27. Verifikasi Log End-to-End

## Proxmox A

```bash
tail -100 /var/log/backup-to-nas.log
```

Cari:

```text
Backup berhasil disalin dan diverifikasi.
Retention NAS selesai.
DR restore berhasil ditrigger di Proxmox B.
Proxmox A tidak menunggu proses DR restore selesai.
```

## Proxmox B

```bash
tail -100 /var/log/dr-restore-ONEMDORAYA.log
```

Cari:

```text
DR RESTORE SUCCESS
```

---

# 28. Pengujian Failure / Rollback

Pengujian rollback sebaiknya dilakukan pada window maintenance/test.

Simulasikan kegagalan target setelah current tetap tersedia.

Expected:

```text
CURRENT 118
TARGET 117

117 gagal
    ↓
117 dihentikan
    ↓
117 dihapus
    ↓
118 dijalankan
```

Hasil akhir:

```text
118 = RUNNING / CURRENT
117 = tidak ada
```

Pastikan production VM `107` tetap tidak tersentuh.

---

# 29. Validasi Akhir Implementasi

Setelah implementasi selesai, jalankan:

```bash
qm list
```

Pastikan:

```text
VM 107 = tidak ada pada DR
```

Kemudian:

```bash
/usr/local/sbin/dr-validate.sh ONEMDORAYA
```

Expected:

```text
SAFETY VALIDATION: PASSED
```

Cek NFS:

```bash
mount | grep omv-backup
```

Cek backup NAS:

```bash
find /mnt/omv-backup/Regional -maxdepth 2 -type f
```

Cek retention:

```bash
find /mnt/omv-backup/Regional     -mindepth 1     -maxdepth 1     -type d     -printf '%f
' | sort
```

Jumlah folder harus sesuai:

```text
<= 2
```

---

# 30. Operasional Harian

Setelah implementasi selesai, operator cukup memonitor:

### Backup Production

```bash
tail -50 /var/log/backup-to-nas.log
```

### DR Restore

```bash
tail -50 /var/log/dr-restore-ONEMDORAYA.log
```

### Status VM DR

```bash
qm list
```

### Status Current

```bash
/usr/local/sbin/dr-validate.sh ONEMDORAYA
```

Tidak perlu menjalankan restore secara manual pada kondisi normal.

---

# 31. Prosedur Saat Backup Gagal

Jika backup production gagal:

```text
Backup gagal
    ↓
Hook backup-end tidak dianggap berhasil
    ↓
Transfer NAS tidak dianggap berhasil
    ↓
DR tidak boleh dianggap berhasil
```

Periksa:

```bash
tail -100 /var/log/backup-to-nas.log
```

dan log Proxmox/vzdump.

Jangan menghapus backup sebelumnya yang masih valid.

---

# 32. Prosedur Saat Transfer NAS Gagal

Periksa:

```bash
mountpoint -q /mnt/nas-backup
```

Kemudian:

```bash
df -h /mnt/nas-backup
```

Tes koneksi:

```bash
ping -c 4 192.168.71.211
```

Periksa:

```bash
tail -100 /var/log/backup-to-nas.log
```

Pastikan backup lama di NAS tetap tersedia.

---

# 33. Prosedur Saat DR Restore Gagal

Periksa:

```bash
tail -200 /var/log/dr-restore-ONEMDORAYA.log
```

Jika engine melakukan rollback:

```text
TARGET = dihapus
CURRENT = dijalankan kembali
```

Jangan melakukan delete manual sebelum memastikan status VM.

Validasi:

```bash
qm list
```

Kemudian:

```bash
/usr/local/sbin/dr-validate.sh ONEMDORAYA
```

---

# 34. Prosedur Failover Manual

Jika suatu saat DR benar-benar harus digunakan sebagai production:

1. Pastikan production VM dihentikan atau jaringan production sudah tidak aktif.
2. Pastikan current DR VM sehat.
3. Nonaktifkan isolasi network DR sesuai prosedur failover yang telah diuji.
4. Pastikan IP `192.168.71.233` hanya aktif pada satu sisi.
5. Uji akses aplikasi.
6. Catat waktu dan kondisi failover.

> Jangan mengaktifkan koneksi production dan DR dengan IP yang sama secara bersamaan karena dapat menyebabkan konflik IP/ARP.

---

# 35. Checklist Implementasi

Gunakan checklist berikut saat implementasi.

## A. NAS

- [ ] NFS Server aktif
- [ ] `/export/Backup_VM` tersedia
- [ ] Network `192.168.71.0/24` diizinkan
- [ ] Proxmox dapat mengakses NAS

## B. Proxmox A

- [ ] VM 107 tersedia
- [ ] `vzdump` berhasil manual
- [ ] `backup-to-nas.sh` tersedia
- [ ] Transfer manual berhasil
- [ ] Verifikasi ukuran berhasil
- [ ] Retention berhasil
- [ ] `vzdump-hook.sh` tersedia
- [ ] `/etc/vzdump.conf` menunjuk ke hook
- [ ] Cron aktif

## C. Proxmox B

- [ ] NFS client tersedia
- [ ] `/mnt/omv-backup` tersedia
- [ ] NFS mount berhasil
- [ ] `Regional` terlihat
- [ ] `vmbr-dr` tersedia
- [ ] Route ke `192.168.71.233` tersedia
- [ ] VM 107 tidak ada
- [ ] Slot 117 dan 118 tersedia

## D. DR Engine

- [ ] Configuration tersedia
- [ ] `dr-prepare-vm.sh` tersedia
- [ ] `dr-health-check.sh` tersedia
- [ ] `dr-rollback.sh` tersedia
- [ ] `dr-restore-reusable.sh` tersedia
- [ ] `dr-validate.sh` berhasil
- [ ] Current VM sehat

## E. SSH

- [ ] SSH A → B berhasil
- [ ] BatchMode berhasil
- [ ] Tidak meminta password
- [ ] Async dummy test berhasil

## F. End-to-End

- [ ] Backup production berhasil
- [ ] Backup masuk NAS
- [ ] Verifikasi berhasil
- [ ] Retention berhasil
- [ ] Trigger DR berhasil
- [ ] Restore DR berhasil
- [ ] Health check berhasil
- [ ] Promote berhasil
- [ ] VM lama terhapus setelah promote
- [ ] Rollback sudah diuji

---

# 36. Hasil Akhir Implementasi

Jika seluruh tahap selesai, sistem akan bekerja otomatis:

```text
05:00
  |
  v
BACKUP VM 107
  |
  v
BACKUP LOKAL SELESAI
  |
  v
COPY KE NAS
  |
  v
VERIFY
  |
  v
RETENTION = 2
  |
  v
TRIGGER PROXMOX B
  |
  +--------------------------+
                             |
                             v
                       RESTORE DR
                             |
                             v
                       HEALTH CHECK
                       /                               FAIL           OK
                     |              |
                     v              v
                 ROLLBACK        PROMOTE
                     |              |
                     v              v
                CURRENT LAMA     VM BARU
                  RUNNING         CURRENT
```

Dengan desain ini:

- Proxmox A fokus pada backup dan pengiriman trigger.
- NAS menjadi repository backup.
- Proxmox B menangani proses DR secara mandiri.
- Restore berjalan asynchronous.
- VM lama tetap menjadi rollback point sampai VM baru sehat.
- Retention NAS tidak mengganggu backup lokal.
- VM production tidak digunakan sebagai VM DR.
- IP VM DR tetap sama karena network DR diisolasi.
- Siklus DR menggunakan dua slot VM secara bergantian.

---

# 37. Referensi Konfigurasi Implementasi

| Item              | Nilai                                    |
| ----------------- | ---------------------------------------- |
| Proxmox A         | `192.168.71.202`                         |
| Proxmox B         | `192.168.71.205`                         |
| NAS OMV           | `192.168.71.211`                         |
| NFS Export        | `/export/Backup_VM`                      |
| NFS Mount DR      | `/mnt/omv-backup`                        |
| Backup Root       | `/Regional`                              |
| Production VMID   | `107`                                    |
| DR Slot A         | `117`                                    |
| DR Slot B         | `118`                                    |
| VM Name           | `ONEMDORAYA`                             |
| VM IP             | `192.168.71.233`                         |
| DR Bridge         | `vmbr-dr`                                |
| DR Management IP  | `192.168.71.253/32`                      |
| DR Storage        | `local-lvm`                              |
| Retention         | `2`                                      |
| Backup Log        | `/var/log/backup-to-nas.log`             |
| DR Log            | `/var/log/dr-restore-ONEMDORAYA.log`     |
| DR Config         | `/usr/local/etc/dr/ONEMDORAYA.conf`      |
| DR Restore Engine | `/usr/local/sbin/dr-restore-reusable.sh` |
