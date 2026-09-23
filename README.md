# SOP Proxmox Backup, NAS OMV, dan Disaster Recovery (DR)

**Dokumen:** SOP Implementasi Backup & DR Proxmox  
**Versi:** 1.0  
**Status:** Implementasi Produksi  
**Tujuan:** Menyediakan prosedur backup VM Proxmox secara otomatis ke NAS OMV serta melakukan restore otomatis ke Proxmox DR dengan mekanisme health check, rollback, dan rotasi 2 slot.

---

## 1. Tujuan

SOP ini digunakan untuk memastikan:

1. VM produksi di Proxmox utama dibackup secara terjadwal.
2. File backup disalin ke NAS OMV setelah backup lokal selesai.
3. Backup di NAS diverifikasi setelah proses transfer.
4. NAS hanya menyimpan jumlah backup sesuai retention.
5. Backup terbaru dapat digunakan oleh Proxmox DR.
6. Proxmox DR melakukan restore secara otomatis tanpa mengganggu Proxmox produksi.
7. VM hasil restore diperiksa sebelum dinyatakan aktif.
8. Jika restore atau health check gagal, VM DR sebelumnya tetap tersedia sebagai rollback point.
9. Jika restore berhasil, VM DR baru dipromosikan menjadi current dan VM lama dihapus.

> **Catatan:** File script `.sh` tidak dibahas di dokumen ini karena script sudah tersedia dan digunakan sebagai implementasi teknis.

---

# 2. Arsitektur

```text
                    PRODUCTION
                Proxmox A
                192.168.71.202
                      |
                      | Backup VM
                      v
              Local Backup Storage
                      |
                      | Copy + Verify
                      v
                NAS OMV
              192.168.71.211
              /export/Backup_VM
                      |
                      | NFS
                      v
                 Proxmox B
                 192.168.71.205
                    DR Site

                DR VM Slot A: 117
                DR VM Slot B: 118
```

Alur utama:

```text
PROXMOX A
   |
   | 1. Backup VM
   v
BACKUP LOKAL
   |
   | 2. Backup selesai
   v
COPY KE NAS OMV
   |
   | 3. Verifikasi
   v
RETENTION NAS
   |
   | 4. Trigger melalui SSH
   v
PROXMOX B
   |
   | 5. Restore ke slot DR berikutnya
   v
PREPARE VM
   |
   | 6. Start VM
   v
NETWORK + SSH + HTTP CHECK
   |
   +---- GAGAL ----> ROLLBACK KE VM LAMA
   |
   +---- BERHASIL --> PROMOTE VM BARU
                         |
                         v
                    HAPUS VM LAMA
```

---

# 3. Komponen Infrastruktur

| Komponen | Nilai |
|---|---|
| Proxmox Production | `192.168.71.202` |
| Proxmox DR | `192.168.71.205` |
| NAS OMV | `192.168.71.211` |
| NFS Export | `/export/Backup_VM` |
| Mount NFS di DR | `/mnt/omv-backup` |
| Folder backup | `/Regional` |
| Production VMID | `107` |
| Nama VM | `ONEMDORAYA` |
| IP VM | `192.168.71.233` |
| DR Slot A | `117` |
| DR Slot B | `118` |
| DR Bridge | `vmbr-dr` |
| DR IP management bridge | `192.168.71.253/32` |
| DR Storage | `local-lvm` |
| Retention NAS | `2` folder backup |

---

# 4. Konsep Backup Production

Backup VM production dijalankan secara terjadwal menggunakan Proxmox `vzdump`.

VM production yang digunakan:

- VMID: `107`
- Mode: snapshot
- Compression: zstd
- Storage backup lokal: `local`

Backup lokal **tidak dihapus oleh mekanisme retention NAS**.

Urutan:

```text
VM 107
  ↓
vzdump
  ↓
Backup lokal selesai
  ↓
Hook Proxmox dijalankan
  ↓
Backup dikirim ke NAS
```

Prinsip penting:

> Backup dianggap siap dikirim ke NAS hanya setelah proses `vzdump` selesai.

---

# 5. Transfer Backup ke NAS OMV

Setelah backup lokal selesai, hook Proxmox menjalankan proses transfer ke NAS.

Backup disimpan dengan struktur:

```text
Regional/
├── YYYY-MM-DD/
│   └── vzdump-qemu-107-YYYY_MM_DD-HH_MM_SS.vma.zst
├── YYYY-MM-DD/
│   └── ...
└── ...
```

Contoh:

