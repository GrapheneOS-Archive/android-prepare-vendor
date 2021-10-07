#!/usr/bin/env bash

set -euo pipefail

usage() {
cat <<_EOF
  Usage: $(basename "$0") [options]
    OPTIONS:
      -o|--output  : Path to save carrier list
_EOF
  exit 1
}

OUTPUT_DIR=""

while [[ $# -gt 0 ]]
do
  arg="$1"
  case $arg in
    -o|--output)
      OUTPUT_DIR=$(echo "$2" | sed 's:/*$::')
      shift
      ;;
    *)
      echo "[-] Invalid argument '$1'"
      usage
      ;;
  esac
  shift
done

if [[ "$OUTPUT_DIR" == "" || ! -d "$OUTPUT_DIR" ]]; then
  echo "[-] Output directory not found"
  usage
fi

url='https://android.googlesource.com/platform/packages/providers/TelephonyProvider/+/android12-release/assets/latest_carrier_id/carrier_list.pb?format=TEXT'
echo "[*] Downloading carrier list from '$url'"
curl -fS "$url" | base64 --decode > "$OUTPUT_DIR"/carrier_list.pb
