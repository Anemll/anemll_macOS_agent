#!/bin/bash
set -euo pipefail

# ─── Usage ───────────────────────────────────────────────────────────
# Build + package:   ./package.sh
# Use existing app:  ./package.sh /path/to/AnemllAgentHost.app
# With signing:      SIGN_IDENTITY="Developer ID Application: ..." ./package.sh
# With notarize:     SIGN_IDENTITY="..." NOTARY_PROFILE="profile" ./package.sh
# ─────────────────────────────────────────────────────────────────────

APP_NAME="AnemllAgentHost"
DISPLAY_NAME="ANEMLL UI Agent"
SCHEME="AnemllAgentHost"
BUILD_DIR="build"
STAGING_DIR="dmg-staging"
DMG_NAME="${APP_NAME}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

# ─── Step 0: Resolve app path ───────────────────────────────────────
if [ $# -ge 1 ] && [ -d "$1" ]; then
    APP_PATH="$1"
    echo "=== Using existing app: ${APP_PATH} ==="
    SKIP_BUILD=true
else
    SKIP_BUILD=false
fi

# Get version
if [ "$SKIP_BUILD" = true ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "0.0.0")
else
    VERSION=$(defaults read "$(pwd)/${APP_NAME}/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0.0.0")
fi

DMG_FILE="${DMG_NAME}-${VERSION}.dmg"
ZIP_FILE="${DMG_NAME}-${VERSION}.zip"

echo "=== Packaging ${DISPLAY_NAME} v${VERSION} ==="

# ─── Step 1: Build Release (unless app path provided) ───────────────
if [ "$SKIP_BUILD" = false ]; then
    echo ""
    echo "── Building Release..."
    xcodebuild -scheme "${SCHEME}" \
        -configuration Release \
        -derivedDataPath "${BUILD_DIR}" \
        -quiet \
        clean build

    APP_PATH=$(find "${BUILD_DIR}" -name "${APP_NAME}.app" -type d | head -1)
    if [ -z "$APP_PATH" ]; then
        echo "ERROR: ${APP_NAME}.app not found in ${BUILD_DIR}"
        exit 1
    fi
    echo "   Built: ${APP_PATH}"
fi

# ─── Step 2: Code Sign (if identity provided) ───────────────────────
if [ -n "$SIGN_IDENTITY" ]; then
    echo ""
    echo "── Code Signing with: ${SIGN_IDENTITY}"
    codesign --force --deep --options runtime \
        --sign "${SIGN_IDENTITY}" \
        "${APP_PATH}"
    echo "   Signed."
else
    echo ""
    echo "── Skipping code signing (set SIGN_IDENTITY env var to enable)"
fi

# ─── Step 3: Create DMG ─────────────────────────────────────────────
echo ""
echo "── Creating DMG: ${DMG_FILE}"
rm -f "${DMG_FILE}"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
cp -R "${APP_PATH}" "${STAGING_DIR}/"

# Generate DMG background image (arrow between app and Applications)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BG_IMAGE="${SCRIPT_DIR}/dmg_background.png"
if [ -f "${SCRIPT_DIR}/dmg_background.py" ]; then
    echo "   Generating background image..."
    python3 "${SCRIPT_DIR}/dmg_background.py"
fi

# Check if create-dmg is available (brew install create-dmg)
if command -v create-dmg &>/dev/null; then
    echo "   Using create-dmg..."

    CREATE_DMG_ARGS=(
        --volname "${DISPLAY_NAME}"
        --window-pos 200 120
        --window-size 660 400
        --icon-size 100
        --icon "${APP_NAME}.app" 160 190
        --app-drop-link 500 190
        --hide-extension "${APP_NAME}.app"
        --no-internet-enable
    )

    # Add background image if available
    if [ -f "${BG_IMAGE}" ]; then
        CREATE_DMG_ARGS+=(--background "${BG_IMAGE}")
    fi

    # Add code signing if identity provided
    if [ -n "$SIGN_IDENTITY" ]; then
        CREATE_DMG_ARGS+=(--codesign "${SIGN_IDENTITY}")
    fi

    # create-dmg returns non-zero if no signing identity, so allow failure
    create-dmg "${CREATE_DMG_ARGS[@]}" "${DMG_FILE}" "${STAGING_DIR}/" || true

    if [ ! -f "${DMG_FILE}" ]; then
        echo "   create-dmg failed, falling back to hdiutil..."
        USE_HDIUTIL=true
    else
        USE_HDIUTIL=false

        # ── Post-process: Replace symlink with Finder alias for proper icon ──
        echo "   Fixing Applications folder icon..."
        DMG_RW="rw.$$.${DMG_FILE}"
        hdiutil convert "${DMG_FILE}" -format UDRW -o "${DMG_RW}" -quiet

        MOUNT_DIR=$(hdiutil attach -readwrite -noverify "${DMG_RW}" | \
                    grep '/Volumes/' | sed 's/.*\/Volumes/\/Volumes/')
        sleep 2

        # Replace symlink with Finder alias (symlinks can't carry icons)
        if [ -L "${MOUNT_DIR}/Applications" ]; then
            rm "${MOUNT_DIR}/Applications"
            osascript -e "tell application \"Finder\" to make new alias file at POSIX file \"${MOUNT_DIR}\" to POSIX file \"/Applications\"" \
                      -e "tell application \"Finder\" to set name of result to \"Applications\"" 2>/dev/null \
                || echo "   Warning: Could not create Finder alias"
        fi

        # Set the Applications folder icon explicitly
        APPS_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns"
        if [ -f "${MOUNT_DIR}/Applications" ] && [ -f "$APPS_ICON" ] && command -v fileicon &>/dev/null; then
            fileicon set "${MOUNT_DIR}/Applications" "$APPS_ICON" 2>/dev/null \
                || echo "   Warning: Could not set Applications icon via fileicon"
        fi

        sleep 1
        sync
        hdiutil detach "${MOUNT_DIR}" 2>/dev/null || true
        sleep 1

        # Convert back to compressed read-only
        rm -f "${DMG_FILE}"
        hdiutil convert "${DMG_RW}" -format UDZO -imagekey zlib-level=9 -o "${DMG_FILE}" -quiet
        rm -f "${DMG_RW}"
        echo "   Applications icon fixed."
    fi
else
    echo "   create-dmg not found, using hdiutil..."
    echo "   TIP: brew install create-dmg  (for drag-to-Applications layout)"
    USE_HDIUTIL=true
fi

if [ "$USE_HDIUTIL" = true ]; then
    DMG_TMP="tmp-${DMG_NAME}.dmg"
    VOL_NAME="${DISPLAY_NAME}"

    # Add Applications symlink for drag-to-install (create-dmg does this automatically)
    if [ ! -e "${STAGING_DIR}/Applications" ]; then
        ln -s /Applications "${STAGING_DIR}/Applications"
    fi

    # Copy background image into staging if available
    if [ -f "${BG_IMAGE}" ]; then
        mkdir -p "${STAGING_DIR}/.background"
        cp "${BG_IMAGE}" "${STAGING_DIR}/.background/background.png"
    fi

    # Calculate size (staging already has Applications symlink)
    SIZE=$(du -sm "${STAGING_DIR}" | awk '{print $1}')
    SIZE=$((SIZE + 20))

    # Create read-write DMG
    hdiutil create \
        -srcfolder "${STAGING_DIR}" \
        -volname "${VOL_NAME}" \
        -fs HFS+ \
        -fsargs "-c c=64,a=16,e=16" \
        -format UDRW \
        -size ${SIZE}M \
        "${DMG_TMP}"

    # Mount and customize layout
    DEVICE=$(hdiutil attach -readwrite -noverify "${DMG_TMP}" | \
             grep '^/dev/' | sed 1q | awk '{print $1}')
    sleep 2

    # Set icon view options via .DS_Store
    # Using osascript to position icons (requires Finder access)
    osascript <<EOF 2>/dev/null || echo "   Note: AppleScript layout skipped (no Finder access)"
tell application "Finder"
    tell disk "${VOL_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 100, 1060, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 100
        set background picture of viewOptions to file ".background:background.png"
        set position of item "${APP_NAME}.app" of container window to {160, 190}
        set position of item "Applications" of container window to {500, 190}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
EOF

    sync
    hdiutil detach "${DEVICE}"

    # Convert to compressed read-only DMG
    hdiutil convert "${DMG_TMP}" -format UDZO -imagekey zlib-level=9 -o "${DMG_FILE}"
    rm -f "${DMG_TMP}"
fi

rm -rf "${STAGING_DIR}"

if [ -f "${DMG_FILE}" ]; then
    echo "   Created: ${DMG_FILE} ($(du -h "${DMG_FILE}" | cut -f1))"
else
    echo "   ERROR: DMG creation failed"
    exit 1
fi

# ─── Step 4: Create ZIP of DMG ───────────────────────────────────────
echo ""
echo "── Creating ZIP: ${ZIP_FILE}"
rm -f "${ZIP_FILE}"
ditto -c -k "${DMG_FILE}" "${ZIP_FILE}"
echo "   Created: ${ZIP_FILE} ($(du -h "${ZIP_FILE}" | cut -f1))"

# ─── Step 5: Notarize (if identity and profile provided) ────────────
if [ -n "$SIGN_IDENTITY" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    echo ""
    echo "── Notarizing DMG..."
    xcrun notarytool submit "${DMG_FILE}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    echo "── Stapling DMG..."
    xcrun stapler staple "${DMG_FILE}"

    echo "── Notarizing ZIP..."
    xcrun notarytool submit "${ZIP_FILE}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    # Can't staple a zip, but the app inside is notarized via the ticket
    echo "   Notarized and stapled."
else
    echo ""
    echo "── Skipping notarization (set SIGN_IDENTITY and NOTARY_PROFILE env vars)"
fi

# ─── Summary ─────────────────────────────────────────────────────────
echo ""
echo "=== Done ==="
echo "   APP: ${APP_PATH}"
echo "   ZIP: ${ZIP_FILE}"
echo "   DMG: ${DMG_FILE}"
echo ""
echo "── Usage examples:"
echo "   # Package from existing Xcode export:"
echo "   ./package.sh /path/to/AnemllAgentHost.app"
echo ""
echo "   # Sign + notarize:"
echo "   export SIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\""
echo "   export NOTARY_PROFILE=\"your-keychain-profile\""
echo "   ./package.sh"
echo ""
echo "   # Setup notary profile (one-time):"
echo "   xcrun notarytool store-credentials \"your-keychain-profile\" \\"
echo "     --apple-id \"you@example.com\" --team-id \"TEAMID\""
