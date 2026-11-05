# Orange Pi Zero 3W GPU/VPU/NPU image builder

The Orange Pi Zero 3W's Allwinner A733 has an Imagination PowerVR BXM-4-64 GPU, an Allwinner Cedar video engine, and a VIP/NPU accelerator. Orange Pi's stock image ships without the userspace needed to use these accelerators. Radxa's Cubie A7S uses the same A733 silicon and ships compatible PowerVR, Cedar, and VIP userspace in its Debian image.

These scripts build a Debian-based Orange Pi Zero 3W image, including Armbian images, with GPU, VPU, and NPU userspace. GPU/VPU userspace is grafted from a compatible Radxa A733 image, while NPU userspace is retained from the target image or copied from an optional stock Orange Pi donor. The PowerVR kernel module is rebuilt against the selected Orange Pi kernel with DKMS.

No proprietary binaries live in this repository. The GPU/VPU files come from the Radxa image and the NPU files come from the Orange Pi image on your own machine at build time. There's a longer write-up in [this XDA article](https://www.xda-developers.com/orange-pi-zero-3w-beats-raspberry-pi-5-cant-use-half-hardware/).

## What works

When the selected images contain the required compatible userspace and kernel headers, the result has:

- PowerVR Vulkan/OpenGL ES/OpenCL userspace
- `pvrsrvkm` rebuilt for the selected Orange Pi kernel, with PowerVR firmware and the Vulkan ICD in place
- Allwinner CedarC/libcedarc userspace
- VIP/NPU userspace (`libVIPhal.so`) and the Orange Pi `/opt/yolov5` demo tree
- Hardware video decode/encode through GStreamer's OMX plugins
- The selected image's original browser and desktop setup, which the builder leaves unchanged
- Orange Pi's original bootloader, kernel, DTB, Wi-Fi, Bluetooth, desktop, and default user are all untouched

The NPU portion is userspace integration: the image builder retains or copies the VIP HAL
and demo tree supplied by an Orange Pi image. It
does not replace the Orange Pi kernel or claim that every NPU application is
supported. The included YOLOv5 demo is the reference application for checking
the supplied NPU userspace.

## Source images

Download a Debian-based Orange Pi Zero 3W image (including Armbian) and a Radxa A733 image, then verify them using the checksums published by each vendor:

- Orange Pi Zero 3W: <http://www.orangepi.org/html/hardWare/computerAndMicrocontrollers/details/Orange-Pi-Zero-3W.html>
- Radxa Cubie A7S: <https://docs.radxa.com/en/cubie/a7s/download>

For the full image build, put the uncompressed `.img` files in the directory you mount at `/work`. Copy `.env.example` to `.env` and set the exact filenames:

```dotenv
OPI_IMAGE=Orangepizero3w_1.0.2_debian_trixie_desktop_xfce_linux6.6.98.img
RADXA_IMAGE=radxa-a733_trixie_kde_t6.output_512.img
# Optional when the target (e.g. Armbian) lacks NPU userspace:
NPU_IMAGE=Orangepizero3w_1.0.2_debian_trixie_desktop_xfce_linux6.6.98.img
```

The values are filenames, not paths. Leave `OPI_IMAGE` or `RADXA_IMAGE` empty to auto-detect it when exactly one matching image is present. If none or multiple matches are found, the build stops and lists the candidates. Set `OPI_IMAGE` explicitly when both a target and a stock donor image are present. The Orange Pi selection must be a Debian-based Zero 3W image; the Radxa selection must be an A733 image containing the GPU/VPU package manifests and files the build validates. The current image layouts must expose Orange Pi rootfs (including an optional NPU donor) as MBR partition 1 and Radxa rootfs as GPT partition 3. Other Radxa releases/layouts may not be compatible.

`NPU_IMAGE` is optional and is never auto-detected. When blank, the target image
must already contain `/usr/lib/libVIPhal.so` and `/opt/yolov5`. When set, the
builder mounts that stock Orange Pi image read-only and copies those paths into
the target or NPU tarball. This does not copy the donor's kernel or drivers;
Armbian must supply compatible NPU kernel/device-tree support. The Radxa image
used here supplies GPU/VPU files, not these NPU files.

The selected Debian or Armbian image must include one kernel release under `/lib/modules` and matching headers, either installed under `/usr/src/linux-headers-<kernel-release>` or available as a kernel-header `.deb` under `/opt`. The builder checks for a matching kernel/header pair before grafting accelerator files.

## Build a flashable image

Install Docker, then run this from the repository root:

