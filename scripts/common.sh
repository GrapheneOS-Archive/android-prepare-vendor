#!/usr/bin/env bash

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1

command_exists() {
  type "$1" &> /dev/null
}

check_dir() {
  local dirPath="$1"
  local dirDesc="$2"

  if [[ "$dirPath" == "" || ! -d "$dirPath" ]]; then
    echo "[-] $dirDesc directory not found"
    usage
  fi
}

check_file() {
  local filePath="$1"
  local fileDesc="$2"

  if [[ "$filePath" == "" || ! -f "$filePath" ]]; then
    echo "[-] $fileDesc file not found"
    usage
  fi
}

check_opt_file() {
  local filePath="$1"
  local fileDesc="$2"

  if [[ "$filePath" != "" && ! -f "$filePath" ]]; then
    echo "[-] '$fileDesc' file not found"
    usage
  fi
}

array_contains() {
  local element
  for element in "${@:2}"; do [[ "$element" == "$1" ]] && return 0; done
  return 1
}

array_contains_rel() {
  local element
  for element in "${@:2}"; do [[ "$element" =~ $1 ]] && return 0; done
  return 1
}

jqRawStrTop() {
  local query="$1"
  local conf_file="$2"

  jq -r ".\"$query\"" "$conf_file" || {
    echo "[-] json raw top string parse failed" >&2
    abort 1
  }
}

jqIncRawArrayTop() {
  local query="$1"
  local conf_file="$2"

  jq -r ".\"$query\"[]" "$conf_file" || {
    echo "[-] json top raw string string parse failed" >&2
    abort 1
  }
}

jqRawStr() {
  local query="$1"
  local conf_file="$2"

  jq -r ".\"$query\"" "$conf_file" || {
    echo "[-] json raw string parse failed" >&2
    abort 1
  }
}

jqIncRawArray() {
  local query="$1"
  local conf_file="$2"

  jq -r ".\"$query\"[]" "$conf_file" || {
    echo "[-] json raw string array parse failed" >&2
    abort 1
  }

  return
}
