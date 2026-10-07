#!/bin/bash
set -e

FOLDER_ID="${GDRIVE_FOLDER_ID}"
REPO="${GITHUB_REPOSITORY:-epicmud/enchilada-lineage-ota}"

echo "Checking Google Drive folder for LineageOS builds..."

# Install gdown python package
pip3 install --quiet gdown

# Create temporary directory
mkdir -p drive_tmp
cd drive_tmp

# Download folder contents via gdown
gdown --folder "https://drive.google.com/drive/folders/$FOLDER_ID" --remaining-ok || true

# Find the latest ROM zip file
LATEST_FILE=$(ls lineage-*.zip 2>/dev/null | sort -V | tail -n 1)

if [ -z "$LATEST_FILE" ]; then
  echo "No matching ROM ZIP file found in the folder."
  cd ..
  rm -rf drive_tmp
  exit 0
fi

echo "Latest build found: $LATEST_FILE"

# Extract date tag and LineageOS version
BUILD_TAG=$(echo "$LATEST_FILE" | grep -oP '\d{8}')
VERSION=$(echo "$LATEST_FILE" | grep -oP 'lineage-\K[0-9.]+')

if [ -z "$BUILD_TAG" ]; then
  BUILD_TAG="build-$(date +%Y%m%d)"
fi

cd ..

# Check if release tag already exists on GitHub
if gh release view "$BUILD_TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release tag '$BUILD_TAG' already exists on GitHub. Nothing to do."
  rm -rf drive_tmp
  exit 0
fi

# Move build file to root working directory
mv "drive_tmp/$LATEST_FILE" "./$LATEST_FILE"
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
