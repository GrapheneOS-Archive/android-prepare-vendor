#!/usr/bin/env bash
#
# Generate AOSP compatible vendor data for the provided device & build ID
#

set -e # fail on unhandled error
set -u # fail on undefined variable
#set -x # debug

readonly SCRIPTS_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
readonly TMP_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}"/android_prepare_vendor.XXXXXX) || exit 1
declare -a SYS_TOOLS=("mkdir" "curl" "dirname" "date" "touch" "shasum" "bsdtar")

# Realpath implementation in bash (required for macOS support)
readonly REALPATH_SCRIPT="$SCRIPTS_ROOT/scripts/realpath.sh"

# Common & global constants scripts
readonly CONSTS_SCRIPT="$SCRIPTS_ROOT/scripts/constants.sh"
readonly COMMON_SCRIPT="$SCRIPTS_ROOT/scripts/common.sh"

# Helper script to download factory images
readonly DOWNLOAD_SCRIPT="$SCRIPTS_ROOT/scripts/download-nexus-image.sh"

# Helper script to download carrier list
readonly DOWNLOAD_CARRIER_LIST_SCRIPT="$SCRIPTS_ROOT/scripts/carriersettings-extractor/download_carrier_list.sh"

# Helper script to extract system & vendor images data
readonly EXTRACT_SCRIPT="$SCRIPTS_ROOT/scripts/extract-factory-images.sh"

# Helper script to extract carrier settings
readonly EXTRACT_CARRIER_SETTINGS_SCRIPT="$SCRIPTS_ROOT/scripts/carriersettings-extractor/carriersettings_extractor.py"

# Helper script to extract ota data
readonly OTA_SCRIPT="$SCRIPTS_ROOT/scripts/extract-ota.sh"

# Helper script to generate "proprietary-blobs.txt" file
readonly GEN_BLOBS_LIST_SCRIPT="$SCRIPTS_ROOT/scripts/gen-prop-blobs-list.sh"

# Helper script to repair bytecode prebuilt archives
readonly REPAIR_SCRIPT="$SCRIPTS_ROOT/scripts/system-img-repair.sh"

# Helper script to generate vendor AOSP includes & makefiles
readonly VGEN_SCRIPT="$SCRIPTS_ROOT/scripts/generate-vendor.sh"

# Directory with host specific binaries
readonly LC_BIN="$SCRIPTS_ROOT/hostTools/Linux/bin"

abort() {
  rm -rf "$TMP_WORK_DIR"
  exit "$1"
}

usage() {
cat <<_EOF
  Usage: $(basename "$0") [options]
    OPTIONS:
      -d|--device <name> : Device codename (angler, bullhead, etc.)
      -b|--buildID <id>  : BuildID string (e.g. MMB29P)
      -o|--output <path> : Path to save generated vendor data
      -i|--img <path>    : [OPTIONAL] Read factory image archive from file instead of downloading
      -O|--ota <path>    : [OPTIONAL] Read OTA image archive from file instead of downloading
      -j|--java <path    : [OPTIONAL] Java path to use instead of system auto detected global version
      -k|--keep    : [OPTIONAL] Keep all extracted factory images & repaired data (default: false)
      -s|--skip    : [OPTIONAL] Skip /system bytecode repairing (default: false)
      -y|--yes     : [OPTIONAL] Auto accept Google ToS when downloading Nexus factory images (default: false)
      --force-opt  : [OPTIONAL] Override LOCAL_DEX_PREOPT to always pre-optimize /system bytecode (default: false)
      --deodex-all : [OPTIONAL] De-optimize all packages under /system (default: false)
      --force-vimg : [OPTIONAL] Force factory extracted blobs under /vendor to be always used regardless AOSP definitions (default: false)

    INFO:
      * oatdump is used by default to deoptimize bytecode. Use --skip if such behaviour is undesired.
_EOF
  abort 1
}

check_bash_version() {
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "[-] Minimum supported version of bash is 4.x"
    abort 1
  fi
}

dir_exists_or_create() {
  local path="$1"
  if [[ ! -d "$path" ]]; then
    mkdir -p "$path"
  fi
}

check_compatible_system() {
  local hostOS
  hostOS=$(uname -s)
  if [[ "$hostOS" != "Linux" ]]; then
    echo "[-] '$hostOS' OS is not supported"
    abort 1
  fi
}

