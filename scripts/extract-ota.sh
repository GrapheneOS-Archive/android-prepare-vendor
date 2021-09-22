#!/usr/bin/env bash
#
# Extract images from ota zip
#

set -e # fail on unhandled error
set -u # fail on undefined variable
#set -x # debug

readonly SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
readonly CONSTS_SCRIPT="$SCRIPTS_DIR/constants.sh"
readonly COMMON_SCRIPT="$SCRIPTS_DIR/common.sh"
readonly EXTRACT_PAYLOAD_SCRIPT="$SCRIPTS_DIR/extract_android_ota_payload/extract_android_ota_payload.py"
readonly TMP_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}"/android_img_extract.XXXXXX) || exit 1
declare -a SYS_TOOLS=("tar" "find" "unzip" "uname" "du" "stat" "tr" "cut")

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
      -i|--input    : Archive with ota as downloaded from
                      Google Nexus ota website
      -o|--output   : Path to save contents extracted from ota
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
    tar -xf "$in_archive" -C "$out_dir" || { echo "[-] tar extract failed"; abort 1; }
  elif [[ "$f_ext" == "zip" ]]; then
    unzip -qq "$in_archive" -d "$out_dir" || { echo "[-] zip extract failed"; abort 1; }
  else
    echo "[-] Unknown archive format '$f_ext'"
    abort 1
  fi
}

extract_payload() {
  local otaFile="$1"
  local out_dir="$2"
  $EXTRACT_PAYLOAD_SCRIPT $out_dir/payload.bin $out_dir $otaFile
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
readonly OTA_IMGS_LIST="$(jqIncRawArrayTop "ota-partitions" "$CONFIG_FILE")"
if [[ "$OTA_IMGS_LIST" != "" ]]; then
  readarray -t OTA_IMGS < <(echo "$OTA_IMGS_LIST")
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

# For Pixel devices with AB partitions layout, copy additional images required for OTA
if [[ "$VENDOR" == "google" && "$OTA_IMGS_LIST" != "" ]]; then
  for img in "${OTA_IMGS[@]}"
  do
    extract_payload "$img.img" "$extractDir"
    if [ ! -f "$extractDir/$img.img" ]; then
      echo "[-] Failed to locate '$img.img' in ota zip"
      abort 1
    fi
    mv "$extractDir/$img.img" "$RADIO_DATA_OUT/"
  done
fi

abort 0
