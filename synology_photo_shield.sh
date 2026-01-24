#!/bin/bash
# ============================================================================
# SCRIPT: synology_photo_shield.sh
# DESCRIPTION: Securely integrates a photos-viewer of external photo libraries
#              into Synology Photos with full app functionality and enforced
#              Read-Only protection.
#
# LICENSE: MIT License
# COPYRIGHT: (c) 2026 Francisco Mata
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
# OPERATIONAL WORKFLOW:
#   1. PRE-CHECK: Wait for Synology Photos indexing engine to be idle.
#   2. CLEANUP: Clear target directory of existing mounts and empty folders.
#   3. INITIALIZATION: Recreate directory structure for the new mounts.
#   4. EXECUTION: Mount external sources and trigger indexing task.
#   5. MONITORING: Wait for indexing process to fully complete.
#   6. ENFORCEMENT: Secure directories with strictly Read-Only permissions.
#
# NOTE: Highly recommended to run at System Boot or low usage periods,
# as full Read-Only protection is finalized only after indexing completes.
# =============================================================================



# ----------------------------------------------------------------------------
# BASIC CONFIGURATION
# ----------------------------------------------------------------------------
# Delay in seconds before the script starts, vital for 'on boot' tasks (300)
SLEEP_START=150

# Set the parent folder containing your gallery subfolders
ROOT_SRC="/volume1/homes/<path_to_user_gallery_folder>"

# Destination in Synology Photos Shared Space (default: /volume1/photo)
ROOT_DST="/volume1/photo"

# List of folder in ROOT_SRC to not include in Synology Photos
DISCARD=("@eaDir" "#recycle" "Backups_Synology" "temp")

# Include manually extra folders to mount (Full absolute paths)
EXTRA_SRC_DIRS=()

# ----------------------------------------------------------------------------
# ADVANCED SYSTEM CONFIGURATION (DSM INTERNAL PROCESSES)
# ----------------------------------------------------------------------------
# Official Synology Photos CLI tool for library indexing and metadata tasks
INDEX_TOOL="/var/packages/SynologyPhotos/target/usr/bin/synofoto-bin-index-tool"

# Internal engine to monitor before locking read-only mode.
PHOTOS_ENG="synofoto-task-center"

# Duration in seconds of the observation to monitor photos engine activity (30)
MONITOR_TIMEOUT=30

# CPU percentage threshold. Activity above this value is considered busy (6)
CPU_THRESHOLD=6



# ----------------------------------------------------------------------------
# SCRIPT FUNCTIONS DEFINITION
# ----------------------------------------------------------------------------
log_info() {
    # """
    # Prints an informational message with a timestamp and white [INFO] tag.
    # Args: $1 (message): The string to be logged.
    # """
    printf "$(date '+[%H:%M:%S]') [INFO] %s\n" "${1}"
}

log_warning() {
    # """
    # Prints a warning message with a timestamp and yellow [WARN] tag.
    # Args: $1 (message): The string to be logged.
    # """
    printf "$(date '+[%H:%M:%S]') [WARN] %s\n" "${1}"
}

log_error() {
    # """
    # Prints an error message with a timestamp and red [ERROR] tag.
    # Args: $1 (message): The string to be logged.
    # """
    printf "$(date '+[%H:%M:%S]') [ERROR] %s\n" "${1}"
}

release_directory_mounts() {
    # """
    # Detects and forces the unmounting of any active mounts within a specific root directory.
    #
    # Args:
    #   $1 (target_root): The parent directory to scan for sub-mounts.
    #
    # Returns:
    #   0: All mounts were successfully released or none were found.
    #   1: Some mounts failed to unmount
    # """
    local target_root="${1}"
    log_info "Detecting and releasing previous mounts in $target_root..."

    # Extract mounted paths specifically under the target_root
    mount | grep "on $target_root/" | awk -F' on ' '{print $2}' | awk -F' type ' '{print $1}' | while read -r mounted_path; do
        if [ ! -z "$mounted_path" ]; then
            log_info "Releasing mount: $mounted_path"
            
            # Force unmount (-f) to ensure the directory is freed
            if umount -f "$mounted_path"; then
                sleep 0.5
            else
                log_error "Failed to unmount: $mounted_path"
                return 1
            fi
        fi
    done
    return 0
}

