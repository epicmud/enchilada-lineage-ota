#!/bin/bash
set -e

FOLDER_ID="${GDRIVE_FOLDER_ID}"
REPO="${GITHUB_REPOSITORY:-epicmud/enchilada-lineage-ota}"

echo "Checking Google Drive folder for LineageOS builds..."

pip3 install --quiet gdown

mkdir -p drive_tmp

FOLDER_URL="https://drive.google.com/drive/folders/$FOLDER_ID"
FILES_JSON=$(gdown "$FOLDER_URL" --json 2>/dev/null || true)

if [ -z "$FILES_JSON" ]; then
  echo "Error: Failed to fetch folder contents from Google Drive."
  rm -rf drive_tmp
  exit 1
fi

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
    url = f.get("url") or (
        "https://drive.google.com/uc?id=" + fid if fid else ""
    )

    if path.lower().endswith(".zip") and "lineage" in path.lower():
        zips.append({
            "path": path,
            "url": url
        })

if not zips:
    print("NONE")
    sys.exit(0)

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

BUILD_TAG=$(echo "$LATEST_FILE" | grep -oP '\d{8}' | head -1)
VERSION=$(echo "$LATEST_FILE" | grep -oP 'lineage-\K[0-9.]+' | head -1)

if [ -z "$BUILD_TAG" ]; then
  BUILD_TAG="build-$(date +%Y%m%d)"
fi

if [ -z "$VERSION" ]; then
  echo "Error: Could not determine LineageOS version."
  exit 1
fi

if gh release view "$BUILD_TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release tag '$BUILD_TAG' already exists on GitHub."

  # Important:
  # Even if the release already exists, regenerate the OTA JSON.
  # This allows the endpoint format to be corrected without
  # requiring a new ROM release.

else
  echo "Downloading target build asset $LATEST_FILE..."

  gdown "$URL" -O "./$LATEST_FILE"

  SHA256=$(sha256sum "$LATEST_FILE" | awk '{print $1}')
  FILESIZE=$(stat -c%s "$LATEST_FILE")

  gh release create "$BUILD_TAG" "./$LATEST_FILE" \
    --title "LineageOS $VERSION ($BUILD_TAG)" \
    --notes "Automated OTA build synced from Google Drive." \
    --repo "$REPO"

  rm -f "$LATEST_FILE"
fi

# Obtain release asset information directly from GitHub
ASSET_URL="https://github.com/$REPO/releases/download/$BUILD_TAG/$LATEST_FILE"

echo "Obtaining release asset metadata..."

RELEASE_JSON=$(gh release view "$BUILD_TAG" \
  --repo "$REPO" \
  --json assets)

SHA256=$(echo "$RELEASE_JSON" | python3 -c '
import sys, json

data = json.load(sys.stdin)

for asset in data["assets"]:
    if asset["name"] == sys.argv[1]:
        print(asset.get("digest", "").replace("sha256:", ""))
        break
' "$LATEST_FILE")

FILESIZE=$(echo "$RELEASE_JSON" | python3 -c '
import sys, json

data = json.load(sys.stdin)

for asset in data["assets"]:
    if asset["name"] == sys.argv[1]:
        print(asset["size"])
        break
' "$LATEST_FILE")

if [ -z "$SHA256" ]; then
  echo "Error: Could not determine SHA256."
  exit 1
fi

if [ -z "$FILESIZE" ]; then
  echo "Error: Could not determine file size."
  exit 1
fi

YEAR=${BUILD_TAG:0:4}
MONTH=${BUILD_TAG:4:2}
DAY=${BUILD_TAG:6:2}

DATETIME=$(date -u -d "${YEAR}-${MONTH}-${DAY} 00:00:00" +%s)

mkdir -p v1/enchilada

cat <<EOF > v1/enchilada/unofficial
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

cp v1/enchilada/unofficial ota.json

echo "Generated OTA JSON:"
cat ota.json

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

git add ota.json v1/

if git diff --cached --quiet; then
  echo "OTA endpoint is already up to date."
else
  git commit -m "Update OTA endpoint for build $BUILD_TAG"
  git push
fi

echo "Successfully updated OTA endpoint!"
