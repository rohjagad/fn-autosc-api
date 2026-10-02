# Bug-Finding & Fixing Phase Plan (`fn-autosc-api`)

Rencana kerja sistematis untuk **penemuan bug (Finding)** dan **perbaikan bug (Fixing)** di repositori `fn-autosc-api` (server HTTP Python + `lib.sh` + 19 handler + `menu-api`). Setiap fase mencakup metodologi audit, teknik pemindaian pola cacat, verifikasi terhadap kontrak panel, serta standar perbaikan minimalis tanpa regresi.

Repo ini kecil (±800 baris) tetapi berjalan sebagai **root** dan memutasi state bersama panel (`json/*.json`, `/etc/passwd`, unit systemd) — satu bug di sini berakibat takeover atau korupsi konfigurasi.

---

## 1. Dokumen & Sumber Referensi Wajib (Mandatory References)

Setiap langkah dalam seluruh fase **WAJIB** membaca dan mengacu pada 7 sumber referensi utama berikut sebelum melakukan analisis, perubahan kode, atau evaluasi regresi:

| # | Sumber Referensi | Lokasi / Perintah | Kegunaan & Batas Kepatuhan |
| :- | :--- | :--- | :--- |
| 1 | **Git Commit History** | `git log --stat` / `git log -p` | Riwayat mengapa tiap hardening ada (single-thread revert, lock yang dibuang, `re_escape`, `require` di luar subshell). Jangan mengulang kesalahan yang sudah diperbaiki. |
| 2 | **FN-API Reference** | `https://github.com/rohjagad/FN-API` (read-only) | Daftar endpoint asli. Dipakai hanya sebagai daftar; tidak ada yang di-fetch/diubah dari sana. |
| 3 | **Panel Backend Contract** | Skrip panel di VPS: `/usr/bin/add-*`, `/usr/bin/delete-*`, `/usr/bin/extend-*`, `/usr/bin/rere/` terinstal | Handler hanyalah pembungkus; prompt, file state, dan restart milik panel. Uji handler = uji kesesuaian dengan perilaku panel aktual, bukan asumsi. |
| 4 | **Panel Decisions** | `fn-autosc: project-information/is-decision.md` (khusus Decision 4 `0 not allowed`, Decision 18 desain API, Decision 23 `"level": 0`) | Batas yang diwarisi endpoint (contoh: `limit-ip`/`quota`/`expired` mengikuti validasi panel; transport `http` bukan `upgrade`). |
| 5 | **Panel API Spec** | `fn-autosc: project-information/fn-api.md` | Kontrak request/response, bentuk `{"status":...}`, daftar endpoint, catatan batasan edisi lite. |
| 6 | **Live VPS Target** | `202.155.17.126` (SSH port `3303`, domain `autosc.rohcuan.dpdns.org`) | Verifikasi perilaku nyata, bukan inspeksi sumber saja. Aturan akun uji `testcard*` / `livetest*` berlaku. |
| 7 | **Regresi Silang** | `git log` repo ini + Section 4-Check di bawah | Setiap perubahan wajib lulus 4 kriteria: Regression, Over-Strictness, Over-Engineering, Source Alignment. |

---

## 2. Prinsip Kerja: Finding & Fixing

### 2.1 Metodologi Finding (Penemuan Bug)
1. **Pemindaian Pola Rawan:** `grep` untuk `$( )` yang memuat `fail`/`exit`, interpolasi `$user` tanpa `re_escape`, `systemctl restart` di dalam loop per-user, `rm -rf` dengan variabel, `curl` tanpa `--max-time`, `read` tanpa guard EOF.
2. **Injeksi Kegagalan Batas:** body JSON kosong / bukan-JSON / field hilang / field bertipe salah; username `"a.b"`, `".*"`, `"../x"`, string 10KB; `core` tak dikenal; token kosong / 10KB.
3. **Audit Diferensial Panel:** setiap handler yang mem-pipe jawaban ke skrip panel (`printf ... | "$script"`) wajib dicocokkan jumlah/urutan prompt terhadap skrip panel aktual di VPS — prompt panel yang berubah membuat jawaban bergeser (kredensial masuk ke field yang salah).
4. **Verifikasi Kontrak Respons:** sukses harus berarti perubahan benar terjadi di config (pola `verify`, bukan klaim buta); error harus `{"status":"error","message":...}` + exit 0, bukan exit non-nol (itu = HTTP 500).

