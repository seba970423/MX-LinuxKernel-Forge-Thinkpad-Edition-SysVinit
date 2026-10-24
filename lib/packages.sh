#!/usr/bin/env bash

source "$(dirname -- "${BASH_SOURCE[0]}")/progress.sh"

compile_selected_kernel() {
    local checkout="$1" variant="$2" tree="$3"
    local package_dir="$checkout/$variant" log_file="$checkout/$variant/.kernelforge-build.log"
    local manifest="$package_dir/.kernelforge-built-packages" package name architecture release
    local before after jobs="${KERNELFORGE_JOBS:-$(nproc)}" start_seconds=$SECONDS
    [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { echo 'ERROR: Invalid KERNELFORGE_JOBS.' >&2; return 1; }
    source "$package_dir/.kernelforge-recipe"
    release="$(make -s -C "$tree" kernelrelease)" || return 1
    [[ "$release" =~ ^[a-zA-Z0-9.+-]+$ && ${#release} -le 64 ]] || {
        echo 'ERROR: Kernel release is unsuitable for Debian packaging.' >&2; return 1;
    }
    printf '%s\n' "$release" >"$package_dir/.kernelforge-kernelrelease"
    before="$(sha256sum "$tree/.config")"
    cp "$tree/.config" "$package_dir/.kernelforge-validated.config"
    printf '==> Building Debian packages with %s jobs.\n' "$jobs"
    printf '==> Kernel release: %s\n==> Build log: %s\n' "$release" "$log_file"
    printf '==> Elapsed-time updates every %s seconds; compiler output is saved in the log.\n' \
        "${KERNELFORGE_PROGRESS_INTERVAL:-30}"
    # Use the final, validated tree directly. No source extraction, upstream
    # prepare(), or clean target runs again here.
    : >"$log_file"
    if ! kernelforge_run_logged Build "$log_file" make -C "$tree" -j"$jobs" bindeb-pkg \
        KDEB_PKGVERSION="$KF_PACKAGE_VERSION+mx1" \
        KDEB_SOURCENAME=kernelforge-thinkpad; then
        printf 'ERROR: Debian kernel build did not complete. Log: %s\n' "$log_file" >&2
        return 1
    fi
    after="$(sha256sum "$tree/.config")"
    [[ "$before" == "$after" ]] || {
        echo 'ERROR: The validated configuration changed during compilation; installation refused.' >&2; return 1;
    }
    mkdir -p "$package_dir/packages"
    : >"$manifest"
    : >"$package_dir/.kernelforge-package-checksums"
    local image_count=0 header_count=0
    for package in "$package_dir/src/"*.deb; do
        [[ -f "$package" ]] || continue
        name="$(dpkg-deb -f "$package" Package)" || return 1
        architecture="$(dpkg-deb -f "$package" Architecture)" || return 1
        [[ "$architecture" == amd64 ]] || { echo 'ERROR: Unexpected package architecture.' >&2; return 1; }
        cp -p -- "$package" "$package_dir/packages/" || return 1
        package="$package_dir/packages/${package##*/}"
        case "$name" in
            "linux-image-$release") ((image_count+=1)) ;;
            "linux-headers-$release") ((header_count+=1)) ;;
            *) continue ;; # Keep debug/libc artifacts; install only this image + headers.
        esac
        printf '%s\n' "$package" >>"$manifest"
        sha256sum "$package" >>"$package_dir/.kernelforge-package-checksums"
    done
    [[ "$image_count" == 1 && "$header_count" == 1 ]] || {
        echo 'ERROR: Expected exactly one Debian kernel image and headers package.' >&2; return 1;
    }
    printf '==> Debian package build completed in %dm %02ds.\n' \
        "$(((SECONDS-start_seconds)/60))" "$(((SECONDS-start_seconds)%60))"
    printf '==> Installable packages:\n'
    cat "$manifest"
    du -sh -- "$package_dir/src" "$package_dir/packages" "$TMPDIR" >"$package_dir/.kernelforge-space-report.txt"
}

install_built_kernel() {
    local checkout="$1" variant="$2" package release name image=0 headers=0
    local package_dir="$checkout/$variant"
    local -a packages=() install_environment=("PATH=$PATH")
    [[ -s "$package_dir/.kernelforge-built-packages" && -s "$package_dir/.kernelforge-kernelrelease" &&
       -s "$package_dir/.kernelforge-package-checksums" ]] || {
        echo 'ERROR: Missing build/package manifest.' >&2; return 1;
    }
    release="$(<"$package_dir/.kernelforge-kernelrelease")"
    [[ "$release" =~ ^[a-zA-Z0-9.+-]+$ ]] || return 1
    sha256sum --check "$package_dir/.kernelforge-package-checksums" || return 1
    while IFS= read -r package; do
        [[ "$package" == "$package_dir/packages/"*.deb && -f "$package" && ! -L "$package" ]] || return 1
        name="$(dpkg-deb -f "$package" Package)" || return 1
        case "$name" in
            "linux-image-$release") ((image+=1)) ;;
            "linux-headers-$release") ((headers+=1)) ;;
            *) echo 'ERROR: Package manifest contains an unrelated package.' >&2; return 1 ;;
        esac
        packages+=("$package")
    done <"$package_dir/.kernelforge-built-packages"
    [[ "$image" == 1 && "$headers" == 1 ]] || return 1
    command -v update-grub >/dev/null || {
        echo 'ERROR: update-grub is missing. This edition integrates with MX/Debian GRUB.' >&2; return 1;
    }
    if ! command -v update-initramfs >/dev/null; then mx_apt_install initramfs-tools || return 1; fi
    # DKMS hooks must see the compiler used for the kernel even when sudo's
    # secure_path would hide a private LLVM/Rust toolchain.
    local variable
    for variable in BINDGEN LIBCLANG_PATH RUST_LIB_SRC CARGO_HOME RUSTUP_HOME RUSTUP_TOOLCHAIN LLVM LLVM_IAS; do
        if [[ -v "$variable" ]]; then install_environment+=("$variable=${!variable}"); fi
    done
    mx_as_root /usr/bin/env "${install_environment[@]}" apt-get --no-remove --reinstall install "${packages[@]}" || return 1
    [[ -f "/boot/vmlinuz-$release" ]] || { echo 'ERROR: Installed boot image is missing.' >&2; return 1; }
    if [[ -f "/boot/initrd.img-$release" ]]; then
        mx_as_root update-initramfs -u -k "$release" || return 1
    else
        mx_as_root update-initramfs -c -k "$release" || return 1
    fi
    mx_as_root update-grub || return 1
    [[ -s "/boot/initrd.img-$release" ]] || { echo 'ERROR: initramfs generation failed.' >&2; return 1; }
    printf '==> Installed %s and refreshed its initramfs and GRUB menu.\n' "$release"
    printf '==> Reboot manually when ready.\n'
}
