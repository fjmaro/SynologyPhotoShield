#!/bin/bash
# ============================================================================
# SCRIPT: synology_photo_shield.sh
# DESCRIPTION: Securely integrates a photos-viewer of external photo libraries
#              into Synology Photos with full app functionality and enforced
#              Read-Only protection.
#
# LICENSE: MIT License
# COPYRIGHT: (c) 2026 Francisco Mata Aroco
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software, provided that the above copyright notice is included in 
# all copies or substantial portions of the Software.
# ============================================================================
# AUTHOR: Francisco Mata Aroco
# GITHUB: https://github.com/fjmaro/SynologyPhotoShield
# VERSION: 1.0
# DSM VER: 7.3.2 (Tested)
# ============================================================================


# ----------------------------------------------------------------------------
# BASIC CONFIGURATION
# ----------------------------------------------------------------------------
# Set the parent folder containing your gallery subfolders
ROOT_SRC="/volume1/homes/<path_to_user_gallery_folder>"

# Destination in Synology Photos Shared Space (default: /volume1/photo)
ROOT_DST="/volume1/photo"

# List of folder in ROOT_SRC to not include in Synology Photos
DISCARD=("@eaDir" "#recycle" "Backups_Synology" "temp")

# Delay before the script starts, vital for 'on boot' tasks [30]
SLEEP_START=30

# Stabilization delay after mounting before indexing starts [10]
SLEEP_STABILIZE=10

# Time to wait for Synology Photos to trigger its internal engines [15]
SLEEP_MONITOR=15

# Official Synology Photos CLI tool for library indexing and metadata tasks
INDEX_TOOL="/var/packages/SynologyPhotos/target/usr/bin/synofoto-bin-index-tool"

# Include manually extra folders to mount (Full absolute paths)
EXTRA_SRC_DIRS=()

# ----------------------------------------------------------------------------
# PHASE 1: INITIALIZATION AND GLOBAL DESTINATION CLEANUP
# ----------------------------------------------------------------------------
echo -e "\n[INFO] Waiting $SLEEP_START seconds to ensure system services are ready..."
sleep $SLEEP_START

echo -e "\n[INFO] PHASE 1: Detecting previous mounts in $ROOT_DST..."
mount | grep "on $ROOT_DST/" | awk -F' on ' '{print $2}' | awk -F' type ' '{print $1}' | while read -r mounted_path; do
    echo "[INFO] -> Releasing mount: $mounted_path"
    umount -f "$mounted_path"
    sleep 0.5
done

# ----------------------------------------------------------------------------
# PHASE 2: SCAN AND GENERATE MOUNT PATHS
# ----------------------------------------------------------------------------
echo -e "\n[INFO] PHASE 2: Scanning and generating paths to be mounted..."

# Arrays to store final paths
SRC_PATHS=()
DST_PATHS=()
FOLDER_NAMES=()

for extra_path in "${EXTRA_SRC_DIRS[@]}"; do
    if [ -d "$extra_path" ]; then
        name=$(basename "$extra_path")
        SRC_PATHS+=("$extra_path")
        DST_PATHS+=("$ROOT_DST/$name")
        FOLDER_NAMES+=("$name")
        echo "[INFO] Manual extra folder injected: [$extra_path]"
    else
        echo -e "\n[ERROR] Manual folder not found: [$extra_path]"
        exit 1
    fi
done

