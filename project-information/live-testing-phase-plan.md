# Live-Testing Phase Plan (`fn-autosc-api`)

Alur pengujian live lapisan API `fn-autosc-api` dari client KVM lokal Debian 12 (`/dev/kvm`) ke server target VPS `202.155.17.126` (domain `autosc.rohcuan.dpdns.org`). API dipasang sebagai add-on opsional panel via `menu-api install` dan diuji melalui `https://<domain>/api/<endpoint>` (nginx → `127.0.0.1:9000`).

---

## 1. Topologi & Protokol Keselamatan

```
┌───────────────────────────────┐                  ┌───────────────────────────────┐
│     Client KVM Debian 12      │                  │       Target VPS Server       │
│          (/dev/kvm)           │                  │       202.155.17.126          │
│  Real Traffic: curl (loop,    │──(IPv4 Publik /)─►  Nginx /api/ → 127.0.0.1:9000 │
│  parallel, malformed JSON)    │  (443, tapi      │  api.service → /usr/bin/rere/ │
└───────────────────────────────┘   endpointnya)   │  → skrip panel fn-autosc     │
                                                   └───────────────────────────────┘
```

1. **Aturan Penamaan Akun Uji:**
   - Seluruh akun pengujian wajib menggunakan awalan `testcard*` atau `livetest*`.
   - Dilarang memodifikasi akun operasional persisten (`wgtest1`, `wglive1`).
   - Token API tidak boleh ditempel di file/dokumen; baca dari `/etc/xray/.key` di VPS per sesi uji lalu hapus salinan lokal (`shred -u`).

2. **Snapshot Sebelum Pengujian Mutasi:**
   ```bash
   cp -a /etc/xray/json /tmp/snap-xray-json
   cp -a /etc/funny /tmp/snap-funny
   user_list_snapshot=$(grep -h '^###' /etc/xray/json/*.json | sort)
   ```

3. **Pembersihan Pasca Pengujian:**
   - Hapus akun uji via endpoint `delete-*` (bukan manual), verifikasi `grep -c` = 0 di `json/*.json`.
   - Validasi config: `xray run -test -config` tiap transport yang disentuh.
   - Bila API hanya dipasang untuk pengujian, tutup dengan `menu-api uninstall` dan pastikan service `inactive`.

---

## 2. Dokumen & Sumber Referensi Wajib (Mandatory References)

Setiap pengujian pada seluruh fase **WAJIB** merujuk dan mencocokkan hasil aktual dengan 7 sumber referensi utama:

| # | Sumber Referensi | Lokasi / Sumber | Peran dalam Pengujian Live |
| :- | :--- | :--- | :--- |
| 1 | **Endpoint Contract** | `README.md` (tabel kontrak + contoh `curl`) | Bentuk request/response yang diharapkan tiap endpoint. |
| 2 | **Server & Helper Source** | `server`, `lib.sh` (repo ini) | Batas perilaku yang disengaja: single-threaded, 401 tanpa token, 404 path >1 segmen, timeout 180s. |
| 3 | **Git Commit History** | `git log --stat` / `git log -p` | Alasan tiap hardening (revert threading, `re_escape`, `require` di luar subshell). |
| 4 | **Panel Backend** | Skrip panel VPS (`/usr/bin/add-*`, `delete-*`, `extend-*`) | Kebenaran akhir: sukses API harus tercermin di config panel. |
| 5 | **Panel Decisions & Spec** | `fn-autosc: is-decision.md` + `fn-api.md` | Validasi bahwa "penolakan" adalah kepatuhan (Decision 4, transport `http` vs `upgrade`, error edisi lite). |
| 6 | **Handler Sources** | `handlers/*`, `menu-api` (repo ini) | Prompt yang di-pipe, verifikasi grep, dan pesan error yang diharapkan. |
| 7 | **Live Journal** | `journalctl -u api`, `/etc/xray/api.log`, `journalctl -u xray@*` | Bukti sisi server: request tercatat, restart terhitung (deteksi restart storm). |

