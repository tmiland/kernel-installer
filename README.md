# kernel-installer
Automatic install script for [The Linux kernel](https://www.kernel.org)

Inspired by [LinuxKernelBuild](https://github.com/Angristan/LinuxKernelBuild)

[![GitHub release](https://img.shields.io/github/release/tmiland/kernel-installer.svg?style=for-the-badge)](https://github.com/tmiland/kernel-installer/releases)
[![licence](https://img.shields.io/github/license/tmiland/kernel-installer.svg?style=for-the-badge)](https://github.com/tmiland/kernel-installer/blob/master/LICENSE)
![Bash](https://img.shields.io/badge/Language-SH-4EAA25.svg?style=for-the-badge)

### Script to install the latest [stable/mainline/longterm] kernel from source on Debian-based distributions, for all architectures.

[![kernel-installer Image](https://raw.githubusercontent.com/tmiland/kernel-installer/main/_images/kernel_installer.png)](https://github.com/tmiland/kernel-installer/blob/main/_images/kernel_installer.png)

### Dependencies

Will be installed when running script.
```bash
wget curl git rsync fakeroot build-essential ncurses-dev xz-utils libssl-dev bc liblz4-tool paxctl libelf-dev flex bison
```

### Notes

- This script reverts bug #1086172 [Enable more ZRAM compression options by default](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1086172)
  - Sets default compression to zstd, and enables support for the rest of the algorithms
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
If called without arguments, installs stable kernel using /opt/linux

--help                 |-h   display this help and exit
--kernel               |-k   kernel version of choice
--stable               |-s   stable kernel version 6.15.6
--mainline             |-m   mainline kernel version 6.16-rc6
--longterm             |-l   longterm kernel version 6.12.38
--dir                  |-d   install directory
--kexec                |-x   load new kernel without reboot
--config               |-c   set configuration target
--verbose              |-v   increase verbosity
--get-verified-tarball |-gvt cryptographically verify kernel tarball
--nproc                |-n   set the number of processing units to use
--enable-debug-info    |-edi enable debug info
--lowlatency           |-low convert generic config to lowlatency
--list-installed       |-li  list installed kernels
--default-compression  |-cp  select default compression algorithm
--changelog            |-cl  view changelog for kernel version
--update               |-upd check for script update
--uninstall            |-u   uninstall kernel (use with -k option)
```

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

```bash
config          - Update current config utilising a line-oriented program
nconfig         - Update current config utilising a ncurses menu based program
menuconfig      - Update current config utilising a menu based program
xconfig         - Update current config utilising a QT based front-end
gconfig         - Update current config utilising a GTK based front-end
oldconfig       - Update current config utilising a provided .config as base
localmodconfig  - Update current config disabling modules not loaded
localyesconfig  - Update current config converting local mods to core
silentoldconfig - Same as oldconfig, but quietly, additionally update deps
defconfig       - New config with default from ARCH supplied defconfig
savedefconfig   - Save current config as ./defconfig (minimal config)
allnoconfig     - New config where all options are answered with no
allyesconfig    - New config where all options are accepted with yes
allmodconfig    - New config selecting modules when possible
alldefconfig    - New config with all symbols set to default
randconfig      - New config with random answer to all options
listnewconfig   - List new options
olddefconfig    - Same as silentoldconfig but sets new symbols to their default value
kvmconfig       - Enable additional options for guest kernel support
tinyconfig      - Configure the tiniest possible kernel
```

To use --get-verified-tarball:
```bash
./kernel_installer.sh --get-verified-tarball
```
 - [Linux kernel releases PGP signatures](https://www.kernel.org/category/signatures.html)
 - Source script [get-verified-tarball](https://git.kernel.org/pub/scm/linux/kernel/git/mricon/korg-helpers.git/tree/get-verified-tarball)
 - Installing dependencies `gnupg2` and `gpgv2` if not installed

Used together:
```bash
./kernel_installer.sh --stable --config menuconfig --kexec --dir /path/to/dir --get-verified-tarball
```

Watch install log:
```bash
tail -f ./kernel_installer.log
```

- installation log in kernel_installer.log
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

## Uninstall kernel

To uninstall previously installed kernel:
```bash
./kernel_installer.sh --uninstall --kernel 5.17.7
```

- You will be prompted with a yes/no answer

## Testing

Tested and working on: Debian 12

- See [kernel_installer.log](https://raw.githubusercontent.com/tmiland/kernel-installer/main/log/kernel_installer.log)

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

[![MIT License Image](https://upload.wikimedia.org/wikipedia/commons/thumb/0/0c/MIT_logo.svg/220px-MIT_logo.svg.png)](https://github.com/tmiland/kernel-installer/blob/master/LICENSE)

[MIT License](https://github.com/tmiland/kernel-installer/blob/master/LICENSE)
