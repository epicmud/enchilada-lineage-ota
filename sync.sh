#!/bin/bash
FOLDER_ID="1OxNLQFPe-fcaTDJAyeg0uQhq2CoIBbrW/1NajCZVFr2hXQVLXzKA-B4B2ePPZa2J7e" # The folder ID from your GDrive link

# List files in the folder sorted by name/date
LATEST_FILE=$(rclone lsjson --no-check-certificate --drive-root-folder-id "$FOLDER_ID" :drive: | grep -oP '"Path":"\Klineage-[^"]+\.zip' | sort -V | tail -n 1)

if [ -z "$LATEST_FILE" ]; then
  echo "No ROM file found."
  exit 0
fi

echo "Latest build on Drive: $LATEST_FI
LE"
