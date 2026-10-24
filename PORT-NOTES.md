# MX/Debian port r01 — validation notes

24 October 2026.

## Baseline

Original ThinkPad builder:
`seba970423/CachyOSKernel-Forge-Thinkpad-Edition`
revision `c2915b1294ebdec1f2684c96c672698d6370caf1`.

The complete `profiles/` tree, including the T590 reference configuration, is
byte-identical to that revision. Hardware policy, feature choices and their
regression coverage are retained. The optional DWARF probe also receives a small
Bash local-variable initialization correction needed for reliable use.

Current kernel recipe snapshot inspected:
`CachyOS/linux-cachyos` revision
`523baf9cc1e37b7f8079064447f1418702c45154`.

## Passed

- Complete shell syntax and regression suite, including the 104 protected
  profile settings and the 46 audited platform-driver removals.
- ShellCheck at warning severity for entrypoints and libraries; externally used
  globals and the inherited cleanup mkdir-mode advisory are excluded.
- Metadata evaluation of all ten currently discovered kernel recipes.
- Actual RT-BORE `cachyos-7.3.0-4` source archive checksum and detached signature
  verification against the recipe's pinned signing fingerprint.
- Configuration normalization, universal ThinkPad profile application, policy
  validation and DWARF/BTF preservation on the real patched RT-BORE source tree.
  This used GCC 13.3, Rust 1.98.0, bindgen 0.71.1, libclang/LLVM 19 and pahole 1.30.
- Native Debian image/headers collection and exclusion of generated libc/debug
  packages using genuine tiny `.deb` test artifacts.
- Package tamper rejection and guarded APT transactions.
- MX SysVinit/Debian host handling with fixtures; Arch and Ubuntu host rejection.
- Private LLVM release selection, checksum verification, extraction and compiler
  selection using small local fixtures. The selector was also checked against
  current official LLVM 22.1.8 release metadata and its published asset digest.
- Official private Rust installation, including its version-pinned source tree.

## Scope of the real-source test

The source/configuration smoke test ran in a Linux build environment with
locally available build tools. It was not a boot test on the T590, nor an actual
MX SysVinit installation. A full kernel `.deb` compilation and installation have
not been performed here. Debian package generation/installation control flow
is covered by the fixture tests; the target machine still needs its first full
build and boot test.

The full official LLVM release archive was not downloaded for this test; its
native download/extraction path was exercised with checksum-verified fixtures.
Runtime compatibility of an official binary is checked on the build host before
it is accepted. Both entrypoints use the same source and configuration path.

## Dependency behavior that matters on stable

Generic minimum tool versions alone do not satisfy every native profile.
The inspected source makes native CPU optimization depend on newer Rust APX
feature handling. The resolver therefore also honors the Rust compiler level
recorded by a Rust-enabled baseline. It does not disable Rust or native tuning
as a workaround.

A Rust-enabled Clang LTO build needs matching Clang/rustc LLVM major versions.
Enabled APT repositories are preferred. A missing suite can be supplied by an
explicitly accepted official LLVM binary download into the build directory;
the release API's SHA256 is mandatory and checked before extraction. Download
size is displayed first. The current LLVM archive is substantial, so GCC flavors
such as RT-BORE generally need fewer toolchain downloads on stable.

The tool adds no APT sources, changes no init system, and retains the selected
compiler environment for installation hooks and future external-module builds.
