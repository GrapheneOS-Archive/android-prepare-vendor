#!/usr/bin/env bash
#
# Process the system partition and try to de-optimize applications from factory images
#

set -e # fail on unhandled error
set -u # fail on undefined variable
#set -x # debug

readonly SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
readonly CONSTS_SCRIPT="$SCRIPTS_DIR/constants.sh"
readonly COMMON_SCRIPT="$SCRIPTS_DIR/common.sh"
readonly TMP_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}"/android_img_repair.XXXXXX) || exit 1
declare -a SYS_TOOLS=("cp" "touch" "date" "sed" "zipinfo" "jar" "zip" "wc" "cut" "dexrepair")

abort() {
  # If debug keep work dir for bugs investigation
  if [[ "$-" == *x* ]]; then
    echo "[*] Workspace available at '$TMP_WORK_DIR' - delete manually \
          when done"
  else
    rm -rf "$TMP_WORK_DIR"
  fi
  exit "$1"
}

usage() {
cat <<_EOF
  Usage: $(basename "$0") [options]
    OPTIONS:
      -i|--input      : Root path of extracted factory image system partition
      -o|--output     : Path to save input partition with repaired bytecode
      -m|--method     : Repair methods ('NONE', 'OATDUMP')
      --oatdump       : [OPTIONAL] Path to oatdump executable
      --bytecode-list : [OPTIONAL] list with bytecode archive files to be included in
                        generated MKs. When provided only required bytecode is repaired,
                        otherwise all bytecode in partition is repaired.
    INFO:
      * Input path expected to be system root as extracted from factory system image
      * dexrepair is used from hostTools
      * oatdump is used from AOSP build system
      * When creating vendor makefiles, extra care is needed for APKs signature type
      * '--bytecode-list' flag is provided to speed up things in case only specific files are wanted
_EOF
  abort 1
}

# Cover as many cases as possible (Linux, macOS with BSD, macOS with GNU)
stamp_file() {
  local _tstamp="$1"
  local _file="$2"

  touch -d @"$_tstamp" "$_file" 2>/dev/null || \
    touch -d "$(date -r "$_tstamp" +%Y%m%d%H%M.%S)" "$_file" 2>/dev/null || \
      echo "[-] File timestamp failed"
}

