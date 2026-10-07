#!/bin/bash
set -e

# Target Google Drive subfolder ID (extracted from the end of your Drive URL)
FOLDER_ID="${GDRIVE_FOLDER_ID}"
REPO="${GITHUB_REPOSITORY:-epicmud/enchilada-lineage-ota}"

echo "Checking Google Drive folder for LineageOS builds..."

# Query Google Drive via rclone for lineage-*.zip files and select the latest build
LATEST_FILE=$(rclone lsjson --no-check-certificate --drive-root-folder-id "$FOLDER_ID" :drive: | grep -oP '"Path":"\Klineage-[^"]+\.zip' | sort -V | tail -n 1)

if [ -z "$LATEST_FILE" ]; then
  echo "No matching ROM ZIP file found in the folder."
  exit 0
fi

echo "Latest build found on Drive: $LATEST_FILE"

# Extract 8-digit date tag (YYYYMMDD) and LineageOS version
BUILD_TAG=$(echo "$LATEST_FILE" | grep -oP '\d{8}')
VERSION=$(echo "$LATEST_FILE" | grep -oP 'lineage-\K[0-9.]+')

if [ -z "$BUILD_TAG" ]; then
  BUILD_TAG="build-$(date +%Y%m%d)"
fi

# Check if a GitHub release for this build already exists
if gh release view "$BUILD_TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release tag '$BUILD_TAG' already exists on GitHub. No update needed."
  exit 0
fi

echo "New build detected ($LATEST_FILE). Downloading from Google Drive..."
rclone copyto --no-check-certificate --drive-root-folder-id "$FOLDER_ID" ":drive:$LATEST_FILE" "./$LATEST_FILE"

# Calculate checksum and filesize
SHA256=$(sha256sum "$LATEST_FILE" | awk '{print $1}')
FILESIZE=$(stat -c%s "$LATEST_FILE")

# Convert YYYYMMDD string to Unix timestamp for LineageOS Updater date comparison
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

# Commit and push updated ota.json back to the main branch
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add ota.json
git commit -m "Update ota.json for build $BUILD_TAG"
git push

echo "Successfully created release and up
dated ota.json!"
