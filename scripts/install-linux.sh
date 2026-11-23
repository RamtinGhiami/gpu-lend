#!/usr/bin/env bash
# Installs GPU Lend for the current user (no root): copies the app to ~/.local/opt/gpu-lend, adds a launcher to the applications
# menu and, if you answer y, starts it with your desktop session.
#
# Run it from the unpacked folder:       ./install.sh
# Or download and install in one step:   curl -fsSL https://raw.githubusercontent.com/RamtinGhiami/gpu-lend/main/scripts/install-linux.sh | bash
set -euo pipefail

REPO="RamtinGhiami/gpu-lend"
DEST="${HOME}/.local/opt/gpu-lend"
APPS="${HOME}/.local/share/applications"
AUTOSTART="${HOME}/.config/autostart"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SRC=""
if [ -x "$HERE/gpu_lend" ]; then
  SRC="$HERE"
else
  echo "Downloading the latest GPU Lend for Linux..."
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  URL="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep -o 'https://[^"]*linux-x64\.tar\.gz' | head -1)"
  [ -n "$URL" ] || { echo "No Linux build found in the latest release."; exit 1; }
  curl -fSL "$URL" -o "$TMP/gpu-lend.tar.gz"
  tar -xzf "$TMP/gpu-lend.tar.gz" -C "$TMP"
  SRC="$TMP/gpu-lend"
fi

rm -rf "$DEST"
mkdir -p "$DEST" "$APPS"
cp -r "$SRC"/. "$DEST"/
chmod +x "$DEST/gpu_lend"

ICON="$DEST/data/flutter_assets/assets/icon.png"
cat > "$APPS/gpu-lend.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=GPU Lend
Comment=Run AI models on your graphics card and serve them to your programs or your server
Exec=$DEST/gpu_lend
Icon=$ICON
Terminal=false
Categories=Utility;Development;
EOF

read -r -p "Start GPU Lend with your desktop session? [y/N] " ans < /dev/tty || ans="n"
if [ "${ans:-n}" = "y" ] || [ "${ans:-n}" = "Y" ]; then
  mkdir -p "$AUTOSTART"
  sed "s|Exec=$DEST/gpu_lend|Exec=$DEST/gpu_lend --minimized|" "$APPS/gpu-lend.desktop" > "$AUTOSTART/gpu-lend.desktop"
  echo "Autostart enabled."
fi

echo "Installed to $DEST. Start it from the applications menu (GPU Lend)."
echo "To remove it: rm -rf '$DEST' '$APPS/gpu-lend.desktop' '$AUTOSTART/gpu-lend.desktop'"