cleanup_empty_directories() {
    # """
    # Scans subdirectories within a root directory and removes those that do not 
    # contain "real" files, ignoring system-specific folders like @eaDir or #recycle.
    #
    # Args:
    #   $1 (target_root): The parent directory to scan for cleanup.
    #
    # Returns:
    #   0: Cleanup completed successfully.
    #   1: Target directory is invalid or empty.
    # """
    local target_root="${1}"

    if [[ -z "$target_root" || ! -d "$target_root" ]]; then
        log_error "Invalid or missing target directory: [$target_root]"
        return 1
    fi

    log_info "Cleaning up empty leftover directories in $target_root..."

    # Iterate through each item in the target directory
    for dir in "$target_root"/*; do
        # Skip if it's not a directory
        [[ -d "$dir" ]] || continue

        # Protection for Synology root system folders
        local dir_name=$(basename "$dir")
        case "$dir_name" in
            ("@eaDir"|"#recycle"|"@tmp"|".@__thumb")
                continue
                ;;
        esac

        # Count real files, excluding Synology/system metadata patterns
        # -type f: only files
        # ! -path: exclude specific patterns
        local real_files_count
        real_files_count=$(find "$dir" -type f \
            ! -path "*/@eaDir/*" \
            ! -path "*/#recycle/*" \
            ! -name "@eaDir" \
            ! -name "#recycle" | wc -l)

        local dir_name
        dir_name=$(basename "$dir")

        if [ "$real_files_count" -eq 0 ]; then
            log_info "Removing empty tree or system-only folder: [$dir_name]"
            # Use with caution: deletes the directory and system metadata within it
            rm -rf "$dir"
        fi
    done

    return 0
}

