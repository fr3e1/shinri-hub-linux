#!/usr/bin/env bash
# shinri-hub-setup.sh — install Shinri Trial Hub on Linux using Steam's Proton.
#
# Works on Debian/Ubuntu, Fedora, Arch and openSUSE (and their derivatives).
# Requirements: Steam (distro package or Valve's .deb, logged in), Garry's Mod installed
# and launched at least once with Proton, python3, curl or wget, and 7-Zip with NSIS
# support. Missing packages are offered for install with the system package manager.
#
# Why it can't just run the installer: the Windows installer's "is the app
# running?" PowerShell check always fails under Wine. Also, the hub needs to see
# Steam and GMod, so it is installed into Garry's Mod's Proton prefix
# (compatdata/4000), where Proton provides a Windows steam.exe connected to
# Linux Steam. Three extra things the hub's launch check needs are added:
#   * an ActiveUser value in the prefix's Steam registry key
#   * a process named steamwebhelper.exe (a renamed copy of Wine's ping.exe)
#   * a tasklist wrapper, because Wine's tasklist output can't be parsed by the hub
#
# One-line install:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/fr3e1/shinri-hub-linux/main/shinri-hub-setup.sh)"
#
# Usage:
#   shinri-hub-setup.sh                      download the latest hub and install it
#   shinri-hub-setup.sh --installer FILE     install from a local "Shinri Hub Setup *.exe"
#   shinri-hub-setup.sh --update             reinstall only if a newer hub version exists
#   shinri-hub-setup.sh --check              only run the checks, change nothing
#   shinri-hub-setup.sh --uninstall [--purge]  remove it (--purge also deletes hub settings and logs)
#
# Environment: SHINRI_WM_DECORATIONS=1 keeps window-manager title bars on Wine windows
# (by default they're turned off in GMod's prefix to fix offset mouse clicks on KDE/Wayland).
#
# Note: while the hub is open, Steam shows Garry's Mod as running, so you can't also start
# plain GMod from Steam. Quit the hub (including from the tray) first.

set -euo pipefail

FEED="https://storage.shinri.red/hub"
REPO_RAW="${SHINRI_REPO_RAW:-https://raw.githubusercontent.com/fr3e1/shinri-hub-linux/main}"
APPID=4000
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/shinri-hub"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/shinri-hub"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/shinri-hub"
BIN="$HOME/.local/bin/shinri-hub"
DESKTOP="${XDG_DATA_HOME:-$HOME/.local/share}/applications/shinri-hub.desktop"
ICON="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps/shinri-hub.png"

c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_dim=$'\e[2m'; c_off=$'\e[0m'
[ -t 1 ] || { c_ok=; c_warn=; c_err=; c_dim=; c_off=; }
say()  { printf '%s==>%s %s\n' "$c_ok" "$c_off" "$*"; }
info() { printf '    %s%s%s\n' "$c_dim" "$*" "$c_off"; }
warn() { printf '%swarning:%s %s\n' "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

MODE=install INSTALLER="" PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --installer) INSTALLER="${2:?--installer needs a file}"; shift ;;
    --update) MODE=update ;;
    --check) MODE=check ;;
    --uninstall) MODE=uninstall ;;
    --purge) PURGE=1 ;;
    -h|--help) awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,"");print}' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

[ "$(id -u)" -ne 0 ] || die "run this as your normal user, not root"

py() { python3 -I - "$@"; }

# ---------------------------------------------------------------- uninstall
if [ "$MODE" = uninstall ]; then
  if [ -f "$CONF_DIR/config.sh" ]; then
    # shellcheck disable=SC1091
    . "$CONF_DIR/config.sh"
    if pgrep -f '^C:.Program Files.Shinri Hub.Shinri Hub[.]exe' >/dev/null; then die "close Shinri Hub first"; fi
    say "Removing hub files from the GMod prefix"
    rm -rf -- "$PFX/drive_c/Program Files/Shinri Hub" "$PFX/drive_c/Program Files/Shinri Hub Linux"
    for w in "$PROTON/files/bin/wine" "$PROTON/dist/bin/wine"; do
      [ -x "$w" ] && { WINEPREFIX="$PFX" "$w" reg delete 'HKCU\Software\Wine\X11 Driver' /v Decorated /f >/dev/null 2>&1 || true; break; }
    done
    if [ "$PURGE" = 1 ]; then
      say "Removing hub settings and logs"
      rm -rf -- "$PFX/drive_c/users/steamuser/AppData/Roaming/st-hub" \
                "$PFX/drive_c/users/steamuser/AppData/Roaming/Shinri Trial"
    fi
  else
    warn "no config at $CONF_DIR/config.sh; removing only the launcher files"
  fi
  rm -f -- "$BIN" "$DESKTOP" "$ICON"
  rm -rf -- "$DATA_DIR" "$CONF_DIR" "$CACHE_DIR"
  command -v update-desktop-database >/dev/null && update-desktop-database -q "$(dirname "$DESKTOP")" 2>/dev/null || true
  say "Uninstalled. (GMod and its Proton prefix were not touched.)"
  exit 0
