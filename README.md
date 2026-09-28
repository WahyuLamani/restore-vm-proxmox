# README — Standar Implementasi Restore Disaster Recovery Proxmox

**Dokumen:** Tutorial Implementasi Restore / Disaster Recovery  
**Platform:** Proxmox VE + OpenMediaVault (OMV)  
**Model:** Restore VM Production ke Proxmox DR dari backup OMV  
**Status:** Implementasi final / teruji  
**Versi:** 1.1

---

# 1. Tujuan

Dokumen ini merupakan panduan standar **tahapan restore VM Production ke Proxmox DR** menggunakan backup yang tersimpan di OpenMediaVault.

Alur yang digunakan:

```text
Backup di OMV
      ↓
Mount NFS pada Proxmox DR
      ↓
Pilih backup
      ↓
Restore ke VMID baru
      ↓
Set network VM ke vmbr-dr
      ↓
Boot VM
      ↓
Akses melalui jalur DR
      ↓
Health Check
      ↓
READY FOR DR
      ↓
Failover jika diperlukan
```

Dokumen ini **tidak membahas pembuatan backup, script backup, maupun script restore**.

---

# 2. Infrastruktur yang Digunakan

## 2.1 Proxmox Production

| Parameter             | Nilai            |
| --------------------- | ---------------- |
| IP Proxmox Production | `192.168.71.202` |
| VM Production         | `107`            |
| Nama VM               | `ONEMDORAYA`     |
| IP VM                 | `192.168.71.233` |
| Gateway               | `192.168.71.100` |

## 2.2 OpenMediaVault

| Parameter     | Nilai               |
| ------------- | ------------------- |
| IP OMV        | `192.168.71.211`    |
| NFS Export    | `/export/Backup_VM` |
| Folder backup | `/Regional`         |

Struktur backup:

```text
/Regional/
└── YYYY-MM-DD/
    └── vzdump-qemu-VMID-YYYY_MM_DD-HH_MM_SS.vma.zst
```

Contoh:

```text
/Regional/
└── 2026-09-21/
    └── vzdump-qemu-107-2026_09_21-07_00_02.vma.zst
```

## 2.3 Proxmox DR

| Parameter         | Nilai            |
| ----------------- | ---------------- |
| IP Proxmox DR     | `192.168.71.205` |
| Storage restore   | `local-lvm`      |
| Bridge Production | `vmbr0`          |
| Bridge Isolasi DR | `vmbr-dr`        |
| Source IP DR      | `192.168.71.253` |

---

# 3. Konsep Restore

VM hasil restore **tetap menggunakan IP Production**.

Contoh:

```text
Production VM
IP: 192.168.71.233

DR VM
IP: 192.168.71.233
```

Agar tidak terjadi konflik IP, VM DR **tidak boleh langsung menggunakan `vmbr0`**.

Selama proses restore dan pengujian:

```text
VM DR
  |
  +--- vmbr-dr
          |
          +--- Isolated
```

Setelah VM lulus health check dan diperlukan untuk failover, koneksi VM dapat dipromosikan ke jaringan Production.

---

# 4. Tutorial Restore

## Step 1 — Login ke Proxmox DR

Login ke server Proxmox DR:

```text
192.168.71.205
```

Contoh:

```bash
ssh root@192.168.71.205
```

---

## Step 2 — Pastikan NFS Backup OMV Ter-mount

Cek mount:

```bash
mountpoint /mnt/omv-backup
```

Kemudian cek isi backup:

```bash
ls -lah /mnt/omv-backup/Regional
```

Lihat file backup:

```bash
find /mnt/omv-backup/Regional -maxdepth 2 -type f -name "*.vma.zst"
```

Contoh:

```text
/mnt/omv-backup/Regional/2026-09-21/vzdump-qemu-107-2026_09_21-07_00_02.vma.zst
```

> Restore dilakukan langsung dari NFS OMV. File backup tidak perlu disalin manual ke `/var/lib/vz/dump`.