verify_destination_security() {
    # """
    # Checks if existing destination directories are empty (ignoring system folders).
    #
    # Returns:
    #   0: All existing folders are empty and safe.
    #   1: Missing arguments or empty arrays.
    #   3: Security error: An existing destination contains real data.
    # """
    local -n _dst_paths=$1
    local -n _folder_names=$2

    if [[ -z "$1" || ${#_dst_paths[@]} -eq 0 ]]; then
        log_error "Security Check: No destination paths provided."
        return 1
    fi

    for i in "${!_dst_paths[@]}"; do
        local target="${_dst_paths[$i]}"
        local name="${_folder_names[$i]}"

        # If the directory exists, it MUST be empty
        if [ -d "$target" ]; then
            local real_files
            real_files=$(ls -A "$target" 2>/dev/null | grep -vE "@eaDir|#recycle" | wc -l)

            if [ "$real_files" -ne 0 ]; then
                log_error "Security Breach: Destination [$name] is NOT empty. Data detected."
                return 3
            fi
        fi
    done
    return 0
}

create_destination_directories() {
    # """
    # Creates destination directories if they do not exist.
    #
    # Returns:
    #   0: All directories exist or were created successfully.
    #   1: Missing arguments or empty arrays.
    #   2: Execution error: Failed to create a directory.
    # """
    local -n _dst_paths=$1
    local -n _folder_names=$2

    if [[ -z "$1" || ${#_dst_paths[@]} -eq 0 ]]; then
        log_error "Folder Creation: No paths provided."
        return 1
    fi

    for i in "${!_dst_paths[@]}"; do
        local target="${_dst_paths[$i]}"
        local name="${_folder_names[$i]}"

        if [ ! -d "$target" ]; then
            log_info "Creating missing folder: $name"
            if ! mkdir -p "$target"; then
                log_error "Critical Error: Could not create $target"
                return 2
            fi
            sleep 0.1
        else
            log_info "Destination folder already exists: $name"
        fi
    done
    return 0
}

execute_bind_mounts() {
    # """
    # Performs bind mounts from a list of source directories to destination directories.
    #
    # Args:
    #   $1 (ref_src_paths): Reference to the array of source paths.
    #   $2 (ref_dst_paths): Reference to the array of destination paths.
    #
    # Returns:
    #   0: All mounts succeeded.
    #   1: Mount failed.
    # """
    declare -n src_list="$1"
    declare -n dst_list="$2"

    local mount_count=0

    for i in "${!dst_list[@]}"; do
        local source="${src_list[$i]}"
        local dest="${dst_list[$i]}"

        log_info "Mounting: [$source] into [$dest]"

        if mount -o bind "$source" "$dest"; then
            ((mount_count++))
        else
            log_error "Failure: Could not mount $source"
            return 1
        fi
    done

    log_info "Total successful mounts: $mount_count"
    return 0
}

run_photos_index() {
    # """
    # Runs the Synology Photos indexing tool on a specific directory.
    #
    # Args:
    #   $1 (index_tool): Path to the synofoto-index-tool binary.
    #   $2 (target_dir): The root directory to be indexed.
    #
    # Returns:
    #   0: Indexing completed successfully.
    #   1: Indexing failed.
    # """
    local index_tool="${1}"
    local target_dir="${2}"

    if [ ! -f "$index_tool" ]; then
        log_error "Index tool not found at: $index_tool"
        return 1
    fi

    log_info "Starting Synology Photos index on: $target_dir"

    # Execution as SynologyPhotos user (as you confirmed it works)
    if sudo -u SynologyPhotos "$index_tool" -i "$target_dir" -t basic 2>&1; then
        log_info "Indexing process launched successfully."
        return 0
    else
        log_error "Indexing process failed to launch."
        return 1
    fi
}

check_process_activity() {
    # """
    # Monitors a specific process for CPU activity above a given threshold.
    #
    # This function uses the 'top' command to sample the real-time CPU usage 
    # of a process. If the integer value of the CPU usage meets or exceeds 
    # the threshold, the function exits early.
    #
    # Args:
    #   $1 (process_name): Name of the process to monitor (e.g., "synofoto-task-center").
    #   $2 (threshold):    Integer CPU percentage threshold (e.g., 5 for 5%).
    #   $3 (timeout):      Maximum monitoring time in seconds.
    #
    # Returns:
    #   0: No activity detected above threshold within the timeout period.
    #   1: Activity detected above threshold (early exit).
    # """
    local process_name="${1}"
    local threshold="${2}"
    local timeout="${3}"
    
    log_info "Monitoring: [$process_name] for $timeout seconds..."
    for i in $(seq 1 "$timeout"); do
        # Find the PID using the logic validated for this NAS
        local pid=$(ps auxww | grep "$process_name" | grep -v grep | awk '{print $2}' | head -n 1)

        if [ ! -z "$pid" ]; then
            # Capture Column %CPU from the second iteration of top
            local top_output=$(top -b -n 2 -d 0.2)
            local col_idx=$(echo "$top_output" | grep "PID" | tail -n 1 | awk '{for(i=1;i<=NF;i++) if($i=="%CPU") print i}')
            local cpu_val=$(echo "$top_output" | grep -w "^ *${pid}" | tail -n 1 | awk -v col="$col_idx" '{print $col}' | cut -d. -f1 | tr -d ' ')
            
            # local dbg_line=$(echo "$top_output" | grep -w "^ *${pid}" | tail -n 1)
            # log_info "DEBUG LINE: [$dbg_line]"

            # Check if cpu_val is a number and compare to threshold
            if [ "${cpu_val:-0}" -ge "$threshold" ] 2>/dev/null; then
                log_info "Activity detected: ${cpu_val}%"
                return 1
            fi
        fi
        sleep 1
    done

    return 0
}

execute_readonly_bind_mounts() {
    # """
    # Performs bind mounts in Read-Only mode from source to destination arrays.
    # It first creates the bind and then remounts it as read-only for security.
    #
    # Args:
    #   $1 (ref_src_paths): Reference to the array of source paths.
    #   $2 (ref_dst_paths): Reference to the array of destination paths.
    #
    # Returns:
    #   0: All mounts succeeded and are locked as Read-Only.
    #   1: Any mount or remount operation failed.
    # """
    local -n src_list="$1"
    local -n dst_list="$2"

    local mount_count=0

    for i in "${!dst_list[@]}"; do
        local source="${src_list[$i]}"
        local dest="${dst_list[$i]}"

        log_info "Mounting (RO): [$source] -> [$dest]"

        # Step 1: Perform the bind mount
        if mount --bind "$source" "$dest"; then
            # Step 2: Remount as Read-Only to block any write operations
            if mount -o remount,ro,bind "$dest"; then
                ((mount_count++))
            else
                log_error "Failure: Could not set Read-Only lock on $dest"
                return 1
            fi
        else
            log_error "Failure: Could not perform bind mount for $source"
            return 1
        fi
    done

    log_info "Total successful read-only mounts: $mount_count"
    return 0
}

# ----------------------------------------------------------------------------
# PHASE 1: INITIALIZATION AND DESTINATION CLEANUP
# ----------------------------------------------------------------------------
echo
log_info "Waiting $SLEEP_START seconds to ensure system services are ready..."
sleep $SLEEP_START

log_info "Waiting for SynologyPhotos to stop operating..."
while ! check_process_activity "$PHOTOS_ENG" "$CPU_THRESHOLD" 30; do
    log_info "Synology Photos is still active. waiting..."
done

echo
log_info "PHASE 1: Preparing destination directory $ROOT_DST..."
release_directory_mounts "$ROOT_DST" || exit 1
cleanup_empty_directories "$ROOT_DST" || exit 2

# ----------------------------------------------------------------------------
# PHASE 2: SCAN AND GENERATE MOUNT PATHS
# ----------------------------------------------------------------------------
echo
log_info "PHASE 2: Scanning paths to be mounted..."

# Arrays to store final paths
SRC_PATHS=()
DST_PATHS=()
FOLDER_NAMES=()

# Registers extra source directories and includes their destination mapping.
for extra_path in "${EXTRA_SRC_DIRS[@]}"; do
    if [ -d "$extra_path" ]; then
        name=$(basename "$extra_path")
        SRC_PATHS+=("$extra_path")
        DST_PATHS+=("$ROOT_DST/$name")
        FOLDER_NAMES+=("$name")
        log_info "Manual extra folder injected: [$extra_path]"
    else
        echo
        log_error "Manual extra folder not found: [$extra_path]"
        exit 3
    fi
done

# Discover subdirectories while skips those defined in the DISCARD exclusion list.
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
        log_info "Folder included in paths: [$path]"
    fi
done

# ----------------------------------------------------------------------------
# PHASE 3: PREPARE DESTINATION POINTS
# ----------------------------------------------------------------------------
echo
log_info "PHASE 3: preparing destination points in $ROOT_DST..."
verify_destination_security DST_PATHS FOLDER_NAMES || exit 3
create_destination_directories DST_PATHS FOLDER_NAMES || exit 4

# ----------------------------------------------------------------------------
# PHASE 4: MOUNT THE FOLDERS AND LAUNCH INDEXER
# ----------------------------------------------------------------------------
echo
log_info "PHASE 4: Mounting folders..."
execute_bind_mounts SRC_PATHS DST_PATHS || exit 5
sleep 10  # Short delay for the file system to stabilize after mounting
run_photos_index "$INDEX_TOOL" "$ROOT_DST" || exit 6
sleep 60  # Grace period for Synology Photos to initialize in the process list

# ----------------------------------------------------------------------------
# PHASE 5: WAITING FOR SYNOLOGY PHOTOS SYNCHRONIZATION
# ----------------------------------------------------------------------------
echo
log_info "PHASE 5: Waiting for SynologyPhotos indexing to complete..."
while ! check_process_activity "$PHOTOS_ENG" "$CPU_THRESHOLD" "$MONITOR_TIMEOUT"; do
    log_info "Indexing is still active. waiting..."
done

# ----------------------------------------------------------------------------
# PHASE 6: SECURE DIRECTORIES WITH READ-ONLY MOUNTS
# ----------------------------------------------------------------------------
echo
log_info "PHASE 6: Securing directories with Read-Only bind mounts..."
if ! execute_readonly_bind_mounts SRC_PATHS DST_PATHS; then
    log_error "Critical failure. Aborting script."
    exit 7
fi
log_info "All directories successfully mounted in Read-Only mode."