check_for_oatdump() {
  if [ ! -f "$SCRIPTS_ROOT/../out/host/linux-x86/bin/oatdump" ]; then
    echo "[*] oatdump has not been compiled. This can be done with 'm oatdump' in your GrapheneOS tree."
    abort 1
  fi
}

is_aosp_root() {
  local targetDir="$1"
  if [ -f "$targetDir/.repo/project.list" ]; then
    return 0
  fi
  return 1
}

check_input_args() {
  if [[ "$DEVICE" == "" ]]; then
    echo "[-] device codename cannot be empty"
    usage
  fi
  if [[ "$BUILDID" == "" ]]; then
    echo "[-] buildId cannot be empty"
    usage
  fi
  if [[ "$OUTPUT_DIR" == "" || ! -d "$OUTPUT_DIR" ]]; then
    echo "[-] Invalid output directory"
    usage
  fi
  if [[ "$INPUT_IMG" != "" && ! -f "$INPUT_IMG" ]]; then
    echo "[-] Invalid '$INPUT_IMG' file"
    abort 1
  fi
  if [[ "$USER_JAVA_PATH" != "" ]]; then
    if  [ ! -f "$USER_JAVA_PATH" ]; then
      echo "[-] '$USER_JAVA_PATH' path not found"
      abort 1
    fi
    if [[ "$(basename "$USER_JAVA_PATH")" != "java" ]]; then
      echo "[-] Invalid java path"
      abort 1
    fi
  fi

  # Some business logic related checks
  if [[ "$DEODEX_ALL" = true && $KEEP_DATA = false ]]; then
    echo "[!] It's pointless to deodex all if not keeping runtime generated data"
    echo "    After vendor generate finishes all files not part of configs will be deleted"
    abort 1
  fi
}

update_java_path() {
  local __javapath=""
  local __javadir=""
  local __javahome=""

  if [[ "$USER_JAVA_PATH" != "" ]]; then
    __javapath=$(_realpath "$USER_JAVA_PATH")
    __javadir=$(dirname "$__javapath")
    __javahome="$__javapath"
    JAVA_FOUND=true
  else
    readonly __JAVALINK=$(command -v java)
    if [[ "$__JAVALINK" == "" ]]; then
      echo "[!] Java not found in system"
    else
      __javapath=$(_realpath "$__JAVALINK")
      __javadir=$(dirname "$__javapath")
      __javahome="$__javapath"
      JAVA_FOUND=true
    fi
  fi

  if [ "$JAVA_FOUND" = true ]; then
    export JAVA_HOME="$__javahome"
    export PATH="$__javadir":$PATH
  fi
}

checkJava() {
  if [ "$JAVA_FOUND" = false ]; then
    echo "[-] Java is required"
    abort 1
  fi
}

check_supported_device() {
  local deviceOK=false
  for devNm in "${SUPPORTED_DEVICES[@]}"
  do
    if [[ "$devNm" == "$DEVICE" ]]; then
      deviceOK=true
    fi
  done
  if [ "$deviceOK" = false ]; then
    echo "[-] '$DEVICE' is not supported"
    abort 1
  fi
}

trap "abort 1" SIGINT SIGTERM
. "$REALPATH_SCRIPT"
. "$CONSTS_SCRIPT"
. "$COMMON_SCRIPT"

# Save the trouble to pass explicit binary paths
export PATH="$PATH:$LC_BIN"

# Global variables
DEVICE=""
BUILDID=""
OUTPUT_DIR=""
INPUT_IMG=""
INPUT_OTA=""
KEEP_DATA=false
SKIP_SYSDEOPT=false
FACTORY_IMGS_DATA=""
CONFIG_FILE=""
USER_JAVA_PATH=""
AUTO_TOS_ACCEPT=true
FORCE_PREOPT=false
BYTECODE_REPAIR_METHOD="OATDUMP"
DEODEX_ALL=false
AOSP_ROOT=""
FORCE_VIMG=false
JAVA_FOUND=false
OTA=false

# Compatibility
check_bash_version
check_compatible_system