---

## Step 3 — Pilih Backup

Tentukan backup yang akan digunakan.

Contoh:

```text
/Regional/2026-09-21/
└── vzdump-qemu-107-2026_09_21-07_00_02.vma.zst
```

Pastikan VMID sumber dan tanggal backup sesuai kebutuhan.

Cek ukuran file:

```bash
ls -lh /mnt/omv-backup/Regional/2026-09-21/
```

---

## Step 4 — Tentukan VMID Hasil Restore

Gunakan **VMID baru**.

Contoh implementasi:

```text
VM Production : 107
VM DR         : 117
```

Pastikan VMID target belum digunakan:

```bash
qm status 117
```

Lihat daftar VM:

```bash
qm list
```

Pastikan tidak ada VM dengan VMID `117`.

---

## Step 5 — Restore ke `local-lvm`

Restore langsung dari file backup yang berada pada NFS OMV:

```bash
qmrestore /mnt/omv-backup/Regional/2026-09-21/vzdump-qemu-107-2026_09_21-07_00_02.vma.zst 117 --storage local-lvm
```

Keterangan:

```text
Source backup : file .vma.zst di OMV
VMID target   : 117
Storage       : local-lvm
```

Tunggu sampai proses restore selesai. Jangan menghentikan proses restore sebelum selesai.

---

## Step 6 — Verifikasi Hasil Restore

Periksa konfigurasi:

```bash
qm config 117
```

Periksa status:

```bash
qm status 117
```

Periksa disk dan storage melalui:

```bash
qm config 117
```

Contoh parameter hasil restore:

```text
VMID       : 117
Name       : ONEMDORAYA
RAM        : 12 GB
CPU        : 4 vCPU
Disk       : local-lvm
```

Pastikan konfigurasi VM sudah terbentuk sebelum melanjutkan.

---

## Step 7 — Set Network ke `vmbr-dr`

Ini adalah langkah **wajib sebelum VM dinyalakan**.

Periksa konfigurasi:

```bash
qm config 117
```

Pastikan interface menggunakan:

```text
bridge=vmbr-dr
```

Jika hasil restore masih menggunakan `vmbr0`, ubah ke `vmbr-dr`.

Contoh:

```bash
qm set 117 --net0 virtio=<MAC_ADDRESS>,bridge=vmbr-dr,firewall=1
```

Verifikasi kembali:

```bash
qm config 117
```

Expected:

```text
net0: virtio=<MAC_ADDRESS>,bridge=vmbr-dr,firewall=1
```

> **Jangan start VM sebelum network berada pada `vmbr-dr`.**

---

## Step 8 — Pastikan IP VM Tetap IP Production

VM hasil restore tetap menggunakan:

```text
IP      : 192.168.71.233
Gateway : 192.168.71.100
```

Tidak perlu mengganti IP ke jaringan sementara seperti `10.99.0.0/24`.

Isolasi dilakukan melalui `vmbr-dr`.

---

## Step 9 — Start VM DR

Nyalakan VM:

```bash
qm start 117
```

Cek status:

```bash
qm status 117
```

Expected:

```text
status: running
```

---

## Step 10 — Verifikasi Route DR

Pastikan route menuju IP VM menggunakan `vmbr-dr`:

```bash
ip route get 192.168.71.233
```

Expected:

```text
192.168.71.233 dev vmbr-dr src 192.168.71.253
```

Artinya traffic menuju VM DR menggunakan interface isolasi `vmbr-dr`.

---

## Step 11 — Verifikasi Ping

Lakukan ping melalui interface DR:

```bash
ping -I vmbr-dr 192.168.71.233
```

Expected:

```text
64 bytes from 192.168.71.233
```

Status:

```text
PASS
```

---

## Step 12 — Verifikasi ARP

Cek ARP:

```bash
ip neigh show 192.168.71.233
```

Expected terdapat MAC address VM pada `vmbr-dr`.

Contoh:

```text
192.168.71.233 dev vmbr-dr lladdr 62:97:d0:79:bf:21 REACHABLE
```

Status:

```text
PASS
```

---

## Step 13 — Verifikasi SSH

Karena VM menggunakan IP Production tetapi masih terisolasi, akses administrator dilakukan melalui jalur DR.

Dari PC administrator:

```bash
ssh -L 2222:192.168.71.233:22 root@192.168.71.205
```

Dari terminal lain:

```bash
ssh -p 2222 regional@127.0.0.1
```

Jika berhasil masuk ke VM hasil restore:

```text
SSH = PASS
```

---

## Step 14 — Verifikasi HTTP/HTTPS dan Service

Periksa service utama VM, misalnya:

```text
Apache
Nginx
Database
Application
API
```

Untuk aplikasi web, lakukan pemeriksaan HTTP/HTTPS.

Pada implementasi yang telah diuji, hasilnya:

```text
HTTP/1.1 200 OK
```

Status:

```text
HTTP/HTTPS = PASS
```

---

# 5. Health Check dan Status READY FOR DR

VM hasil restore dinyatakan **READY FOR DR** jika seluruh pemeriksaan berikut berhasil:

| Pemeriksaan             | Hasil |
| ----------------------- | ----- |
| Restore selesai         | PASS  |
| VM configuration        | PASS  |
| Disk `local-lvm`        | PASS  |
| VM running              | PASS  |
| Network `vmbr-dr`       | PASS  |
| IP `192.168.71.233`     | PASS  |
| Route melalui `vmbr-dr` | PASS  |
| Ping                    | PASS  |
| ARP                     | PASS  |
| SSH                     | PASS  |
| HTTP/HTTPS              | PASS  |
| Service aplikasi        | PASS  |

Jika pemeriksaan kritis gagal, **jangan hubungkan VM DR ke jaringan Production**.

---

# 6. Kondisi Akhir Mode Testing

Jika restore hanya untuk pengujian DR, kondisi akhir:

```text
Production VM
192.168.71.233
       |
       +---- vmbr0 / Production
       |
       +---- tetap aktif


DR VM
192.168.71.233
       |
       +---- vmbr-dr
              |
              +---- isolated
```

Dengan kondisi ini VM Production dan VM DR dapat diuji tanpa konflik IP pada jaringan Production.

---

# 7. Failover — Promosi VM DR Menjadi VM Aktif

Bagian ini hanya dilakukan apabila diperlukan untuk failover aktual.

## Step 1 — Pastikan Production VM Tidak Aktif

Sebelum VM DR masuk ke jaringan Production:

```text
VM Production 192.168.71.233
```

harus sudah dihentikan atau tidak lagi menggunakan jaringan Production.

> **Jangan pernah mengaktifkan dua VM dengan IP `192.168.71.233` pada jaringan Production secara bersamaan.**

## Step 2 — Pindahkan Network VM DR ke `vmbr0`

Setelah Production VM tidak aktif, ubah bridge VM DR dari:

```text
vmbr-dr
```

menjadi:

```text
vmbr0
```

Contoh:

```bash
qm set 117 --net0 virtio=<MAC_ADDRESS>,bridge=vmbr0,firewall=1
```

Jika diperlukan, restart VM agar perubahan network diterapkan.

## Step 3 — Verifikasi dari Client Production

Lakukan pemeriksaan dengan urutan:

```text
Ping
  ↓
SSH
  ↓
HTTP/HTTPS
  ↓
Application
```

Jika seluruh service normal, VM DR telah menjadi VM aktif.

---

# 8. Rollback Jika Testing Gagal

Jika health check VM DR gagal, VM tetap menggunakan:

```text
vmbr-dr
```

dan tetap isolated.

Jangan pindahkan VM DR ke `vmbr0` jika:

- service belum sehat
- IP belum benar
- aplikasi gagal
- database gagal
- network belum benar
- VM Production masih aktif

Jika pengujian tidak menggunakan failover, VM Production tetap menjadi VM aktif.

