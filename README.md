# README — Standar Implementasi Restore Disaster Recovery Proxmox

**Dokumen:** Standar Implementasi Restore / Disaster Recovery  
**Platform:** Proxmox VE + OpenMediaVault (OMV)  
**Model:** Restore VM produksi ke Proxmox DR menggunakan backup yang tersimpan di OMV  
**Status:** Implementasi final / teruji  
**Versi:** 1.0

---

## 1. Tujuan

Dokumen ini menjadi standar implementasi untuk proses **restore VM Proxmox ke server Disaster Recovery (DR)** menggunakan backup yang tersimpan pada OpenMediaVault.

Standar ini mengikuti implementasi yang telah diuji, dengan prinsip:

- Proxmox DR mengambil backup langsung dari OMV melalui NFS.
- Tidak perlu menyalin file backup secara manual ke `/var/lib/vz/dump`.
- VM hasil restore menggunakan **IP produksi yang sama**.
- VM hasil restore ditempatkan terlebih dahulu pada jaringan **isolasi DR**.
- Akses administrasi dan health check tetap dapat dilakukan tanpa mematikan VM produksi.
- Setelah VM tervalidasi, VM dapat dipromosikan menjadi VM aktif saat diperlukan.
- Proses restore dapat digunakan untuk **uji DR** maupun **actual failover**.

> **Catatan:** Dokumen ini hanya membahas implementasi restore/DR. Proses pembuatan backup dan script backup tidak dibahas di dalam dokumen ini.

---

## 2. Arsitektur Restore

```text
                 PRODUCTION
              Proxmox A
           192.168.71.202
                  |
                  | Backup
                  v
        +----------------------+
        |   OpenMediaVault     |
        |   192.168.71.211     |
        |                      |
        | /export/Backup_VM    |
        |      /Regional       |
        +----------+-----------+
                   |
                   | NFS
                   v
        +----------------------+
        |    Proxmox DR / B    |
        |    192.168.71.205    |
        |                      |
        |   local-lvm          |
        |   vmbr0              |
        |   vmbr-dr            |
        +----------+-----------+
                   |
                   | Isolated DR VM
                   v
            Production IP
            192.168.71.233
```

### Prinsip jaringan

VM hasil restore **tidak langsung ditempatkan pada `vmbr0`**.

VM terlebih dahulu menggunakan:

```text
vmbr-dr
```

Dengan demikian VM dapat menggunakan IP produksi:

```text
192.168.71.233
```

tanpa langsung berada pada jaringan produksi melalui bridge utama.

---

# 3. Komponen Infrastruktur

## 3.1 Proxmox Production

| Parameter   | Nilai            |
| ----------- | ---------------- |
| Host        | Proxmox A        |
| IP          | `192.168.71.202` |
| VM Produksi | `VMID 107`       |
| Nama VM     | `ONEMDORAYA`     |
| IP VM       | `192.168.71.233` |
| Gateway     | `192.168.71.100` |

## 3.2 OpenMediaVault

| Parameter     | Nilai               |
| ------------- | ------------------- |
| IP OMV        | `192.168.71.211`    |
| NFS Export    | `/export/Backup_VM` |
| Folder backup | `/Regional`         |

Struktur backup:

```text
/export/Backup_VM/
└── Regional/
    └── YYYY-MM-DD/
        └── backup VM
```

Contoh:

```text
/Regional/
└── 2026-09-21/
    └── vzdump-qemu-107-2026_09_21-07_00_02.vma.zst
```

## 3.3 Proxmox DR

| Parameter       | Nilai            |
| --------------- | ---------------- |
| Host            | Proxmox B / DR   |
| IP              | `192.168.71.205` |
| Storage restore | `local-lvm`      |
| Bridge utama    | `vmbr0`          |
| Bridge isolasi  | `vmbr-dr`        |

---

# 4. Prasyarat Restore

Sebelum melakukan restore, pastikan:

