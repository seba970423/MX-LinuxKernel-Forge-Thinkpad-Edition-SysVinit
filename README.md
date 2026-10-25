# KernelForge ThinkPad — MX/Debian Edition

Build a custom **Debian kernel** for **64-bit MX Linux and Debian**, including
**SysVinit**. Sources and the starting configuration come from matching Debian
`linux-source` and `linux-config` packages. Packages integrate with
**initramfs-tools, DKMS and GRUB**.

This edition now follows Debian's standard kernel. The previous CachyOS
source provider, RT/BORE flavours, patches and private LLVM/Rust downloads have
been removed. The change follows desktop/input instability reported with the
previous build and successful use of the stock Debian 6.12.107 kernel.

## Run

Clone and run as your regular user:

```bash
git clone https://github.com/seba970423/MX-LinuxKernel-Forge-Thinkpad-Edition-SysVinit.git
cd MX-LinuxKernel-Forge-Thinkpad-Edition-SysVinit
./builder.sh
```

Launchers and tests are executable in Git; a fresh clone needs no manual
`chmod`. Missing build dependencies are offered through APT. The builder asks
for sudo to refresh package lists, install dependencies or install the finished kernel. Compilation
and installation are separate choices. Reboot manually when ready.

Prepare and validate without compiling or installing kernel packages:

```bash
./builder-dry-run.sh
```

The dry run downloads source/config packages and runs configuration checks.
It can offer missing build dependencies, but does not install a kernel.
Common dependencies can also be installed using `./install-deps.sh`.

## Debian source and configuration

- Debian 13 / MX 25: **Linux 6.12**.
- Debian 12 / MX 23: **Linux 6.1** (unit-tested selection; see test limits below).
- The Debian base is detected from `/etc/debian_version`, independently of MX's
  own release number. Unknown Debian bases fail explicitly.
- The source uses the APT candidate for that series, including available Debian
  security updates. The matching configuration package must have the **same
  exact package version**. Backports candidates are rejected.
- `apt-get download` retrieves both packages as the build user. APT verifies its
  repository metadata and package hashes; the builder also checks both SHA256
  values and package names, versions and architectures before extracting.
- Source/config packages stay inside the build workspace. No `deb-src` entry,
  new repository, system source-package installation or kernel recipe is needed.
- The starting configuration is **`config.amd64_none_amd64.xz`**: Debian's
  standard amd64 flavour, with generic CPU settings and non-RT preemption.
  Cloud and RT configurations are not selected. The currently running kernel's
  configuration is never used as a source.
- The builder uses distribution **GCC and binutils**, checks source tool
  requirements, and checks pahole for BTF. Inherited LLVM/native-build overrides
  are cleared. No private compiler, Rust, Cargo or bindgen download is offered.

APT package lists are refreshed before source selection. If the requested
source/config version is unavailable, the run stops with the APT diagnostics.
It does not enable testing, unstable or another distribution's repositories.

## ThinkPad profile and choices

The universal ThinkPad hardware list is retained. Host inventory is for
information and CPU-vendor-specific prompts; it never prunes another ThinkPad's
hardware. Drivers retain their exact Debian baseline states, including disabled
or version-absent drivers. This preserves Debian's input transport choices.

The profile keeps tickless idle and its existing removal list for other
manufacturers' motherboard/platform interfaces. It retains the KVM, applicable
TDX/SEV, NVMe Fabrics/Target, tick-frequency, autogrouping, THP and DWARF Zstandard
choices. Unsupported TDX/SEV settings do not produce a prompt. Enter keeps the
Debian baseline for optional tuning; `upstream` in the frequency prompt means
the selected Debian kernel's default.

CachyOS-only `CONFIG_X86_NATIVE_CPU` tuning is replaced by Debian's CPU target.
The original and resolved configuration are compared to ensure that **Debian
preemption, i915 graphics and touchpad/TrackPoint transport settings** survive
unchanged. RT preemption is rejected. Toolchain normalization cannot silently
drop BTF or other checked baseline features.

