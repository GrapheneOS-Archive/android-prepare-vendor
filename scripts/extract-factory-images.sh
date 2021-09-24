#!/usr/bin/env bash
#
# Extract system & vendor images from factory archive after converting from sparse to raw
#

set -e # fail on unhandled error
set -u # fail on undefined variable
#set -x # debug

readonly SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
readonly CONSTS_SCRIPT="$SCRIPTS_DIR/constants.sh"
readonly COMMON_SCRIPT="$SCRIPTS_DIR/common.sh"
readonly TMP_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}"/android_img_extract.XXXXXX) || exit 1
declare -a SYS_TOOLS=("find" "bsdtar" "uname" "du" "stat" "tr" "cut" "simg2img" "debugfs" "jq")

abort() {
  # If debug keep work dir for bugs investigation
  if [[ "$-" == *x* ]]; then
    echo "[*] Workspace available at '$TMP_WORK_DIR' - delete manually when done"
  else
    rm -rf "$TMP_WORK_DIR"
  fi
  exit "$1"
}

usage() {
cat <<_EOF
  Usage: $(basename "$0") [options]
    OPTIONS:
      -i|--input    : Archive with factory images as downloaded from
                      Google Nexus images website
      -o|--output   : Path to save contents extracted from images
      --conf-file   : Device configuration file

_EOF
  abort 1
}

extract_archive() {
  local in_archive="$1"
  local out_dir="$2"
  local archiveFile

  echo "[*] Extracting '$in_archive'"

  archiveFile="$(basename "$in_archive")"
  local f_ext="${archiveFile##*.}"
  if [[ "$f_ext" == "tar" || "$f_ext" == "tar.gz" || "$f_ext" == "tgz" ]]; then
    bsdtar xf "$in_archive" -C "$out_dir" || { echo "[-] tar extract failed"; abort 1; }
  elif [[ "$f_ext" == "zip" ]]; then
    bsdtar xf "$in_archive" -C "$out_dir" || { echo "[-] zip extract failed"; abort 1; }
  else
    echo "[-] Unknown archive format '$f_ext'"
    abort 1
  fi
}

extract_partition_size() {
  local partition_img_raw="$2"
  local out_file="$3/${1}_partition_size"
  local size=""

  size="$((du -b "$partition_img_raw" || stat -f %z "$partition_img_raw" || echo "") 2>/dev/null | tr '\t' ' ' | cut -d' ' -f1)"
  if [[ "$size" == "" ]]; then
    echo "[!] Failed to extract vendor partition size from '$partition_img_raw'"
    abort 1
  fi

  # Write to file so that 'generate-vendor.sh' can pick the value
  # for BoardConfigVendor makefile generation
  echo "$size" > "$out_file"
}

extract_vendor_partition_size() {
  extract_partition_size vendor "$1" "$2"
}

extract_product_partition_size() {
  extract_partition_size product "$1" "$2"
}

extract_system_ext_partition_size() {
  extract_partition_size system_ext "$1" "$2"
}

extract_img_data() {
  local image_file="$1"
  local out_dir="$2"
  local logFile="$TMP_WORK_DIR/debugfs.log"

  if [ ! -d "$out_dir" ]; then
    mkdir -p "$out_dir"
  fi

  debugfs -R 'ls -p' "$image_file" 2>/dev/null | cut -d '/' -f6 | while read -r entry
  do
    debugfs -R "rdump \"$entry\" \"$out_dir\"" "$image_file" >> "$logFile" 2>&1 || {
      echo "[-] Failed to extract data from '$image_file'"
      abort 1
    }
  done


  local symlink_err="rdump: Attempt to read block from filesystem resulted in short read while reading symlink"
  if grep -Fq "$symlink_err" "$logFile"; then
    echo "[-] Symlinks have not been properly processed from $image_file"
    echo "[!] You may be using an incompatible debugfs version."
    abort 1
  fi
}

trap "abort 1" SIGINT SIGTERM
. "$CONSTS_SCRIPT"
. "$COMMON_SCRIPT"

INPUT_ARCHIVE=""
OUTPUT_DIR=""
CONFIG_FILE=""

# Compatibility
HOST_OS=$(uname)
if [[ "$HOST_OS" != "Linux" ]]; then
  echo "[-] '$HOST_OS' OS is not supported"
  abort 1
fi

while [[ $# -gt 0 ]]
do
  arg="$1"
  case $arg in
    -o|--output)
      OUTPUT_DIR=$(echo "$2" | sed 's:/*$::')
      shift
      ;;
    -i|--input)
      INPUT_ARCHIVE=$2
      shift
      ;;
    --conf-file)
      CONFIG_FILE="$2"
      shift
      ;;
    *)
      echo "[-] Invalid argument '$1'"
      usage
      ;;
  esac
  shift
done

# Check that system tools exist
for i in "${SYS_TOOLS[@]}"
do
  if ! command_exists "$i"; then
    echo "[-] '$i' command not found"
    abort 1
  fi
done

# Input args check
check_dir "$OUTPUT_DIR" "Output"
check_file "$INPUT_ARCHIVE" "Input archive"
check_file "$CONFIG_FILE" "Device Config File"

# Fetch required values from config
readonly VENDOR="$(jqRawStrTop "vendor" "$CONFIG_FILE")"