- Proxmox DR dalam kondisi normal.
- Storage `local-lvm` tersedia dan memiliki kapasitas yang cukup.
- Server DR dapat mengakses OMV.
- NFS backup OMV dapat di-mount pada Proxmox DR.
- Folder `/Regional` dapat dibaca.
- File backup VM tersedia dan dapat dibaca.
- VM produksi masih dapat berjalan apabila pengujian dilakukan tanpa failover.
- Konfigurasi jaringan `vmbr-dr` tersedia.
- IP produksi VM yang akan direstore sudah diketahui.
- VMID target pada Proxmox DR tidak sedang digunakan oleh VM lain.
- Tidak ada VM DR lain yang menggunakan IP produksi yang sama pada jaringan aktif.

---

# 5. Mount Backup OMV pada Proxmox DR

Backup diakses langsung dari OMV melalui NFS.

Mount point standar:

```text
/mnt/omv-backup
```

Setelah mount berhasil, lokasi backup harus dapat diakses melalui:

```text
/mnt/omv-backup/Regional
```

Pastikan folder tanggal dan file backup tersedia, misalnya:

```text
/mnt/omv-backup/Regional/2026-09-21/
```

---

# 6. Pemilihan Backup

Pilih backup berdasarkan kebutuhan restore.

Prioritas pemilihan:

1. Backup terbaru yang tersedia.
2. Backup merupakan backup VM yang benar.
3. File backup dapat dibaca dari NFS.
4. VMID sumber sesuai dengan VM yang akan direstore.

Contoh:

```text
vzdump-qemu-107-2026_09_21-07_00_02.vma.zst
```

Informasi penting:

```text
VMID     : 107
Tanggal  : 2026-09-21
```

---

# 7. Restore Langsung dari OMV

Restore dilakukan langsung dari lokasi backup yang telah di-mount.

Alur:

```text
OMV
 |
 | NFS
 v
Proxmox DR
 |
 | Restore
 v
local-lvm
 |
 v
VM baru
```

Tidak diperlukan proses:

```text
OMV
  ↓
copy backup
  ↓
/var/lib/vz/dump
  ↓
restore
```

File backup tetap berada di OMV dan Proxmox DR membaca sumber backup langsung melalui NFS.

---

# 8. Penentuan VMID Restore

VMID hasil restore harus dipastikan tidak sedang digunakan.

Contoh:

```text
VM produksi       : 107
VM hasil restore  : 117
```

Penggunaan VMID baru digunakan untuk proses pengujian restore agar VM production dan VM DR menjadi dua objek VM yang berbeda.

---

# 9. Parameter VM Hasil Restore

Setelah proses restore selesai, periksa konfigurasi VM.

| Parameter   | Standar                      |
| ----------- | ---------------------------- |
| Nama VM     | Sama dengan VM produksi      |
| RAM         | Sesuai kebutuhan VM produksi |
| CPU         | Sesuai kemampuan node DR     |
| Storage     | `local-lvm`                  |
| Disk        | Sesuai ukuran backup         |
| Network     | `vmbr-dr`                    |
| IP VM       | IP produksi                  |
| Gateway     | Gateway produksi             |
| MAC Address | Dicatat dan diverifikasi     |
| Boot        | Sesuai kebutuhan DR          |

Pada implementasi yang telah diuji:

```text
RAM     : 12 GB
CPU     : 4 vCPU
Storage : local-lvm
Bridge  : vmbr-dr
IP      : 192.168.71.233
```

Jumlah CPU harus disesuaikan dengan kemampuan node DR. Pada node DR yang diuji, penggunaan lebih dari 4 vCPU untuk VM tersebut tidak diperbolehkan oleh konfigurasi node.

---

# 10. Network Isolation

VM hasil restore tetap menggunakan IP produksi:

```text
192.168.71.233
```

Namun network interface VM ditempatkan pada:

```text
vmbr-dr
```

bukan:

```text
vmbr0
```