fi

# ---------------------------------------------------------------- basic tools
say "Checking requirements"
[ "$(uname -m)" = x86_64 ] || die "Shinri Hub needs an x86_64 machine (this is $(uname -m))"

# Distro family, for package names and install commands (Debian/Ubuntu, Fedora, Arch, openSUSE)
DISTRO=unknown DISTRO_NAME="your distro" IMMUTABLE=0
OS_RELEASE=${SHINRI_OS_RELEASE:-/etc/os-release}
if [ -r "$OS_RELEASE" ]; then
  # shellcheck disable=SC1090
  OS_IDS=$(. "$OS_RELEASE"; echo "${ID:-} ${ID_LIKE:-}")
  DISTRO_NAME=$(. "$OS_RELEASE"; echo "${PRETTY_NAME:-${NAME:-Linux}}")
  case " $OS_IDS " in
    *" arch "*|*" steamos "*) DISTRO=arch ;;
    *" fedora "*|*" rhel "*|*" centos "*) DISTRO=fedora ;;
    *" debian "*|*" ubuntu "*) DISTRO=debian ;;
    *suse*|*" sles "*) DISTRO=suse ;;
  esac
  case " $OS_IDS " in *" steamos "*) IMMUTABLE=1 ;; esac
fi
[ -e /run/ostree-booted ] && IMMUTABLE=1   # Silverblue, Kinoite, Bazzite, …
pkg_cmd() { # prints the install command for the given packages
  case "$DISTRO" in
    debian) echo "sudo apt-get install -y $*" ;;
    fedora) echo "sudo dnf install -y $*" ;;
    arch)   echo "sudo pacman -S --needed --noconfirm $*" ;;
    suse)   echo "sudo zypper --non-interactive install $*" ;;
    *)      echo "" ;;
  esac
}
pkg_name() { # tool -> package names to try, best first ("a|b c" = try "a", then "b c")
  case "$DISTRO:$1" in
    debian:7zip) echo "7zip|p7zip-full" ;;   fedora:7zip) echo "7zip|p7zip p7zip-plugins" ;;
    arch:7zip)   echo "7zip|p7zip" ;;        suse:7zip)   echo "7zip|p7zip-full" ;;
    arch:python3) echo "python" ;;           *:python3)   echo "python3" ;;
    debian:pgrep|suse:pgrep) echo "procps" ;; *:pgrep)    echo "procps-ng" ;;
    *:curl) echo "curl" ;;
    *) echo "$1" ;;
  esac
}
# Offer to install a missing tool with the system package manager (asks first)
offer_install() { # tool, reason
  local tool=$1 why=$2 alts cmd ans
  alts=$(pkg_name "$tool")
  cmd=$(pkg_cmd "${alts%%|*}")
  if [ "$IMMUTABLE" = 1 ] || [ -z "$cmd" ]; then
    die "$why
    $DISTRO_NAME: install '${alts%%|*}' with your system's usual method (on immutable systems,
    e.g. rpm-ostree install, or run this script inside a distrobox), then rerun this script."
  fi
  if [ "${SHINRI_ASSUME_YES:-0}" != 1 ]; then
    if [ ! -t 0 ] || [ ! -t 1 ]; then die "$why
    Install it with:  $cmd
    then rerun this script."; fi
    printf '%s\n' "$why" >&2
    read -r -p "    Install it now with '$cmd'? [Y/n] " ans
    case "$ans" in ""|[Yy]*) ;; *) die "Install it with:  $cmd   then rerun this script." ;; esac
  fi
  [ "$DISTRO" = debian ] && { sudo apt-get update -qq || true; }
  local p rest=$alts
  while [ -n "$rest" ]; do
    p=${rest%%|*}; [ "$p" = "$rest" ] && rest="" || rest=${rest#*|}
    eval "$(pkg_cmd "$p")" && return 0      # package names are fixed strings from pkg_name
    warn "installing '$p' failed${rest:+, trying '${rest%%|*}'}"
  done
  die "couldn't install ${alts%%|*}; install it manually and rerun this script"
}

