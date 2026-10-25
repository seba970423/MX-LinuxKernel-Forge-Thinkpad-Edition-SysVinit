# Debian sources and optional RT/BORE — revision 05

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
retain the previous CachyOS recipe stack. PREEMPT_RT and BORE are now explicit,
independent user choices on the Debian source foundation; their addition does
not establish a cause or cure for the earlier instability.

Runtime selection is Debian 13 / Linux 6.12 or Debian 12 / Linux 6.1, using the
APT candidate for the base release's series. Source and config must have the
same exact version and verified SHA256. No distribution upgrade, repository
addition, installed-kernel removal or init-system change is part of the build.

The hardware allowlist and optional feature choices remain. The deliberate
profile changes are Debian CPU targeting and preservation of Debian's disabled
hardware/transport states. Standard non-RT preemption remains the default;
selecting RT uses the same-version Debian RT baseline and full Debian RT series.
Debian's private
certificate paths are adjusted for a local build. Source/config packages and
provenance remain available after optional build cleanup.

## Optional features

Both launchers ask separately about PREEMPT_RT and BORE before preparation and
naming. Enter declines each. The resulting standard, RT, BORE and RT+BORE builds
have distinct default names and workspaces. Debian 12 / Linux 6.1 keeps its
standard build; these optional patch inputs currently target Debian 6.12 only.

RT inputs are version-mapped to Debian 6.12.107-1, 6.12.111-1 and 6.12.113-1.
The newer two releases carry byte-identical RT series. The bundled archives
preserve every original patch and its order, including the i915 fixes; a new
source version needs a reviewed mapping. BORE 7.0.0 is pinned to its upstream
commit and original file bytes. All selected inputs are checked before source
mutation, and every patch is checked/applied with zero fuzz and forward-only
operation. Provenance and licenses are documented under `patches/`.

The RT baseline must preserve the standard configuration's Intel graphics,
touchpad/TrackPoint transports and CPU target. Final validation preserves the
selected Debian flavour's full preemption settings and ThinkPad hardware states,
requires selected RT/BORE features, and rejects unselected ones. THP tuning is
not offered on RT. The source/config packages, both original configurations,
patch identities and selections remain available after build cleanup.

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

### RT/BORE validation

- Full regression suite, Bash syntax and ShellCheck warning checks passed.
- Independent prompt/default/EOF/retry tests cover all four selections; both
  actual launcher main functions retain the choices and correct default names
  through the source-preparation boundary. Missing candidates, failed APT
  refreshes and the prior candidate-parser SIGPIPE regression remain covered.
- Tests verify patch hashes, archive structure, integrity failures before
  mutation, strict native patch application, and refusal of reversed or fuzzy
  patches. All bundled RT files match the original Debian packaging byte for
  byte for each mapped source version.
- The production source-preparation and configuration flow passed for all four
  combinations on real Debian **6.12.107-1**, and for RT, BORE and RT+BORE on real
  **6.12.113-1**, using matching standard/RT configs. Checks used 1000 Hz,
  autogroup enabled, THP unchanged and DWARF compression declined; graphics,
  input transports, selected preemption, BTF and debug settings passed validation.
- With those full ThinkPad configurations, actual `prepare`, `modules_prepare`,
  `kernel/sched/`, `kernel/fork.o`, `kernel/exit.o` and `kernel/futex/waitwake.o`
  builds passed for BORE, RT and RT+BORE on **both 6.12.107-1 and 6.12.113-1**.
- The complete combined `drivers/gpu/drm/i915/i915.o` driver compiled on RT+BORE
  for both source versions. Configurations stayed byte-identical during these
  compilation checks. These are source/configuration and object-build checks,
  not a full image/package build or a hardware boot test of the new flavours.

## Limits

Validation here runs in an Ubuntu 24.04 tool environment; the production host
gate remains MX/Debian only. No kernel is installed or booted in that test
environment. Complete ThinkPad kernel-image/package builds and hardware boot
tests of the new flavours remain for the user's T590. The Debian 12 / Linux 6.1 selection is covered by unit tests,
without a complete 6.1 kernel build. The 6.12.111 RT series is bundled and
byte-verified; its full source/configuration build was not exercised separately.
Custom builds require rebuilding for later
security updates; retain a working stock Debian kernel for fallback.

The separate old-kernel uninstaller is an independent user deliverable and is
not part of this repository.