```text
Regional/
└── 2026-09-22/
    └── vzdump-qemu-107-2026_09_22-05_00_02.vma.zst
```

Proses transfer:

```text
Backup lokal
     ↓
NAS /Regional/YYYY-MM-DD/
     ↓
File selesai ditransfer
     ↓
Verifikasi ukuran file
```

Verifikasi dilakukan dengan membandingkan ukuran file sumber dan file tujuan.

Jika ukuran berbeda:

```text
TRANSFER GAGAL
```

Jika ukuran sama:

```text
TRANSFER BERHASIL
```

---

# 6. Retention Backup NAS

Retention hanya berlaku pada folder backup di NAS.

Nilai retention saat ini:

```text
RETENTION = 2
```

Artinya:

> NAS mempertahankan **2 folder backup terbaru**, bukan 2 tanggal tertentu atau 2 minggu kalender.

Contoh:

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

Folder paling lama dihapus.

### Ketentuan

- Retention berdasarkan **jumlah folder**.
- Folder backup diurutkan berdasarkan nama tanggal.
- Folder dengan format `YYYY-MM-DD` yang digunakan sebagai backup.
- Backup lokal Proxmox **tidak dihapus** oleh proses ini.
- Retention hanya mengontrol backup di NAS.

---

# 7. Konsep Proxmox DR

Proxmox DR menggunakan dua slot VM:

```text
Slot A = VMID 117
Slot B = VMID 118
```

Production VMID:

```text
107
```

VM production tidak pernah digunakan sebagai slot DR.

Tujuan dua slot adalah agar VM DR lama tetap tersedia sebagai rollback point selama VM baru sedang diuji.

Contoh:

```text
CURRENT = 118
TARGET  = 117
```

Setelah restore dan health check berhasil:

```text
CURRENT = 117
TARGET  = 118
```

Pada siklus berikutnya:

```text
CURRENT = 117
TARGET  = 118
```

Dengan demikian proses restore selalu bergantian antara VMID `117` dan `118`.

---

# 8. Isolasi Network DR

VM hasil restore tetap menggunakan IP production:

```text
192.168.71.233
```

IP tersebut **tidak diubah** pada VM DR.

Untuk mencegah konflik dengan production, VM DR ditempatkan pada bridge:

```text
vmbr-dr
```

Bridge tersebut tidak menggunakan physical NIC.

Konsep:

```text
Production VM
192.168.71.233
     |
     | vmbr0
     |
Production Network


DR VM
192.168.71.233
     |
     | vmbr-dr
     |
Isolated Network
```

Proxmox DR memiliki jalur khusus untuk melakukan akses management dan health check terhadap VM DR.

IP management bridge DR:

```text
192.168.71.253/32
```

Route khusus diarahkan ke:

```text
192.168.71.233
```

Dengan konfigurasi tersebut, VM DR dapat diuji tanpa membuat IP production menjadi konflik di jaringan production.

---

# 9. Trigger dari Proxmox Production ke Proxmox DR

Setelah backup berhasil:

```text
Backup lokal
    ↓
Copy ke NAS
    ↓
Verifikasi backup
    ↓
Trigger Proxmox DR melalui SSH
```

Proxmox Production memiliki akses SSH tanpa password ke:

```text
root@192.168.71.205
```

Trigger DR menggunakan proses asynchronous.

Artinya:

> Proxmox Production hanya memastikan bahwa perintah restore berhasil dikirim ke Proxmox DR. Proxmox Production tidak menunggu proses restore selesai.

Hal ini penting karena proses restore VM berukuran besar dapat membutuhkan waktu lama.

Contoh alur:

```text
Proxmox A
    |
    | SSH trigger
    v
Proxmox B
    |
    +--> Restore VM
    +--> Start VM
    +--> Health check
    +--> Promote / Rollback
```

Proxmox A selesai setelah trigger berhasil dikirim.

Hasil akhir proses DR dicatat pada Proxmox B.

---

# 10. Proses Restore DR

Misalnya kondisi saat ini:

```text
CURRENT = 118
TARGET  = 117
```

Maka proses:

### Tahap 1 — Validasi

Sebelum restore:

- Configuration diperiksa.
- Slot A dan B harus berbeda.
- Current VM harus valid.
- Target VM harus belum ada.
- Production VMID tidak boleh ada di Proxmox DR.
- Backup NAS harus tersedia.
- Storage DR harus tersedia.
- Helper script harus tersedia.
- Current VM harus sehat.

Jika validasi gagal:

```text
RESTORE DIBATALKAN
```

---