command -v python3 >/dev/null || offer_install python3 "python3 is required."
python3 -c 'import sys; sys.exit(sys.version_info < (3, 6))' || die "python3 3.6 or newer is required"
command -v pgrep >/dev/null || offer_install pgrep "pgrep (procps) is required."
for t in realpath mktemp awk sed grep; do
  command -v "$t" >/dev/null || die "'$t' is missing; install your distro's coreutils/awk/sed/grep packages"
done
command -v curl >/dev/null || command -v wget >/dev/null || offer_install curl "curl (or wget) is required to download the hub."

# 7-Zip that can open NSIS installers (p7zip's standalone 7za can't)
SEVENZ=""
find_7zip() {
  SEVENZ=""
  for c in 7zz 7z 7za; do
    command -v "$c" >/dev/null || continue
    if "$c" i 2>/dev/null | grep -i nsis >/dev/null; then SEVENZ=$c; return 0; fi
  done
  return 1
}
if ! find_7zip && [ "$MODE" != check ]; then
  offer_install 7zip "7-Zip (with NSIS support) is required to unpack the Windows installer."
  find_7zip || die "7-Zip was installed but none of 7zz/7z/7za can open NSIS installers.
    On Fedora install p7zip-plugins; on Debian/Ubuntu install 7zip or p7zip-full."
fi
fetch() { # url outfile
  if command -v curl >/dev/null; then curl -fL --retry 3 --connect-timeout 15 -o "$2" "$1"
  elif command -v wget >/dev/null; then wget -q --show-progress -O "$2" "$1"
  else die "curl or wget is required"; fi
}
fetch_text() { # url  (short timeout, to stdout)
  if command -v curl >/dev/null; then curl -fsSL --max-time 15 "$1"
  else wget -qO- --timeout=15 "$1"; fi
}

# ---------------------------------------------------------------- Steam
STEAM="" STEAM_KIND=native
for d in "$HOME/.local/share/Steam" "$HOME/.steam/debian-installation" "$HOME/.steam/steam" "$HOME/.steam/root" \
         "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam" \
         "$HOME/snap/steam/common/.local/share/Steam"; do
  if [ -f "$d/steamapps/libraryfolders.vdf" ] || [ -f "$d/config/libraryfolders.vdf" ]; then
    STEAM=$(realpath "$d"); break
  fi
done
[ -n "$STEAM" ] || die "Steam not found. Install Steam, log in, and install Garry's Mod first."
case "$STEAM" in
  */.var/app/com.valvesoftware.Steam/*) STEAM_KIND=flatpak ;;
  */snap/steam/*) STEAM_KIND=snap ;;
esac
info "Steam: $STEAM ($STEAM_KIND)"
[ "$STEAM_KIND" = native ] || warn "$STEAM_KIND Steam is only partly supported; native Steam is recommended."

# ---------------------------------------------------------------- GMod, prefix, Proton, Steam user
# Prints shell assignments: GMOD=, COMPAT=, PROTON=, ACTIVE_USER=
GMOD="" COMPAT="" PROTON="" PROTON_WANT="" ACTIVE_USER=1 RUNTIME="" RUNTIME_APPID="" LIBRARIES=""
detect_env() {
py "$@" <<'PY'
import os, re, sys, glob, shlex
steam, appid = sys.argv[1], sys.argv[2]
def read(p):
    try: return open(p, encoding="utf-8", errors="replace").read()
    except OSError: return ""
def out(k, v): print(f"{k}={shlex.quote(v)}")

# libraries
libs = [steam]
for f in (f"{steam}/steamapps/libraryfolders.vdf", f"{steam}/config/libraryfolders.vdf"):
    libs += re.findall(r'"path"\s+"([^"]+)"', read(f))
seen, L = set(), []
for l in libs:
    l = os.path.realpath(l.replace("\\\\", "\\"))
    if l not in seen and os.path.isdir(f"{l}/steamapps"): seen.add(l); L.append(l)

gmod = compat = ""
for l in L:
    acf = read(f"{l}/steamapps/appmanifest_{appid}.acf")
    if acf:
        m = re.search(r'"installdir"\s+"([^"]+)"', acf)
        gmod = f"{l}/steamapps/common/{m.group(1) if m else 'GarrysMod'}"
        break
for l in L:
    if os.path.isdir(f"{l}/steamapps/compatdata/{appid}/pfx"):
        compat = f"{l}/steamapps/compatdata/{appid}"; break
out("GMOD", gmod); out("COMPAT", compat)

# Proton: the tool Steam uses for GMod, else one matching the prefix version, else the newest
cands = []
for base in [f"{l}/steamapps/common" for l in L] + [f"{steam}/compatibilitytools.d",
             os.path.expanduser("~/.steam/root/compatibilitytools.d"),
             "/usr/share/steam/compatibilitytools.d"]:
    cands += [os.path.dirname(p) for p in glob.glob(f"{base}/*/proton")]
