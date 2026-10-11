# SukiSU manager one-shot installer (zuma family)

Installs the reSukiSU manager (`com.resukisu.resukisu`, vercode 35171,
v4.2.0-rc3) exactly once as a regular
**user app** — never as a system app — on akita / husky / shiba, but only
for custom kernels whose prebuilt directory name contains `ksu`
(e.g. `shiba_cp2a_005_wksu_avgust`). Stock kernels get nothing.

## Files

| File | Installed to | Purpose |
|---|---|---|
| `SukiSU_35171.apk` | `/system/etc/sukisu/` | Inert manager copy. Not scanned as an app (only `app/`/`priv-app/` are scanned) |
| `install_manager.sh` | `/system/etc/sukisu/` | Installer script, run by init |
| `init.sukisu_manager.rc` | `/vendor/etc/init/` | Oneshot service + `boot_completed` trigger (auto-imported) |
| `sukisu.mk` | (build only) | `PRODUCT_COPY_FILES`, self-gated on ksu kernel |
| `../sepolicy/vendor/sukisu_install.te` | (policy only) | **Required**: re-applies `domain_trans(init, shell_exec, shell)` — see below |
| `README.md` | — | this file |

`device/google/zuma/common.mk` includes `sukisu.mk` (akita/husky/shiba all
include `common.mk` after `TARGET_KERNEL_DIR` is resolved).

## How it works

1. Every boot that reaches `sys.boot_completed=1` (first boot after setup,
   first boot after OTA, ...) init starts the disabled oneshot service
   `sukisu_manager_install` → `/system/bin/sh install_manager.sh` as root.
2. No `seclabel` on purpose: init executes `shell_exec` and the stock
   `domain_trans(init, shell_exec, shell)` policy moves the script into the
   shell domain — exactly the context `adb install` / `pm install` runs in.
   (An explicit seclabel would need an init→domain transition rule stock
   policy does not ship; staying in init context cannot exec `app_process`
   at all — `zygote_exec` has no init transition. Verified against
   `system/sepolicy/private/init.te`, `te_macros`, `service.cpp`.)
3. The script (`pm install -r`, staged via `/data/local/tmp` like `adb
   install` does) installs or updates the manager silently, then records
   the vercode in `Settings.Global sukisu_manager_handled_vercode`.
4. Key == VER → no-op. Installed versionCode == VER (side-load, backup
   restore) → just record key. Installed newer than bundled → keep it, no
   downgrade, record key. Installed older/missing → `pm install -r`
   (update or fresh install). Install failed → key untouched, retry next
   boot. User uninstall after handling → key stays == VER → respected,
   no reinstall.

## Bumping the manager

Replace the APK, keeping the `<label>_<vercode>.apk` naming (the script
parses vercode from the filename and compares it against both the
Settings key and the installed versionCode, so a newer build updates
exactly once). Nothing else to edit. No manual migration: devices that
still carry the old `/data/local/tmp/sukisu/manager_*.installed` file-flag
are handled naturally — first run with the new script sees key != VER and
reconciles from the real package state (same version → record key, older →
update, newer → keep).

## SELinux: why sukisu_install.te exists

The service runs `/system/bin/sh` with no `seclabel`, so init needs a
`init -> shell` domain transition on exec. The stock
`domain_trans(init, shell_exec, shell)` (system/sepolicy) has no effect in
this build — proven on-device: after a clean flash + reboot, init parses
the `.rc`, fires the trigger at `boot_completed`, then aborts (dmesg):

> Could not start service: File /system/bin/sh (labeled
> "u:object_r:shell_exec:s0") has incorrect label or no domain transition
> from u:r:init:s0 ...

`../sepolicy/vendor/sukisu_install.te` re-applies exactly that stock
expansion (no neverallow covers it). Without it the service can never
start: no install, no Settings key, no error in logcat (only the dmesg line).

If a future base-policy update restores the stock rule, the build fails
loudly with a duplicate `type_transition` error — that means the `.te`
file is obsolete and can be deleted.

## Verification (after flashing a ksu build)

- `ls /system/etc/sukisu/` — APK + script present; stock-kernel build: absent.
- `settings get global sukisu_manager_handled_vercode` — `35171` after first boot.
- `pm list packages com.resukisu.resukisu` — present, and it is a user app
  (`dumpsys package com.resukisu.resukisu | grep -i system` → empty / `codePath`
  under `/data/app`).
- `logcat -s` / `dmesg | grep sukisu-install` — `install OK` on first boot,
  `already handled` afterwards.
- Note: supersedes the old `com.sukisu.ultra` (vercode 40900) build — the old
  manager is NOT auto-uninstalled, remove it manually if both end up installed.
