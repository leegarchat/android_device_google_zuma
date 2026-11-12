#!/system/bin/sh
# SukiSU manager one-shot installer (user app, NOT a system app).
#
# Runs as an init oneshot service (root, ksu SELinux domain, see
# init.sukisu_manager.rc) triggered on sys.boot_completed=1.
#
# Bidirectional flavor switch, driven by release STATUS first, vercode
# second: the tree ships exactly ONE manager APK (stable
# com.resukisu.resukisu or dev com.resukisu.resukisu.dev, named
# <label>[_dev]_<vercode>.apk). Whichever flavor is bundled wins the
# channel — even when its vercode is LOWER than the installed other
# flavor (a dev build never vetoes a stable bundle and vice versa).
# Vercode comparison applies ONLY within the same flavor (never
# downgrade an installed newer build of the bundled flavor).
#   bundled dev 35260  vs installed stable 35171 -> switch to dev
#   bundled stable 35259 vs installed dev 35260  -> switch BACK to stable
#       (status parity beats vercode)
#   bundled == installed flavor+vercode          -> no-op (record key)
#   installed SAME-flavor newer than bundled     -> keep, no downgrade
#   bundled flavor missing + other flavor present -> channel switch:
#       install bundled even if HANDLED==VER (the key may be stale from
#       an older firmware generation); user-uninstall respect applies
#       only when NEITHER flavor is installed
#   bundled missing + nothing installed + HANDLED==VER -> respect, no install
#
# Settings migration: both flavors keep preferences in the same DataStore
# proto (files/datastore/app_preferences.preferences_pb, same keys incl.
# themes), so the file is copied, re-owned (whole files/ subtree —
# root-made dirs lack MLS categories or the app crash-loops) and
# relabeled. Only when the source file exists and the target one is
# missing or differs; both apps are force-stopped first so no live
# process rewrites it mid-copy. WebView prefs / caches / traces are
# deliberately NOT migrated.
#
# State: one Settings.Global key per flavor holding the last HANDLED
# vercode, so repeats are no-ops and a deliberate user uninstall of the
# ACTIVE flavor is respected (its key stays == VER). The inactive flavor
# is removed whenever present once the active one is OK, even if already
# handled before.
#
# Layout on device (read-only, from the build):
#   /system/etc/sukisu/*.apk   — exactly ONE manager APK
# State:
#   Settings.Global sukisu_manager_dev_handled_vercode    — dev flavor
#   Settings.Global sukisu_manager_handled_vercode        — stable flavor
#   /data/local/tmp/sukisu_manager_install.apk            — staging copy for pm
#
# Exit 0 = nothing to do (or done); exit 1 = something failed, retry next
# boot (the handled key is left untouched on install failure, so the next
# boot_completed trigger retries; the inactive flavor is left alone too).

TAG="sukisu-install"
STABLE_PKG="com.resukisu.resukisu"
DEV_PKG="com.resukisu.resukisu.dev"
STABLE_KEY="sukisu_manager_handled_vercode"
DEV_KEY="sukisu_manager_dev_handled_vercode"
APK_DIR="/system/etc/sukisu"
STAGE="/data/local/tmp/sukisu_manager_install.apk"
PROTO="files/datastore/app_preferences.preferences_pb"

log() {
    echo "$TAG: $*"
    # Mirror to logcat: stdio_to_kmsg goes only to the kernel buffer
    # (unreadable without root), this line is visible via `logcat -s`.
    command -p /system/bin/log -p i -t "$TAG" "$*" 2>/dev/null || true
}

is_installed() {
    pm list packages "$1" 2>/dev/null | grep -qx "package:$1"
}

installed_ver() {
    dumpsys package "$1" 2>/dev/null | grep -m1 'versionCode=' | sed 's/.*versionCode=\([0-9][0-9]*\).*/\1/'
}

pkg_uid() {
    # Owner uid of the app data dir; empty if never installed.
    stat -c %u "/data/user/0/$1" 2>/dev/null
}

# Exactly one bundled APK, named <label>[_dev]_<vercode>.apk
# (ReSukiSU_35171.apk = stable, ReSukiSU_dev_35260.apk = dev).
APK=""
for f in "$APK_DIR"/*.apk; do
    [ -f "$f" ] || continue
    if [ -n "$APK" ]; then
        log "more than one APK in $APK_DIR, using first match: $APK"
        break
    fi
    APK="$f"
done
if [ -z "$APK" ]; then
    log "no bundled APK in $APK_DIR, nothing to do"
    exit 0
fi
base="${APK##*/}"
VER="${base##*_}"
VER="${VER%.apk}"
case "$VER" in
    ''|*[!0-9]*)
        log "cannot parse vercode from $base, refusing to install"
        exit 1
        ;;
esac
case "$base" in
    *_dev_*) PKG="$DEV_PKG"; KEY="$DEV_KEY"; OTHER="$STABLE_PKG" ;;
    *)       PKG="$STABLE_PKG"; KEY="$STABLE_KEY"; OTHER="$DEV_PKG" ;;
esac
log "bundled $PKG vercode $VER ($base)"

mark_handled() {
    if settings put global "$KEY" "$VER" 2>/dev/null; then
        return 0
    fi
    log "failed to record $KEY=$VER, will retry next boot"
    return 1
}

HANDLED="$(settings get global "$KEY" 2>/dev/null)"
case "$HANDLED" in
    null|"") HANDLED="" ;;