Tujuannya mencegah VM hasil restore langsung berkomunikasi dengan jaringan produksi dan menyebabkan konflik IP.

### Kondisi pengujian

```text
VM Production
192.168.71.233
      |
      +---- jaringan produksi

VM DR
192.168.71.233
      |
      +---- vmbr-dr
             |
             +---- isolated
```

Kedua VM dapat memiliki IP yang sama selama berada pada segmen jaringan yang benar-benar terisolasi.

---

# 11. Akses Administrasi Saat VM Terisolasi

Walaupun VM DR menggunakan IP produksi, administrator tetap perlu melakukan:

- ping
- SSH
- HTTP/HTTPS
- health check
- pemeriksaan service

Pada implementasi final, akses dilakukan melalui routing khusus pada host Proxmox DR.

Parameter:

```text
DR Host       : 192.168.71.205
DR VM         : 192.168.71.233
DR Source IP  : 192.168.71.253
Bridge        : vmbr-dr
```

Route khusus diarahkan ke VM:

```text
192.168.71.233/32
```

sehingga traffic menuju IP tersebut dari host DR menggunakan `vmbr-dr`.

Hasil pengujian:

- route menuju `192.168.71.233` menggunakan `vmbr-dr`
- ping berhasil
- ARP VM berhasil
- HTTP menghasilkan `HTTP/1.1 200 OK`
- SSH berhasil masuk ke server Ubuntu
- akses administrasi dari PC dapat dilakukan melalui SSH tunnel ke Proxmox DR

---

# 12. Verifikasi Setelah Restore

Jangan langsung melakukan failover setelah restore.

Lakukan health check terlebih dahulu.

## 12.1 Verifikasi VM

Pastikan VM dalam kondisi:

```text
running
```

Periksa:

- CPU
- RAM
- disk
- network interface
- boot configuration
- hostname
- IP address

## 12.2 Verifikasi Network

Pastikan route menuju:

```text
192.168.71.233
```

menggunakan:

```text
vmbr-dr
```

bukan:

```text
vmbr0
```

## 12.3 Verifikasi ICMP

Lakukan ping melalui interface DR.

Expected:

```text
PING 192.168.71.233
64 bytes from 192.168.71.233
```

Status:

```text
PASS
```

## 12.4 Verifikasi SSH

Lakukan koneksi SSH ke VM hasil restore.

Expected:

```text
SSH connection successful
```

Verifikasi login menggunakan user administrasi yang sesuai.

Status:

```text
PASS
```

## 12.5 Verifikasi Service

Periksa service utama VM, misalnya:

```text
Apache / Nginx
Database
Application
API
```

Untuk aplikasi web, lakukan pemeriksaan HTTP/HTTPS.

Expected:

```text
HTTP/1.1 200 OK
```

Status:

```text
PASS
```

---

# 13. Health Check Minimum

VM hanya dianggap **READY FOR DR** apabila minimal pemeriksaan berikut berhasil:

| Pemeriksaan             | Status |
| ----------------------- | ------ |
| VM running              | PASS   |
| Disk terbaca            | PASS   |
| Network interface aktif | PASS   |
| IP sesuai               | PASS   |
| vmbr-dr aktif           | PASS   |
| Route DR benar          | PASS   |
| Ping                    | PASS   |
| SSH                     | PASS   |
| HTTP/HTTPS              | PASS   |
| Service aplikasi        | PASS   |

Jika salah satu pemeriksaan kritis gagal, VM tidak boleh dipromosikan sebagai VM aktif.

---

# 14. Mode Pengujian DR

Pada mode pengujian:

```text
Production VM
192.168.71.233
    |
    +--- tetap berjalan

DR VM
192.168.71.233
    |
    +--- vmbr-dr
         |
         +--- isolated
```

Tujuan mode ini adalah memastikan:

- backup dapat direstore
- VM dapat boot
- storage dapat digunakan
- network VM benar
- service dapat berjalan
- administrator dapat melakukan health check

Tanpa mematikan VM produksi.

