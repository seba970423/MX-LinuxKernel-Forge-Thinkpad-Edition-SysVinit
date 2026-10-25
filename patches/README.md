# Optional Debian RT and BORE inputs

These inputs are used only after an explicit feature selection. Standard builds
apply neither. Patch files retain their original authorship and commit headers.
They are Linux kernel patches; GPL-2.0 terms are provided in `COPYING.GPL-2.0`.

## Debian RT series

The archives contain only `debian-rt/series` and the original regular patch files
from Debian's `debian/patches-rt` directory. No patch has been rewritten. Tar
ownership/time metadata is normalized; file permissions are 0644. All listed
patches are applied in their original order, including i915 fixes and the RT15
localversion. The builder uses the same-version Debian RT configuration.

| Debian source | Original packaging archive SHA256 | Bundled input |
| --- | --- | --- |
| `6.12.107-1` | `d8c003ecac7c54f59c69dc61258f93d937dce90e70f53bb5a34dd58db13028ed` | `debian-6.12.107-1-rt.tar.xz`, 43 patches |
| `6.12.111-1` | `e0146c63a70014f23141fe3e4e830e8a5b2627427d449f3e5415d930016be297` | `debian-6.12.111-113-rt.tar.xz`, 42 patches |
| `6.12.113-1` | `e2d62aaf6d3771dce7116feea9c419b47d6bbf8cb957153896fbbc276f2a54f9` | same 42-patch input; RT files are byte-identical to `6.12.111-1` |

Original archive URLs:

- https://deb.debian.org/debian/pool/main/l/linux/linux_6.12.107-1.debian.tar.xz
- https://security.debian.org/pool/main/l/linux/linux_6.12.111-1.debian.tar.xz
- https://security.debian.org/pool/main/l/linux/linux_6.12.113-1.debian.tar.xz

Bundled SHA256 values:

```text
5438f4cc417e318580a65473bc5a317c4267ac5839f9e73fda98c5986d72b6c0  debian-6.12.107-1-rt.tar.xz
7d96e5e2dee684a5096cb79d8897d9e9f3395c28e12d24373711ad616d33436b  debian-6.12.111-113-rt.tar.xz
```

Exact source versions select the input. An unknown version stops RT selection
before downloading/extracting a kernel. Updating this mapping requires reviewing
the new Debian RT series and configuration and repeating source/build checks.

## BORE

Upstream: https://github.com/firelzrd/bore-scheduler

- Commit: `1e2f57ad74e8b8b1d315c03b7abd8d74e40448b4`
- Original path: `patches/stable/0001-linux6.12.37-bore-7.0.0.patch`
- Git blob: `1e91c3d6c875b5caaf7d9a00af8ec87ed2494c3d`
- Bundled path: `linux-6.12-bore-7.0.0.patch`
- SHA256: `4362579319376f47d0c38e2aa30347082d73e6f122d32442def194462243e2c6`

The bundled file preserves upstream bytes, including whitespace. When both
features are selected, Debian RT is applied first, then BORE. Every patch has a
dry run before application, with `--batch --forward --fuzz=0`; line offsets are
allowed, incomplete/reversed/fuzzy application is refused. A source update can
therefore require a reviewed patch update instead of silently dropping BORE.

Patch identities and selections are saved in `.kernelforge-flavour` and source
metadata. Copies of selected inputs remain in the workspace downloads after
optional build cleanup. No CachyOS recipes, patches or private tools are used.