---

## 3. Struktur 18 Fase Pengujian Live

```
Fase 1:  Lifecycle install/status/uninstall
   │
Fase 2:  Matriks autentikasi semua method
   │
Fase 3:  Rotasi token & token file edge cases
   │
Fase 4:  Traversal path & endpoint tak dikenal
   │
Fase 5:  Create Xray core ws
   │
Fase 6:  Create Xray core http, split & grpc
   │
Fase 7:  Validitas link via client xray sungguhan
   │
Fase 8:  Read-only, cek & unsupported
   │
Fase 9:  Renew, password & delete + injeksi nama
   │
Fase 10: Handler SSH edisi full
   │
Fase 11: Error edisi lite (tool hilang)
   │
Fase 12: Handler NoobzVPN vs database
   │
Fase 13: Konkruensi create paralel
   │
Fase 14: Konkruensi delete & campuran
   │
Fase 15: Coalescing restart burst
   │
Fase 16: Timeout & body malformed
   │
Fase 17: Audit log & kebocoran rahasia
   │
Fase 18: Cleanup, uninstall & box-as-found
```

---

### Fase 1: Lifecycle `menu-api`

- **Tujuan:** Add-on terpasang/terhapus bersih dan status jujur.
- **Langkah Pengujian:**
  1. `menu-api install`: `api.service` active, listen `127.0.0.1:9000`, 19 handler + 2 symlink di `/usr/bin/rere/`, token 40 char mode `0600`.
  2. `menu-api status`: angka service/listen/handler/token-prefix cocok kondisi nyata.
  3. TUI: opsi `0` → exit 0; invalid → redisplay; EOF → keluar anggun; tiap aksi write di-gate lisensi.

### Fase 2: Matriks Autentikasi Semua Method

- **Tujuan:** Tanpa celah auth di method non-standar.
- **Langkah Pengujian:**
  1. Tanpa header dan token salah → `401` untuk GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS, CONNECT, TRACE.
  2. Token benar → `ping` 200 `{"status":"success",...}`.
  3. Header kosong-spasi dan 10KB → `401`, tanpa exception (500).

### Fase 3: Rotasi Token & Token File Edge Cases

- **Tujuan:** Rotasi atomik dan fail-closed.
- **Langkah Pengujian:**
  1. `menu-api token`: token berubah + service restart; token lama langsung `401`, token baru 200.
  2. Kosongkan `/etc/xray/.key` sementara + restart `api` → service exit 1 dengan pesan (fail closed, bukan jalan tanpa auth); kembalikan token.
  3. Tambah baris sampah/kosong di token file → baris valid tetap diterima, sampah diabaikan.

### Fase 4: Traversal Path & Endpoint Tak Dikenal

- **Tujuan:** Handler di luar `/usr/bin/rere/` tak terjangkau.
- **Langkah Pengujian:**
  1. `/api/..%2f..%2fetc/passwd`, `/api/../server`, `/api/a/b`, `/`, nama 10KB → ditolak (`404` app; edge nginx dapat `400` — keduanya deny).
  2. `/api/nope123` → `404 Script not found`.
  3. `/api/ping?x=1` → tetap route ke `ping` (perilaku terdefinisi).

### Fase 5: Create Xray Core `ws`

- **Tujuan:** Jalur default (`core` kosong → `ws`) untuk 3 protokol.
- **Langkah Pengujian:**
  1. `add-vmess`/`add-vless`/`add-trojan` dengan `username`, `expired`, `limit-ip`, `quota` → sukses + `links[]` terisi.
  2. `core` kosong → `ws`; `expired` kosong → default 30 (cocokkan README).
  3. Duplikat username → error berisi alasan panel, tanpa akun ganda.
  4. `core: "upgrade"` (nama internal panel) → ditolak; yang benar `http` (kontrak publik).

