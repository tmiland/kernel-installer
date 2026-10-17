# kernel-installer
Automatic install script for [The Linux kernel](https://www.kernel.org)

Inspired by [LinuxKernelBuild](https://github.com/Angristan/LinuxKernelBuild)

[![GitHub release](https://img.shields.io/github/release/tmiland/kernel-installer.svg?style=for-the-badge)](https://github.com/tmiland/kernel-installer/releases)
[![licence](https://img.shields.io/github/license/tmiland/kernel-installer.svg?style=for-the-badge)](https://github.com/tmiland/kernel-installer/blob/main/LICENSE)
![Bash](https://img.shields.io/badge/Language-SH-4EAA25.svg?style=for-the-badge)

### Script to install the latest [stable/mainline/longterm] kernel from source on Debian-based distributions and the Fedora/RHEL family.

[![kernel-installer Image](https://raw.githubusercontent.com/tmiland/kernel-installer/main/_images/kernel_installer.png)](https://github.com/tmiland/kernel-installer/blob/main/_images/kernel_installer.png)

### Dependencies

Missing packages are installed when running the script.
```bash
# Debian/Ubuntu
wget curl git rsync fakeroot cpio kmod build-essential libncurses-dev xz-utils libssl-dev bc lz4 libelf-dev flex bison debhelper dpkg-dev procps apt-transport-https libdw-dev
# Fedora/RHEL
wget curl git rsync ca-certificates procps-ng findutils diffutils hostname bc binutils bison dwarves elfutils-libelf-devel flex gcc make openssl openssl-devel perl python3 ncurses-devel cpio kmod xz lz4 rpm-build dracut grubby
```
`gnupg` is also installed on demand when tarball verification needs `gpg`/`gpgv`, and `kexec-tools` when `--kexec` is used.

On Debian-based systems `lsb-release` is required; the script offers to install it if it is missing.

### Notes

- This script reverts bug #1086172 [Enable more ZRAM compression options by default](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1086172) (kernel 6.12 and newer)
  - Sets default compression to zstd (change it with `--default-compression`), and enables support for the rest of the algorithms
  - Options are:
```bash
lz4 compression support (ZRAM_BACKEND_LZ4) [Y/n/?] y
lz4hc compression support (ZRAM_BACKEND_LZ4HC) [Y/n/?] y
zstd compression support (ZRAM_BACKEND_ZSTD) [Y/n/?] y
deflate compression support (ZRAM_BACKEND_DEFLATE) [Y/n/?] y
842 compression support (ZRAM_BACKEND_842) [Y/n/?] y
lzo and lzo-rle compression support (ZRAM_BACKEND_LZO) [Y/n/?] y
Default zram compressor
  1. lzo-rle (ZRAM_DEF_COMP_LZORLE)
  2. lzo (ZRAM_DEF_COMP_LZO)
  3. lz4 (ZRAM_DEF_COMP_LZ4) (NEW)
  4. lz4hc (ZRAM_DEF_COMP_LZ4HC) (NEW)
> 5. zstd (ZRAM_DEF_COMP_ZSTD)
  6. deflate (ZRAM_DEF_COMP_DEFLATE) (NEW)
  7. 842 (ZRAM_DEF_COMP_842) (NEW)
```

### Download the script

Quick install with default options:

With Curl:
```bash
curl -sSL https://github.com/tmiland/kernel-installer/raw/main/kernel_installer.sh | bash || exit 0
```
With Wget:
```bash
wget -qO - https://github.com/tmiland/kernel-installer/raw/main/kernel_installer.sh | bash || exit 0
```

When run outside a git checkout, a pinned and checksum-verified copy of the
function library (`src/slib.sh`) is fetched automatically.

For latest release

```bash
curl -s https://api.github.com/repos/tmiland/kernel-installer/releases/latest \
| grep "browser_download_url.*sh" \
| cut -d : -f 2,3 \
| tr -d \" \
| wget -qi -
```

For main branch
```bash
wget https://github.com/tmiland/kernel-installer/raw/main/kernel_installer.sh
```

Set execute permission:
```bash
chmod +x kernel_installer.sh
```
For usage, run:
```bash
./kernel_installer.sh -h
```

### Help output

```bash
Usage:  kernel_installer.sh [options]
  If called without arguments, installs stable kernel 7.2.11 using /opt/linux-kernel

--help                 |-h   display this help and exit
--kernel               |-k   kernel version of choice
--stable               |-s   stable kernel version 7.2.11
--mainline             |-m   mainline kernel version 7.3-rc7
--longterm             |-l   longterm kernel version 6.18.57
--dir                  |-d   install directory
--kexec                |-x   load new kernel without reboot
--config               |-c   set configuration target
--custom-config        |-cc  set custom configuration directive, can be used multiple times
--verbose              |-v   increase verbosity
--get-verified-tarball |-gvt cryptographically verify kernel tarball (default)
--nproc                |-n   set the number of processing units to use
--enable-debug-info    |-edi enable debug info
--lowlatency           |-low convert generic config to lowlatency
--list-installed       |-li  list installed kernels
--default-compression  |-dc  select default compression algorithm
--changelog            |-cl  view changelog for kernel version
--update               |-upd check for script update
--uninstall            |-u   uninstall kernel (use with -k option)
```

The versions shown are looked up live from kernel.org each time the script runs.

To use opt --kernel:
```bash
./kernel_installer.sh --kernel 5.17.8
```
Else use:
```bash
./kernel_installer.sh --stable, --mainline or --longterm separately
```
To use --dir opt:
```bash
./kernel_installer.sh --dir /path/to/dir
```
The source is downloaded and built in a `linux-kernel` subdirectory (here `/path/to/dir/linux-kernel`, default `/opt/linux-kernel`), which is removed after a successful install. The script refuses to use a directory that is not empty unless it created it in a previous run.
To load [kernel without reboot](https://linux.die.net/man/8/kexec):
```bash
./kernel_installer.sh --kexec
```
To use --config:
```bash
./kernel_installer.sh --config menuconfig
```
default is `olddefconfig`

### Configuration targets

As listed by `make help` in the kernel source (7.3); older kernels may lack some of them.
With the default `olddefconfig`, the kernel build picks up the running kernel's
configuration (e.g. `/boot/config-$(uname -r)`) as the base when one is available.

```bash
config          - Update current config utilising a line-oriented program
nconfig         - Update current config utilising a ncurses menu based program
menuconfig      - Update current config utilising a menu based program
xconfig         - Update current config utilising a Qt based front-end
gconfig         - Update current config utilising a GTK+ based front-end
oldconfig       - Update current config utilising a provided .config as base
localmodconfig  - Update current config disabling modules not loaded
localyesconfig  - Update current config converting local mods to core
defconfig       - New config with default from ARCH supplied defconfig
savedefconfig   - Save current config as ./defconfig (minimal config)
allnoconfig     - New config where all options are answered with no
allyesconfig    - New config where all options are accepted with yes
allmodconfig    - New config selecting modules when possible
alldefconfig    - New config with all symbols set to default
randconfig      - New config with random answer to all options
yes2modconfig   - Change answers from yes to mod if possible
mod2yesconfig   - Change answers from mod to yes if possible
mod2noconfig    - Change answers from mod to no if possible
listnewconfig   - List new options
helpnewconfig   - List new options and help text
olddefconfig    - Same as oldconfig but sets new symbols to their default value without prompting
tinyconfig      - Configure the tiniest possible kernel
```

### Custom configuration directives

In order to enable specific kernel configs, one can use `--custom-config` like the following example:
```
./kernel_installer.sh --custom-config "scripts/config --set-val CONFIG_DM_VDO m"
```

The directive must be a `scripts/config` command; raw `CONFIG_*` assignments (e.g. `CONFIG_DM_VDO=y`) are not accepted.

Note that `--custom-config` can be used multiple times like:
```
./kernel_installer.sh --custom-config "scripts/config --set-val CONFIG_DM_VDO m" --custom-config "scripts/config --set-val CONFIG_KERNEL_ZSTD y"
```

### Tarball verification

Stable, longterm and `--kernel` tarballs are cryptographically verified by default
(`--get-verified-tarball` is accepted but no longer needed). The `sha256sums.asc`
file is checked against the kernel.org autosigner key, and the tarball against
the Linus Torvalds / Greg Kroah-Hartman signatures, fetched via WKD.
 - [Linux kernel releases PGP signatures](https://www.kernel.org/category/signatures.html)
 - Source script [get-verified-tarball](https://git.kernel.org/pub/scm/linux/kernel/git/mricon/korg-helpers.git/tree/get-verified-tarball)
 - Installs `gnupg` if `gpg`/`gpgv` are not available
 - Keys are kept in `$GNUPGHOME` (default `~/.gnupg`); run with `GNUPGHOME=` (empty) to use a throwaway keyring instead
 - Mainline snapshots from git.kernel.org are not signed and are not verified

To skip verification:
```bash
GET_VERIFIED_TARBALL=0 ./kernel_installer.sh
```

Used together:
```bash
./kernel_installer.sh --stable --config menuconfig --kexec --dir /path/to/dir
```

Watch install log:
```bash
tail -f /var/log/kernel_installer.log
```

- installation log in `/var/log/kernel_installer.log` (recreated on every run)
- [./src/slib.sh](https://github.com/tmiland/kernel-installer/blob/main/src/slib.sh) function script is sourced remotely if not found locally
  - This script is a combination of functions for spinners, colors and logging
    - Source: Spinner: [swelljoe/spinner](https://github.com/swelljoe/spinner)
    - Source: Run ok: [swelljoe/run_ok](https://github.com/swelljoe/run_ok)
    - Source: Slog: [swelljoe/slog](https://github.com/swelljoe/slog)
    - Source: Slib: [virtualmin/slib](https://github.com/virtualmin/slib)

***Note: you will need to run this script as root***

If root password is not set, type:

```bash
sudo passwd root
```

Then:

```bash
su root
```


**Full write-up on the blog:** https://tmiland.com/kernel-installer/
## Uninstall kernel

To uninstall previously installed kernel:
```bash
./kernel_installer.sh --uninstall --kernel 5.17.7
```

- The `linux-image-<version>` and `linux-headers-<version>` packages (Fedora/RHEL: `kernel-<version>` and `kernel-devel-<version>`) are removed
- On Debian-based systems `apt` asks for confirmation; on Fedora/RHEL they are removed without a prompt

## Testing

Tested and working on: Debian 12/13, Ubuntu 22.04/24.04 and Fedora 44 (see [test-install.yml](.github/workflows/test-install.yml))

- Each CI run uploads the installer log of every distro as a workflow artifact (`kernel-installer-logs-<distro>`) on the [Actions](https://github.com/tmiland/kernel-installer/actions/workflows/test-install.yml) page

## Maintenance

### Updating the vendored slib

`src/slib.sh` is a curated subset of [virtualmin/slib](https://github.com/virtualmin/slib) (tracked via [tmiland/slib](https://github.com/tmiland/slib)). Updates are two-phase, and CI enforces the second one on `main`:

```bash
# Phase 1 - vendor the new file (defaults to tmiland/slib@master)
scripts/update-slib.sh
git add src/slib.sh && git commit -m 'chore: update vendored slib.sh' && git push

# Phase 2 - pin the pushed commit (updates SLIB_REV / SLIB_SHA256)
scripts/update-slib.sh --finalize <commit>
git add kernel_installer.sh && git commit -m 'chore: bump slib pin' && git push
```

- Use `--source virtualmin/slib` to pull upstream directly. Sync your fork first with `gh repo sync tmiland/slib -b master`.
- Sources contain extra Virtualmin-only helpers and are not lint-clean as-is (e.g. `#!/bin/sh` shebang); the vendored copy is a trimmed, lint-clean subset. Review `git diff src/slib.sh` and the helper's shellcheck output before committing.
- Until phase 2 lands on `main`, the `slib pin` CI job fails (that is the reminder).

## Feature request and bug reports
- [Bug report](https://github.com/tmiland/kernel-installer/issues/new?assignees=tmiland&labels=bug&template=bug_report.md&title=Bug-report:)
- [Feature request](https://github.com/tmiland/kernel-installer/issues/new?assignees=tmiland&labels=enhancement&template=feature_request.md&title=Feature-request:)

## Donations
<a href="https://www.buymeacoffee.com/tmiland" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>
- [PayPal me](https://paypal.me/milandtommy)
- [BTC] : 33mjmoPxqfXnWNsvy8gvMZrrcG3gEa3YDM

#### Disclaimer 

*** ***Use at own risk*** ***

### License

[![MIT License Image](https://upload.wikimedia.org/wikipedia/commons/thumb/0/0c/MIT_logo.svg/220px-MIT_logo.svg.png)](https://github.com/tmiland/kernel-installer/blob/main/LICENSE)

[MIT License](https://github.com/tmiland/kernel-installer/blob/main/LICENSE)