# Prepare output folders
SYSTEM_DATA_OUT="$OUTPUT_DIR/system"
if [ -d "$SYSTEM_DATA_OUT" ]; then
  rm -rf "${SYSTEM_DATA_OUT:?}"/*
fi

VENDOR_DATA_OUT="$OUTPUT_DIR/vendor"
if [ -d "$VENDOR_DATA_OUT" ]; then
  rm -rf "${VENDOR_DATA_OUT:?}"/*
fi

PRODUCT_DATA_OUT="$OUTPUT_DIR/product"
if [ -d "$PRODUCT_DATA_OUT" ]; then
  rm -rf "${PRODUCT_DATA_OUT:?}"/*
fi

SYSTEM_EXT_DATA_OUT="$OUTPUT_DIR/system_ext"
if [ -d "$SYSTEM_EXT_DATA_OUT" ]; then
  rm -rf "${SYSTEM_EXT_DATA_OUT:?}"/*
fi

RADIO_DATA_OUT="$OUTPUT_DIR/radio"
if [ -d "$RADIO_DATA_OUT" ]; then
  rm -rf "${RADIO_DATA_OUT:?}"/*
fi
mkdir -p "$RADIO_DATA_OUT"

archiveName="$(basename "$INPUT_ARCHIVE")"
fileExt="${archiveName##*.}"
archName="$(basename "$archiveName" ".$fileExt")"
extractDir="$TMP_WORK_DIR/$archName"
mkdir -p "$extractDir"

# Extract archive
extract_archive "$INPUT_ARCHIVE" "$extractDir"

hasProductImg=false
hasSystemExtImg=false
if [[ -f "$extractDir/system.img" && -f "$extractDir/vendor.img" ]]; then
  sysImg="$extractDir/system.img"
  vImg="$extractDir/vendor.img"
  if [[ -f "$extractDir/product.img" ]]; then
    pImg="$extractDir/product.img"
    hasProductImg=true
  fi
  if [[ -f "$extractDir/system_ext.img" ]]; then
    sysExtImg="$extractDir/system_ext.img"
    hasSystemExtImg=true
  fi
else
  updateArch=$(find "$extractDir" -iname "image-*.zip" | head -n 1)
  echo "[*] Extracting '$(basename "$updateArch")'"
  mkdir -p "$extractDir/images" && bsdtar xf "$updateArch" -C "$extractDir/images" || {
    echo "[-] extraction failed"
    abort 1
  }
  sysImg="$extractDir/images/system.img"
  vImg="$extractDir/images/vendor.img"
  if [[ -f "$extractDir/images/product.img" ]]; then
    pImg="$extractDir/images/product.img"
    hasProductImg=true
  fi
  if [[ -f "$extractDir/images/system_ext.img" ]]; then
    sysExtImg="$extractDir/images/system_ext.img"
    hasSystemExtImg=true
  fi
fi

# Baseband image
hasRadioImg=true
radioImg=$(find "$extractDir" -iname "radio-*.img" | head -n 1)
if [[ "$radioImg" == "" ]]; then
  echo "[!] No baseband firmware present - skipping"
  hasRadioImg=false
fi

# Bootloader image
bootloaderImg=$(find "$extractDir" -iname "bootloader-*.img" | head -n 1)
if [[ "$bootloaderImg" == "" ]]; then
  echo "[-] Failed to locate bootloader image"
  abort 1
fi

# Convert from sparse to raw
rawSysImg="$extractDir/images/system.img.raw"
rawVImg="$extractDir/images/vendor.img.raw"
rawPImg="$extractDir/images/product.img.raw"
rawSysExtImg="$extractDir/images/system_ext.img.raw"

simg2img "$sysImg" "$rawSysImg" || {
  echo "[-] simg2img failed to convert system.img from sparse"
  abort 1
}
simg2img "$vImg" "$rawVImg" || {
  echo "[-] simg2img failed to convert vendor.img from sparse"
  abort 1
}
if [ $hasProductImg = true ]; then
  simg2img "$pImg" "$rawPImg" || {
    echo "[-] simg2img failed to convert product.img from sparse"
    abort 1
  }
fi
if [ $hasSystemExtImg = true ]; then
  simg2img "$sysExtImg" "$rawSysExtImg" || {
    echo "[-] simg2img failed to convert system_ext.img from sparse"
    abort 1
  }
fi

# Save raw vendor img partition size
extract_vendor_partition_size "$rawVImg" "$OUTPUT_DIR"
if [ $hasProductImg = true ]; then
  extract_product_partition_size "$rawPImg" "$OUTPUT_DIR"
fi
if [ $hasSystemExtImg = true ]; then
  extract_system_ext_partition_size "$rawSysExtImg" "$OUTPUT_DIR"
fi

# Extract raw system, vendor, product, and system_ext images. Data will be processed later
extract_img_data "$rawSysImg" "$SYSTEM_DATA_OUT"
extract_img_data "$rawVImg" "$VENDOR_DATA_OUT"
if [ $hasProductImg = true ]; then
  extract_img_data "$rawPImg" "$PRODUCT_DATA_OUT"
fi
if [ $hasSystemExtImg = true ]; then
  extract_img_data "$rawSysExtImg" "$SYSTEM_EXT_DATA_OUT"
fi

# Copy bootloader & radio images
if [ $hasRadioImg = true ]; then
  mv "$radioImg" "$RADIO_DATA_OUT/" || {
    echo "[-] Failed to copy radio image"
    abort 1
  }
fi
mv "$bootloaderImg" "$RADIO_DATA_OUT/" || {
  echo "[-] Failed to copy bootloader image"
  abort 1
}

abort 0