cands = list(dict.fromkeys(cands))
def name(d): return os.path.basename(d)

cfg = read(f"{steam}/config/config.vdf")
want = ""
i = cfg.find('"CompatToolMapping"')
if i >= 0:
    sect = cfg[i:]
    for key in (appid, "0"):
        m = re.search(r'"%s"\s*\{[^}]*?"name"\s+"([^"]*)"' % key, sect)
        if m and m.group(1): want = m.group(1); break

def pick_by_tool(t):
    for d in cands:
        if name(d) == t: return d
    if t == "proton_experimental": pats = [r"^Proton - Experimental$"]
    elif t == "proton_hotfix": pats = [r"^Proton Hotfix$"]
    else:
        m = re.fullmatch(r"proton_(\d+)", t)
        pats = [r"^Proton %s\.\d+$" % m.group(1), r"^Proton %s\." % m.group(1)] if m else []
    for p in pats:
        for d in cands:
            if re.search(p, name(d)): return d
    return ""

proton = pick_by_tool(want) if want else ""
if not proton and compat:
    v = read(f"{compat}/version").strip()           # e.g. 11.0-100
    mm = re.match(r"(\d+\.\d+)", v)
    if mm:
        for d in cands:
            if re.search(r"proton-%s\b" % re.escape(mm.group(1)), read(f"{d}/version")) or \
               re.fullmatch(r"Proton %s" % re.escape(mm.group(1)), name(d)):
                proton = d; break
if not proton:
    def key(d):
        m = re.search(r"(\d+)\.(\d+)", name(d))
        return (1 if m else 0, int(m.group(1)) if m else 0, int(m.group(2)) if m else 0)
    numbered = sorted([d for d in cands if name(d).startswith("Proton ")], key=key)
    proton = numbered[-1] if numbered else (cands[0] if cands else "")
out("PROTON", proton); out("PROTON_WANT", want)

# Steam Linux Runtime container the Proton build requires (Steam runs Proton inside it)
runtime = ""
m = re.search(r'"require_tool_appid"\s+"(\d+)"', read(f"{proton}/toolmanifest.vdf")) if proton else None
if m:
    for l in L:
        acf = read(f"{l}/steamapps/appmanifest_{m.group(1)}.acf")
        d = re.search(r'"installdir"\s+"([^"]+)"', acf)
        if d and os.path.exists(f"{l}/steamapps/common/{d.group(1)}/_v2-entry-point"):
            runtime = f"{l}/steamapps/common/{d.group(1)}"; break
out("RUNTIME", runtime); out("RUNTIME_APPID", m.group(1) if m else "")
out("LIBRARIES", ":".join(L))

# Steam user for ActiveUser (most recent login)
lu = read(f"{steam}/config/loginusers.vdf")
best, best_ts, first = 0, -1, 0
for m in re.finditer(r'"(\d{17})"\s*\{([^}]*)\}', lu):
    acc = int(m.group(1)) - 76561197960265728
    body = m.group(2)
    first = first or acc
    if re.search(r'"mostrecent"\s+"1"', body, re.I): best = acc; break
    ts = re.search(r'"timestamp"\s+"(\d+)"', body, re.I)
    if ts and int(ts.group(1)) > best_ts: best_ts, best = int(ts.group(1)), acc
out("ACTIVE_USER", str(best or first or 1))
PY
}
DETECTED=$(detect_env "$STEAM" "$APPID") || die "failed to read Steam's config files"
eval "$DETECTED"

[ -n "$GMOD" ] && [ -d "$GMOD" ] || die "Garry's Mod (app $APPID) is not installed in any Steam library. Install it in Steam first."
info "Garry's Mod: $GMOD"
if [ ! -e "$GMOD/gmod.exe" ] && [ ! -e "$GMOD/hl2.exe" ]; then
  die "Garry's Mod is installed as the Linux build, but the hub needs the Windows build.
    In Steam: Garry's Mod > Properties > Compatibility > tick 'Force the use of a specific
    Steam Play compatibility tool', pick a Proton version, let Steam update the game,
    launch GMod once, quit it, then rerun this script."
fi
[ -n "$COMPAT" ] && [ -d "$COMPAT/pfx/drive_c" ] || die "GMod's Proton prefix does not exist yet.
    Launch Garry's Mod once from Steam (with Proton), quit it, then rerun this script."