---

# 15. Promosi VM Menjadi VM Aktif

Apabila DR digunakan untuk failover aktual, VM hasil restore dipromosikan menjadi VM aktif.

Urutan:

```text
1. Pastikan VM Production tidak lagi aktif.
2. Pastikan tidak ada VM lain menggunakan IP produksi.
3. Pastikan VM DR sudah lulus health check.
4. Siapkan perubahan network dari isolated DR ke network aktif.
5. Pastikan konfigurasi IP tetap menggunakan IP produksi.
6. Aktifkan konektivitas produksi.
7. Lakukan ping.
8. Lakukan SSH.
9. Lakukan HTTP/HTTPS.
10. Lakukan verifikasi aplikasi.
```

> **PENTING:** Jangan mengaktifkan VM DR pada jaringan produksi sementara VM produksi dengan IP yang sama masih aktif.

---

# 16. Akses Setelah Failover

Setelah VM DR dipromosikan:

```text
Client
  |
  v
Network Production
  |
  v
VM DR
192.168.71.233
```

Lakukan pemeriksaan dari sisi client:

- Ping
- SSH
- HTTP/HTTPS
- Aplikasi
- Database
- Service terkait

Pastikan akses berasal dari jaringan produksi dan bukan lagi melalui jalur isolasi DR.

---

# 17. Rollback Pengujian

Jika pengujian tidak sesuai harapan, VM DR tetap dipertahankan dalam kondisi isolated.

Jangan menghubungkan VM DR ke jaringan produksi apabila:

- service belum sehat
- IP belum benar
- aplikasi gagal
- database gagal
- network belum benar
- VM produksi masih aktif

Prinsip rollback:

```text
VM DR gagal
     |
     v
Tetap isolated
     |
     v
VM Production tetap menjadi VM aktif
```

Pada implementasi dengan mekanisme slot restore, VM lama dipertahankan sampai VM hasil restore benar-benar sehat.

---

# 18. Pengelolaan Slot Restore

Implementasi DR menggunakan konsep VM hasil restore sebagai **slot DR**.

Contoh:

```text
VMID 117
ONEMDORAYA
```

Setelah restore dan health check berhasil, slot tersebut menjadi kandidat VM DR aktif.

Konsep slot bertujuan untuk:

- menghindari konflik VMID
- memisahkan VM production dan VM DR
- memudahkan pengujian berulang
- memudahkan rollback
- menjaga VM production tetap aman selama pengujian

---

# 19. Form Pemeriksaan Restore

Catat hasil setiap proses restore:

```text
Tanggal restore       :
Jam restore           :
VMID sumber           :
VMID hasil restore    :
Nama VM               :
File backup           :
Tanggal backup        :
Storage target        :
Bridge network        :
IP VM                 :
Status VM             :
Ping                  :
SSH                   :
HTTP/HTTPS            :
Service aplikasi      :
Status health check   :
Status DR             :
Administrator         :
```

---

# 20. Kriteria Restore Berhasil

Restore dinyatakan **BERHASIL** apabila:

1. File backup dapat dibaca dari OMV.
2. Restore selesai tanpa error.
3. VM berhasil dibuat pada Proxmox DR.
4. Disk VM berhasil ditempatkan pada storage DR.
5. VM dapat melakukan boot.
6. Network interface aktif.
7. VM menggunakan `vmbr-dr` selama pengujian.
8. IP VM sesuai dengan IP produksi.
9. Ping berhasil.
10. SSH berhasil.
11. Service utama berjalan.
12. HTTP/HTTPS berhasil apabila VM menyediakan layanan web.
13. Tidak terjadi konflik dengan VM produksi.
14. VM siap digunakan untuk proses failover apabila diperlukan.

---

# 21. Alur Standar Implementasi

