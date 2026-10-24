# KernelForge ThinkPad — MX/Debian Edition

A separate custom kernel builder for **64-bit MX Linux and Debian**, including
**SysVinit** installations. It produces native Debian kernel image and headers
packages and integrates with **initramfs-tools and GRUB**.

The universal ThinkPad hardware profile, feature choices and validation rules
come from [KernelForge ThinkPad Edition](https://github.com/seba970423/CachyOSKernel-Forge-Thinkpad-Edition).
The complete `profiles/` directory is retained byte for byte. Native CPU tuning,
tickless idle, virtualization/NVMe choices, tick-frequency selection, optional
autogrouping, THP and DWARF Zstandard compression retain their existing behavior.
Support covers the ThinkPad family; the build host's inventory never prunes
other ThinkPad hardware. Run on the target ThinkPad for native CPU optimization.

## Run

Clone the project and run **as your regular user**:

```bash
git clone https://github.com/seba970423/MX-LinuxKernel-Forge-Thinkpad-Edition-SysVinit.git
cd MX-LinuxKernel-Forge-Thinkpad-Edition-SysVinit
./builder.sh
```

The launchers, standalone preparation helpers and test scripts have executable
permissions recorded in Git. A fresh clone needs no manual `chmod` step.
An extracted release archive can be used the same way.

The builder offers to install missing Debian development packages through APT.
It requests sudo only for dependencies and optional kernel installation. You
select the kernel flavor, optional name and existing profile choices; compilation
and installation are separate opt-in steps. Rebooting is manual.

Prepare sources and validate the configuration without compiling a kernel:

```bash
./builder-dry-run.sh
```

This downloads source archives and builds the preparation tools and Rust
objects required by the selected source. It can install build dependencies
after confirmation. It does not build the complete kernel image or Debian
kernel packages, and it does not install a kernel.

Install the common build dependencies separately if desired:

```bash
./install-deps.sh
```

Normal operation targets current MX/Debian stable. Older releases can work when
their enabled repositories supply the selected source's compiler and pahole
requirements. The builder reports unavailable requirements before compilation;
it never enables testing/unstable or adds an external APT repository.

## MX/Debian dependency handling

- Native APT package names replace the Arch dependency list.
- Common dependencies include `libdw-dev`, required as `libdw-dev:native` by
  the kernel's Debian packaging metadata, alongside `libelf-dev` and `libssl-dev`.
- APT displays a simulated transaction first. Both simulation and installation
  use `--no-remove`; dependency installation uses `--no-install-recommends`.
- GCC, binutils, LLVM, Rust and bindgen minimum versions are read from the actual
  extracted kernel's `scripts/min-tool-version.sh`.
- BTF builds also check the source's documented minimum pahole version.
- LLVM builds select a complete versioned Debian LLVM suite and matching
  libclang development files. The same environment is used by source preparation,
  every configuration probe, and the final Debian package build.
- For native CPU optimization with Rust enabled, the Rust compiler level recorded
  by the selected upstream config is also required. This accounts for native
  CPU constraints such as `RUSTC_HAS_APXF`, beyond the kernel's generic minimum.
  Rust-enabled LTO additionally requires the same LLVM major version in Clang
  and rustc. If enabled APT repositories cannot supply that suite, the builder
  offers an official private LLVM release archive, verified against its published
  GitHub asset SHA256. The download size is displayed before confirmation.
  Existing custom LLVM installations can also be selected explicitly.
- A suitable installed Rust compiler and its matching sources are reused. The
  builder can install Debian's Rust packages when adequate. If they are too old,
  it offers a private, version-pinned official Rust toolchain under the build
  directory, with `rust-src` and `rustfmt`, without changing the user's global Rust default.
- Bindgen must pass a real forward-declaration/definition check with the final
  selected libclang, after any Rust-LTO LLVM adjustment. Libclang 22 exposes a
  known defect in unpatched bindgen versions older than 0.72.1: real structure
  fields can become opaque `_address` placeholders. A distro version with the
  fix backported is accepted when the generated member is correct. Otherwise,
  a compatible APT version is preferred, or bindgen-cli is built privately with
  Cargo, `--locked`, and a pinned version satisfying both the source minimum and
  the libclang compatibility requirement. The resulting binary is tested again
  and retained in the shared preparation/build/install environment.
- Missing or incompatible tools stop the run. Losing Rust, BTF, CFI or the selected LTO mode during
  configuration is an error; the builder does not disable them as a workaround.

For a pre-existing custom LLVM installation, optionally set
`KERNELFORGE_LLVM_ROOT=/absolute/path/to/llvm` (containing `bin/` and `lib/`).
To reduce compile parallelism, set `KERNELFORGE_JOBS`, for example:

```bash
KERNELFORGE_JOBS=4 ./builder.sh
```

## Sources and kernel flavors

The kernel sources, patches, flavor definitions and baseline configs still come
from the [CachyOS kernel recipe repository](https://github.com/CachyOS/linux-cachyos).
That is the source provider. This edition has no Arch/CachyOS host, package
installation or bootloader integration path, and requires neither `pacman` nor
`makepkg`.

The port reads the trusted upstream recipe's source metadata, verifies every
upstream-declared checksum, verifies detached archive signatures against the
recipe's full pinned PGP fingerprints, and runs only its source `prepare()`
function. It never runs upstream Arch build/package/install functions.
Unknown source formats or changed recipe contracts fail explicitly.
Upstream source checksum entries marked `SKIP` retain their upstream meaning;
the signed kernel archive must still pass the pinned-key signature check.

The default release suffix is `mx-thinkpad`, `mx-thinkpad-rt-bore`, etc. Custom
suffixes use Debian-compatible lowercase letters, digits, `.`, `+` and `-`.
The builder never changes `uname` for the running kernel or an installed stock
kernel. It prepares the new release in a fresh work directory.

## Packages and SysVinit

The already validated source tree is built with the kernel's native
`bindeb-pkg` target. Its source preparation is not repeated. The validated
configuration is checked again after compilation.

All generated `.deb` files are retained. Automatic installation selects exactly
one `linux-image-<release>` and one `linux-headers-<release>` from this run.
Generated `linux-libc-dev` and debug packages are retained for inspection and
excluded from that install transaction. Package hashes are checked before APT
receives the exact local file paths.

Debian package hooks handle module/DKMS integration. The initial installation
passes the selected compiler environment through sudo to those hooks. If a
private compiler was required, keep that toolchain available for future external
module builds; its environment can be restored from `.kernelforge-toolchain-env`. The builder verifies the
installed boot image, creates or refreshes its initramfs with `update-initramfs`,
and runs `update-grub`. It makes no service-manager calls and neither installs
nor switches init systems. Existing kernel packages are kept.

GRUB is the supported bootloader integration for this edition. `update-grub`
must exist before installation; no bootloader is installed or replaced.
Secure Boot signing/enrollment is not automated. A locally built unsigned kernel
needs the corresponding firmware/signing setup before it can boot under Secure
Boot enforcement.

## Logs, artifacts and cleanup

Builds live under `/var/tmp/kernelforge-mx-build.*`; compiler temporary files
also live there. Each selected flavor keeps:

- `.kernelforge-prepare.log`: source verification and preparation output;
- `.kernelforge-build.log`: streamed compiler/package output;
- `.kernelforge-toolchain-env`: the exact selected tool environment;
- `.kernelforge-validated.config`: the configuration sent to compilation;
- `.kernelforge-built-packages`: the exact image/headers install manifest;
- `.kernelforge-package-checksums`: hashes checked before installation;
- `packages/`: generated Debian artifacts, outside disposable source directories.

The small bindgen compatibility header, generated bindings and diagnostics are
retained under `toolchain/bindgen-probe/` for troubleshooting.

The optional existing post-install cleanup retains packages, source downloads,
logs, patches, private toolchains and copies of final/baseline configurations.
It checks ownership, symlinks and mounts before removing generated source/build
and compiler temporary directories. See `POST-INSTALL-CLEANUP.md`.

## Validation

```bash
bash tests/run-tests.sh
```

The suite retains the source project's hardware/profile, prompt, tuning,
configuration-validation and cleanup coverage. MX/Debian tests additionally
exercise native recipe evaluation, source checksum failures, pinned-signature
selection, toolchain feature loss, genuine tiny `.deb` artifacts, exact package
selection, tamper rejection and APT transaction guards.

See `PORT-NOTES.md` for the tested revision and actual smoke-test limits. A
passing test suite does not substitute for compiling and boot-testing the new
kernel on the target ThinkPad. Keep a working distribution kernel available.

## Provenance

Derived from ThinkPad Edition revision
`c2915b1294ebdec1f2684c96c672698d6370caf1` (24 October 2026 snapshot).
The original GPL-3.0 license is retained in `LICENSE`.

Build references:
[Debian kernel compilation](https://www.debian.org/doc/manuals/debian-handbook/sect.kernel-compilation.en.html),
[kernel tool requirements](https://kernel.org/doc/html/latest/process/changes.html).