PFX="$COMPAT/pfx"
info "Proton prefix: $COMPAT"
[ -e "$PFX/drive_c/Program Files (x86)/Steam/steam.exe" ] || \
  warn "the prefix has no steam.exe yet; launch GMod once from Steam to finish setting it up"
[ -n "$PROTON" ] && [ -x "$PROTON/proton" ] || die "no Proton found. In Steam, install 'Proton' (search your Library for Proton) and run GMod once with it."
info "Proton: $PROTON${PROTON_WANT:+ (set for GMod in Steam: $PROTON_WANT)}"
if [ -n "$RUNTIME" ]; then
  info "Steam Linux Runtime: $RUNTIME"
elif [ -n "$RUNTIME_APPID" ]; then
  warn "this Proton needs Steam Linux Runtime (app $RUNTIME_APPID), which isn't installed; running Proton directly.
    Launching Garry's Mod once from Steam installs it; then rerun this script."
fi
info "Steam account for ActiveUser: $ACTIVE_USER"
PING="$PFX/drive_c/windows/system32/ping.exe"
[ -f "$PING" ] || die "ping.exe missing from the prefix ($PING); try launching GMod once to repair it"
pgrep -x steam >/dev/null || pgrep -f 'steamwebhelper' >/dev/null || warn "Steam isn't running right now; it must be running and logged in when you use the hub."

if [ "$MODE" = check ]; then
  [ -n "$SEVENZ" ] || warn "7-Zip is missing (needed to install)"
  if [ -f "$DATA_DIR/version" ]; then info "Installed hub version: $(cat "$DATA_DIR/version")"; else info "Hub not installed yet"; fi
  say "All checks passed"; exit 0
fi

# ---------------------------------------------------------------- get installer
mkdir -p "$DATA_DIR" "$CONF_DIR" "$CACHE_DIR"
INSTALLED_VER=$(cat "$DATA_DIR/version" 2>/dev/null || true)
VERSION="" SHA512=""

if [ -z "$INSTALLER" ]; then
  say "Checking the latest hub version"
  YML=$(fetch_text "$FEED/latest.yml") || die "couldn't reach $FEED/latest.yml (offline?). Use --installer FILE instead."
  VERSION=$(printf '%s\n' "$YML" | awk '/^version:/{sub(/^version: */,""); print; exit}')
  FILE=$(printf '%s\n' "$YML" | awk '/^path:/{sub(/^path: */,""); print; exit}')
  SHA512=$(printf '%s\n' "$YML" | awk '/^sha512:/{sub(/^sha512: */,""); print; exit}')
  [ -n "$VERSION" ] && [ -n "$FILE" ] && [ -n "$SHA512" ] || die "unexpected update feed format"
  info "Latest: $VERSION${INSTALLED_VER:+, installed: $INSTALLED_VER}"
  if [ "$MODE" = update ] && [ "$VERSION" = "$INSTALLED_VER" ]; then say "Already up to date"; exit 0; fi
  INSTALLER="$CACHE_DIR/$FILE"
  # reuse a copy already in ~/Downloads if present
  for d in "$CACHE_DIR" "$HOME/Downloads" "$HOME/Downloads/Software"; do
    [ -f "$d/$FILE" ] && { INSTALLER="$d/$FILE"; break; }
  done
  if [ ! -f "$INSTALLER" ]; then
    say "Downloading $FILE"
    fetch "$FEED/$(py "$FILE" <<<'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))')" "$INSTALLER.part"
    mv -f "$INSTALLER.part" "$INSTALLER"
  fi
  say "Verifying download"
  py "$INSTALLER" "$SHA512" <<'PY' || { rm -f "$CACHE_DIR/$FILE"; die "checksum mismatch for $INSTALLER (deleted cached copy, rerun to download again)"; }
import sys, hashlib, base64
h = hashlib.sha512()
with open(sys.argv[1], "rb") as f:
    for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
sys.exit(0 if base64.b64encode(h.digest()).decode() == sys.argv[2] else 1)
PY
else
  [ -f "$INSTALLER" ] || die "installer not found: $INSTALLER"
  INSTALLER=$(realpath "$INSTALLER")
  VERSION=$(basename "$INSTALLER" | sed -n 's/.*Setup \([0-9][0-9.]*\)\.exe$/\1/p')
  VERSION=${VERSION:-unknown}
  warn "using a local installer without checksum verification: $INSTALLER"
fi