### Tahap 2 — Shutdown Current

Current VM:

```text
118
```

dimatikan terlebih dahulu.

VM tersebut **tidak langsung dihapus**.

Tujuannya adalah mempertahankan VM lama sebagai rollback point.

```text
118 = rollback point
117 = target restore
```

---

### Tahap 3 — Restore Backup

Backup terbaru dari NAS digunakan sebagai source restore.

Contoh:

```text
Regional/
└── 2026-09-22/
    └── vzdump-qemu-107-2026_09_22-05_00_02.vma.zst
```

Restore dilakukan ke:

```text
VMID 117
```

Backup menggunakan konfigurasi identity/network yang dipertahankan sesuai desain DR.

---

# 11. Prepare VM DR

Setelah restore:

- CPU disesuaikan dengan resource Proxmox DR.
- Memory disesuaikan.
- Network interface diarahkan ke `vmbr-dr`.
- Firewall VM tetap aktif.
- `onboot` tidak digunakan untuk menjalankan VM secara otomatis pada tahap ini.

VM belum dianggap berhasil hanya karena restore selesai.

Restore selesai berarti:

```text
DISK BERHASIL DIRESTORE
```

Bukan berarti:

```text
SERVICE SIAP DIGUNAKAN
```

---

# 12. Start dan Health Check

Setelah VM target dipersiapkan, VM dijalankan.

Health check dilakukan secara bertahap:

```text
VM START
   ↓
Network readiness
   ↓
ICMP / Ping
   ↓
SSH port 22
   ↓
HTTP port 80
   ↓
Final health check
```

Untuk VM `ONEMDORAYA`, pemeriksaan menggunakan:

```text
IP   : 192.168.71.233
SSH  : 22
HTTP : 80
```

VM dianggap sehat jika pemeriksaan yang diperlukan berhasil.

Contoh hasil:

```text
HEALTH CHECK: SUCCESS
ONEMDORAYA (192.168.71.233) HEALTHY.
```

---

# 13. Mekanisme Rollback

Jika VM target gagal health check:

```text
CURRENT = 118
TARGET  = 117
```

maka:

1. Target `117` dihentikan.
2. Target `117` dihapus.
3. Current `118` dijalankan kembali.
4. Current `118` tetap menjadi VM DR aktif.

Hasil:

```text
117 = FAILED / DELETED
118 = CURRENT / RUNNING
```

Prinsip utama:

> VM current tidak dihapus sebelum target berhasil melewati seluruh health check.

---

# 14. Mekanisme Promote

Jika target berhasil:

```text
CURRENT = 118
TARGET  = 117
```

maka:

1. Target `117` dinyatakan sehat.
2. `117` dipromosikan menjadi current.
3. Status current diperbarui menjadi `117`.
4. VM lama `118` dihapus.

Hasil:

```text
117 = CURRENT / RUNNING
118 = DELETED
```

Siklus berikutnya otomatis menggunakan:

```text
CURRENT = 117
TARGET  = 118
```

---

# 15. Siklus DR Lengkap

### Siklus pertama

```text
Current : 117
Target  : 118

117 shutdown
118 restore
118 health check

Jika gagal:
    118 destroy
    117 start

Jika berhasil:
    118 promote
    117 delete
```

### Siklus berikutnya

```text
Current : 118
Target  : 117

118 shutdown
117 restore
117 health check

Jika gagal:
    117 destroy
    118 start

Jika berhasil:
    117 promote
    118 delete
```

Dengan demikian hanya satu VM DR yang menjadi current pada setiap saat.

---

# 16. Safety Validation

Sebelum restore otomatis dijalankan, sistem memastikan:

- VM production `107` tidak terdapat pada Proxmox DR.
- Current VM hanya boleh `117` atau `118`.
- Target harus merupakan slot yang berlawanan.
- Target tidak boleh sudah ada.
- Backup root harus tersedia.
- Backup terbaru harus ditemukan.
- Storage restore harus tersedia.
- Helper script harus tersedia.
- Current VM harus sehat.
- Slot A dan Slot B tidak boleh sama.

Jika salah satu kondisi penting tidak terpenuhi:

```text
RESTORE DIBATALKAN
```

---

# 17. Logging

### Production

Log backup dan transfer:

```text
/var/log/backup-to-nas.log
```

Log tersebut mencatat:

- backup selesai
- file source
- target NAS
- ukuran file
- hasil transfer
- hasil verifikasi
- retention
- hasil trigger DR

### Proxmox DR

Log proses restore:

```text
/var/log/dr-restore-ONEMDORAYA.log
```

Log tersebut mencatat:

- validasi
- backup yang digunakan
- shutdown current
- restore
- prepare VM
- start VM
- health check
- rollback atau promote
- hasil akhir DR

---

# 18. Kondisi Keberhasilan

Satu siklus backup dan DR dianggap berhasil jika:

```text
[OK] Backup production selesai
[OK] Backup tersalin ke NAS
[OK] Ukuran backup source = target
[OK] Retention NAS selesai
[OK] Trigger DR berhasil dikirim
[OK] Restore DR selesai
[OK] VM DR berhasil start
[OK] Network ready
[OK] SSH ready
[OK] HTTP ready
[OK] Final health check berhasil
[OK] VM baru dipromosikan
[OK] VM lama dihapus setelah promote
```

---

# 19. Kondisi Kegagalan

Jika backup production gagal:

```text
DR TIDAK DITRIGGER
```

Jika transfer ke NAS gagal:

```text
DR TIDAK DITRIGGER
```

Jika verifikasi backup gagal:

```text
DR TIDAK DITRIGGER
```

Jika trigger SSH ke DR gagal:

```text
Backup production tetap selesai,
tetapi proses DR tidak dimulai.
```

Jika restore DR gagal:

```text
Target dibersihkan
Current dikembalikan
```

Jika health check gagal:

```text
Target dihapus
Current dijalankan kembali
```

---

# 20. Prosedur Monitoring Operator

Operator tidak perlu menjalankan script internal secara manual pada kondisi normal.

Monitoring dilakukan dengan memeriksa:

### Production

```text
/var/log/backup-to-nas.log
```

Pastikan terdapat informasi:

```text
Backup berhasil disalin dan diverifikasi
Retention NAS selesai
DR restore berhasil ditrigger
```

### DR

```text
/var/log/dr-restore-ONEMDORAYA.log
```

Pastikan terdapat:

```text
DR RESTORE SUCCESS
```

dan current VM menunjukkan VMID yang baru.

---

# 21. Prinsip Operasional

Beberapa prinsip yang harus dipertahankan:

1. **Production VMID 107 tidak boleh digunakan sebagai DR slot.**
2. **DR hanya menggunakan slot 117 dan 118.**
3. **Current VM tidak boleh dihapus sebelum target sehat.**
4. **Backup lokal production tidak dihapus oleh retention NAS.**
5. **Retention hanya berlaku pada NAS.**
6. **Retention berdasarkan jumlah folder, bukan kalender.**
7. **Proxmox A tidak menunggu restore DR selesai.**
8. **Hasil restore sebenarnya ditentukan oleh Proxmox B.**
9. **VM DR tetap menggunakan IP production karena network DR diisolasi.**
10. **Perubahan konfigurasi harus dilakukan melalui prosedur dan script yang telah ditetapkan.**

---

# 22. Ringkasan SOP

```text
PROXMOX A
    |
    | Backup VM 107
    v
BACKUP LOKAL
    |
    | Backup selesai
    v
COPY KE OMV
    |
    | Verifikasi ukuran
    v
RETENTION NAS
    |
    | Trigger SSH asynchronous
    v
PROXMOX B
    |
    | Tentukan TARGET slot
    v
SHUTDOWN CURRENT
    |
    | Current tetap sebagai rollback
    v
RESTORE TARGET
    |
    v
PREPARE TARGET
    |
    v
START TARGET
    |
    v
NETWORK CHECK
    |
    v
SSH CHECK
    |
    v
HTTP CHECK
    |
    v
FINAL HEALTH CHECK
    |
    +---- FAIL ----> DESTROY TARGET
    |                   |
    |                   v
    |              START CURRENT
    |
    +---- SUCCESS --> PROMOTE TARGET
                        |
                        v
                   DELETE OLD CURRENT
                        |
                        v
                    DR SUCCESS
```

---

# 23. Status Implementasi

Implementasi saat ini menggunakan:

```text
Production VM      : 107
DR Slot A          : 117
DR Slot B          : 118
Current DR         : 118
Target berikutnya  : 117
NAS Retention      : 2
DR Restore         : Asynchronous
Network DR         : Isolated
Health Check       : ICMP + SSH + HTTP
Rollback           : Otomatis
Promote            : Otomatis
```

Dokumen ini merupakan **SOP operasional dan implementasi**. Detail konfigurasi serta kode `.sh` dipisahkan dari dokumen agar SOP dapat dibagikan dan digunakan sebagai panduan tanpa membawa source code server.