### Fase 6: Create Xray Core `http`, `split` & `grpc`

- **Tujuan:** 9 kombinasi tersisa (3 proto × 3 core) selebar core `ws`.
- **Langkah Pengujian:**
  1. Ulangi matriks Fase 5 untuk `http`, `split`, `grpc` (akun `livetest_*` berbeda per sel).
  2. `core` tak dikenal (`"ss"`, `"wireguard"`, angka) → error menyebut daftar valid.
  3. Verifikasi tiap akun mendarat di JSON yang benar (`upgrade.json` untuk `http`, dst.) dengan `"level": 0`.

### Fase 7: Validitas Link via Client Xray Sungguhan

- **Tujuan:** Link yang dikembalikan benar-benar konek, bukan sekadar string.
- **Langkah Pengujian:**
  1. Pilih 1 link per core (`ws`, `http`, `split`, `grpc`): jalankan `xray-core` lokal, download payload 5MB, checksum identik dengan direct.
  2. Decode `id`/password link == kredensial yang dibuat via API.
  3. Hapus keempat akun via API sesudahnya.

### Fase 8: Read-Only, Cek & Unsupported

- **Tujuan:** Baca konsisten; yang tak didukung gagal eksplisit.
- **Langkah Pengujian:**
  1. `list-xray` vs `grep '^###'`: jumlah + nama + expiry + transport cocok persis.
  2. `list-ssh`/`cek-ssh`/`list-noobz`/`cek-xray`: bandingkan dengan tool panel langsung; database kosong → tetap sukses konsisten.
  3. `/api/add-ss`, `/api/add-socks` → error eksplisit (tak ada backend di panel/referensi).
  4. Method silang (GET→`add-vmess`, POST→`list-xray`) → tanpa crash, perilaku terdokumentasi.

### Fase 9: Renew, Password & Delete + Injeksi Nama

- **Tujuan:** Mutasi terverifikasi; injeksi regex gagal total.
- **Langkah Pengujian:**
  1. `renew-xray`: `previous_expired` ≠ `expired`; file `_usage` tidak nol (usage dipertahankan).
  2. `renew-xray` fiktif → error tanpa restart (`ActiveEnterTimestamp` tak berubah).
  3. `password-ssh`: shadow berubah; lama ditolak, baru diterima; berspasi ditolak eksplisit.
  4. `delete-xray` akun di 2 transport → keduanya hilang, `deleted_from` akurat.
  5. Injeksi `".*"`, `"a.b"`, `"a|b"`, prefix (`test` vs `test2`) ke delete/renew → hanya target persis tersentuh (via `list` sebelum/sesudah).
  6. Tiap mutasi: `xray -test` valid + service active.

### Fase 10: Handler SSH Edisi Full

- **Tujuan:** Jalur SSH ujung-ke-ujung di edisi full.
- **Langkah Pengujian:**
  1. `addssh` → `id` ada, shell `/bin/false`, login password diterima.
  2. `password-ssh` + `renew-ssh` + `delete-ssh` seperti Fase 9 untuk SSH.
  3. `delete-ssh` fiktif → error bersih tanpa efek samping.

### Fase 11: Error Edisi Lite (Tool Hilang)

- **Tujuan:** Kegagalan kapabilitas dilaporkan jujur.
- **Langkah Pengujian:**
  1. `rename` sementara `extend-ssh`, `pwd-ssh`, `noobzvpns` (kembalikan sesudahnya): handler terkait menjawab error `does not ship`.
  2. Matikan `jq` sementara: handler JSON error rapi `jq is required`, bukan crash.
  3. Pastikan tidak ada respons `success` palsu selama tool hilang; kembalikan semua dan verifikasi normal.

### Fase 12: Handler NoobzVPN vs Database