check_java_version() {
  local java_ver_minor=""
  local _token

  for _token in $(java -version 2>&1 | grep -i version)
  do
    if [[ $_token =~ \"([[:digit:]])\.([[:digit:]])\.(.*)\" ]]
    then
      java_ver_minor=${BASH_REMATCH[2]}
      break
    fi
  done

  if [ "$java_ver_minor" -lt 8 ]; then
    echo "[-] Java version ('$java_ver_minor') is detected, while minimum required version is 8"
    echo "[!] Consider exporting PATH like the following if a system-wide set is not desired"
    echo ' # PATH=/usr/local/java/jdk1.8.0_71/bin:$PATH; ./execute-all.sh <..args..>'
    abort 1
  fi
}

oatdump_repair() {
  local -a abis
  local -a bootJars
  local _base_path

  # Identify supported ABI(s) - extra work for 64bit ABIs
  for cpu in "arm" "arm64" "x86" "x86_64"
  do
    if [ -d "$INPUT_DIR/framework/$cpu" ]; then
      abis+=("$cpu")
    fi
  done

  # Cache boot jars so that we can skip them so that we don't have to increase
  # the repair complexity due to them following different naming/dir conventions
  while read -r file
  do
    jarFile="$(basename "$file" | cut -d '-' -f2- | sed 's#.oat#.jar#')"
    bootJars+=("$jarFile")
  done < <(find "$INPUT_DIR/framework/${abis[0]}" -iname "boot*.oat")

  while read -r file
  do
    relFile=$(echo "$file" | sed "s#^$INPUT_DIR##")
    relDir=$(dirname "$relFile")
    fileExt="${file##*.}"
    fileName=$(basename "$relFile")

    odexFound=0
    dexsExported=0

    # Skip special files
    if array_contains "$fileExt" "${ART_FILE_EXTS[@]}"; then
      continue
    fi

    # Maintain dir structure
    mkdir -p "$OUTPUT_SYS/$relDir"

    # If not APK/jar file, copy as is
    if [[ "$fileExt" != "apk" && "$fileExt" != "jar" ]]; then
      cp -a "$file" "$OUTPUT_SYS/$relDir/" || {
        echo "[!] Failed to copy '$relFile' - skipping"
      }
      continue
    fi

    # If boot jar skip
    if array_contains_rel "$fileName" "${bootJars[@]}"; then
      continue
    fi

    # If APKs selection enabled, skip if not in list
    if [ "$hasBytecodeList" = true ]; then
      if ! array_contains_rel "$relFile" "${BYTECODE_LIST[@]}"; then
        continue
      fi
    fi

    # For Apk/Jar files apply bytecode repair
    zipRoot=$(dirname "$file")
    pkgName=$(basename "$file" ".$fileExt")

    # If Apk/Jar is not stripped copy as is, otherwise start processing the optimized data
    if zipinfo "$file" classes.dex &>/dev/null; then
      echo "[!] '$relFile' bytecode is not stripped - copying without changes"
      cp -a "$file" "$OUTPUT_SYS/$relDir"
      continue
    fi

    # Check if APK/jar bytecode is pre-optimized
    if [ -d "$zipRoot/oat" ]; then
      # Check if optimized code available at app's directory for all ABIs
      odexFound=$(find "$zipRoot/oat" -type f -iname "$pkgName*.odex" | \
                  wc -l | tr -d ' ')
    fi
    if [ "$odexFound" -eq 0 ]; then
      if ! zipinfo "$file" classes.dex &>/dev/null; then
        echo "[!] '$relFile' not pre-optimized & without 'classes.dex' - copying without changes"
        cp -a "$file" "$OUTPUT_SYS/$relDir"
      fi
    else
      # If pre-compiled, dump bytecode from oat .rodata section
      # If bytecode compiled for more than one ABIs - only the first is kept
      # (shouldn't make any difference)
      deoptSuccess=false
      for abi in "${abis[@]}"
      do
        curOdex="$zipRoot/oat/$abi/$pkgName.odex"
        if [ ! -f "$curOdex" ]; then
          continue
        fi

        # If we already have bytecode de-optimized for one ABI don't redo the work
        # just create the dir annotation to pickup multi-lib both scenarios
        if [ $deoptSuccess = true ]; then
          mkdir -p "$OUTPUT_SYS/$relDir/oat/$abi"
          continue
        fi

        local oatdump_log="$TMP_WORK_DIR/oatdump_log.txt"
        $OATDUMP_BIN --oat-file="$curOdex" --export-dex-to="$TMP_WORK_DIR" &>"$oatdump_log" || {
          echo "[-] DEX dump from '$curOdex' failed"
          cat "$oatdump_log"
          abort 1
        }

        # If DEX not created, oatdump failed to resolve a dependency and skipped file
        dexsExported=$(find "$TMP_WORK_DIR" -maxdepth 1 -type f -name "*_export.dex" | wc -l | tr -d ' ')
        if [ "$dexsExported" -eq 0 ]; then
          echo "[-] '$relFile' DEX export failed"
          cat "$oatdump_log"
          abort 1
        else
          # Generate an empty directory under package dir with the detected ABI
          # so that vendor generate script can detect possible multilib scenarios
          mkdir -p "$OUTPUT_SYS/$relDir/oat/$abi"
          deoptSuccess=true
        fi
      done

      # Repair CRC for all dex files & remove un-repaired original dumps
      dexrepair -I "$TMP_WORK_DIR" &>/dev/null
      rm -f "$TMP_WORK_DIR/"*_export.dex

      # Check if expected number of repaired files found
      dexsRepaired=$(find "$TMP_WORK_DIR" -maxdepth 1 -type f -name "*_repaired.dex" | wc -l | tr -d ' ')
      if [ "$dexsRepaired" -ne "$dexsExported" ]; then
        echo "[-] '$dexsExported' DEX files exported, although only '$dexsRepaired' repaired"
        echo "[-] '$pkgName' bytecode repair failed"
        abort 1
      fi

      # Copy APK/jar to workspace for repair
      cp "$file" "$TMP_WORK_DIR"

      # Normalize names & add dex files back to zip archives (jar or APK)
      # considering possible multi-dex cases. zipalign is not necessary since
      # AOSP build rules will align them if not already
      if [ "$dexsExported" -gt 1 ]; then
        # multi-dex file
        echo "[*] '$relFile' is multi-dex - adjusting recursive archive adds"
        counter=2
        curMultiDex="$(find "$TMP_WORK_DIR" -type f -maxdepth 1 \
                       -name "*classes$counter.dex*_repaired.dex")"
        while [ "$curMultiDex" != "" ]
        do
          mv "$curMultiDex" "$TMP_WORK_DIR/classes$counter.dex"
          stamp_file "$TIMESTAMP" "$TMP_WORK_DIR/classes$counter.dex"
          jar -uf "$TMP_WORK_DIR/$fileName" -C "$TMP_WORK_DIR" \
               "classes$counter.dex" &>/dev/null || {
            echo "[-] '$fileName' 'classes$counter.dex' append failed"
            abort 1
          }
          rm "$TMP_WORK_DIR/classes$counter.dex"

          counter=$(( counter + 1))
          curMultiDex="$(find "$TMP_WORK_DIR" -type f -maxdepth 1 \
                         -name "*classes$counter.dex*_repaired.dex")"
        done
      fi

      # All archives have at least one "classes.dex"
      mv "$TMP_WORK_DIR/"*_repaired.dex "$TMP_WORK_DIR/classes.dex"
      stamp_file "$TIMESTAMP" "$TMP_WORK_DIR/classes.dex"
      jar -uf "$TMP_WORK_DIR/$fileName" -C "$TMP_WORK_DIR" \
         classes.dex &>/dev/null || {
        echo "[-] '$fileName' classes.dex append failed"
        abort 1
      }
      rm "$TMP_WORK_DIR/classes.dex"

      # Remove old signature from APKs so that we don't create problems with V2 sign format
      if [[ "$fileExt" == "apk" ]]; then
        zip -d "$TMP_WORK_DIR/$fileName" META-INF/\* &>/dev/null
      fi

      mv "$TMP_WORK_DIR/$fileName" "$OUTPUT_SYS/$relDir"
    fi
  done < <(find "$INPUT_DIR" -not -type d)
}

trap "abort 1" SIGINT SIGTERM
. "$CONSTS_SCRIPT"
. "$COMMON_SCRIPT"

# Check that system tools exist
for i in "${SYS_TOOLS[@]}"
do
  if ! command_exists "$i"; then
    echo "[-] '$i' command not found"
    abort 1
  fi
done

INPUT_DIR=""
OUTPUT_DIR=""
REPAIR_METHOD=""
BYTECODE_LIST_FILE=""
TIMESTAMP="1230768000"

# Paths for external tools provided from args
OATDUMP_BIN=""

# Global variables accessible from sub-routines
declare -a BYTECODE_LIST
hasBytecodeList=false

while [[ $# -gt 1 ]]
do
  arg="$1"
  case $arg in
    -i|--input)
      INPUT_DIR=$(echo "$2" | sed 's:/*$::')
      shift
      ;;
    -o|--output)
      OUTPUT_DIR=$(echo "$2" | sed 's:/*$::')
      shift
      ;;
    -m|--method)
      REPAIR_METHOD="$2"
      shift
      ;;
    --oatdump)
      OATDUMP_BIN="$2"
      shift
      ;;
    --bytecode-list)
      BYTECODE_LIST_FILE="$2"
      shift
      ;;
    *)
      echo "[-] Invalid argument '$1'"
      usage
      ;;
  esac
  shift
