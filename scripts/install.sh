#!/bin/sh
# Installs the latest Sequence Studio release on Linux (x86_64).
#
#   curl -fsSL https://raw.githubusercontent.com/paulherter/sequence-studio/main/scripts/install.sh | sh
#
# Downloads SequenceStudio-linux-x86_64.AppImage to ~/Applications/SequenceStudio.AppImage and adds a menu entry and
# icon under ~/.local/share. The file comes from the latest GitHub release (releases/latest/download), so every
# release must carry exactly this asset name. Nothing is installed system-wide and nothing needs sudo.
# On a Mac, download the .dmg from the releases page. On Windows, download the Setup installer.
# Environment: SQ_INSTALL_BASE overrides the download base URL (tests with a local folder served over http or file://).
set -eu

REPO="paulherter/sequence-studio"
RELEASES="https://github.com/$REPO/releases/latest"
BASE="${SQ_INSTALL_BASE:-$RELEASES/download}"
LINUX_ASSET="SequenceStudio-linux-x86_64.AppImage"
APP_NAME="Sequence Studio"

say() { printf '%s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found"; }

case "$(uname -s)" in
  Linux) ;;
  Darwin)
    say "On a Mac, download the .dmg from $RELEASES"
    exit 1
    ;;
  *) die "this script is for Linux; on Windows download the Setup installer from $RELEASES" ;;
esac

need curl
[ "$(uname -m)" = "x86_64" ] || die "the Linux build is for x86_64 only (this machine is $(uname -m))"

work="$(mktemp -d "${TMPDIR:-/tmp}/sq-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT INT TERM

apps="$HOME/Applications"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
image="$work/$LINUX_ASSET"

say "Downloading $LINUX_ASSET ..."
curl -fL --proto '=https,file' --tlsv1.2 --retry 3 --progress-bar -o "$image" "$BASE/$LINUX_ASSET" ||
  die "download failed: $BASE/$LINUX_ASSET (is there a release yet? see https://github.com/$REPO/releases)"
chmod +x "$image"

mkdir -p "$apps"
dest="$apps/SequenceStudio.AppImage"
# Copy to a hidden name in the same folder, then rename: the rename is atomic, so a running or interrupted
# install never leaves a broken file at the final path.
partial="$apps/.SequenceStudio.AppImage.part"
cp "$image" "$partial"
chmod +x "$partial"
mv -f "$partial" "$dest"

# Icon and file type come from the image itself, so they always match the installed version.
icon_dir="$data/icons/hicolor/256x256/apps"
mime_dir="$data/mime/packages"
mkdir -p "$icon_dir" "$mime_dir" "$data/applications"
extract="$work/extract"
mkdir -p "$extract"
(cd "$extract" && "$dest" --appimage-extract 'usr/share/icons/hicolor/256x256/apps/sequence-studio.png' >/dev/null 2>&1) || true
(cd "$extract" && "$dest" --appimage-extract 'usr/share/mime/packages/*.xml' >/dev/null 2>&1) || true
icon_src="$extract/squashfs-root/usr/share/icons/hicolor/256x256/apps/sequence-studio.png"
if [ -f "$icon_src" ]; then cp "$icon_src" "$icon_dir/sequence-studio.png"; fi
for xml in "$extract"/squashfs-root/usr/share/mime/packages/*.xml; do
  if [ -f "$xml" ]; then cp "$xml" "$mime_dir/"; fi
done

# Exec is quoted as the Desktop Entry spec asks (the path may hold spaces).
cat >"$data/applications/sequence-studio.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=$APP_NAME
GenericName=Video Editor
Comment=Video editor for the timeline, color, masks and titles
Exec="$dest" %F
Icon=sequence-studio
Terminal=false
Categories=AudioVideo;Video;AudioVideoEditing;
MimeType=application/x-sequence-studio-project;application/x-sequence-studio-pack;
StartupWMClass=sequence-studio
DESKTOP
if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database "$data/applications" >/dev/null 2>&1 || true; fi
if command -v update-mime-database >/dev/null 2>&1; then update-mime-database "$data/mime" >/dev/null 2>&1 || true; fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then gtk-update-icon-cache -q -t "$data/icons/hicolor" >/dev/null 2>&1 || true; fi

say "Installed $dest"
say "Find Sequence Studio in your application menu, or run: $dest"
say "Voiceover from Text needs espeak-ng from your package manager."
