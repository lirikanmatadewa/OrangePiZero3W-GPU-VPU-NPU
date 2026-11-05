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

  resolve_image OPI_IMAGE "Debian or Armbian Orange Pi Zero 3W" '*orangepizero3w*.img' || return 1
  resolve_image RADXA_IMAGE "Radxa A733" '*radxa*.img' || return 1

  OPI_IMG="$IMAGE_DIR/$OPI_IMAGE"
  RADXA_IMG="$IMAGE_DIR/$RADXA_IMAGE"
  NPU_IMG="$OPI_IMG"
  if [[ -n "${NPU_IMAGE:-}" ]]; then
    resolve_image NPU_IMAGE "Orange Pi Zero 3W NPU donor" '*orangepizero3w*.img' || return 1
    NPU_IMG="$IMAGE_DIR/$NPU_IMAGE"
  fi
}

prepare_npu_source() {
  NPU_ROOTFS=$1
  NPU_PATHS=(/usr/lib/libVIPhal.so /opt/yolov5)
  local start
  local path

  if [[ "$NPU_IMG" != "$OPI_IMG" ]]; then
    read -r start < <(partx -g -b -o START -r --nr 1 "$NPU_IMG")
    : "${start:?could not read NPU donor partition 1 from $NPU_IMG}"
    NPU_LOOP=$(losetup --read-only -o "$((start * 512))" -f --show "$NPU_IMG")
    NPU_ROOTFS=/mnt/npu
    mkdir -p "$NPU_ROOTFS"
    mount -o ro "$NPU_LOOP" "$NPU_ROOTFS"
  fi

  for path in "${NPU_PATHS[@]}"; do
    if [[ ! -e "$NPU_ROOTFS$path" ]]; then
      echo "ERROR: required NPU path is missing from $NPU_IMG: $path" >&2
      echo "       Set NPU_IMAGE to a compatible stock Orange Pi image containing the VIP HAL and YOLOv5 demo." >&2
      return 1
    fi
  done
  echo ">> [check] NPU userspace source: $NPU_IMG"
}

copy_npu_userspace() {
  local destination=$1
  local path
  for path in "${NPU_PATHS[@]}"; do
    if [[ -d "$NPU_ROOTFS$path" ]]; then
      mkdir -p "$destination$path"
      cp -aL "$NPU_ROOTFS$path/." "$destination$path/"
    else
      mkdir -p "$destination$(dirname "$path")"
      cp -aL "$NPU_ROOTFS$path" "$destination$path"
    fi
  done
}

install_gstomx_config() {
  local rootfs=$1
  local donor=$2
  local config="$rootfs/etc/xdg/gstomx-allwinner.conf"
  local hacks="event-port-settings-changed-ndata-parameter-swap;event-port-settings-changed-port-0-to-1;no-disable-outport;no-component-reconfigure;no-component-role;no-empty-eos-buffer;pass-color-format-to-decoder;pass-profile-to-decoder;signals-premature-eos;height-multiple-16"

  if [[ ! -f "$donor/etc/xdg/gstomx-allwinner.conf" ]]; then
    echo "ERROR: Radxa image is missing /etc/xdg/gstomx-allwinner.conf" >&2
    return 1
  fi
  mkdir -p "$rootfs/etc/xdg"
  cp -a --remove-destination "$donor/etc/xdg/gstomx-allwinner.conf" "$config"
  # A relative link also works in a standalone tarball without dpkg alternatives.
  ln -sfn gstomx-allwinner.conf "$rootfs/etc/xdg/gstomx.conf"
  sed -i "s|^hacks=.*|hacks=$hacks|" "$config"
  echo "   installed and patched /etc/xdg/gstomx-allwinner.conf"
}

is_debian_compatible() {
  local os_release=$1
  local image_id=
  local image_like=
  local key value

  while IFS='=' read -r key value; do
    value=${value//\"/}
    case "$key" in
      ID) image_id=$value ;;
      ID_LIKE) image_like=$value ;;
    esac
  done < "$os_release"

  [[ "$image_id" == debian || "$image_id" == armbian || " $image_like " == *" debian "* ]]
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