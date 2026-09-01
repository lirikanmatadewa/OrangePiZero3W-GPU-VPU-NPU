# Orange Pi Zero 3W GPU/VPU/NPU image builder

The Orange Pi Zero 3W's Allwinner A733 has an Imagination PowerVR BXM-4-64 GPU, an Allwinner Cedar video engine, and a VIP/NPU accelerator. Orange Pi's stock image ships without the userspace needed to use these accelerators. Radxa's Cubie A7S uses the same A733 silicon and ships compatible PowerVR, Cedar, and VIP userspace in its Debian image.

These scripts build an Orange Pi Zero 3W Ubuntu image with working GPU, VPU, and NPU userspace. GPU/VPU userspace is grafted from a Radxa image, while the NPU userspace already present in the Orange Pi image is retained, then the PowerVR kernel module is rebuilt against Orange Pi's kernel with DKMS.

No proprietary binaries live in this repository. The GPU/VPU files come from the Radxa image and the NPU files come from the Orange Pi image on your own machine at build time. There's a longer write-up in [this XDA article](https://www.xda-developers.com/orange-pi-zero-3w-beats-raspberry-pi-5-cant-use-half-hardware/).

## What works

On the tested image pair, the result has:

- PowerVR Vulkan/OpenGL ES/OpenCL userspace
- `pvrsrvkm` rebuilt for Orange Pi's `6.6.98-sun60iw2` kernel, with PowerVR firmware and the Vulkan ICD in place
- Allwinner CedarC/libcedarc userspace
- VIP/NPU userspace (`libVIPhal.so`) and the Orange Pi `/opt/yolov5` demo tree
- Hardware video decode/encode through GStreamer's OMX plugins
- Hardware-accelerated WebGL/WebGPU in Chromium via ANGLE-on-Vulkan, installed from the saiarcot895 PPA (Ubuntu's repository `chromium-browser` is only a Snap transition package that's unsuitable for this userspace). Two test launchers are added to the desktop. The first is a WebGL aquarium and the second is a `chrome://gpu` shortcut
- Orange Pi's original bootloader, kernel, DTB, Wi-Fi, Bluetooth, desktop, and default user are all untouched

The NPU portion is userspace integration: the image builder retains the VIP HAL
and demo tree supplied by the Orange Pi image. It
does not replace the Orange Pi kernel or claim that every NPU application is
supported. The included YOLOv5 demo is the reference application for checking
the supplied NPU userspace.

## Source images

Download both images, then verify each against the checksum the vendor actually publishes. The two cover different files: OrangePi checksums the extracted `.img`, while Radxa checksums the downloaded `.xz`. Each value below is the one that vendor signs, so they're verified at different stages.

**Orange Pi Zero 3W: Ubuntu Jammy XFCE desktop, kernel 6.6.98**
- Download: <http://www.orangepi.org/html/hardWare/computerAndMicrocontrollers/details/Orange-Pi-Zero-3W.html>
- Archive `Orangepizero3w_1.0.0_ubuntu_jammy_desktop_xfce_linux6.6.98.7z`, which extracts to `Orangepizero3w_1.0.0_ubuntu_jammy_desktop_xfce_linux6.6.98.img`
- SHA256 of the extracted `.img`: `af6697c4f158f63ffdf55f5a17453ef3b9b2895f35b2891e6090d28f65faf264`

**Radxa Cubie A7S: Bullseye KDE, kernel 5.15.147**
- Download: <https://docs.radxa.com/en/cubie/a7s/download>
- Archive `radxa-a733_bullseye_kde_r2.output_512.img.xz`, which extracts to `radxa-a733_bullseye_kde_r2.output_512.img`
- SHA256 of the downloaded `.xz`: `1b5604fed61647ab1b510f24af5968477e8a7a361430aa0864efbed7b5fe6ca2`

```bash
# OPi: verify the .img after extracting the .7z
shasum -a 256 Orangepizero3w_1.0.0_ubuntu_jammy_desktop_xfce_linux6.6.98.img

# Radxa: verify the downloaded archive before extracting
shasum -a 256 radxa-a733_bullseye_kde_r2.output_512.img.xz
```

I only tested this exact image pair. The scripts read partition offsets from each image's own partition table, but the package names and paths are hardcoded to those two BSP images, including `/usr/lib/libVIPhal.so` and `/opt/yolov5` for NPU support. A different or newer image may need small path/package-name fixes. When an input doesn't match, the scripts fail at the missing file rather than producing a broken image.

## Build a flashable image

Install Docker, then run this from the repository root:

```bash
docker run --rm --privileged -v "$(pwd):/work" -w /work \
  debian:bookworm-slim bash /work/scripts/build.sh
```

The output is `hybrid-opi66-with-radxa-gpu-vpu-npu.img`. Flash it with your usual imaging tool, or with `dd`.

To rebuild the PowerVR module, `build.sh` runs DKMS against the kernel headers the stock Orange Pi image already ships at `/opt/linux-headers-current-sun60iw2_*.deb`. The build depends on that `.deb` being present there; the pinned image carries it.

macOS:

```bash
diskutil list
sudo diskutil unmountDisk /dev/diskN
sudo dd if=hybrid-opi66-with-radxa-gpu-vpu-npu.img of=/dev/rdiskN bs=4m status=progress
sudo diskutil eject /dev/diskN
```

Login is unchanged: `orangepi`/`orangepi`.

## Userspace tarballs only

To pull just the PowerVR and VPU userspace out of the Radxa image (for an Orange Pi 6.6 system you've already set up) skip the full build:

```bash
docker run --rm --privileged -v "$(pwd):/work" -w /work \
  debian:bookworm-slim bash /work/scripts/make-tarball.sh
```

This command expects both source images in `/work`: Radxa supplies GPU/VPU
files, and the Orange Pi image supplies the NPU files.

Or use the repository wrapper, which checks both images before starting Docker:

```bash
./build-tarballs.sh
```

That produces three independent bundles:

- `pvr-userspace.tar.gz`: PowerVR userspace and firmware files
- `vpu-userspace.tar.gz`: Cedar/libcedarc and GStreamer OMX files
- `npu-userspace.tar.gz`: the VIP/NPU HAL (`/usr/lib/libVIPhal.so`) and the Orange Pi `/opt/yolov5` demo tree

Copy the bundles you need to the board and extract them as root. For the full
GPU/VPU/NPU setup:

```bash
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
tree is absent from the source image, both the full image build and the NPU
tarball build stop with an error.

This does not build the PowerVR kernel module. Use the full image builder if you want DKMS handled for you.

### Armbian and newer Debian/Ubuntu images

The exported tarballs are intended to be portable userspace bundles. They can
also be used on compatible Armbian images and on newer Debian or Ubuntu images
for the Orange Pi Zero 3W, instead of flashing the pinned Jammy image used by
the full builder. Install only the bundles you need; the NPU bundle is
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
