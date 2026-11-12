---
title: "Optimized Linux kernels on Debian: profiles, CachyOS BORE, and boot verification"
post_status: publish
post_excerpt: Kernel-installer now builds workload-specific kernels with use-case profiles, the CachyOS source and BORE scheduler, Clang LTO, CPU tuning, named releases, and a QEMU boot smoke test.
taxonomy:
    category:
        - linux
        - kernel
    post_tag:
        - linux
        - kernel
        - cachyos
        - bore
        - debian
---

# Optimized Linux kernels on Debian: profiles, CachyOS BORE, and boot verification

For a long time [kernel-installer](https://github.com/tmiland/kernel-installer) did one thing: download a kernel.org tarball, build it with `make bindeb-pkg`, and install the result on Debian, Ubuntu, Fedora or RHEL. That is still the core, but release 1.4.0 adds a layer on top: workload profiles, an optional CachyOS source build with the BORE scheduler, Clang LTO, CPU tuning, named kernel releases, and a QEMU boot smoke test in CI.

This post is a follow-up to the original kernel-installer write-up and covers what changed, how to use it, and where the limits are.

## The problem: a fast build should not make the desktop unusable

The motivation was local LLM and Android builds. On a 16-core Ryzen 9 5950X, a `-j32` build can make the desktop feel like it is running through treacle: the compositor, browser and terminal all compete with hundreds of compiler threads. BORE — the Burst-Oriented Response Enhancer scheduler used by CachyOS — is designed for exactly that kind of bursty, CPU-hungry background work. It is not a magic switch, but it is the right kind of scheduler-level help.

The other half is not a kernel setting at all: put the build in its own cgroup slice and leave the desktop outside it.

```bash
systemd-run --user --scope --slice=build.slice \
  -p CPUWeight=50 -p IOWeight=50 -p MemoryHigh=75% \
  bash -lc 'make -j$(( $(nproc) - 2 ))'
```

BORE improves how the remaining CPU time is shared; the slice reserves capacity. Use both.

## Use-case profiles

Instead of hand-writing a stack of `--custom-config` directives, the installer now has named profiles:

| Profile | Intended workload | Key settings |
|---|---|---|
| `desktop` | daily interactive desktop | HZ 1000, full preempt, THP madvise, MGLRU, zram, BBR, O2 |
| `workstation` | LLM/Android builds plus a responsive desktop | desktop + PSI/cgroup CPU limits, BBR default |
| `gaming` | latency-sensitive games | desktop timer/preempt settings, O2 |
| `server` | network/storage throughput | HZ 250, relaxed preempt, MGLRU, BBR default, NR_CPUS 256, O2 |
| `laptop` | battery and thermals | HZ 300, relaxed preempt, schedutil, AMD/Intel P-state, energy model, MGLRU, O2 |
| `lowlatency` | audio/live interactive work (legacy alias) | HZ 1000, full preempt, LATENCYTOP |

```bash
./kernel_installer.sh --profile workstation
./kernel_installer.sh --list-profiles
```

Profile builds default to the running kernel’s config, so the machine keeps its hardware support. `--base-config none` keeps the old arch-defconfig behavior, and `--custom-config` is applied after the profile so it can override anything.

## CachyOS source and BORE

BORE is not a mainline scheduler and the BORE patch does not apply cleanly to a vanilla kernel tree. The clean path is the CachyOS source tree, which already carries the CachyOS base patchset (`CONFIG_CACHY`), plus a pinned BORE patch:

```bash
sudo ./kernel_installer.sh -d /path/to/parent \
  --source cachyos --sched bore --profile workstation
```

The source is pinned to CachyOS 7.3.4-1 and verified with the CachyOS release keys. The config and BORE patch are pinned by commit and SHA256. The resulting kernel enables:

```text
CONFIG_CACHY=y
CONFIG_SCHED_BORE=y
```

`--source cachyos` uses the pinned CachyOS config by default; `--base-config running`, a path, or `none` still override it.

## Named kernels

Optimized builds get a `CONFIG_LOCALVERSION`, so they are visible everywhere it matters:

```text
7.3.4-cachyos-workstation-bore
```

That name flows through `uname -r`, `/lib/modules`, the headers package, DKMS, initramfs, GRUB and the `.deb` names. Adding native CPU or ThinLTO extends it:

```text
7.3.4-cachyos-workstation-bore-native-lto
```

`--kernel-tag <suffix>` overrides the generated suffix. The default vanilla build without a profile stays untagged.

A new localversion is a new kernel release, so DKMS modules must be rebuilt for it:

```bash
sudo dkms autoinstall -k 7.3.4-cachyos-workstation-bore
```

The installer warns when `dkms status -k <release>` finds nothing. Use the full release for removal:

```bash
sudo ./kernel_installer.sh --uninstall -k "$(uname -r)"
```

`--uninstall` without `-k` now defaults to the running release.

## CPU tuning and LTO

`--cpu` changes only the compiler ISA target:

- `generic` — portable x86-64 baseline; the default.
- `native` — `-march=native`, best for the build machine.
- `zen4` — `-march=znver4`, CachyOS source only.
- `x86-64-v3` — AVX2-era x86-64, CachyOS source only.
- `x86-64-v4` — AVX-512-era, CachyOS source only; limited hardware.

On a Ryzen 9 5950X, `native` means `znver3`; `x86-64-v3` is the portable modern choice; `zen4` and `v4` are the wrong targets for that CPU. The honest expectation for `native` versus `generic` is a small, workload-dependent gain — the kernel is mostly scalar code, and the profile/BORE changes matter far more for interactive responsiveness. If the OS may move to another machine, keep `generic`; build `native` on the new machine if you want it.

`--lto thin|full` adds Clang LTO and installs `clang`, `lld` and `llvm` on demand. It is a build-time choice, not a profile.

## Boot verification

Every distro install job in CI now boots the installed kernel under QEMU with a minimal initramfs and requires a `BOOT_SMOKE_OK` marker. That is not a full-OS boot or a benchmark, but it catches the “packages built, kernel does not boot” class of failure before a release. The same smoke test runs in the profile and CachyOS BORE jobs.

On the desktop, the named `7.3.4-cachyos-workstation-bore` kernel booted with `CONFIG_CACHY=y` and `CONFIG_SCHED_BORE=y`; `amdgpu`, `nct6687d` and `vpsu` DKMS modules were present for the new release, and fancontrol came up normally.

## Limits

- BORE is a patched scheduler, not mainline; it is pinned to the CachyOS source version.
- The boot smoke test is a minimal initramfs, not bare-metal or full userspace.
- Secure Boot users still need to sign the kernel or disable Secure Boot.
- A custom kernel is not a substitute for keeping a known-good distribution kernel in GRUB.
- CPU-specific builds are not portable to older machines.
- There are no benchmark numbers in this post; the “startup feels faster” observation is subjective. Measure your own workload.

## What’s next

The next items are sched_ext (which needs BTF/`pahole` and a userspace `scx` scheduler), and the remaining CachyOS kernel features that come with the base patchset: 500/600/750 Hz timer options, BBR3, Binder/Waydroid, and the hardware/MGLRU/I-O patches. BMQ, hardened, RT and AutoFDO are separate variants, not profile checkboxes.

The work is released as [v1.4.0](https://github.com/tmiland/kernel-installer/releases/tag/v1.4.0). Feedback and test reports are welcome — especially from anyone running the `workstation` profile under a real LLM or Android build.
