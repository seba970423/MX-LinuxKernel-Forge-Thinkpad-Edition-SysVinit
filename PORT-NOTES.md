# Debian source migration — revision 04

The source backend now uses Debian `linux-source` and the same-version
`linux-config` package, downloaded through APT. This replaces the previous
CachyOS recipe/patch/prepare backend completely.

## Reason and scope

The T590 booted the previous custom `7.3.0-4-seba-rt-bore` kernel, but subsequent
use showed input and desktop instability. The user reports that the stock
`6.12.107+deb13-amd64` kernel behaves normally. The supplied log spans multiple
boots and includes i915 atomic-update messages and RMI input messages; it does
not establish one fault responsible for every symptom. This change follows the
user's decision to use Debian's kernel foundation rather than diagnose or
retain the previous patch stack.

Runtime selection is Debian 13 / Linux 6.12 or Debian 12 / Linux 6.1, using the
APT candidate for the base release's series. Source and config must have the
same exact version and verified SHA256. No distribution upgrade, repository
addition, installed-kernel removal or init-system change is part of the build.

The hardware allowlist and optional feature choices remain. The deliberate
profile changes are Debian CPU targeting and preservation of Debian's disabled
hardware/transport states, with standard non-RT preemption. Debian's private
certificate paths are adjusted for a local build. Source/config packages and
provenance remain available after optional build cleanup.

## Verification

- Shell syntax and ShellCheck warning checks (existing `SC2034`/`SC2174`
  exclusions retained).
- Full hardware/profile, prompt, tuning, package, cleanup and progress suite.
- Genuine fixture Debian source/config packages exercise production selection,
  exact source/config version matching, package hashes, correct standard-flavour
  choice, naming, compiler environment and failures before extraction.
- Debian `linux-source-6.12` and `linux-config-6.12`, **6.12.107-1**, obtained from
  the Debian archive. The production preparation/configuration flow ran against
  that actual source and the standard amd64 configuration with GCC 13.3.
- Real profile normalization and validation with 1000 Hz, autogroup enabled,
  NVMe Fabrics/Target removed, THP unchanged and DWARF compression declined.
  i915, touchpad transports, CPU targeting and preemption remained identical to
  the original Debian settings; BTF and DWARF settings were retained.
- Actual `prepare` and `modules_prepare` targets passed with that configuration.
- Built an actual minimal Linux 6.12.107 test kernel and produced native image,
  headers and `linux-libc-dev` packages. The final production packaging path
  preserved the validated configuration byte for byte, used release
  `6.12.107-forge-debian-smoke`, and selected only its matching image/headers
  for installation. No generated package was installed. This is a packaging
  smoke test, not a build of the full ThinkPad hardware configuration.

Linux 6.12's `kernelrelease` reads generated `include/config/auto.conf` for the
local suffix. The builder therefore runs `syncconfig` before computing release
and package identity, and rejects any configuration drift at that step.
A regression test checks the synchronization order.

## Limits

Validation here runs in an Ubuntu 24.04 tool environment; the production host
gate remains MX/Debian only. No kernel is installed or booted in that test
environment. The full ThinkPad configuration needs compilation and boot testing
on the user's T590. The Debian 12 / Linux 6.1 selection is covered by unit tests,
without a complete 6.1 kernel build. Custom builds require rebuilding for later
security updates; retain a working stock Debian kernel for fallback.

The separate old-kernel uninstaller is an independent user deliverable and is
not part of this repository.