---

# 9. Alur Lengkap Restore

```text
START
  |
  v
Login Proxmox DR
  |
  v
Cek NFS /mnt/omv-backup
  |
  v
Cek /mnt/omv-backup/Regional
  |
  v
Pilih backup
  |
  v
Tentukan VMID baru
  |
  v
qmrestore
  |
  v
Restore selesai?
  |
  +---- NO ----> Investigasi restore
  |
 YES
  |
  v
Cek qm config
  |
  v
Set network = vmbr-dr
  |
  v
Start VM
  |
  v
Cek route vmbr-dr
  |
  v
Ping
  |
  v
ARP
  |
  v
SSH
  |
  v
HTTP/HTTPS
  |
  v
Service aplikasi
  |
  v
READY FOR DR
  |
  +---- TESTING ----> Tetap vmbr-dr
  |
  +---- FAILOVER ---> Production VM OFF
                          |
                          v
                       vmbr0
                          |
                          v
                     Ping / SSH / HTTP
                          |
                          v
                         END
```

---

# 10. Checklist Restore

## Persiapan

- [ ] Login ke Proxmox DR
- [ ] NFS OMV ter-mount
- [ ] `/mnt/omv-backup/Regional` dapat diakses
- [ ] Backup yang benar tersedia
- [ ] VMID target belum digunakan

## Restore

- [ ] `qmrestore` dijalankan
- [ ] Restore selesai tanpa error
- [ ] `qm config <VMID>` berhasil
- [ ] Disk berada pada `local-lvm`
- [ ] RAM sesuai kebutuhan
- [ ] CPU sesuai kemampuan node DR

## Network Isolation

- [ ] Network VM menggunakan `vmbr-dr`
- [ ] IP VM tetap `192.168.71.233`
- [ ] Route menuju VM menggunakan `vmbr-dr`
- [ ] Tidak ada konflik dengan Production

## Health Check

- [ ] VM running
- [ ] Ping PASS
- [ ] ARP PASS
- [ ] SSH PASS
- [ ] HTTP/HTTPS PASS
- [ ] Service aplikasi PASS
- [ ] Status READY FOR DR

## Failover

- [ ] Production VM sudah OFF / tidak menggunakan jaringan Production
- [ ] VM DR dipindahkan dari `vmbr-dr` ke `vmbr0`
- [ ] Ping dari client PASS
- [ ] SSH dari client PASS
- [ ] HTTP/HTTPS PASS
- [ ] Aplikasi PASS
- [ ] Failover dinyatakan berhasil

---

# 11. Parameter Implementasi Final

```text
Proxmox Production : 192.168.71.202
Proxmox DR         : 192.168.71.205
OMV                : 192.168.71.211

NFS Export         : /export/Backup_VM
NFS Mount DR       : /mnt/omv-backup
Backup Directory   : /mnt/omv-backup/Regional

Production VMID    : 107
DR VMID (contoh)   : 117

Production IP      : 192.168.71.233
Gateway            : 192.168.71.100

Production Bridge  : vmbr0
DR Bridge          : vmbr-dr
DR Source IP       : 192.168.71.253

Restore Storage    : local-lvm
```

---

# 12. Prinsip Wajib

1. **Restore langsung dari backup OMV melalui NFS.**
2. **Gunakan VMID baru untuk VM hasil restore.**
3. **Jangan start VM DR pada `vmbr0` saat VM Production masih aktif.**
4. **VM DR tetap menggunakan IP Production.**
5. **Gunakan `vmbr-dr` selama proses restore dan testing.**
6. **Pastikan route menuju IP DR menggunakan `vmbr-dr`.**
7. **Lakukan health check sebelum failover.**
8. **Untuk failover, pastikan VM Production sudah tidak aktif terlebih dahulu.**
9. **Setelah failover, pindahkan network VM DR ke `vmbr0`.**
10. **Verifikasi ulang akses dari client Production setelah failover.**
