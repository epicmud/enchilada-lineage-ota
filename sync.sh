#!/bin/bash
set -e

FOLDER_ID="${GDRIVE_FOLDER_ID}"
REPO="${GITHUB_REPOSITORY:-epicmud/enchilada-lineage-ota}"

echo "Checking Google Drive folder for LineageOS builds..."

# Install gdown python package
pip3 install --quiet gdown

mkdir -p drive_tmp

# Query Drive folder metadata as JSON without downloading payloads
FOLDER_URL="https://drive.google.com/drive/folders/$FOLDER_ID"
FILES_JSON=$(gdown "$FOLDER_URL" --json 2>/dev/null || true)

if [ -z "$FILES_JSON" ]; then
  echo "Error: Failed to fetch folder contents from Google Drive."
  rm -rf drive_tmp
  exit 1
fi

# Parse JSON to locate the newest LineageOS zip build (OFFICIAL or UNOFFICIAL)
LATEST_INFO=$(echo "$FILES_JSON" | python3 -c '
import sys, json

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

zips = []
for f in data:
    path = f.get("path") or f.get("name") or ""
    fid = f.get("id") or ""
    url = f.get("url") or ("https://drive.google.com/uc?id=" + fid if fid else "")
    if path.lower().endswith(".zip") and "lineage" in path.lower():
        zips.append({"path": path, "url": url})

if not zips:
    print("NONE")
    sys.exit(0)

# Sort by filename (YYYYMMDD ordering places the newest build last)
zips.sort(key=lambda x: x["path"])
latest = zips[-1]

print(latest["url"] + "|" + latest["path"])
')

if [ "$LATEST_INFO" = "NONE" ] || [ -z "$LATEST_INFO" ]; then
  echo "No matching ROM ZIP file found in the folder."
  rm -rf drive_tmp
  exit 0
fi

URL=$(echo "$LATEST_INFO" | cut -d'|' -f1)
LATEST_FILE=$(echo "$LATEST_INFO" | cut -d'|' -f2)

echo "Latest build detected: $LATEST_FILE"

# Extract date tag and LineageOS version
BUILD_TAG=$(echo "$LATEST_FILE" | grep -oP '\d{8}')
VERSION=$(echo "$LATEST_FILE" | grep -oP 'lineage-\K[0-9.]+')

if [ -z "$BUILD_TAG" ]; then
  BUILD_TAG="build-$(date +%Y%m%d)"
fi

# Check if release tag already exists on GitHub BEFORE downloading
if gh release view "$BUILD_TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release tag '$BUILD_TAG' already exists on GitHub. Nothing to do."
  rm -rf drive_tmp
  exit 0
fi

echo "Downloading target build asset $LATEST_FILE..."
gdown "$URL" -O "./$LATEST_FILE"
rm -rf drive_tmp

# Calculate checksum and filesize
SHA256=$(sha256sum "$LATEST_FILE" | awk '{print $1}')
FILESIZE=$(stat -c%s "$LATEST_FILE")

# Convert YYYYMMDD string to Unix timestamp
YEAR=${BUILD_TAG:0:4}
MONTH=${BUILD_TAG:4:2}
DAY=${BUILD_TAG:6:2}
if [ -n "$YEAR" ] && [ -n "$MONTH" ] && [ -n "$DAY" ]; then
  DATETIME=$(date -u -d "${YEAR}-${MONTH}-${DAY} 00:00:00" +%s)
else
  DATETIME=$(date +%s)
fi

echo "Creating GitHub Release '$BUILD_TAG'..."
gh release create "$BUILD_TAG" "./$LATEST_FILE" \
  --title "LineageOS $VERSION ($BUILD_TAG)" \
  --notes "Automated OTA build synced from Google Drive." \
  --repo "$REPO"

ASSET_URL="https://github.com/$REPO/releases/download/$BUILD_TAG/$LATEST_FILE"

echo "Updating ota.json..."
cat <<EOF > ota.json
{
  "response": [
    {
      "datetime": $DATETIME,
      "filename": "$LATEST_FILE",
      "id": "$SHA256",
      "romtype": "unofficial",
      "size": $FILESIZE,
      "url": "$ASSET_URL",
      "version": "$VERSION"
    }
  ]
}
EOF

# Commit and push updated ota.json
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add ota.json
git commit -m "Update ota.json for build $BUILD_TAG"
git push

echo "Successfully updated OTA endpoint!"
