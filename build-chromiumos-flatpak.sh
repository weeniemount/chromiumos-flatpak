#!/bin/bash
set -e

APP_ID="org.chromium.ChromiumOS"
WORK_DIR="$(pwd)/chromiumos-flatpak-build"
EXTRACT_DIR="$WORK_DIR/chromium-extracted"
ZIP_FILE="$WORK_DIR/chromium.zip"
BUNDLE_OUT="$WORK_DIR/ChromiumOS.flatpak"
REVISION_FILE="$WORK_DIR/revision.txt"

echo "setting up directories"
mkdir -p "$WORK_DIR" "$EXTRACT_DIR"

for cmd in wget unzip flatpak flatpak-builder; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "error: '$cmd' is not installed"
    exit 1
  fi
done

echo "downloading chromiumos"
BUCKET_BASE="https://commondatastorage.googleapis.com/chromium-browser-snapshots/Linux_ChromiumOS_Full"

if [[ -f "$REVISION_FILE" ]]; then
  SNAPSHOT_REVISION=$(cat "$REVISION_FILE" | tr -d '[:space:]')
  echo "using cached revision: $SNAPSHOT_REVISION"
else
  echo "fetching latest revision number"
  SNAPSHOT_REVISION=$(wget -qO- "$BUCKET_BASE/LAST_CHANGE" | tr -d '[:space:]')
  if [[ -z "$SNAPSHOT_REVISION" || ! "$SNAPSHOT_REVISION" =~ ^[0-9]+$ ]]; then
    echo "error: could not fetch revision from LAST_CHANGE"
    exit 1
  fi
  echo "$SNAPSHOT_REVISION" > "$REVISION_FILE"
  echo "latest revision: $SNAPSHOT_REVISION"
fi

if [[ ! -f "$ZIP_FILE" ]]; then
  wget -O "$ZIP_FILE" "$BUCKET_BASE/$SNAPSHOT_REVISION/chrome-chromeos.zip"
else
  echo "zip already exists, skipping download"
fi

echo "extracting"
unzip -o "$ZIP_FILE" -d "$EXTRACT_DIR"

CHROME_BIN=$(find "$EXTRACT_DIR" -name "chrome" -type f | head -n 1)
if [[ -z "$CHROME_BIN" ]]; then
  echo "error: could not find chrome executable"
  exit 1
fi
CHROME_SUBDIR=$(dirname "$CHROME_BIN")
echo "found chrome at $CHROME_BIN"

echo "detecting version"
CHROME_VERSION=""

CHROME_VERSION=$("$CHROME_BIN" --product-version --no-sandbox 2>/dev/null | tr -d '[:space:]' || true)