esac

# --- Step 1: reconcile the ACTIVE (bundled) flavor ---
# Status first: the mere presence of the OTHER flavor means a channel
# switch is in progress (or the channel already flipped) — the bundled
# flavor gets installed no matter the vercodes or stale handled keys.
# Vercode is compared only against the SAME flavor.
B_INSTALLED=false
O_INSTALLED=false
is_installed "$PKG" && B_INSTALLED=true
is_installed "$OTHER" && O_INSTALLED=true

if $B_INSTALLED && ! $O_INSTALLED && [ "$HANDLED" = "$VER" ]; then
    log "already handled (global $KEY=$VER), nothing to do"
elif ! $B_INSTALLED && ! $O_INSTALLED && [ "$HANDLED" = "$VER" ]; then
    log "handled $VER but nothing installed (user uninstall?), respecting it"
    exit 0
else
    INST_VER="$(installed_ver "$PKG")"
    case "$INST_VER" in
        ''|*[!0-9]*) INST_VER="" ;;
    esac
    NEED_INSTALL=false

    if ! $B_INSTALLED && $O_INSTALLED; then
        # Channel switch: bundled flavor missing, other flavor present.
        # Install bundled unconditionally — its vercode may be lower
        # than the other's (release status beats version number), and
        # HANDLED may equal VER from an older firmware generation.
        log "channel switch: installing bundled $PKG vercode $VER over present $OTHER"
        NEED_INSTALL=true
    # Same version already on device (side-load, backup restore, ...):
    # just record it, don't reinstall.
    elif [ -n "$INST_VER" ] && [ "$INST_VER" = "$VER" ]; then
        log "package $PKG $VER already present, recording"
        mark_handled || exit 1
    # Same flavor newer on device: never downgrade, just record.
    elif [ -n "$INST_VER" ] && [ "$INST_VER" -gt "$VER" ] 2>/dev/null; then
        log "package $PKG $INST_VER newer than bundled $VER, keeping it"
        mark_handled || exit 1
    elif [ -n "$INST_VER" ]; then
        log "updating $PKG $INST_VER -> $VER from $APK"
        NEED_INSTALL=true
    else
        log "installing $PKG from $APK (vercode $VER)"
        NEED_INSTALL=true
    fi

    if $NEED_INSTALL; then
        cp "$APK" "$STAGE" 2>/dev/null || {
            log "staging copy failed"
            exit 1
        }

        if pm install -r "$STAGE" 2>&1; then
            rm -f "$STAGE"
            if is_installed "$PKG"; then
                log "install OK"
                mark_handled || exit 1
            else
                log "pm reported success but package missing afterwards"
            fi
        else
            log "pm install failed"
        fi
        rm -f "$STAGE"
    fi
fi

if ! is_installed "$PKG"; then
    log "active flavor not installed, keeping other for now; retry next boot"
    exit 1
fi

# --- Step 2: migrate settings inactive -> active ---
SRC_PROTO="/data/user/0/$OTHER/$PROTO"
DST_PROTO="/data/user/0/$PKG/$PROTO"
if [ -f "$SRC_PROTO" ]; then
    if [ ! -f "$DST_PROTO" ] || ! cmp -s "$SRC_PROTO" "$DST_PROTO"; then
        log "migrating settings $OTHER -> $PKG"
        am force-stop "$OTHER" 2>/dev/null
        am force-stop "$PKG" 2>/dev/null
        UID="$(pkg_uid "$PKG")"
        if [ -z "$UID" ]; then
            log "no data dir for $PKG yet, skipping migration"
        else
            mkdir -p "/data/user/0/$PKG/files/datastore" 2>/dev/null
            # mkdir as root leaves root-owned dirs (no MLS categories) that
            # the app cannot write to — re-own the whole files/ subtree.
            chown -R "$UID:$UID" "/data/user/0/$PKG/files" 2>/dev/null
            restorecon -R "/data/user/0/$PKG/files" 2>/dev/null
            if cp "$SRC_PROTO" "$DST_PROTO" 2>/dev/null \
                    && chown "$UID:$UID" "$DST_PROTO" 2>/dev/null \
                    && chmod 600 "$DST_PROTO" 2>/dev/null; then
                restorecon -R "/data/user/0/$PKG/files/datastore" 2>/dev/null
                if cmp -s "$SRC_PROTO" "$DST_PROTO"; then
                    log "settings migrated OK"
                else
                    log "settings copy verify failed"
                fi
            else
                log "settings copy failed"
            fi
        fi
    else
        log "settings already in sync, nothing to migrate"
    fi
else
    log "no $OTHER settings found, nothing to migrate"
fi

# --- Step 3: remove the inactive flavor (cannot coexist) ---
# Only when the active flavor is actually installed: if the user
# deliberately removed the active one, the inactive one is their choice
# and must be left alone.
if is_installed "$PKG"; then
    if is_installed "$OTHER"; then
        log "removing inactive flavor $OTHER"
        if pm uninstall "$OTHER" 2>&1; then
            if is_installed "$OTHER"; then
                log "uninstall reported success but package still present, retry next boot"
                exit 1
            fi
            log "inactive flavor removed"
        else
            log "inactive uninstall failed, retry next boot"
            exit 1
        fi
    else
        log "no inactive flavor installed"
    fi
else
    log "active flavor absent, keeping user's packages untouched"
fi

exit 0
