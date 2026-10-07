#!/bin/bash
set -euo pipefail

FOLDER_ID="${GDRIVE_FOLDER_ID}"
REPO="${GITHUB_REPOSITORY:-epicmud/enchilada-lineage-ota}"

echo "========================================"
echo " LineageOS Enchilada OTA Synchronizer"
echo "========================================"

echo
echo "Checking Google Drive folder for LineageOS builds..."

# Install gdown
pip3 install --quiet gdown

mkdir -p drive_tmp

FOLDER_URL="https://drive.google.com/drive/folders/$FOLDER_ID"

echo "Querying Google Drive..."

FILES_JSON=$(gdown "$FOLDER_URL" --json 2>/dev/null || true)

if [ -z "$FILES_JSON" ]; then
    echo "ERROR: Failed to fetch folder contents from Google Drive."
    rm -rf drive_tmp
    exit 1
fi

# ------------------------------------------------------------
# Find newest LineageOS ZIP
# ------------------------------------------------------------

LATEST_INFO=$(echo "$FILES_JSON" | python3 -c '
import sys
import json

try:
    data = json.load(sys.stdin)
except Exception as e:
    print("JSON_ERROR", file=sys.stderr)
    sys.exit(1)

zips = []

for f in data:
    path = f.get("path") or f.get("name") or ""
    fid = f.get("id") or ""

    url = f.get("url")

    if not url and fid:
        url = "https://drive.google.com/uc?id=" + fid

    if (
        path.lower().endswith(".zip")
        and "lineage" in path.lower()
        and "enchilada" in path.lower()
    ):
        zips.append({
            "path": path,
            "url": url
        })

if not zips:
    print("NONE")
    sys.exit(0)

# YYYYMMDD in the filename sorts correctly.
zips.sort(key=lambda x: x["path"])

latest = zips[-1]

print(latest["url"] + "|" + latest["path"])
')

if [ "$LATEST_INFO" = "NONE" ] || [ -z "$LATEST_INFO" ]; then
    echo "No matching LineageOS Enchilada ROM ZIP found."
    rm -rf drive_tmp
    exit 0
fi

URL=$(echo "$LATEST_INFO" | cut -d'|' -f1)
LATEST_FILE=$(echo "$LATEST_INFO" | cut -d'|' -f2)

echo
echo "Latest build detected:"
echo "  $LATEST_FILE"

# ------------------------------------------------------------
# Extract build information from filename
# ------------------------------------------------------------

BUILD_TAG=$(echo "$LATEST_FILE" | grep -oP '\d{8}' | head -1 || true)
VERSION=$(echo "$LATEST_FILE" | grep -oP 'lineage-\K[0-9.]+' | head -1 || true)

if [ -z "$BUILD_TAG" ]; then
    BUILD_TAG="build-$(date -u +%Y%m%d)"
fi

if [ -z "$VERSION" ]; then
    echo "ERROR: Could not determine LineageOS version from:"
    echo "$LATEST_FILE"
    exit 1
fi

echo "  Version: $VERSION"
echo "  Release: $BUILD_TAG"
echo "  Device:  enchilada"
echo "  Type:    unofficial"

# ------------------------------------------------------------
# Download new build only when release does not exist
# ------------------------------------------------------------

RELEASE_EXISTS=0

if gh release view "$BUILD_TAG" --repo "$REPO" >/dev/null 2>&1; then
    RELEASE_EXISTS=1
    echo
    echo "GitHub release '$BUILD_TAG' already exists."
    echo "Using the existing release asset."
else
    echo
    echo "GitHub release '$BUILD_TAG' does not exist."
    echo "Downloading ROM from Google Drive..."

    gdown "$URL" -O "./$LATEST_FILE"

    echo "Creating GitHub release..."

    gh release create "$BUILD_TAG" "./$LATEST_FILE" \
        --title "LineageOS $VERSION ($BUILD_TAG)" \
        --notes "Automated OTA build synced from Google Drive." \
        --repo "$REPO"

    rm -f "./$LATEST_FILE"

    RELEASE_EXISTS=1
fi

# ------------------------------------------------------------
# Get GitHub release asset metadata
# ------------------------------------------------------------

echo
echo "Reading GitHub release asset metadata..."

RELEASE_JSON=$(gh api \
    "repos/$REPO/releases/tags/$BUILD_TAG")

ASSET_INFO=$(echo "$RELEASE_JSON" | python3 -c '
import sys
import json

data = json.load(sys.stdin)

target = sys.argv[1]

for asset in data.get("assets", []):
    if asset.get("name") == target:
        asset_id = asset.get("id", "")
        size = asset.get("size", 0)
        digest = asset.get("digest", "")

        if digest.startswith("sha256:"):
            digest = digest[len("sha256:"):]

        print(f"{asset_id}|{size}|{digest}")
        sys.exit(0)

print("NOT_FOUND")
sys.exit(1)
' "$LATEST_FILE")

if [ "$ASSET_INFO" = "NOT_FOUND" ]; then
    echo "ERROR: Could not find release asset:"
    echo "$LATEST_FILE"
    exit 1
fi

ASSET_ID=$(echo "$ASSET_INFO" | cut -d'|' -f1)
FILESIZE=$(echo "$ASSET_INFO" | cut -d'|' -f2)
SHA256=$(echo "$ASSET_INFO" | cut -d'|' -f3)

if [ -z "$FILESIZE" ] || [ "$FILESIZE" = "0" ]; then
    echo "ERROR: GitHub returned an invalid file size."
    exit 1
fi

if [ -z "$SHA256" ]; then
    echo
    echo "GitHub did not provide a SHA256 digest."
    echo "Downloading the release asset to calculate it..."

    mkdir -p drive_tmp

    gh release download "$BUILD_TAG" \
        --repo "$REPO" \
        --pattern "$LATEST_FILE" \
        --dir drive_tmp

    SHA256=$(sha256sum "drive_tmp/$LATEST_FILE" | awk '{print $1}')

    rm -rf drive_tmp
fi

echo
echo "OTA asset information:"
echo "  Filename: $LATEST_FILE"
echo "  Size:     $FILESIZE bytes"
echo "  SHA256:   $SHA256"

# ------------------------------------------------------------
# Determine OTA timestamp
# ------------------------------------------------------------
#
# For LineageOS 23.2+/24.x the updater uses datetime.
#
# If the ZIP is newly downloaded, try to extract the actual
# post-timestamp from META-INF/com/android/metadata.
#
# If the release already existed and the metadata isn't locally
# available, use the build date from the filename.
#
# ------------------------------------------------------------

DATETIME=""

if [ -f "./$LATEST_FILE" ]; then
    METADATA_TIMESTAMP=$(unzip -p "./$LATEST_FILE" \
        META-INF/com/android/metadata 2>/dev/null \
        | grep '^post-timestamp=' \
        | cut -d'=' -f2 \
        | tr -d '\r' \
        || true)

    if [[ "$METADATA_TIMESTAMP" =~ ^[0-9]+$ ]]; then
        DATETIME="$METADATA_TIMESTAMP"
    fi
fi

# If we don't have the ZIP locally, use the date in the filename.
if [ -z "$DATETIME" ]; then
    YEAR="${BUILD_TAG:0:4}"
    MONTH="${BUILD_TAG:4:2}"
    DAY="${BUILD_TAG:6:2}"

    if [[ "$YEAR" =~ ^[0-9]{4}$ ]] &&
       [[ "$MONTH" =~ ^[0-9]{2}$ ]] &&
       [[ "$DAY" =~ ^[0-9]{2}$ ]]; then

        DATETIME=$(date -u \
            -d "${YEAR}-${MONTH}-${DAY} 23:59:59" \
            +%s)
    else
        DATETIME=$(date -u +%s)
    fi
fi

echo "  OTA datetime: $DATETIME"

# ------------------------------------------------------------
# GitHub download URL
# ------------------------------------------------------------

ASSET_URL="https://github.com/$REPO/releases/download/$BUILD_TAG/$LATEST_FILE"

# ------------------------------------------------------------
# Generate LineageOS 23.2+/24.x API v2 endpoint
# ------------------------------------------------------------

echo
echo "Generating LineageOS v2 OTA endpoint..."

mkdir -p api/v2/devices/enchilada

cat > api/v2/devices/enchilada/builds <<EOF
[
  {
    "datetime": $DATETIME,
    "files": [
      {
        "filename": "$LATEST_FILE",
        "sha256": "$SHA256",
        "size": $FILESIZE,
        "url": "$ASSET_URL"
      }
    ],
    "type": "unofficial",
    "version": "$VERSION"
  }
]
EOF

# ------------------------------------------------------------
# Keep the old v1 endpoint too
# ------------------------------------------------------------

mkdir -p v1/enchilada

cat > v1/enchilada/unofficial <<EOF
[
  {
    "datetime": $DATETIME,
    "files": [
      {
        "filename": "$LATEST_FILE",
        "sha256": "$SHA256",
        "size": $FILESIZE,
        "url": "$ASSET_URL"
      }
    ],
    "type": "unofficial",
    "version": "$VERSION"
  }
]
EOF

# Root copy
cp api/v2/devices/enchilada/builds ota.json

# ------------------------------------------------------------
# Validate generated JSON
# ------------------------------------------------------------

echo
echo "Validating JSON..."

python3 -m json.tool api/v2/devices/enchilada/builds >/dev/null
python3 -m json.tool v1/enchilada/unofficial >/dev/null
python3 -m json.tool ota.json >/dev/null

echo "JSON validation successful."

echo
echo "Generated v2 endpoint:"
cat api/v2/devices/enchilada/builds

# ------------------------------------------------------------
# Commit and push
# ------------------------------------------------------------

echo
echo "Updating Git repository..."

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

git add \
    ota.json \
    api/v2/devices/enchilada/builds \
    v1/enchilada/unofficial

if git diff --cached --quiet; then
    echo "OTA endpoint is already up to date."
else
    git commit \
        -m "Update OTA endpoint for build $BUILD_TAG"

    git push
fi

echo
echo "========================================"
echo " OTA synchronization completed!"
echo "========================================"