# Parse calling arguments
while [[ $# -gt 0 ]]
do
  arg="$1"
  case $arg in
    -o|--output)
      dir_exists_or_create "$2"
      OUTPUT_DIR="$(_realpath "$2")"
      shift
      ;;
    -d|--device)
      DEVICE=$(echo "$2" | tr '[:upper:]' '[:lower:]')
      shift
      ;;
    -b|--buildID)
      BUILDID=$(echo "$2" | tr '[:upper:]' '[:lower:]')
      shift
      ;;
    -i|--img|--imgs)
      INPUT_IMG="$(_realpath "$2")"
      shift
      ;;
    -O|--ota)
      INPUT_OTA="$(_realpath "$2")"
      shift
      ;;
    -k|--keep)
      KEEP_DATA=true
      ;;
    -s|--skip)
      SKIP_SYSDEOPT=true
      ;;
    -j|--java)
      USER_JAVA_PATH="$(_realpath "$2")"
      shift
      ;;
    -y|--yes)
      AUTO_TOS_ACCEPT=true
      ;;
    --force-opt)
      FORCE_PREOPT=true
      ;;
    --deodex-all)
      DEODEX_ALL=true
      ;;
    --force-vimg)
      FORCE_VIMG=true
      ;;
    *)
      echo "[-] Invalid argument '$1'"
      usage
      ;;
  esac
  shift
done

# Check user input args
check_input_args

# Check that system tools exist
for i in "${SYS_TOOLS[@]}"
do
  if ! command_exists "$i"; then
    echo "[-] '$i' command not found"
    abort 1
  fi
done

# Check if output directory is AOSP root
if is_aosp_root "$OUTPUT_DIR"; then
  if [ "$KEEP_DATA" = true ]; then
    echo "[!] Not safe to keep data when output directory is AOSP root - choose different path"
    abort 1
  fi
  AOSP_ROOT="$OUTPUT_DIR"
  OUTPUT_DIR="$TMP_WORK_DIR"
fi

# Resolve Java location
update_java_path

# Check if supported device
check_supported_device

# Specify device configuration json
CONFIG_FILE="$SCRIPTS_ROOT/$DEVICE/config.json"

# Prepare output dir structure
OUT_BASE="$OUTPUT_DIR/$DEVICE/$BUILDID"
if [ ! -d "$OUT_BASE" ]; then
  mkdir -p "$OUT_BASE"
fi
FACTORY_IMGS_DATA="$OUT_BASE/factory_imgs_data"
FACTORY_IMGS_R_DATA="$OUT_BASE/factory_imgs_repaired_data"
OTA_DATA="$OUT_BASE/ota_data"
echo "[*] Setting output base to '$OUT_BASE'"

# Download images if not provided
factoryImgArchive=""
if [[ "$INPUT_IMG" == "" ]]; then

  __extraArgs=""
  if [ $AUTO_TOS_ACCEPT = true ]; then
    __extraArgs="--yes"
  fi

 $DOWNLOAD_SCRIPT --device "$DEVICE" \
       --buildID "$BUILDID" --output "$OUT_BASE" $__extraArgs || {
    echo "[-] Images download failed"
    abort 1
  }
  factoryImgArchive="$(find "$OUT_BASE" -iname "*$DEVICE*$BUILDID-factory*.tgz" -or \
                       -iname "*$DEVICE*$BUILDID-factory*.zip" | head -1)"
else
  factoryImgArchive="$INPUT_IMG"
fi

readonly OTA_IMGS_LIST="$(jqIncRawArrayTop "ota-partitions" "$CONFIG_FILE")"
if [[ "$OTA_IMGS_LIST" != "" ]]; then
  OTA=true
fi

if [ "$OTA" = true ]; then
OtaArchive=""
if [[ "$INPUT_OTA" == "" ]]; then

  __extraArgs=""
  if [ $AUTO_TOS_ACCEPT = true ]; then
    __extraArgs="--yes"
  fi

 $DOWNLOAD_SCRIPT --device "$DEVICE" \
       --buildID "$BUILDID" --output "$OUT_BASE" $__extraArgs --ota || {
    echo "[-] OTA download failed"
    abort 1
  }
  OtaArchive="$(find "$OUT_BASE" -iname "*$DEVICE*ota-$BUILDID*.tgz" -or \
                       -iname "*$DEVICE*ota-$BUILDID*.zip" | head -1)"
else
  OtaArchive="$INPUT_OTA"
fi
fi

if [[ "$factoryImgArchive" == "" ]]; then
  echo "[-] Failed to locate factory image archive"
  abort 1
fi