# ---------------------------------------------------------------- extract
if pgrep -f '^C:.Program Files.Shinri Hub.Shinri Hub[.]exe' >/dev/null; then die "Shinri Hub is running. Close it (also from the tray icon) and rerun."; fi
say "Unpacking installer"
TMP=$(mktemp -d "$CACHE_DIR/extract.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT
"$SEVENZ" x -y -bso0 -bsp0 -o"$TMP/nsis" "$INSTALLER" '$PLUGINSDIR/app-64.7z' >/dev/null \
  || die "couldn't unpack the installer (is it a Shinri Hub Setup .exe?)"
[ -f "$TMP/nsis/\$PLUGINSDIR/app-64.7z" ] || die "installer has no app-64.7z payload; its format may have changed"
"$SEVENZ" x -y -bso0 -bsp0 -o"$TMP/app" "$TMP/nsis/\$PLUGINSDIR/app-64.7z" >/dev/null || die "couldn't unpack the app payload"
[ -f "$TMP/app/Shinri Hub.exe" ] || die "unpacked app has no 'Shinri Hub.exe'; its format may have changed"

# ---------------------------------------------------------------- install into prefix
APP="$PFX/drive_c/Program Files/Shinri Hub"
SHIM="$PFX/drive_c/Program Files/Shinri Hub Linux"
say "Installing into the GMod prefix"
if [ -e "$APP" ] && [ ! -f "$APP/Shinri Hub.exe" ]; then die "$APP exists but doesn't look like Shinri Hub; refusing to overwrite it"; fi
rm -rf -- "$APP"
mkdir -p "$(dirname "$APP")"
mv "$TMP/app" "$APP"

# Shim files (kept outside the app folder so hub reinstalls don't wipe them):
#  steamwebhelper.exe  renamed Wine ping.exe; the hub's "is Steam running" check looks for this process
#  tasklist.bat/tl.js  Wine's tasklist writes UTF-16 + LF when no console is attached, but the hub
#                      parses ANSI + CRLF and would see no processes (STEAM_NOT_RUNNING). These run
#                      the real tasklist through the hub's own Node runtime and convert the output.
#  launch.bat          puts the shim first on PATH, sets ActiveUser, turns off WM decorations
#                      (KDE/XWayland clicks land offset otherwise), starts the helper, runs the hub
say "Writing Linux compatibility shim"
rm -rf -- "$SHIM"
mkdir -p "$SHIM"
cp -f "$PING" "$SHIM/steamwebhelper.exe"
cat > "$SHIM/tl.js" <<'EOF'
// Generated by shinri-hub-setup.sh. Wine's tasklist writes UTF-16LE + LF when no console is
// attached; Shinri Hub splits its output on CRLF and expects ANSI. Re-encode it.
const { spawnSync } = require('child_process');
const r = spawnSync('C:\\windows\\system32\\tasklist.exe', process.argv.slice(2), { windowsHide: true });
const conv = b => {
  if (!b || !b.length) return '';
  let s = (b.length > 1 && b.indexOf(0) !== -1) ? b.toString('utf16le') : b.toString('latin1');
  if (s.charCodeAt(0) === 0xfeff) s = s.slice(1);
  return s.replace(/\r?\n/g, '\r\n');
};
process.stdout.write(Buffer.from(conv(r.stdout), 'latin1'));
process.stderr.write(Buffer.from(conv(r.stderr), 'latin1'));
process.exitCode = r.status ?? 1;
EOF
printf '%s\r\n' '@echo off' 'setlocal' 'set ELECTRON_RUN_AS_NODE=1' \
  '"C:\Program Files\Shinri Hub\Shinri Hub.exe" "C:\Program Files\Shinri Hub Linux\tl.js" %*' \
  'exit /b %ERRORLEVEL%' > "$SHIM/tasklist.bat"
DECOR_LINE='reg add "HKCU\Software\Wine\X11 Driver" /v Decorated /t REG_SZ /d N /f >nul'
[ "${SHINRI_WM_DECORATIONS:-0}" = 1 ] && DECOR_LINE='rem WM decorations left on (SHINRI_WM_DECORATIONS=1)'
{
  printf '%s\r\n' '@echo off'
  printf '%s\r\n' 'rem Generated by shinri-hub-setup.sh; rerun it to regenerate.'
  printf '%s\r\n' 'set "PATH=C:\Program Files\Shinri Hub Linux;%PATH%"'
  printf '%s\r\n' "reg add \"HKCU\\Software\\Valve\\Steam\\ActiveProcess\" /v ActiveUser /t REG_DWORD /d $ACTIVE_USER /f >nul"
  printf '%s\r\n' "$DECOR_LINE"
  printf '%s\r\n' 'start "" /b "C:\Program Files\Shinri Hub Linux\steamwebhelper.exe" -n 999999 127.0.0.1 >nul'
  printf '%s\r\n' '"C:\Program Files\Shinri Hub\Shinri Hub.exe" %*'
  printf '%s\r\n' 'taskkill /f /im steamwebhelper.exe >nul 2>&1'
} > "$SHIM/launch.bat"

printf '%s\n' "$VERSION" > "$DATA_DIR/version"
# Keep a copy of this script for the launcher's update checks. When run as
# bash -c "$(curl …)" there is no file to copy, so fetch it from the repo instead.
SELF="$DATA_DIR/shinri-hub-setup.sh"
if [ -f "$0" ] && grep -q 'shinri-hub-setup.sh' "$0" 2>/dev/null; then
  [ "$(realpath "$0")" = "$(realpath "$SELF" 2>/dev/null || true)" ] || cp -f "$0" "$SELF"
elif fetch "$REPO_RAW/shinri-hub-setup.sh" "$SELF.part" >/dev/null 2>&1 && grep -q 'shinri-hub-setup.sh' "$SELF.part"; then
  mv -f "$SELF.part" "$SELF"
else
  rm -f "$SELF.part"; warn "couldn't save a copy of this script; automatic hub updates won't work"
fi
chmod +x "$SELF" 2>/dev/null || true

# ---------------------------------------------------------------- config + launcher
cat > "$CONF_DIR/config.sh" <<EOF
# Generated by shinri-hub-setup.sh. Rerun the setup script to regenerate.
STEAM=$(printf %q "$STEAM")
STEAM_KIND=$STEAM_KIND
COMPAT=$(printf %q "$COMPAT")
PFX=$(printf %q "$PFX")
PROTON=$(printf %q "$PROTON")
RUNTIME=$(printf %q "$RUNTIME")
LIBRARIES=$(printf %q "$LIBRARIES")
APPID=$APPID
AUTO_UPDATE=1
EOF

mkdir -p "$(dirname "$BIN")"
cat > "$BIN" <<'EOF'
#!/usr/bin/env bash
# Shinri Hub launcher (generated by shinri-hub-setup.sh)
set -u
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/shinri-hub/config.sh"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/shinri-hub"
LOG="${XDG_CACHE_HOME:-$HOME/.cache}/shinri-hub/launch.log"
mkdir -p "$(dirname "$LOG")"
notify() { command -v notify-send >/dev/null && notify-send -a "Shinri Hub" "Shinri Hub" "$1"; echo "$1" >&2; }
[ -f "$CONF" ] || { notify "Not set up. Run shinri-hub-setup.sh first."; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

# Proton gets updated or removed by Steam sometimes, so re-detect it when it's gone
if [ ! -x "$PROTON/proton" ]; then
  notify "Proton changed, reconfiguring…"
  "$DATA/shinri-hub-setup.sh" >>"$LOG" 2>&1 || { notify "Setup failed, see $LOG"; exit 1; }
  . "$CONF"
fi

# The hub's built-in updater can't install under Wine, so update here instead
if [ "${AUTO_UPDATE:-1}" = 1 ] && ! pgrep -f '^C:.Program Files.Shinri Hub.Shinri Hub[.]exe' >/dev/null; then
  "$DATA/shinri-hub-setup.sh" --update >>"$LOG" 2>&1 || notify "Update check failed (continuing), see $LOG"
fi

# Steam must be running and logged in
if ! pgrep -x steam >/dev/null && ! pgrep -f 'steamwebhelper' >/dev/null; then
  notify "Starting Steam…"
  case "$STEAM_KIND" in
    flatpak) flatpak run com.valvesoftware.Steam -silent >/dev/null 2>&1 & ;;
    *) STEAM_BIN=$(command -v steam || echo /usr/games/steam)   # Debian puts it in /usr/games
       "$STEAM_BIN" -silent >/dev/null 2>&1 & ;;
  esac
  for _ in $(seq 1 60); do pgrep -f 'steamwebhelper' >/dev/null && break; sleep 1; done
  sleep 5