if [[ -z "$CHROME_VERSION" || ! "$CHROME_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  VERSION_FILE=$(find "$CHROME_SUBDIR" -maxdepth 1 \( -name "VERSION" -o -name "version" \) 2>/dev/null | head -n 1)
  if [[ -n "$VERSION_FILE" ]]; then
    CHROME_VERSION=$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$VERSION_FILE" | head -n 1 || true)
  fi
fi

if [[ -z "$CHROME_VERSION" || ! "$CHROME_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  CHROME_VERSION=$(strings "$CHROME_BIN" 2>/dev/null \
    | grep -Eo '^[1-9][0-9]{1,2}\.[0-9]+\.[0-9]{4,}\.[0-9]+$' \
    | head -n 1 || true)
fi

if [[ -z "$CHROME_VERSION" ]]; then
  CHROME_VERSION="0.0.0.0"
  echo "warning: could not detect version, using 0.0.0.0"
else
  echo "version: $CHROME_VERSION-r$SNAPSHOT_REVISION"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ICON_SRC="$SCRIPT_DIR/chromium.svg"
if [[ ! -f "$ICON_SRC" ]]; then
  echo "error: chromium.svg not found next to this script"
  exit 1
fi

echo "writing manifest"
SOURCES_DIR="$WORK_DIR/sources"
MANIFEST="$WORK_DIR/$APP_ID.json"

cat > "$MANIFEST" <<EOF
{
  "app-id": "$APP_ID",
  "runtime": "org.freedesktop.Platform",
  "runtime-version": "24.08",
  "sdk": "org.freedesktop.Platform",
  "command": "chromiumos",
  "finish-args": [
    "--share=network",
    "--share=ipc",
    "--socket=x11",
    "--socket=wayland",
    "--socket=pulseaudio",
    "--device=dri",
    "--persist=.local/share/chromiumos-profile",
    "--persist=Downloads",
    "--talk-name=org.freedesktop.Notifications"
  ],
  "modules": [
    {
      "name": "chromiumos",
      "buildsystem": "simple",
      "build-commands": [
        "mkdir -p /app/lib/$APP_ID /app/bin /app/share/icons/hicolor/scalable/apps /app/share/applications /app/share/metainfo",
        "cp -r chromium/. /app/lib/$APP_ID/",
        "install -Dm755 chromiumos.sh /app/bin/chromiumos",
        "install -Dm644 chromium.svg /app/share/icons/hicolor/scalable/apps/$APP_ID.svg",
        "install -Dm644 $APP_ID.desktop /app/share/applications/$APP_ID.desktop",
        "install -Dm644 $APP_ID.metainfo.xml /app/share/metainfo/$APP_ID.metainfo.xml"
      ],
      "sources": [
        {
          "type": "dir",
          "path": "sources"
        }
      ]
    }
  ]
}
EOF

echo "preparing sources"
mkdir -p "$SOURCES_DIR/chromium"
cp -r "$CHROME_SUBDIR"/. "$SOURCES_DIR/chromium/"
cp "$ICON_SRC" "$SOURCES_DIR/chromium.svg"

cat > "$SOURCES_DIR/chromiumos.sh" << 'WRAPPER'
#!/bin/sh
PROFILE_DIR="${XDG_DATA_HOME}/chromiumos-profile"
DEFAULT_DIR="${PROFILE_DIR}/Default"

if [ ! -f "${DEFAULT_DIR}/Preferences" ]; then
  mkdir -p "${DEFAULT_DIR}"
  cat > "${DEFAULT_DIR}/Preferences" << 'PREFS'
{
  "browser": {
    "window_placement": {
      "bottom": 1080,
      "left": 0,
      "maximized": false,
      "right": 1920,
      "top": 0,
      "work_area_bottom": 1080,
      "work_area_left": 0,
      "work_area_right": 1920,
      "work_area_top": 0
    }
  }
}
PREFS
fi

exec /app/lib/org.chromium.ChromiumOS/chrome \
  --no-sandbox \
  --user-data-dir="${PROFILE_DIR}" \
  --download-default-directory="${HOME}/Downloads" \
  "$@"
WRAPPER
chmod +x "$SOURCES_DIR/chromiumos.sh"

cat > "$SOURCES_DIR/$APP_ID.desktop" << EOF
[Desktop Entry]
Version=1.0
Name=ChromiumOS
Comment=Unofficial Flatpak of the ChromiumOS for Linux builds
Exec=chromiumos %U
Icon=$APP_ID
Type=Application
Categories=Network;WebBrowser;
StartupWMClass=Chromium
X-Flatpak-Developer=Chromium team
X-AppVersion=${CHROME_VERSION}-r${SNAPSHOT_REVISION}
EOF

cat > "$SOURCES_DIR/$APP_ID.metainfo.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>$APP_ID</id>
  <metadata_license>FSFAP</metadata_license>
  <project_license>BSD-3-Clause</project_license>
  <name>ChromiumOS</name>
  <summary>Unofficial Flatpak of the ChromiumOS for Linux builds</summary>
  <description>
    <p>Unofficial Flatpak of the ChromiumOS for Linux builds.</p>
    <p>Packaged from the official ChromiumOS for Linux snapshot builds provided by the Chromium team.</p>
  </description>
  <launchable type="desktop-id">$APP_ID.desktop</launchable>
  <developer id="org.chromium">
    <name>Chromium team</name>
  </developer>
  <url type="homepage">https://www.chromium.org/chromium-projects/</url>
  <releases>
    <release version="${CHROME_VERSION}-r${SNAPSHOT_REVISION}" date="$(date +%Y-%m-%d)"/>
  </releases>
  <content_rating type="oars-1.1"/>
</component>
EOF

cp "$MANIFEST" "$SOURCES_DIR/$APP_ID.json"

echo "checking runtime"
flatpak remote-add --if-not-exists --user flathub https://flathub.org/repo/flathub.flatpakrepo || true

if ! flatpak info --user org.freedesktop.Platform//24.08 &>/dev/null && \
   ! flatpak info --system org.freedesktop.Platform//24.08 &>/dev/null; then
  echo "installing org.freedesktop.Platform"
  flatpak install --user -y flathub org.freedesktop.Platform//24.08
else
  echo "runtime already installed"
fi

echo "building flatpak"
BUILD_DIR="$WORK_DIR/build"
flatpak-builder \
  --user \
  --install \
  --force-clean \
  --state-dir="$WORK_DIR/.flatpak-builder" \
  "$BUILD_DIR" \
  "$MANIFEST"

echo ""
FULL_VERSION="${CHROME_VERSION}-r${SNAPSHOT_REVISION}"
echo "done. chromiumos $FULL_VERSION installed."
echo "run with: flatpak run $APP_ID"
echo "" > /dev/null  # version: $FULL_VERSION

echo "bundling .flatpak (this takes a while)"
REPO_PATH="${HOME}/.local/share/flatpak/repo"

flatpak build-bundle \
  --runtime-repo=https://flathub.org/repo/flathub.flatpakrepo \
  "$REPO_PATH" \
  "$BUNDLE_OUT" \
  "$APP_ID" &
BUNDLE_PID=$!

echo -n "bundling"
while kill -0 "$BUNDLE_PID" 2>/dev/null; do
  echo -n "."
  sleep 5
done
wait "$BUNDLE_PID"
BUNDLE_EXIT=$?

echo ""
if [[ $BUNDLE_EXIT -eq 0 ]]; then
  BUNDLE_SIZE=$(du -sh "$BUNDLE_OUT" 2>/dev/null | cut -f1 || echo "?")
  echo "bundle saved to $BUNDLE_OUT ($BUNDLE_SIZE)"
  echo "install elsewhere with: flatpak install ChromiumOS.flatpak"
else
  echo "warning: bundling failed (exit $BUNDLE_EXIT), app is still installed locally"
  echo "retry manually: flatpak build-bundle $REPO_PATH $BUNDLE_OUT $APP_ID"
fi
