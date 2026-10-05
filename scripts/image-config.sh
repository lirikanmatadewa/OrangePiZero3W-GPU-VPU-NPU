#!/bin/bash

resolve_image() {
  local variable=$1
  local label=$2
  local pattern=$3
  local configured=${!variable:-}
  local selected=
  local -a matches=()

  if [[ -n "$configured" ]]; then
    if [[ "$configured" == */* ]]; then
      echo "ERROR: $variable must be an image filename, not a path: $configured" >&2
      return 1
    fi
    if [[ "${configured,,}" != $pattern ]]; then
      echo "ERROR: $configured does not match the expected $label image pattern: $pattern" >&2
      return 1
    fi
    selected="$IMAGE_DIR/$configured"
    if [[ ! -f "$selected" ]]; then
      echo "ERROR: configured $label image not found: $selected" >&2
      return 1
    fi
  else
    mapfile -d '' -t matches < <(
      find "$IMAGE_DIR" -maxdepth 1 -type f -iname "$pattern" \
        ! -iname '*+radxa_gpu_vpu_npu.img' -print0 | sort -z
    )
    if (( ${#matches[@]} == 0 )); then
      echo "ERROR: no $label image matching '$pattern' found in $IMAGE_DIR" >&2
      return 1
    fi
    if (( ${#matches[@]} > 1 )); then
      echo "ERROR: multiple $label images found in $IMAGE_DIR; set $variable in .env:" >&2
      printf '  %s\n' "${matches[@]}" >&2
      return 1
    fi
    selected=${matches[0]}
    printf -v "$variable" '%s' "$(basename "$selected")"
  fi

  if [[ "${selected,,}" != *.img ]]; then
    echo "ERROR: $label image must be an uncompressed .img file: $selected" >&2
    return 1
  fi
}

load_image_config() {
  local config_file=${IMAGE_CONFIG_FILE:-$IMAGE_DIR/.env}

  if [[ -f "$config_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$config_file"
    set +a
  fi

  resolve_image OPI_IMAGE "Debian Orange Pi Zero 3W" '*orangepizero3w*debian*.img' || return 1
  resolve_image RADXA_IMAGE "Radxa A733" '*radxa*.img' || return 1

  OPI_IMG="$IMAGE_DIR/$OPI_IMAGE"
  RADXA_IMG="$IMAGE_DIR/$RADXA_IMAGE"
}

find_unique() {
  local label=$1
  shift
  local -a matches=()
  mapfile -d '' -t matches < <(find "$@" -print0)
  if (( ${#matches[@]} != 1 )); then
    echo "ERROR: expected exactly one $label, found ${#matches[@]}" >&2
    printf '  %s\n' "${matches[@]}" >&2
    return 1
  fi
  printf '%s' "${matches[0]}"
}