fi

export STEAM_COMPAT_DATA_PATH="$COMPAT" STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM"
export SteamAppId="$APPID" SteamGameId="$APPID"
echo "--- $(date) launching $*" >>"$LOG"
if [ "$STEAM_KIND" = flatpak ]; then
  exec flatpak run --command="$PROTON/proton" \
    --env=STEAM_COMPAT_DATA_PATH="$COMPAT" --env=STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM" \
    --env=SteamAppId="$APPID" --env=SteamGameId="$APPID" \
    com.valvesoftware.Steam run cmd /c 'C:\Program Files\Shinri Hub Linux\launch.bat' "$@" >>"$LOG" 2>&1
fi
# If a previous hub is still shutting down, starting a new one at the same moment can fail
# ("Failed to initialize: ERR_FAILED"). Wait (max 20s) for this prefix's Wine to exit, but
# only when neither the hub nor the game is running (otherwise it would never exit).
if ! pgrep -f '^C:.Program Files.Shinri Hub.Shinri Hub[.]exe' >/dev/null && \
   ! pgrep -f 'shinri-trial[.]exe -steam|GarrysMod.*(gmod|hl2)[.]exe' >/dev/null; then
  for ws in "$PROTON/files/bin/wineserver" "$PROTON/dist/bin/wineserver"; do
    [ -x "$ws" ] && { WINEPREFIX="$COMPAT/pfx" timeout 20 "$ws" -w >/dev/null 2>&1 || true; break; }
  done