```text
START
  |
  v
Backup tersedia di OMV
  |
  v
Mount NFS pada Proxmox DR
  |
  v
Pilih backup yang akan direstore
  |
  v
Tentukan VMID restore
  |
  v
Restore langsung dari OMV
  |
  v
Restore selesai?
  |
  +---- NO ----> Investigasi error
  |
 YES
  |
  v
Periksa konfigurasi VM
  |
  v
Set network = vmbr-dr
  |
  v
Boot VM
  |
  v
Health Check
  |
  +---- FAIL ---> Tetap isolated / rollback
  |
 PASS
  |
  v
VM READY FOR DR
  |
  +---- TEST DR ----> Tetap isolated
  |
  +---- FAILOVER ---> Pastikan Production VM OFF
                          |
                          v
                    Aktifkan network produksi
                          |
                          v
                    Verifikasi layanan
                          |
                          v
                         END
```

---

# 22. Checklist Implementasi Restore

## Infrastruktur

- [ ] Proxmox DR aktif
- [ ] Storage `local-lvm` tersedia
- [ ] NFS OMV dapat diakses
- [ ] `/mnt/omv-backup` tersedia
- [ ] `/mnt/omv-backup/Regional` dapat dibaca
- [ ] Backup tersedia

## Restore

- [ ] Backup yang benar dipilih
- [ ] VMID target tidak konflik
- [ ] Restore selesai
- [ ] Disk tersedia
- [ ] VM configuration tersedia
- [ ] CPU sesuai kemampuan DR
- [ ] RAM sesuai kebutuhan

## Network

- [ ] Network VM menggunakan `vmbr-dr`
- [ ] IP VM sesuai IP produksi
- [ ] Route `/32` menuju IP VM menggunakan `vmbr-dr`
- [ ] Tidak ada konflik IP dengan production VM

## Health Check

- [ ] VM running
- [ ] Ping PASS
- [ ] SSH PASS
- [ ] HTTP/HTTPS PASS
- [ ] Service aplikasi PASS
- [ ] Database PASS jika diperlukan
- [ ] Health check keseluruhan PASS

## Failover

- [ ] Production VM dihentikan terlebih dahulu
- [ ] Tidak ada device/VM lain menggunakan IP produksi
- [ ] VM DR siap
- [ ] Network DR dipromosikan ke jaringan produksi
- [ ] Ping dari client PASS
- [ ] SSH dari client PASS
- [ ] Aplikasi dapat diakses
- [ ] Status failover dicatat

---

# 23. Prinsip Operasional

### 1. Production tidak disentuh saat pengujian

Pengujian dilakukan dengan VM DR dalam kondisi isolated.

### 2. IP produksi tetap dipertahankan

VM DR tidak membutuhkan IP sementara seperti `10.99.0.0/24`.

### 3. Restore langsung dari OMV

Tidak diperlukan copy manual backup ke `/var/lib/vz/dump`.

### 4. Isolasi dilakukan sebelum VM aktif

VM hasil restore harus menggunakan `vmbr-dr` selama proses validasi.

### 5. Health check dilakukan sebelum failover

VM tidak boleh dipromosikan hanya karena proses restore berhasil.

### 6. Production dan DR tidak boleh aktif bersamaan pada IP yang sama

Ini merupakan kontrol utama untuk mencegah konflik jaringan.

### 7. VM hasil restore dipertahankan sampai validasi selesai

VM production tidak dihapus atau digantikan sebelum VM DR dinyatakan sehat.

---

# 24. Status Implementasi

Implementasi berikut telah diuji:

```text
Backup OMV
     ↓
NFS Mount
     ↓
Restore langsung dari OMV
     ↓
VMID baru
     ↓
Storage local-lvm
     ↓
vmbr-dr
     ↓
IP produksi 192.168.71.233
     ↓
Boot VM
     ↓
Ping       PASS
SSH        PASS
HTTP       PASS
Service    PASS
     ↓
READY FOR DR
```

Standar ini dapat digunakan sebagai baseline implementasi restore Disaster Recovery untuk VM Proxmox yang menggunakan backup tersimpan di OMV.
