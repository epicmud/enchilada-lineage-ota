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
# Find newest LineageOS Enchilada ZIP
# ------------------------------------------------------------

LATEST_INFO=$(echo "$FILES_JSON" | python3 -c '
import sys
import json

try:
    data = json.load(sys.stdin)
except Exception:
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

if gh release view "$BUILD_TAG" --repo "$REPO" >/dev/null 2>&1; then

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
        size = asset.get("size", 0)
        digest = asset.get("digest", "")

        if digest.startswith("sha256:"):
            digest = digest[len("sha256:"):]

        print(f"{size}|{digest}")
        sys.exit(0)

print("NOT_FOUND")
sys.exit(1)
' "$LATEST_FILE")

if [ "$ASSET_INFO" = "NOT_FOUND" ]; then
    echo "ERROR: Could not find release asset:"
    echo "$LATEST_FILE"
    exit 1
fi

FILESIZE=$(echo "$ASSET_INFO" | cut -d'|' -f1)
SHA256=$(echo "$ASSET_INFO" | cut -d'|' -f2)

if [ -z "$FILESIZE" ] || [ "$FILESIZE" = "0" ]; then
    echo "ERROR: GitHub returned an invalid file size."
    exit 1
fi

# ------------------------------------------------------------
# Calculate SHA256 if GitHub does not provide one
# ------------------------------------------------------------

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

DATETIME=""

# If the ZIP is locally available, use its actual Android
# post-timestamp.
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

# If the ZIP isn't available locally, use the build date
# contained in the filename.
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
# Generate LineageOS 24 OTA v2 endpoint
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
# Root copy for easy reference
# ------------------------------------------------------------

cp api/v2/devices/enchilada/builds ota.json

# ------------------------------------------------------------
# Validate JSON
# ------------------------------------------------------------

echo
echo "Validating JSON..."

python3 -m json.tool \
    api/v2/devices/enchilada/builds \
    >/dev/null

python3 -m json.tool \
    ota.json \
    >/dev/null

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
    api/v2/devices/enchilada/builds

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