### 2.2 Metodologi Fixing (Perbaikan Bug)
1. **Shortest Working Diff Wins:** patch minimal; tanpa dependensi baru (server tetap stdlib-only, handler tetap bash+jq).
2. **Anti Over-Strictness:** jangan tolak input sah yang panel terima; pesan error menyebut nilai yang benar (contoh: core `ws|http|split|grpc`).
3. **Gagal Tertutup (Fail Closed):** token hilang/tak terbaca → tolak; tool panel tak ada (edisi lite) → error eksplisit, bukan sukses palsu.
4. **Evaluasi 4 Kriteria Regresi** untuk setiap perubahan (lihat tabel referensi #7).

---

## 3. Struktur 16 Fase Bug-Finding & Fixing

```
Fase 1:  Server — matriks autentikasi & token
   │
Fase 2:  Server — routing path & traversal
   │
Fase 3:  Server — method, body, timeout & logging
   │
Fase 4:  lib.sh inti — body, j, field, require, fail
   │
Fase 5:  lib.sh keamanan — re_escape & output helper
   │
Fase 6:  add-xray — pipe prompt 12 kombinasi proto×core
   │
Fase 7:  addssh & add-noobz — kredensial & DB
   │
Fase 8:  delete-xray/ssh/noobz — injeksi regex & lintas transport
   │
Fase 9:  renew-xray/ssh & password-ssh — expiry & spasi
   │
Fase 10: Handler read-only — list/cek/ping
   │
Fase 11: Alias unsupported — add-ss/add-socks
   │
Fase 12: NoobzVPN — varian bentuk CLI
   │
Fase 13: menu-api — gate lisensi & fetch resiliency
   │
Fase 14: menu-api — unit systemd, token & uninstall
   │
Fase 15: Restart fan-out — coalescing per batch
   │
Fase 16: Gerbang regresi & sinkron docs
```

---

### Fase 1: Server — Matriks Autentikasi & Token

- **Komponen Target:** `server` (`_authorized`, `_unauthorized`, `load_tokens`, startup check).
- **Finding:**
  - Tanpa header dan token salah → 401 + header `WWW-Authenticate` di semua 10 method.
  - Token ber-spasi di ujung, token 10KB, header ganda → 401 tanpa exception.
  - File token multi-baris: tiap baris valid; baris kosong diabaikan.
  - Token file hilang/kosong saat startup → exit 1 dengan pesan jelas (fail closed), bukan jalan tanpa auth.
  - Token di-reload per request (rotasi tanpa restart server harus langsung berlaku).
- **Fixing:**
  - Perbandingan token dengan `in` pada list yang di-strip; jangan log nilai token.

---

### Fase 2: Server — Routing Path & Traversal

- **Komponen Target:** `server` (`_run`: split path, cek `/`, `.`, `..`, `isfile`).
- **Finding:**
  - `/../x`, `/..%2f..%2fetc/passwd`, `/%2e%2e/`, path dua segmen, nama 10KB, NUL byte, `/` kosong → 404 tanpa eksekusi.
  - Query string (`/ping?x=1`) → route ke `ping` (perilaku terdefinisi, bukan celah).
  - Symlink di `/usr/bin/rere/` ke luar direktori (mis. `add-ss` → `unsupported` adalah symlink legal) → pastikan target tetap di dalam direktori handler.
  - File non-executable bernama endpoint → 404/error rapi, bukan eksekusi gagal misterius.
- **Fixing:**
  - Validasi segmen-tunggal sebelum `os.path.join`; uji traversal ulang tiap ada perubahan routing.

---

### Fase 3: Server — Method, Body, Timeout & Logging

- **Komponen Target:** `server` (`do_*`, `_body`, `subprocess.run timeout=180`, `_send`, `_info`, `main`).
- **Finding:**
  - Tanpa `Content-Length`, `Content-Length` bukan angka/negatif, body lebih pendek dari klaim → tak hang, handler terima string kosong.
  - Body 10MB & binary → diteruskan sebagai string `replace`, memori terkendali.
  - Handler sleep > 180s → 500 `handler timed out`, koneksi berikutnya normal.
  - Handler exit non-nol → 500 berisi `error` + `stdout` (maks 8000 char, bukan dump 1MB).
  - `TERM=xterm` dan stdin-string-kosong: GET handler yang menjalankan server manual tak boleh blok di `cat`.
  - `/etc/xray/api.log` tak bisa ditulis → warning stderr, server tetap jalan; tiap request tercatat (IP, UA, path, hasil) tanpa membocorkan token/body password.
- **Fixing:**
  - Pertahankan single-threaded (regresi historis: threading menghilangkan 4/12 create). Jangan tambah thread/greenlet.

---

### Fase 4: `lib.sh` Inti — Body, `j`, `field`, `require`, `fail`

- **Komponen Target:** `lib.sh` baris 10-32.
- **Finding:**
  - Tanpa `jq` di panel → semua helper error rapi di awal, bukan `command not found` sebagai sukses.
  - `j` pada JSON rusak/duplikat-key/tipe-salah (angka vs string untuk username) → `empty`, lalu `require` gagal eksplisit.
  - `require` di dalam `$( )` → `exit` hanya bunuh subshell dan teks error dipakai sebagai nilai (audit semua handler, pola ini dilarang).
  - `field` dengan default: pastikan field opsional (`core`, `expired`, `limit-ip`, `quota`, `days`) punya default yang sama dengan README.
  - `fail` vs `ok`: error bisnis selalu exit 0 (HTTP 200 + status error); exit non-nol hanya untuk crash.
- **Fixing:**
  - Pindahkan `require` keluar subshell; samakan default dengan tabel kontrak README.

---

### Fase 5: `lib.sh` Keamanan — `re_escape` & Output Helper

- **Komponen Target:** `lib.sh` (`re_escape`, `strip_ansi`, `json_array`, `panel_reason`, `noobz_accounts`).
- **Finding:**
  - `re_escape`: uji tiap metachar (`- ] / & ^ $ * + ? ( ) { } | \ .`) terhadap `grep -E "^### <name>( |$)"` — pola tak boleh melebar ke akun lain.
  - `panel_reason` pada output panel 1MB+ → tetap 300 char, satu baris, tanpa ANSI dan tanpa membocorkan escape yang merusak JSON.
  - `json_array` pada daftar link kosong → `[]` valid, bukan error jq.
  - `noobz_accounts` bila biner hilang → string kosong yang ditangani pemanggil, bukan teks error shell.
- **Fixing:**
  - Tambah escape yang kurang; jangan pernah membangun pola grep dari input mentah di handler mana pun.

---

### Fase 6: `add-xray` — Pipe Prompt 12 Kombinasi

- **Komponen Target:** `handlers/add-xray` (+ alias `add-vmess/vless/trojan`).
- **Finding:**
  - Hitung prompt skrip panel (`add-<proto>-<core>`) vs baris `printf` handler untuk tiap proto×core (3×4=12): selisih satu baris = kredensial masuk field salah.
  - Username lolos handler tapi ditolak panel → error eksplisit berisi alasan panel (`panel_reason`), bukan sukses.
  - `core` tak dikenal/kosong → error menyebut daftar valid; default `ws` terdokumentasi.
  - Verifikasi `grep "^### <esc>"` sebelum klaim sukses; link `://` diekstrak dan cocok dengan UUID/password yang dibuat.
  - Duplikat: create ganda → gagal bersih tanpa akun ganda.
- **Fixing:**
  - Selaraskan urutan/jumlah jawaban dengan panel aktual; jangan klaim sukses tanpa grep verifikasi.

---

### Fase 7: `addssh` & `add-noobz` — Kredensial & DB

- **Komponen Target:** `handlers/addssh`, `handlers/add-noobz`.
- **Finding:**
  - `addssh`: password diteruskan apa adanya; password kosong ditolak panel dan pesannya diteruskan; verifikasi via `id` + shell `/bin/false`.
  - `add-noobz`: verifikasi ke `db_user.json` (user ada, password cocok, tak diblokir, expiry benar), bukan teks sukses semata.
  - Tool panel hilang (lite: NoobzVPN tak ada) → error edisi eksplisit via `require_tool`.
  - Password bermetakarakter/spasi diteruskan verbatim dengan quoting aman (tanpa eval).
- **Fixing:**
  - Verifikasi via state sistem/DB; teruskan batasan panel apa adanya.

---

### Fase 8: Delete — Injeksi Regex & Lintas Transport

- **Komponen Target:** `handlers/delete-xray`, `delete-ssh`, `delete-noobz`.
- **Finding:**
  - Injeksi: `".",  ".*",  "a|b",  prefix username lain (`test` vs `test2`) → hanya target persis yang tersentuh (bandingkan `list` sebelum/sesudah).
  - `delete-xray` akun di 2 transport → keduanya hilang, `deleted_from` akurat; akun fiktif → error `no such account` tanpa restart sia-sia.
  - `delete-ssh`: stdin username ke biner Go + verifikasi `id` hilang; `delete-noobz`: hilang dari DB.
  - Restart transport hanya bila sesuatu benar terhapus (lihat Fase 15 untuk coalescing).
- **Fixing:**
  - `re_escape` + jangkar `( |$)` di semua pola; verifikasi sebelum/sesudah mutasi.

---

### Fase 9: Renew & Password — Expiry & Spasi

- **Komponen Target:** `handlers/renew-xray`, `renew-ssh`, `password-ssh`.
- **Finding:**
  - `renew-xray`: `previous_expired` ≠ `expired` (bertambah sesuai `days`); jawaban `n` untuk reset usage (file `_usage` tidak nol).
  - `renew-xray` akun fiktif → error tanpa restart (cek `ActiveEnterTimestamp`).
  - `renew-ssh`/`password-ssh` di lite → error `does not ship`, bukan sukses.
  - `password-ssh` berspasi → ditolak eksplisit (batasan `Scanln` panel), bukan terpotong diam-diam; hash shadow benar berubah.
- **Fixing:**
  - Teruskan batasan panel; verifikasi via state (expiry/shadow), bukan teks output.

---

### Fase 10: Handler Read-Only — List/Cek/Ping

- **Komponen Target:** `handlers/ping`, `list-xray`, `list-ssh`, `list-noobz`, `cek-xray`, `cek-ssh`.
- **Finding:**
  - `list-xray` vs `grep '^###'` langsung: jumlah + nama + expiry + transport (`ws|http|split|grpc`, bukan `upgrade` internal).
  - Handler teks (`list-ssh`, `cek-*`, `list-noobz`): output panel diteruskan utuh tanpa pembungkus JSON ganda yang merusak parser klien.
  - Database/JSON kosong → tetap `success`-konsisten (array kosong / teks kosong), bukan error.
  - `ping` via method apa pun → 200; tanpa token → 401.
- **Fixing:**
  - Samakan penamaan transport dengan README; jangan menafsirkan output teks panel.

---

### Fase 11: Alias Unsupported — `add-ss`/`add-socks`

- **Komponen Target:** `handlers/unsupported`, symlink `add-ss`, `add-socks` (dibuat `menu-api install`).
- **Finding:**
  - Kedua endpoint → error eksplisit menyebut tak ada backend SS/Socks5 di panel maupun kedua versi referensi.
  - Symlink ada dan executable pasca-install; hilang/rusak → 404/500 yang jelas (bukan timeout).
  - Uninstall menghapus symlink (tidak tertinggal menunjuk ke `/usr/bin/rere/unsupported` yang sudah dihapus).
- **Fixing:**
  - Pertahankan sebagai error, jangan pernah membuat backend palsu.

---

### Fase 12: NoobzVPN — Varian Bentuk CLI

- **Komponen Target:** helper `noobz_accounts`, ketiga handler Noobz.
- **Finding:**
  - `noobzvpns print-all` vs `noobzvpns --info-all-user`: uji kedua bentuk di VPS; bila format output berubah, parser ikut rusak (cocokkan field yang dipakai handler).
  - Biner hilang (lite) → error edisi di semua tiga handler.
  - Akun diblokir/expired di DB → tercermin di `list`, dan create duplikat ditolak dengan alasan.
- **Fixing:**
  - Pertahankan fallback dua bentuk; tambah bentuk ketiga hanya bila terbukti ada di lapangan.

---

### Fase 13: `menu-api` — Gate Lisensi & Fetch Resiliency

- **Komponen Target:** `menu-api` (`gate`, loop fetch `install_api`).
- **Finding:**
  - Tanpa network / IP tak di DB / lisensi expired → exit sebelum mutasi; `lifetime` → lolos tanpa tanggal (Decision 28 panel).
  - Tiap `curl -fsSL` gagal → `FAILED to fetch ...` + return 1 (instalasi setengah jalan dilaporkan, bukan sukses). Uji dengan URL mati.
  - Stale-cache `raw.githubusercontent`: bila fetch gagal padahal file baru di-push, fallback ke URL commit-pinned atau jsDelivr (terdokumentasi di README).
  - Dependensi (`python3`, `jq`, `curl`) hilang dan apt gagal → gagal eksplisit.
- **Fixing:**
  - Fail-fast tiap fetch; jangan lanjutkan instalasi bila satu komponen gagal diunduh.

---

### Fase 14: `menu-api` — Unit Systemd, Token & Uninstall

- **Komponen Target:** `menu-api` (`install_api` unit, `token`/`rotate_token`, `uninstall_api`, `status_api`, TUI).
- **Finding:**
  - Unit `api.service`: wajib `Restart=always` + `RestartSec` wajar (anti spin); `daemon-reload` + `enable`; verifikasi active di akhir install; `User=root` (dibutuhkan skrip panel).
  - Token: 40 char acak, `0600`, hanya tampil di stdout installer (tidak di log file); `rotate_token` mengganti + restart + token lama langsung 401.
  - `status_api`: angka service/listen/handler/token-prefix cocok dengan kondisi nyata (tidak berbohong).
  - `uninstall`: stop+disable, hapus server/handlers/lib + symlink, `daemon-reload`; token dipertahankan (terdokumentasi); tidak ada sisa unit/process.
  - TUI: opsi `0` → exit 0; invalid → redisplay; EOF → keluar anggun; tiap aksi write di-gate lisensi.
- **Fixing:**
  - Lengkapi unit + verifikasi active; jangan hapus token saat uninstall.

---

### Fase 15: Restart Fan-Out — Coalescing per Batch

- **Komponen Target:** handler pemicu restart + (nantinya) mekanisme coalescing + unit `api.service`.
- **Latar (Found 329 di `fn-autosc`):** tiap panggilan API me-restart transport 1x; 6 delete paralel = 6 restart dalam hitungan detik → `start-limit-hit`. Mitigasi unit sudah di sisi panel; akar masalah ada di sini.
- **Finding:**
  - Ukur baseline: N panggilan paralel → hitung `Stopping xray@ws` di journal; catat N restart untuk N panggilan.
  - Rancang jendela batch: restart maksimal 1x per transport per jendela; request terakhir + jeda singkat = batas atas penundaan.
  - Pastikan restart tak hilang saat handler gagal, dan klaim sukses tiap panggilan tetap berbasis grep config.
- **Fixing (standar):**
  - Tandai transport kotor per panggilan; satu flusher me-restart tiap transport kotor tepat sekali. Tanpa thread, tanpa dependensi baru (single-threaded dipertahankan).
  - Kriteria lolos: burst 6 add + 6 delete paralel → semua sukses terverifikasi + 1 restart per transport + service tetap active tanpa `reset-failed` manual.

---

### Fase 16: Gerbang Regresi & Sinkron Docs

- **Komponen Target:** perubahan apa pun + `README.md` (tabel kontrak, contoh curl, bagian Coverage/Security).
- **Finding:**
  - Setiap fix wajib lulus 4-Check (Regression, Over-Strictness, Over-Engineering, Source Alignment) sebelum commit.
  - `README.md` wajib sinkron: endpoint baru/berubah → tabel kontrak + contoh; batasan baru → Coverage; perubahan threat model → Security.
  - Kontrak respons tunggal (`status`/`message`, 200-untuk-error-bisnis, 500-hanya-crash) tidak boleh retak oleh fix mana pun.
- **Fixing:**
  - Tulis/rapikan docs bersamaan dengan kode dalam commit atomik yang sama; commit message menyebut Found/Fix dan fase.