fi

BAT='C:\Program Files\Shinri Hub Linux\launch.bat'
# Run Proton inside the Steam Linux Runtime container like Steam does, so it doesn't depend on
# the host's libraries (Debian/Fedora/Arch all differ). SHINRI_NO_RUNTIME=1 runs it directly.
if [ -n "${RUNTIME:-}" ] && [ -x "$RUNTIME/_v2-entry-point" ] && [ "${SHINRI_NO_RUNTIME:-0}" != 1 ]; then
  export STEAM_COMPAT_LIBRARY_PATHS="$LIBRARIES" STEAM_COMPAT_TOOL_PATHS="$PROTON:$RUNTIME"
  exec "$RUNTIME/_v2-entry-point" --verb=run -- "$PROTON/proton" run cmd /c "$BAT" "$@" >>"$LOG" 2>&1
fi
exec "$PROTON/proton" run cmd /c "$BAT" "$@" >>"$LOG" 2>&1
EOF
chmod +x "$BIN"

# ---------------------------------------------------------------- desktop entry + icon
ICON_REF="$APP/resources/icon.ico"
if py "$APP/resources/icon.ico" "$ICON" <<'PY'
import sys, struct, os, zlib
# Pick the largest icon in the .ico; use it directly if PNG, else convert a 32-bit BMP entry.
d = open(sys.argv[1], "rb").read()
n = struct.unpack_from("<H", d, 4)[0]
entries = []
for i in range(n):
    w, h, _, _, _, bpp, size, off = struct.unpack_from("<BBBBHHII", d, 6 + 16 * i)
    entries.append(((w or 256), d[off:off + size]))
if not entries: sys.exit(1)
w, blob = max(entries, key=lambda e: e[0])
if blob[:8] == b"\x89PNG\r\n\x1a\n":
    png = blob
else:
    hdr, bw, bh, _, bpp = struct.unpack_from("<IiiHH", blob, 0)
    if bpp != 32: sys.exit(1)
    bh //= 2                                   # DIB height includes the AND mask
    stride, px = bw * 4, blob[hdr:]
    rows = []
    for y in range(bh - 1, -1, -1):            # bottom-up BGRA -> top-down RGBA
        r = bytearray(px[y * stride:(y + 1) * stride])
        r[0::4], r[2::4] = r[2::4], r[0::4]
        rows.append(b"\x00" + bytes(r))
    def chunk(t, c): return struct.pack(">I", len(c)) + t + c + struct.pack(">I", zlib.crc32(t + c) & 0xffffffff)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", bw, bh, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))
os.makedirs(os.path.dirname(sys.argv[2]), exist_ok=True)
open(sys.argv[2], "wb").write(png)
PY
then ICON_REF=shinri-hub; fi

mkdir -p "$(dirname "$DESKTOP")"
cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Shinri Hub
Comment=Shinri Trial launcher (runs through Proton in Garry's Mod's prefix)
Exec="$BIN" %u
Icon=$ICON_REF
Terminal=false
Categories=Game;
MimeType=x-scheme-handler/st;
StartupWMClass=shinri hub.exe
EOF
command -v update-desktop-database >/dev/null && update-desktop-database -q "$(dirname "$DESKTOP")" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$(dirname "$(dirname "$(dirname "$ICON")")")" 2>/dev/null || true
command -v xdg-mime >/dev/null && xdg-mime default shinri-hub.desktop x-scheme-handler/st 2>/dev/null || true

say "Shinri Hub $VERSION installed"
info "Start it from your app menu (Shinri Hub) or run: $BIN"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) info "(~/.local/bin is not on your PATH, so use the full path above)";; esac
info "Steam must be running and logged in. Launch log: $CACHE_DIR/launch.log"
