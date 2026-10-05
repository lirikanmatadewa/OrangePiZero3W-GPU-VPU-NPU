#!/bin/bash
# Build a Debian Orange Pi Zero 3W image with compatible Radxa A733 GPU/VPU userspace.
#
# Run this in a privileged debian:bookworm-slim container with the repository
# mounted at /work. Put the source images and optional .env in /work.
#
# Output: /work/YYYYMMDD-<Debian-image-basename>+radxa_gpu_vpu_npu.img
#
# No proprietary binaries are stored in this repository. This script only copies
# files from the Radxa image supplied by the user.

set -euo pipefail

IMAGE_DIR=/work
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/image-config.sh"
load_image_config

OPI_BASENAME=${OPI_IMAGE%.*}
OPI_EXTENSION=${OPI_IMAGE##*.}
OUT_IMG="$IMAGE_DIR/$(date +%Y%m%d)-${OPI_BASENAME}+radxa_gpu_vpu_npu.${OPI_EXTENSION}"

if [[ "$OUT_IMG" == "$OPI_IMG" ]]; then
  echo "ERROR: output path would overwrite the Debian source image: $OPI_IMG" >&2
  exit 1
fi

# Read partition geometry from each image: OPi rootfs is MBR part 1; Radxa is GPT part 3.
read -r OPI_START _ < <(partx -g -b -o START,SECTORS -r --nr 1 "$OPI_IMG")
read -r RADXA_START RADXA_SECTORS < <(partx -g -b -o START,SECTORS -r --nr 3 "$RADXA_IMG")
: "${OPI_START:?could not read OPi partition 1 from $OPI_IMG}"
: "${RADXA_START:?could not read Radxa partition 3 from $RADXA_IMG}"
: "${RADXA_SECTORS:?could not read Radxa partition 3 size from $RADXA_IMG}"
OPI_PART_OFFSET=$((OPI_START * 512))
RADXA_PART_OFFSET=$((RADXA_START * 512))
RADXA_PART_SIZE=$((RADXA_SECTORS * 512))

echo ">> [host] Installing tools"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  qemu-user-static binfmt-support > /dev/null

echo ">> [host] Cloning Debian OPi image -> $(basename "$OUT_IMG")"
rm -f "$OUT_IMG"
cp "$OPI_IMG" "$OUT_IMG"

OUT_LOOP=$(losetup -o $OPI_PART_OFFSET -f --show "$OUT_IMG")
RADXA_LOOP=$(losetup -o $RADXA_PART_OFFSET --sizelimit $RADXA_PART_SIZE -f --show "$RADXA_IMG")
echo "   out rootfs: $OUT_LOOP"
echo "   radxa rootfs (partition 3): $RADXA_LOOP"

mkdir -p /mnt/out /mnt/radxa
mount "$OUT_LOOP" /mnt/out
mount -o ro "$RADXA_LOOP" /mnt/radxa

cleanup() {
  echo ">> [host] cleanup"
  umount -lR /mnt/out/run /mnt/out/dev /mnt/out/sys /mnt/out/proc 2>/dev/null || true
  umount -l /mnt/out 2>/dev/null || true
  umount -l /mnt/radxa 2>/dev/null || true
  losetup -d "$OUT_LOOP" 2>/dev/null || true
  losetup -d "$RADXA_LOOP" 2>/dev/null || true
}
trap cleanup EXIT

if ! grep -Eiq '^ID="?debian"?$' /mnt/out/etc/os-release; then
  echo "ERROR: selected Orange Pi rootfs is not Debian: $OPI_IMG" >&2
  exit 1
fi

shopt -s nullglob
OPI_MODULE_DIRS=(/mnt/out/lib/modules/*)
OPI_HEADER_DEBS=(/mnt/out/opt/linux-headers*.deb)
shopt -u nullglob
if (( ${#OPI_MODULE_DIRS[@]} != 1 )); then
  echo "ERROR: expected one kernel release under /lib/modules in $OPI_IMG; found ${#OPI_MODULE_DIRS[@]}" >&2
  printf '  %s\n' "${OPI_MODULE_DIRS[@]}" >&2
  exit 1
fi
OPI_KVER=$(basename "${OPI_MODULE_DIRS[0]}")
OPI_HEADER_PACKAGES=()
for header_deb in "${OPI_HEADER_DEBS[@]}"; do
  header_contents=$(dpkg-deb -c "$header_deb")
  if grep -F "linux-headers-$OPI_KVER/" <<<"$header_contents" >/dev/null; then
    OPI_HEADER_PACKAGES+=("$header_deb")
  fi
done
if (( ${#OPI_HEADER_PACKAGES[@]} != 1 )); then
  echo "ERROR: expected one /opt header package containing linux-headers-$OPI_KVER in $OPI_IMG; found ${#OPI_HEADER_PACKAGES[@]}" >&2
  printf '  %s\n' "${OPI_HEADER_DEBS[@]}" >&2
  exit 1
fi
OPI_HEADER_DEB=$(basename "${OPI_HEADER_PACKAGES[0]}")
echo ">> [check] Debian target kernel: $OPI_KVER; headers: $OPI_HEADER_DEB"

RADXA_INFO=/mnt/radxa/var/lib/dpkg/info
PVR_LIST=$(find_unique "Radxa PowerVR package manifest" "$RADXA_INFO" -maxdepth 1 -type f -name 'xserver-xorg-img-bxm*.list')
LIBCEDARC_LIST=$(find_unique "Radxa libcedarc package manifest" "$RADXA_INFO" -maxdepth 1 -type f -name 'libcedarc*.list')
GSTOMX_LIST=$(find_unique "Radxa GStreamer OMX package manifest" "$RADXA_INFO" -maxdepth 1 -type f -name 'libgstreamer-openmax-allwinner*.list')
DKMS_SOURCE=$(find_unique "Radxa img-bxm DKMS source" /mnt/radxa/usr/src -mindepth 1 -maxdepth 1 -type d -name 'img-bxm-dkms-*')
RADXA_SID_HEADER=$(find_unique "Radxa sunxi-sid.h header" /mnt/radxa/usr/src -type f -path '*/bsp/include/sunxi-sid.h')
DKMS_SOURCE_NAME=$(basename "$DKMS_SOURCE")
DKMS_VERSION=${DKMS_SOURCE_NAME#img-bxm-dkms-}
RADXA_HEADER_DIR=$(dirname "$(dirname "$(dirname "$RADXA_SID_HEADER")")")
RADXA_KVER=${RADXA_HEADER_DIR##*/linux-headers-}
for required_path in \
  /mnt/radxa/usr/share/vulkan/icd.d/img_icd.json \
  /mnt/radxa/etc/ld.so.conf.d/00_xserver-xorg-img-bxm.conf; do
  if [[ ! -f "$required_path" ]]; then
    echo "ERROR: compatible Radxa image is missing required file: ${required_path#/mnt/radxa}" >&2
    exit 1
  fi
done
shopt -s nullglob
RADXA_FIRMWARE=(/mnt/radxa/lib/firmware/rgx.*)
shopt -u nullglob
if (( ${#RADXA_FIRMWARE[@]} == 0 )); then
  echo "ERROR: compatible Radxa image has no /lib/firmware/rgx.* files" >&2
  exit 1
fi
echo ">> [check] Radxa kernel headers: $RADXA_KVER; DKMS source: $DKMS_SOURCE_NAME"

echo ">> [graft] Copying img-bxm-dkms source from Radxa"
cp -a "$DKMS_SOURCE" /mnt/out/usr/src/

echo ">> [graft] Pre-staging sunxi-sid.h for use inside chroot"
mkdir -p /mnt/out/tmp
cp "$RADXA_SID_HEADER" /mnt/out/tmp/sunxi-sid.h

echo ">> [graft] Copying files from Radxa PowerVR package manifest"

# Copy Radxa's PowerVR userspace package, except the parts that would replace
# OPi's Xorg/lightdm setup.
LIST=$PVR_LIST
COPIED=0
SKIPPED_CONFLICT=0
SKIPPED_MISSING=0
while read -r path; do
  [ -z "$path" ] && continue
  src="/mnt/radxa$path"
  # Leave OPi's display manager and Xorg packages in place.
  case "$path" in
    /usr/bin/Xorg|/etc/X11/*|/usr/lib/xorg/*|/usr/lib/systemd/*|/usr/lib/libxcvt*)
      SKIPPED_CONFLICT=$((SKIPPED_CONFLICT+1))
      continue
      ;;
    # Keep the target distribution's Vulkan loader; Radxa's lacks Wayland symbols.
    /usr/local/lib/libvulkan.so*)
      SKIPPED_CONFLICT=$((SKIPPED_CONFLICT+1))
      continue
      ;;
  esac
  if [ -L "$src" ] || [ -f "$src" ]; then
    mkdir -p "/mnt/out$(dirname "$path")"
    cp -a "$src" "/mnt/out$path"
    COPIED=$((COPIED+1))
  elif [ -d "$src" ]; then
    mkdir -p "/mnt/out$path"
  else
    SKIPPED_MISSING=$((SKIPPED_MISSING+1))
  fi
done < "$LIST"
echo "   copied: $COPIED files; skipped (conflict-with-OPi): $SKIPPED_CONFLICT; skipped (missing on Radxa): $SKIPPED_MISSING"

# Put the DRI drivers where Mesa looks
if [ -d /mnt/out/usr/lib/aarch64-linux-gnu/dri ]; then
  for dri in pvr_dri.so sunxi-drm_dri.so swrast_dri.so; do
    if [ -f /mnt/radxa/usr/local/lib/dri/$dri ] && [ ! -e /mnt/out/usr/lib/aarch64-linux-gnu/dri/$dri ]; then
      cp -a /mnt/radxa/usr/local/lib/dri/$dri /mnt/out/usr/lib/aarch64-linux-gnu/dri/
    fi
  done
fi

echo ">> [graft] Copying PowerVR firmware"
# Jammy uses merged-/usr so we write the fw under /usr/lib/firmware.
mkdir -p /mnt/out/usr/lib/firmware
cp -a /mnt/radxa/lib/firmware/rgx.* /mnt/out/usr/lib/firmware/

echo ">> [graft] Copying Vulkan ICD + ld.so.conf entry"
mkdir -p /mnt/out/usr/share/vulkan/icd.d
cp /mnt/radxa/usr/share/vulkan/icd.d/img_icd.json /mnt/out/usr/share/vulkan/icd.d/
cp /mnt/radxa/etc/ld.so.conf.d/00_xserver-xorg-img-bxm.conf /mnt/out/etc/ld.so.conf.d/

echo ">> [graft] Auto-load pvrsrvkm at boot"
mkdir -p /mnt/out/etc/modules-load.d
echo "pvrsrvkm" > /mnt/out/etc/modules-load.d/pvr.conf

echo ">> [graft] Allwinner VPU userspace (libcedarc + gst-openmax)"

VPU_LISTS="$LIBCEDARC_LIST $GSTOMX_LIST"
VPU_COPIED=0
for L in $VPU_LISTS; do
  while read -r path; do
    [ -z "$path" ] && continue
    case "$path" in
      /usr/include/*|/usr/share/doc/*|/usr/share/metainfo/*|/usr/share/man/*) continue;;
    esac
    src="/mnt/radxa$path"
    # Keep the target image's merged-/usr layout intact.
    case "$path" in
      /lib/*) dst_path="/usr$path" ;;
      *) dst_path="$path" ;;
    esac
    if [ -L "$src" ] || [ -f "$src" ]; then
      mkdir -p "/mnt/out$(dirname "$dst_path")"
      cp -a "$src" "/mnt/out$dst_path"
      VPU_COPIED=$((VPU_COPIED+1))
    fi
  done < "$L"
done
echo "   VPU files copied: $VPU_COPIED"

# The VIP/NPU userspace and YOLOv5 demo are supplied by the Orange Pi image,
# not the Radxa KDE image. The output started as a clone of that image, so
# retain the files in place and verify that the source image really has them.
echo ">> [check] VIP/NPU userspace and YOLOv5 demo from Orange Pi"
for npu_path in /usr/lib/libVIPhal.so /opt/yolov5; do
  npu_src="/mnt/out$npu_path"
  if [ ! -e "$npu_src" ] && [ ! -L "$npu_src" ]; then
    echo "ERROR: required NPU path is missing from Orange Pi image: $npu_path" >&2
    echo "       This image does not contain the expected VIP/YOLOv5 demo." >&2
    exit 1
  fi
done
echo "   NPU paths present: /usr/lib/libVIPhal.so /opt/yolov5"

echo ">> [graft] Patching gstomx.conf"

# libgstomx.so has a set of workarounds. Radxa doesn't enable them all.
# On the OPi, decode/encode stalls during the OMX Loaded -> Idle transition without
# these extra workarounds enabled. The stall happens because the output port 
# keeps the 176x144 placeholder format. Enabling pass-color-format-to-decoder, 
# height-multiple-16, and the other supported flags fixes decode and encode.
#
# Valid flag names were taken from the plugin binary:
#   strings /usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstomx.so | \
#     grep -E "^(no-|event-|signals-|pass-|height-)"
GSTOMX_STAGED=/mnt/out/etc/xdg/gstomx.conf
if [ -f "$GSTOMX_STAGED" ]; then
  HACKS="event-port-settings-changed-ndata-parameter-swap;event-port-settings-changed-port-0-to-1;no-disable-outport;no-component-reconfigure;no-component-role;no-empty-eos-buffer;pass-color-format-to-decoder;pass-profile-to-decoder;signals-premature-eos;height-multiple-16"
  sed -i "s|^hacks=.*|hacks=$HACKS|" "$GSTOMX_STAGED"
  echo "   gstomx.conf patched; $(grep -c '^hacks=' "$GSTOMX_STAGED") entries updated"
fi

echo ">> [graft] Adding udev rule for /dev/cedar_dev_ve2"

# Make the Cedar device nodes usable on headless boots too
cat > /mnt/out/etc/udev/rules.d/99-cedar-ve.rules <<'EOF'
KERNEL=="cedar_dev*", MODE="0666"
SUBSYSTEM=="cedar_ve", TAG+="uaccess", MODE="0666"
SUBSYSTEM=="cedar_ve2", TAG+="uaccess", MODE="0666"
EOF

echo ">> [graft] Xorg device config: bind modesetting to /dev/dri/card0 (sunxi-drm)"
# Bind Xorg to the Allwinner display controller. The PowerVR node is render-only.
mkdir -p /mnt/out/etc/X11/xorg.conf.d
cat > /mnt/out/etc/X11/xorg.conf.d/20-modesetting.conf <<'EOF'
Section "OutputClass"
  Identifier "sunxi-drm"
  MatchDriver "sun60i-display-engine"
  Driver "modesetting"
  Option "PrimaryGPU" "true"
  Option "kmsdev" "/dev/dri/card0"
  Option "SWcursor" "true"
  Option "ShadowFB" "true"
EndSection

Section "Device"
  Identifier "sunxi-drm-card0"
  Driver "modesetting"
  Option "kmsdev" "/dev/dri/card0"
  Option "SWcursor" "true"
  Option "ShadowFB" "true"
EndSection
EOF

echo ">> [graft] OpenCV 4.5d -> 4.5 SONAME compat for OPi-bundled YOLOv5 demo"
# The bundled YOLOv5 demo expects unsuffixed OpenCV 4.5 SONAMEs.
LIBDIR=/mnt/out/usr/lib/aarch64-linux-gnu
for stem in libopencv_core libopencv_imgproc libopencv_imgcodecs; do
  if [ -e "$LIBDIR/${stem}.so.4.5d" ] && [ ! -e "$LIBDIR/${stem}.so.4.5" ]; then
    ln -sf "${stem}.so.4.5d" "$LIBDIR/${stem}.so.4.5"
  fi
done

echo ">> [host] Setting up chroot mounts"
cp /usr/bin/qemu-aarch64-static /mnt/out/usr/bin/
mount -t proc proc /mnt/out/proc
mount --rbind /sys /mnt/out/sys
mount --rbind /dev /mnt/out/dev
mkdir -p /mnt/out/run
mount -t tmpfs tmpfs /mnt/out/run
cp /mnt/out/etc/resolv.conf /tmp/resolv.bak 2>/dev/null || true
echo "nameserver 8.8.8.8" > /mnt/out/etc/resolv.conf

echo
echo "==================== ENTERING ARM64 CHROOT ===================="
chroot /mnt/out /bin/bash <<CHROOT_EOF
set -euo pipefail
export OPI_KVER=${OPI_KVER}
export DKMS_SOURCE_NAME=${DKMS_SOURCE_NAME}
export DKMS_VERSION=${DKMS_VERSION}

echo ">> [chroot] \$(uname -m) on \$(grep PRETTY /etc/os-release | cut -d'"' -f2)"

echo ">> [chroot] Installing build deps"
apt-get update 2>&1 | tail -3
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential dkms 2>&1 | tail -3

echo ">> [chroot] Installing OPi-staged kernel headers from /opt/"
DEBIAN_FRONTEND=noninteractive dpkg -i "/opt/${OPI_HEADER_DEB}" 2>&1 | tail -5

echo ">> [chroot] Staging sunxi-sid.h into OPi BSP includes"
mkdir -p /usr/src/linux-headers-\${OPI_KVER}/bsp/include
cp /tmp/sunxi-sid.h /usr/src/linux-headers-\${OPI_KVER}/bsp/include/
ls -la /usr/src/linux-headers-\${OPI_KVER}/bsp/include/sunxi-sid.h

echo ">> [chroot] DKMS install img-bxm-dkms/0.1.0-2 (build + install)"
dkms add "/usr/src/${DKMS_SOURCE_NAME}" 2>&1 | tail -3 || true
dkms install "img-bxm-dkms/${DKMS_VERSION}" -k \${OPI_KVER} 2>&1 | tail -15

echo ">> [chroot] dkms status:"
dkms status

echo ">> [chroot] Verifying pvrsrvkm.ko placement"
find /lib/modules/\${OPI_KVER}/updates -name "pvrsrvkm*" -ls 2>/dev/null
# Check the built module directly: without it the image has no GPU, so abort
# rather than ship a broken image silently.
if ! ls /lib/modules/\${OPI_KVER}/updates/dkms/pvrsrvkm.ko* >/dev/null 2>&1; then
  echo "ERROR: DKMS did not produce pvrsrvkm.ko for \${OPI_KVER}; aborting." >&2
  exit 1
fi

echo ">> [chroot] depmod"
depmod \${OPI_KVER}

echo ">> [chroot] ldconfig"
ldconfig
ldconfig -p | grep -E "libsrv_um|libGLESv2_PVR|libVE\.so|libOmxCore" | head

echo ">> [chroot] Verifying GStreamer registered the OMX plugin"
gst-inspect-1.0 omxh264dec 2>&1 | grep -E "Hardware|Rank" | head

echo ">> [chroot] Verifying gstomx.conf patch"
grep -c "pass-color-format-to-decoder" /etc/xdg/gstomx.conf || echo "WARN: gstomx.conf patch may not have applied"

echo ">> [chroot] pvrsrvkm in modules.dep?"
grep "pvrsrvkm" /lib/modules/\${OPI_KVER}/modules.dep | head

echo ">> [chroot] Final cleanup"
rm -f /tmp/sunxi-sid.h /usr/bin/qemu-aarch64-static
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT_EOF
echo "==================== EXITED CHROOT ===================="

cp /tmp/resolv.bak /mnt/out/etc/resolv.conf 2>/dev/null || true

echo ""
echo "Sync filesystem"
sync
echo ""
echo "Done. Output: $OUT_IMG"
ls -la "$OUT_IMG"