if [ "$OTA" = true ]; then
if [[ "$OtaArchive" == "" ]]; then
  echo "[-] Failed to locate OTA archive"
  abort 1
fi
fi

# Download carrier list
aospCarrierListFolder="$SCRIPTS_ROOT/scripts/carriersettings-extractor"
$DOWNLOAD_CARRIER_LIST_SCRIPT --output "$aospCarrierListFolder" || {
  echo "[-] Carrier list download failed"
  abort 1
}

# Clear old data if present & extract data from factory images
if [ -d "$FACTORY_IMGS_DATA" ]; then
  rm -rf "${FACTORY_IMGS_DATA:?}"/*
else
  mkdir -p "$FACTORY_IMGS_DATA"
fi

if [ -d "$OTA_DATA" ]; then
  rm -rf "${OTA_DATA:?}"/*
else
  mkdir -p "$OTA_DATA"
fi

EXTRACT_SCRIPT_ARGS=(--input "$factoryImgArchive" --output "$FACTORY_IMGS_DATA")

$EXTRACT_SCRIPT "${EXTRACT_SCRIPT_ARGS[@]}" --conf-file "$CONFIG_FILE" || {
  echo "[-] Factory images data extract failed"
  abort 1
}

if [ "$OTA" = true ]; then
OTA_SCRIPT_ARGS=(--input "$OtaArchive" --output "$OTA_DATA")

$OTA_SCRIPT "${OTA_SCRIPT_ARGS[@]}" --conf-file "$CONFIG_FILE" || {
  echo "[-] OTA data extract failed"
  abort 1
}
fi

# system.img contents are different between Nexus & Pixel
SYSTEM_ROOT="$FACTORY_IMGS_DATA/system"
if [[ -d "$FACTORY_IMGS_DATA/system/system" && -f "$FACTORY_IMGS_DATA/system/system/build.prop" ]]; then
  SYSTEM_ROOT="$FACTORY_IMGS_DATA/system/system"
fi

echo "[*] Processing configuration"

# Generate unified readonly "proprietary-blobs.txt"
$GEN_BLOBS_LIST_SCRIPT --input "$FACTORY_IMGS_DATA/vendor" \
    --output "$SCRIPTS_ROOT/$DEVICE" \
    --conf-file "$CONFIG_FILE" || {
  echo "[-] 'proprietary-blobs.txt' generation failed"
  abort 1
}

# Repair bytecode from system partition
if [ -d "$FACTORY_IMGS_R_DATA" ]; then
  rm -rf "${FACTORY_IMGS_R_DATA:?}"/*
else
  mkdir -p "$FACTORY_IMGS_R_DATA"
fi

# Set bytecode repair method based on user arguments
if [ $SKIP_SYSDEOPT = true ]; then
  BYTECODE_REPAIR_METHOD="NONE"
fi

# Adjust arguments of system repair script based on chosen method
case $BYTECODE_REPAIR_METHOD in
  "NONE")
    ;;
  "OATDUMP")
    REPAIR_SCRIPT_ARG=(--oatdump "$SCRIPTS_ROOT/../out/host/linux-x86/bin/oatdump")
    ;;
  *)
    echo "[-] Invalid bytecode repair method"
    abort 1
    ;;
esac

# If deodex all not set provide a list of packages to repair
if [ $DEODEX_ALL = false ]; then
  BYTECODE_LIST="$TMP_WORK_DIR/bytecode_list.txt"
  jqIncRawArray "system-bytecode" "$CONFIG_FILE" > "$BYTECODE_LIST"
  jqIncRawArray "product-bytecode" "$CONFIG_FILE" >> "$BYTECODE_LIST"
  jqIncRawArray "system_ext-bytecode" "$CONFIG_FILE" >> "$BYTECODE_LIST"
  REPAIR_SCRIPT_ARG+=( --bytecode-list "$BYTECODE_LIST")
fi


$REPAIR_SCRIPT --method "$BYTECODE_REPAIR_METHOD" --input "$SYSTEM_ROOT" \
     --output "$FACTORY_IMGS_R_DATA" "${REPAIR_SCRIPT_ARG[@]}" || {
  echo "[-] System partition bytecode repair failed"
  abort 1
}

# Bytecode under vendor, product or system_ext partition doesn't require repair (at least for now)
# However, make it available to repaired data directory to have a single source
# for next script
ln -s "$FACTORY_IMGS_DATA/vendor" "$FACTORY_IMGS_R_DATA/vendor"
if [[ -d "$FACTORY_IMGS_DATA/product" ]]; then
  ln -s "$FACTORY_IMGS_DATA/product" "$FACTORY_IMGS_R_DATA/product"
fi
if [[ -d "$FACTORY_IMGS_DATA/system_ext" ]]; then
  ln -s "$FACTORY_IMGS_DATA/system_ext" "$FACTORY_IMGS_R_DATA/system_ext"
fi

# Copy vendor, product, and system_ext partition image size as saved from $EXTRACT_SCRIPT script
# $VGEN_SCRIPT will fail over to last known working default if image size
# file not found when parsing data
cp "$FACTORY_IMGS_DATA/vendor_partition_size" "$FACTORY_IMGS_R_DATA"
if [[ -f "$FACTORY_IMGS_DATA/product_partition_size" ]]; then
  cp "$FACTORY_IMGS_DATA/product_partition_size" "$FACTORY_IMGS_R_DATA"
fi
if [[ -f "$FACTORY_IMGS_DATA/system_ext_partition_size" ]]; then
  cp "$FACTORY_IMGS_DATA/system_ext_partition_size" "$FACTORY_IMGS_R_DATA"
fi

# Make radio files available to vendor generate script
if [[ -d "$OTA_DATA/radio" ]]; then
  cp -r "$OTA_DATA/radio" "$FACTORY_IMGS_DATA/"
fi
ln -s "$FACTORY_IMGS_DATA/radio" "$FACTORY_IMGS_R_DATA/radio"

# Older devices do not have separate product partition
PRODUCT_R_ROOT="$FACTORY_IMGS_R_DATA/system/product"
if [ -d "$FACTORY_IMGS_DATA/product" ]; then
  PRODUCT_R_ROOT="$FACTORY_IMGS_R_DATA/product"
fi

# Convert the CarrierSettings protobuf files to XML format compatible with AOSP
carrierSettingsFolder="$(dirname "$(find "${OUT_BASE}" -name carrier_list.pb | head -1)")"
echo "[*] Converting CarrierSettings protobuf files to XML format compatible with AOSP"
CARRIERCONFIG_RRO_OVERLAY_PATH="$SCRIPTS_ROOT/$DEVICE/rro_overlays/CarrierConfigOverlay/res/xml"
mkdir -p "$CARRIERCONFIG_RRO_OVERLAY_PATH"
$EXTRACT_CARRIER_SETTINGS_SCRIPT --carrierlist "$aospCarrierListFolder" \
    --input "$carrierSettingsFolder" \
    --apns "$PRODUCT_R_ROOT/etc/" --vendor "$CARRIERCONFIG_RRO_OVERLAY_PATH" || {
  echo "[-] Carrier settings extract failed"
  abort 1
}

VGEN_SCRIPT_EXTRA_ARGS=()
if [ $FORCE_PREOPT = true ]; then
  VGEN_SCRIPT_EXTRA_ARGS+=( --allow-preopt)
fi
if [ $FORCE_VIMG = true ]; then
  VGEN_SCRIPT_EXTRA_ARGS+=( --force-vimg)
fi
if [[ "$AOSP_ROOT" != "" ]]; then
  VGEN_SCRIPT_EXTRA_ARGS+=( --aosp-root "$AOSP_ROOT")
fi

$VGEN_SCRIPT --input "$FACTORY_IMGS_R_DATA" \
  --output "$OUT_BASE" \
  --conf-file "$CONFIG_FILE" \
  "${VGEN_SCRIPT_EXTRA_ARGS[@]}" || {
  echo "[-] Vendor generation failed"
  abort 1
}

if [ "$KEEP_DATA" = false ]; then
  rm -rf "$FACTORY_IMGS_DATA"
  rm -rf "$FACTORY_IMGS_R_DATA"
  rm -rf "$OTA_DATA"
fi

# If output dir is not AOSP SRC root print some user messages, otherwise the
# generate-vendor.sh script will rsync output intermediates
if [[ "$AOSP_ROOT" == "" ]]; then
  echo "[*] Import '$OUT_BASE/vendor' vendor blobs to AOSP root"
  echo "[*] Import '$OUT_BASE/vendor/google_devices/$DEVICE/overlay' vendor overlays to AOSP root"
fi

echo "[*] All actions completed successfully"
abort 0