- **Tujuan:** CRUD Noobz terverifikasi ke `db_user.json`, bukan teks output.
- **Langkah Pengujian:**
  1. `add-noobz` → entri DB ada (password cocok, tak diblokir, expiry benar).
  2. `list-noobz` mencantumkannya; `delete-noobz` menghilangkannya; hapus ulang → error bersih.
  3. Password bermetakarakter diteruskan verbatim.
  4. Uji kedua bentuk CLI (`print-all` vs `--info-all-user`) bila tersedia.

### Fase 13: Konkruensi Create Paralel

- **Tujuan:** Serialisasi single-threaded terbukti tanpa korupsi.
- **Langkah Pengujian:**
  1. 5 `POST /api/add-vmess` simultan (username beda) → kelimanya `success`.
  2. 10 baris (5 marker + 5 email) di `ws.json`; `xray -test` valid.
  3. `api.log`: request tercatat berurutan tanpa interleave.

### Fase 14: Konkruensi Delete & Campuran

- **Tujuan:** Mutasi hapus paralel seaman create paralel.
- **Langkah Pengujian:**
  1. 5 `delete-xray` simultan → semua hilang, config valid.
  2. Campuran add+delete+renew simultan (username beda) → semua sukses terverifikasi, tanpa akun setengah-jadi.
  3. Delete + create username yang sama berurutan cepat → hasil deterministik (salah satu menang penuh, tak ada duplikat).

### Fase 15: Coalescing Restart Burst

- **Tujuan:** Burst tak membunuh transport (pasca Found 329/330 `fn-autosc`: budget unit `120s/30`).
- **Langkah Pengujian:**
  1. Baseline: `ActiveEnterTimestamp` + hitung `Stopping xray@ws` di journal (0).
  2. Burst 6 add + 6 delete paralel (12 panggilan).
  3. Harapan: semua sukses terverifikasi + service tetap `active` **tanpa `reset-failed` manual** (restart tetap N-per-N karena skrip panel memilikinya; yang dijamin adalah budget unit menahannya, bukan 1-restart-per-batch).
  4. Kriteria gagal (bug baru): `start-limit-hit`, klaim sukses tanpa entri config, atau failed unit.
  5. Bersihkan semua akun uji.

### Fase 16: Timeout & Body Malformed

- **Tujuan:** Server hidup menghadapi input dan backend nakal.
- **Langkah Pengujian:**
  1. Bukan-JSON, tanpa `username`, `username` angka/array/nested, body 10MB → `{"status":"error",...}` (200), bukan 500.
  2. `Content-Length` hilang vs klaim berlebih → tak hang; koneksi reusable.
  3. Endpoint uji `sleep 200` sementara di `/usr/bin/rere/` (hapus sesudahnya) → 500 `handler timed out` tepat waktu; request berikut normal.

### Fase 17: Audit Log & Kebocoran Rahasia

- **Tujuan:** Observabilitas tanpa membocorkan kredensial.
- **Langkah Pengujian:**
  1. Tiap request Fase 2-16 tercatat di `/etc/xray/api.log` (IP, path, hasil).
  2. `grep -iE "password|Authorization|Bearer" /etc/xray/api.log` → **nol temuan**: token dan password tak boleh mendarat di log.
  3. `journalctl -u api`: tak ada traceback Python pada input malformed (error ditangani, bukan exception).
  4. Upaya auth gagal tercatat sebagai warning tanpa membeberkan token yang dicoba.

### Fase 18: Cleanup, Uninstall & Box-as-Found

- **Tujuan:** VPS kembali ke keadaan pra-uji.
- **Langkah Pengujian:**
  1. Semua `livetest_*`/`testcard_*` terhapus via API; `grep -c` = 0 di `json/*.json`, `/etc/passwd`, `db_user.json`.
  2. `xray -test` valid semua transport; 0 failed unit; file sisa (`/tmp/snap-*` boleh dihapus).
  3. `menu-api uninstall` → service `inactive`, biner/handler hilang, token bertahan `0600` (terdokumentasi).
  4. Salinan token lokal di-`shred -u`; tidak ada kredensial uji tersisa di client.