done

# Input args check
if [[ "$REPAIR_METHOD" != "NONE" && "$REPAIR_METHOD" != "OATDUMP" ]]; then
  echo "[-] Invalid repair method"
  usage
fi
check_dir "$INPUT_DIR" "Input"
check_dir "$OUTPUT_DIR" "Output"

# Bytecode list filter file is optional
check_opt_file "$BYTECODE_LIST_FILE" "BYTECODE_LIST_FILE"

# Check optional tool paths if set. Each repair method rechecks that required
# tools are set prior to start processing
check_opt_file "$OATDUMP_BIN" "oatdump"

# Verify input is an Android system partition
if [ ! -f "$INPUT_DIR/build.prop" ]; then
  echo "[-] '$INPUT_DIR' is not a valid system image partition"
  abort 1
fi

# Output directory should be empty to avoid merge races with old extracts
OUTPUT_SYS="$OUTPUT_DIR/system"
if [[ -d "$OUTPUT_SYS" && $(ls -A "$OUTPUT_SYS" | grep -v '^\.') ]]; then
  echo "[!] Output directory should be empty to avoid merge problems with old extracts"
  abort 1
fi

# Verify image contains pre-optimized oat files
if [ ! -d "$INPUT_DIR/framework/oat" ]; then
  echo "[!] System partition doesn't contain any pre-optimized files - link to original partition"
  ln -sfn "$INPUT_DIR" "$OUTPUT_SYS"
  abort 0
fi

# No repairing
if [[ "$REPAIR_METHOD" == "NONE" ]]; then
  echo "[*] No repairing enabled - link to original partition"
  ln -sfn "$INPUT_DIR" "$OUTPUT_SYS"
  abort 0
fi

# Check if blobs list is set so that only selected APKs will be repaired for speed
# JARs under /system/framework are always repaired for safety
if [[ "$BYTECODE_LIST_FILE" != "" ]]; then
  readarray -t BYTECODE_LIST < <(grep -Ev '(^#|^$)' "$BYTECODE_LIST_FILE" | cut -d ":" -f1)
  if [ ${#BYTECODE_LIST[@]} -eq 0 ]; then
    echo "[!] No bytecode files selected for repairing - link to original partition"
    ln -sfn "$INPUT_DIR" "$OUTPUT_SYS"
    abort 0
  fi
  echo "[*] '${#BYTECODE_LIST[@]}' bytecode archive files will be repaired"
  hasBytecodeList=true
else
  echo "[*] All bytecode files under system partition will be repaired"
fi

# Prepare output directory base
mkdir -p "$OUTPUT_SYS"

# oatdump repairing
if [[ "$REPAIR_METHOD" == "OATDUMP" ]]; then
  if [[ "$OATDUMP_BIN" == "" ]]; then
    echo "[-] Missing oatdump external tool"
    abort 1
  fi

  echo "[*] Repairing bytecode under /system partition using oatdump method"
  oatdump_repair
fi

echo "[*] System partition successfully extracted & repaired at '$OUTPUT_DIR'"

abort 0