for path in "$ROOT_SRC"/*; do
    [ -d "$path" ] || continue
    
    # Apply DISCARD filter
    skip=0
    name=$(basename "$path")
    for disc in "${DISCARD[@]}"; do
        if [ "$name" == "$disc" ]; then
            skip=1
            break
        fi
    done
    
    if [ $skip -eq 0 ]; then
        SRC_PATHS+=("$path")
        DST_PATHS+=("$ROOT_DST/$name")
        FOLDER_NAMES+=("$name")
        echo "[INFO] Folder detected: [$path]"
    fi
done

# ----------------------------------------------------------------------------
# PHASE 3: PREPARE DESTINATION POINTS
# ----------------------------------------------------------------------------
echo -e "\n[INFO] PHASE 3: Validating destination points in $ROOT_DST..."
HAS_ERROR=0

for i in "${!DST_PATHS[@]}"; do
    target="${DST_PATHS[$i]}"
    name="${FOLDER_NAMES[$i]}"

    # Ensure destination directory exists and is empty
    if [ ! -d "$target" ]; then
        echo "[INFO] -> Creating destination folder: $name"
        mkdir -p "$target"
        sleep 0.5
    fi

    if [ "$(ls -A "$target")" ]; then
        echo "[ERROR] -> Destination [$name] is NOT empty. Potential real data detected."
        HAS_ERROR=1
    else
        echo "[INFO] -> Destination point ready and verified: $name"
    fi
done

if [ $HAS_ERROR -eq 1 ]; then
    echo -e "\n[ERROR] Mount aborted due to security errors at destination."
    exit 1
fi

# ----------------------------------------------------------------------------
# PHASE 4: MOUNTING AND REFRESHING
# ----------------------------------------------------------------------------
echo -e "\n[INFO] PHASE 4: Executing bind mounts..."
MOUNT_COUNT=0
HAS_MOUNT_ERROR=0

for i in "${!DST_PATHS[@]}"; do
    source="${SRC_PATHS[$i]}"
    dest="${DST_PATHS[$i]}"
    name="${FOLDER_NAMES[$i]}"

    echo "[INFO] Mounting [$name]..."
    
    # Executing the bind mount in RW mode for indexing
    mount -o bind "$source" "$dest"
    
    if [ $? -eq 0 ]; then
        echo "[INFO] -> Success."
        ((MOUNT_COUNT++))
    else
        echo "[ERROR] -> Failure."
        HAS_MOUNT_ERROR=1
    fi
done

if [ $HAS_MOUNT_ERROR -eq 1 ]; then
    echo -e "\n[ERROR] Process completed with errors. Some folders were not mounted."
    exit 1
else
    echo "[INFO] All $MOUNT_COUNT folders successfully mounted."
fi
sleep $SLEEP_STABILIZE

# ----------------------------------------------------------------------------
# PHASE 5: WAITING FOR SYNOLOGY PHOTOS SYNCHRONIZATION
# ----------------------------------------------------------------------------
echo -e "\n[INFO] PHASE 5: Monitoring Synology Photos background processes..."

for i in "${!DST_PATHS[@]}"; do
    dest="${DST_PATHS[$i]}"
    name="${FOLDER_NAMES[$i]}"

    echo "[INFO] Processing: $name"
    
    # 1. 'basic' is key: it only indexes files not already in the database.
    # It is much faster than 'reindex' and avoids API Error 103.
    if [ -f "$INDEX_TOOL" ]; then
        # Running as SynologyPhotos user so the App "owns" the metadata process
        sudo -u SynologyPhotos "$INDEX_TOOL" -i "$dest" -t basic 2>&1
    else
        echo -e "\n[ERROR] Indexing tool not found at $INDEX_TOOL"
        exit 1
    fi

    echo "[INFO] -> Sync triggered for: $name"
done

echo "[INFO] All folders submitted for indexing. Waiting for background tasks..."
sleep $SLEEP_MONITOR

# Monitor the 3 main Synology Photos engines (Indexing, Thumbnails, and Scanner)
while ps w | grep -v grep | grep -E "synofoto-bin-index-tool|synofoto-bin-thumb-tool|synofoto-scand" > /dev/null; do
    echo "[INFO] Synology Photos is active... (Generating thumbnails/metadata). Waiting 30s."
    sleep 30
done
echo "[INFO] Indexing and thumbnail processing completed."

# ----------------------------------------------------------------------------
# PHASE 6: DATA PROTECTION (ARMORING)
# ----------------------------------------------------------------------------
echo -e "\n[INFO] PHASE 6: Applying READ-ONLY (RO) armor to mounts..."
for i in "${!DST_PATHS[@]}"; do
    dest="${DST_PATHS[$i]}"
    name="${FOLDER_NAMES[$i]}"
    
    # Remounting as RO prevents any user or app from deleting your backups
    mount -o remount,ro,bind "$dest"
    
    if [ $? -eq 0 ]; then
        echo "[INFO] -> Secured [$name]"
    else
        echo -e "\n[ERROR] -> Failed to protect [$name]."
        exit 1
    fi
done

echo -e "\n[INFO] Script completed. $MOUNT_COUNT folders successfully mounted and synchronized."
