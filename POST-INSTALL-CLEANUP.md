# Optional post-install build cleanup

After a successful kernel installation, the interactive builder can remove its
generated source/build directories and compiler temporary files. The default
is to keep them. Noninteractive runs skip cleanup.

The cleanup checks the builder's ownership marker, path shape and current
owner, rejects symlinks and mounted descendants, verifies the package manifest,
and copies final/baseline configurations outside the source tree before
removing anything. It removes only `src/`, `pkg/` if present, and the workspace's
`tmp/` directory.

It retains the Debian source/config downloads, generated kernel packages,
build logs, source provenance and version, compiler environment, manifests,
checksums and saved configurations. A refusal or cleanup failure leaves the
successful kernel installation intact.

This cleanup does not uninstall kernels or build dependencies. The separate
uninstaller for the superseded kernel is not included in this project.