With [Pixi](https://pixi.sh) installed, use:

```bash
pixi run check
pixi run build
```

Docker must be running and accessible to your user. The build task runs the
privileged Debian container below with the repository mounted at `/work`, using
the same `.env` and source images. Build tools, QEMU, DKMS, GStreamer tools, and
the XCB/DRI runtime libraries needed by the GPU userspace
are installed inside the container or target rootfs, not on the host. Internet
access to Debian package repositories is required.

Alternatively, run Docker directly:

```bash
docker run --rm --privileged -v "$(pwd):/work" -w /work \
  debian:bookworm-slim bash /work/scripts/build.sh
```

The output is `YYYYMMDD-<Debian-image-basename>+radxa_gpu_vpu_npu.img` in `/work`; for example, `20261002-Orangepizero3w_1.0.2_debian_trixie_desktop_xfce_linux6.6.98+radxa_gpu_vpu_npu.img`. The Debian source image is left unchanged. Flash the result with your usual imaging tool, or with `dd`.

The Ubuntu-only Chromium PPA setup is not run; the selected image's browser and desktop packages are left as supplied.

macOS:

```bash
diskutil list
sudo diskutil unmountDisk /dev/diskN
OUTPUT_IMAGE="YYYYMMDD-Debian-image-basename+radxa_gpu_vpu_npu.img"
sudo dd if="$OUTPUT_IMAGE" of=/dev/rdiskN bs=4m status=progress
sudo diskutil eject /dev/diskN
```

Login and user accounts remain as supplied by the selected target image.

## Userspace tarballs only

To pull just the PowerVR and VPU userspace out of the Radxa image (for an Orange Pi 6.6 system you've already set up) skip the full build:

```bash
pixi run tarballs
```

Or run Docker directly:

```bash
docker run --rm --privileged -v "$(pwd):/work" -w /work \
  debian:bookworm-slim bash /work/scripts/make-tarball.sh
```

This command expects the source images in `/work`: Radxa supplies GPU/VPU
files, and the target or optional `NPU_IMAGE` donor supplies the NPU files. It reads `.env`
from `/work` using the same selectors described above.

Or use the repository wrapper, which checks both images before starting Docker:

```bash
./build-tarballs.sh
```

For `./build-tarballs.sh`, place both images under the repository's `work/`
directory. The wrapper reads `.env` from the repository root and passes the
selected filenames into Docker. The command produces three independent bundles:

- `pvr-userspace.tar.gz`: PowerVR userspace and firmware files
- `vpu-userspace.tar.gz`: Cedar/libcedarc and GStreamer OMX files
- `npu-userspace.tar.gz`: the VIP/NPU HAL (`/usr/lib/libVIPhal.so`) and the Orange Pi `/opt/yolov5` demo tree

Copy the bundles you need to the board and extract them as root. For the full
GPU/VPU/NPU setup:

```bash
sudo apt-get update
sudo apt-get install -y gstreamer1.0-tools \
  libxcb-dri2-0 libxcb-dri3-0 libxcb-present0 libxcb-randr0 \
  libxcb-sync1 libxcb-xfixes0 libxshmfence1
sudo tar xzpf /tmp/pvr-userspace.tar.gz -C /
sudo tar xzpf /tmp/vpu-userspace.tar.gz -C /
sudo tar --dereference --xattrs --numeric-owner -xzpf /tmp/npu-userspace.tar.gz -C /
sudo ldconfig
sudo udevadm control --reload-rules && sudo udevadm trigger
sudo reboot
```

After reboot, confirm that the HAL is visible and run the demo from the
extracted tree. The exact entry point can vary between Radxa image revisions;
list the supplied files first:

```bash
ls -l /usr/lib/libVIPhal.so
find /opt/yolov5 -maxdepth 2 -type f -perm /111 -print
cd /opt/yolov5
```

The NPU tarball contains the following paths from the source image, with
archive metadata preserved:

```bash
sudo tar --dereference --xattrs --numeric-owner -czf npu-userspace.tar.gz \
  /usr/lib/libVIPhal.so \
  /opt/yolov5
```

The demo may still require the Python packages and model assets expected by
the particular Orange Pi image. Those are intentionally kept inside `/opt/yolov5`
when present, but are not downloaded by this repository. If the HAL or demo
tree is absent from the selected NPU source image, both the full image build and the NPU
tarball build stop with an error.

This does not build the PowerVR kernel module. Use the full image builder if you want DKMS handled for you.

### Armbian and newer Debian/Ubuntu images

The exported tarballs are intended to be portable userspace bundles. They can
also be used on compatible Armbian images and on newer Debian or Ubuntu images
for the Orange Pi Zero 3W, instead of rebuilding and flashing a full image.
Install only the bundles you need; the NPU bundle is
independent of the GPU and VPU bundles.

The target image must still provide a compatible A733 kernel and device-tree
support. The tarballs do not install or build a kernel, bootloader, device
tree, or kernel modules. In particular, the full GPU setup needs the
`pvrsrvkm` module built for the target kernel, and VPU/NPU applications need
the corresponding kernel device drivers and device nodes. Userspace library
compatibility can also depend on the target distribution's loader and system
libraries, so test on the specific Armbian or Debian/Ubuntu release in use.

After installing a bundle, run `ldconfig`, reload udev, reboot, and verify the
accelerator before relying on it in an application. The NPU bundle's supplied
`/opt/yolov5` tree is the reference test application, but its Python
dependencies and model assets may need to be installed separately on the
target distribution.

## Scripts

- `scripts/build.sh`: builds the full hybrid image
- `scripts/make-tarball.sh`: pulls PowerVR/VPU userspace from Radxa and NPU userspace from the Orange Pi image

## License and redistribution

The scripts and documentation here are MIT licensed. The Radxa, Imagination Technologies, and Allwinner binaries the scripts copy are not. They come from the Radxa image you provide locally and stay under their original licenses.

Don't open PRs containing source images, generated hybrid images, or the userspace tarballs.
