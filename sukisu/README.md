# SukiSU manager one-shot installer (zuma family)

Installs the reSukiSU manager as a regular
**user app** — never as a system app — on akita / husky / shiba, but only
for custom kernels whose prebuilt directory name contains `ksu`
(e.g. `shiba_wksu21`). Stock kernels get nothing.

Two flavors exist: stable (`com.resukisu.resukisu`) and dev
(`com.resukisu.resukisu.dev`). The tree ships exactly one APK; the
installer makes that flavor active (install/update), migrates settings
from the other one, and uninstalls it — two KSU managers cannot coexist.
Switching back and forth is just swapping the APK in the tree (see
"Bumping"), migration works both ways (same DataStore proto, same keys).

## Files

| File | Installed to | Purpose |
|---|---|---|
| `ReSukiSU[_dev]_<vercode>.apk` | `/system/etc/sukisu/` | Inert manager copy. Not scanned as an app (only `app/`/`priv-app/` are scanned) |
| `install_manager.sh` | `/system/etc/sukisu/` | Installer script, run by init |
| `init.sukisu_manager.rc` | `/vendor/etc/init/` | Oneshot service + `boot_completed` trigger (auto-imported) |
| `sukisu.mk` | (build only) | `PRODUCT_COPY_FILES`, self-gated on ksu kernel |
| `README.md` | — | this file |

`device/google/zuma/common.mk` includes `sukisu.mk` (akita/husky/shiba all
include `common.mk` after `TARGET_KERNEL_DIR` is resolved).

## How it works

1. Every boot that reaches `sys.boot_completed=1` (first boot after setup,
   first boot after OTA, ...) init starts the disabled oneshot service
   `sukisu_manager_install` → `/system/bin/sh install_manager.sh` as root
   in the `ksu` domain (`seclabel u:r:ksu:s0`, patched in by the KSU
   kernel itself).
2. The script (`pm install -r`, staged via `/data/local/tmp` like `adb
   install` does) installs or updates the bundled flavor silently, then
   records the vercode in that flavor's `Settings.Global` key
   (`sukisu_manager_handled_vercode` stable,
   `sukisu_manager_dev_handled_vercode` dev).
3. Key == VER → no-op (unless the other flavor is still around — it gets
   removed). Installed versionCode == VER (side-load, backup restore) →
   just record key. Installed newer than bundled → keep it, no downgrade,
   record key. Installed older/missing → `pm install -r` (update or fresh
   install). Install failed → key untouched, other flavor kept, retry next
   boot. User uninstall of the active flavor after handling → key stays ==
   VER → respected, no reinstall.
4. Settings migration inactive → active: both flavors keep preferences in
   the same DataStore proto (`files/datastore/app_preferences.preferences_pb`,
   same keys incl. themes), so the file is copied over, re-owned (whole
   `files/` subtree — root-made dirs lack MLS categories or the app
   crash-loops) and relabeled. Only when the source file exists and the
   target one is missing or differs; both apps are force-stopped first.
   WebView prefs / caches / traces are deliberately NOT migrated.
5. Inactive flavor removal: `pm uninstall` the other package. Only after
   the active flavor is confirmed installed; failure retries next boot.
   If the active install failed, the other flavor is left alone.

## Bumping the manager

Replace the APK, keeping the `<label>_<vercode>.apk` naming (the script
parses vercode from the filename and compares it against both the
Settings key and the installed versionCode, so a newer build updates
exactly once). Nothing else to edit. State from the old
`com.resukisu.resukisu` flow (key `sukisu_manager_handled_vercode`) is
simply abandoned — the new flow uses its own key and reconciles from
the real package state (same version → record key, older → update,
newer → keep).

## SELinux: why seclabel u:r:ksu:s0

The service runs `/system/bin/sh` with `seclabel u:r:ksu:s0`. Without a
seclabel, init needs an `init -> shell` transition on exec of
`shell_exec` — which does not exist on user builds, and vendor policy
cannot mint core-only transitions (proven on-device: a
`domain_trans(init, shell_exec, shell)` in `sepolicy/vendor/` compiles to
allows without the `typetransition`, and manual `start` aborts with
`Could not ctl.start ... no domain transition from u:r:init:s0`).

The KSU kernel patches its own `init -> ksu` transition at boot (it
starts ksud itself via `exec u:r:ksu:s0 root -- /data/adb/ksud ...` —
visible as strings in the kernel image), so the installer service
reuses the KSU-exclusive context. Verified on-device by replacing the rc
in recovery: service runs to `stopped`, key recorded, manager installed.
KSU kernels only (see `sukisu.mk` gate); stock kernels get no files.

## Verification (after flashing a ksu build)

- `ls /system/etc/sukisu/` — APK + script present; stock-kernel build: absent.
- Handled key for the bundled flavor (`sukisu_manager_handled_vercode`
  stable / `sukisu_manager_dev_handled_vercode` dev) holds the vercode
  after first boot.
- Bundled package present as a user app (`dumpsys package <pkg> |
  grep -i system` → empty / `codePath` under `/data/app`).
- The other flavor absent; themes/settings carried over.
- `logcat -s sukisu-install` shows install/migrate/remove lines on first
  boot, `already handled` afterwards (script mirrors every line to
  logcat; `stdio_to_kmsg` alone is only readable with root).