The default release suffix is **`mx-thinkpad-debian`**. You can choose another
Debian-compatible name. The result is a distinct kernel release, for example
`6.12.107-mx-thinkpad-debian`; the stock kernel's files are not overwritten.
Debian's unavailable private certificate paths are replaced with a generated
local module-signing key and empty extra trust/revocation certificate lists.
Secure Boot signing/enrollment is not automated.

## Build, install and progress

The validated source tree is built using `make bindeb-pkg`. Generated Kconfig
metadata is synchronized before querying the release name. The configuration
must remain identical during preparation and compilation.

Long operations display a short stage and an elapsed-time update every
**30 seconds**, while detailed output goes to the displayed logs:

```text
==> Build still running... 0m 30s elapsed
==> Build still running... 1m 00s elapsed
```

Prompts, APT transaction plans and summaries remain visible. Failures show a
bounded diagnostic excerpt and the complete log path. Ctrl+C interrupts the
command and status reporter. Optional settings:

```bash
KERNELFORGE_JOBS=4 ./builder.sh
KERNELFORGE_PROGRESS_INTERVAL=30 ./builder.sh
```

All produced `.deb` files are retained. Installation selects exactly one image
and its matching headers from the current build, checks their saved hashes,
and supplies the distribution compiler environment to DKMS hooks. Generated
`linux-libc-dev` and debug packages are excluded from installation.

APT dependency installation is simulated first and uses `--no-remove`.
Kernel installation also uses `--no-remove`. Hooks handle modules/DKMS; the
builder verifies the boot image, generates/refreshes its initramfs and runs
`update-grub`. No service-manager calls or init-system changes are made.
Existing kernels and their packages are retained. Choose the desired kernel
from GRUB when testing. Rebuild this custom kernel when new Debian source
updates are available; stock kernel packages continue their own APT updates.

## Retained files and cleanup

Workspaces are under `/var/tmp/kernelforge-mx-build.*`. Each build keeps:

- `downloads/`: original authenticated Debian source/config `.deb` packages;
- `config` and `.kernelforge-source-info`: original configuration and provenance;
- `.kernelforge-source-version`: the exact Debian source version;
- `.kernelforge-toolchain-env`: distribution compiler environment;
- `.kernelforge-prepare.log`, `.kernelforge-config.log`, `.kernelforge-build.log`;
- `.kernelforge-validated.config`: the configuration compiled;
- `.kernelforge-kernelrelease`, package manifest and package SHA256 checks;
- `packages/`: generated artifacts outside disposable build directories.

Optional post-install cleanup checks ownership, paths, symlinks and mounts,
saves final/baseline configurations and removes generated source/build and
temporary directories. Downloads, packages, metadata, logs and saved configs
remain. See [POST-INSTALL-CLEANUP.md](POST-INSTALL-CLEANUP.md).

## Validation and provenance

```bash
bash tests/run-tests.sh
```

Tests cover hardware/profile protection, supported prompts, tuning, source and
configuration version/hash failures, real tiny Debian packages, exact install
selection, APT guards, cleanup and terminal progress/cancellation.
See [PORT-NOTES.md](PORT-NOTES.md) for real-source validation and test limits.
A rebuilt configuration still needs a boot test on the target ThinkPad.

Derived from [KernelForge ThinkPad Edition](https://github.com/seba970423/CachyOSKernel-Forge-Thinkpad-Edition)
revision `c2915b1294ebdec1f2684c96c672698d6370caf1`.
The original GPL-3.0 license is retained in `LICENSE`.
The reference config is now Debian `linux-config-6.12` **6.12.107-1 amd64**;
it is used for regression tests, not as the runtime source baseline.

Build reference: [Debian Linux Kernel Handbook](https://kernel-team.pages.debian.net/kernel-handbook/ch-common-tasks.html).
