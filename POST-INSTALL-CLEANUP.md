# Optional post-install cleanup

After successful installation, the builder offers to remove generated `src/`,
`pkg/` and compiler temporary files inside its own `/var/tmp/kernelforge-mx-build.*`
workspace. Declining or running without a terminal keeps everything.

Before deleting anything, cleanup checks the workspace marker and ownership,
canonical paths, symlinks, package-manifest paths and mounted filesystems. It
copies and verifies the final `.config` and nearby baseline/backup configurations
to `artifacts/kernel-configs/`. It refuses suspicious paths rather than guessing.

The following remain available:

- Debian image/headers and any other generated `.deb` files in `packages/`;
- build and preparation logs, manifests and checksums;
- upstream recipes, patches and signed source archives;
- selected toolchain environment and any private LLVM/Rust/bindgen toolchain;
- archived final and baseline configurations.

Cleanup operates on the build workspace. Installed kernels, firmware, GRUB,
initramfs files, APT caches and the user's other source trees are not cleanup
targets. The cleanup implementation is shared with the original ThinkPad
project and covered by symlink, mountpoint and package-preservation tests.
