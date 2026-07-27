# The driver stack this runs on

Everything in this toolkit — the Ollama tier and the vLLM diffusion server — runs against one
frozen NVIDIA stack. It's frozen on purpose: getting here involved a Secure Boot and boot-disk
ordeal, and I don't want an unattended `apt upgrade` to move any piece of it out from under a
working GPU. This is the record of what's pinned, so a future me (or anyone rebuilding) knows the
exact set.

## What's running (verified 2026-07-26)

| Layer | Version |
|---|---|
| Kernel | `6.8.0-136-generic` |
| NVIDIA driver (userspace) | `565.57.01` |
| NVIDIA kernel module | `565.57.01` (server branch, Canonical-signed) |
| CUDA the driver exposes | 12.7 |
| GPU | RTX 5000 Ada, compute capability 8.9 |

The whole 565 stack is the **server** driver branch, prebuilt and signed by Canonical (so it loads
under Secure Boot without a local DKMS key). Userspace and kernel module must always match — a skew
between them is the classic "Driver/library version mismatch" that makes `nvidia-smi` go blind.

Note the driver exposes **CUDA 12.7**, but the diffusion server runs a **CUDA 12.9** (`+cu129`)
build. That works by CUDA minor-version compatibility (same major 12). See
[`serving/diffusion/README.md`](../serving/diffusion/README.md).

## The apt holds (24 packages)

These are `apt-mark hold`'d so upgrades and unattended-upgrades skip them. They're one coherent set:
the kernel, its module packages, the signed NVIDIA kernel module, and the NVIDIA userspace — all at
565-server / 6.8.0-136. Moving any one without the others reintroduces the mismatch.

```
# kernel + its modules (the -extra package carries vmd.ko, needed to see the NVMe root disk)
linux-image-6.8.0-136-generic
linux-modules-6.8.0-136-generic
linux-modules-extra-6.8.0-136-generic

# HWE metapackages — the "trunk" that would otherwise roll the kernel forward
linux-generic-hwe-22.04
linux-image-generic-hwe-22.04
linux-headers-generic-hwe-22.04

# the signed NVIDIA kernel module (prebuilt, Canonical-signed — loads under Secure Boot)
linux-modules-nvidia-565-server-6.8.0-136-generic
linux-modules-nvidia-565-server-generic-hwe-22.04
linux-objects-nvidia-565-server-6.8.0-136-generic

# NVIDIA driver + userspace libraries
nvidia-driver-565-server
nvidia-kernel-common-565-server
nvidia-kernel-source-565-server
nvidia-compute-utils-565-server
nvidia-utils-565-server
nvidia-firmware-565-server-565.57.01
xserver-xorg-video-nvidia-565-server
libnvidia-cfg1-565-server
libnvidia-common-565-server
libnvidia-compute-565-server
libnvidia-decode-565-server
libnvidia-encode-565-server
libnvidia-extra-565-server
libnvidia-fbc1-565-server
libnvidia-gl-565-server
```

Check the live set anytime:

```bash
apt-mark showhold | sort          # the 24 above
uname -r                          # 6.8.0-136-generic
nvidia-smi --query-gpu=driver_version --format=csv,noheader   # 565.57.01
cat /proc/driver/nvidia/version   # loaded module must match userspace
```

## Why not just upgrade to a newer driver

A newer driver (580+) would unlock things — e.g. NVFP4 quants, the default CUDA-13 vLLM wheels. But
on this box 580 had no matched signed+trusted module pair when I needed it, and moving the kernel
reopened an Intel VMD boot failure (the NVMe root disk vanished without `vmd.ko` in the initramfs).
The cost of touching it is a potential unbootable machine, so it stays frozen until a deliberate,
on-console maintenance window. The diffusion work above is all built to run *within* this frozen
stack rather than around it.
