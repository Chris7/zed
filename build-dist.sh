#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
release_tag=custom
release_repository=Chris7/zed
build_cache="${ZED_BUILD_DIST_CACHE:-$repository_root/.cache/build-dist}"
artifact_directory="$repository_root/target/build-dist"

show_help() {
    cat <<EOF
Usage: ${0##*/} [--no-upload]

Build Zed, its CLI, and a static musl remote server on Ubuntu 24.04 (glibc
2.39), package a runnable bundle, then upload the artifacts to the GitHub
'$release_tag' release in $release_repository.

Artifacts are written to $artifact_directory.

Options:
  --no-upload  Build locally without changing the GitHub release.
  -h, --help   Show this help.
EOF
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$1" >&2
        exit 1
    fi
}

prepare_source_snapshot() {
    local snapshot_directory=$1
    local files_file=$2
    local path

    while IFS= read -r -d '' path; do
        case "$path" in
            .env|.env.*|*/.env|*/.env.*|.netrc|*/.netrc|.npmrc|*/.npmrc|.pypirc|*/.pypirc|.git-credentials|*/.git-credentials|.ssh/*|*/.ssh/*|.aws/*|*/.aws/*|.gnupg/*|*/.gnupg/*|.kube/*|*/.kube/*|.docker/*|*/.docker/*|*.pem|*.p12|*.pfx|*/id_rsa*|*/id_ed25519*)
                continue
                ;;
        esac
        printf '%s\0' "$path" >> "$files_file"
    done < <(git -C "$repository_root" ls-files --cached --others --exclude-standard -z)

    (
        cd "$repository_root"
        tar --create --file=- --null --files-from="$files_file"
    ) | tar --extract --file=- --directory="$snapshot_directory"
}

container_build() {
    local uid=$1
    local gid=$2
    local rust_toolchain=$3
    local commit_sha=$4
    export DEBIAN_FRONTEND=noninteractive
    export HOME=/root
    export CARGO_HOME=/opt/cargo
    export RUSTUP_HOME=/opt/rustup
    export PATH="$CARGO_HOME/bin:$PATH"

    apt-get update
    apt-get install -y ca-certificates curl
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup-init.sh
    sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal --default-toolchain none
    rm -f /tmp/rustup-init.sh

    ./script/linux
    apt-get install -y mold
    rustup toolchain install "$rust_toolchain" --profile minimal --target x86_64-unknown-linux-musl
    setpriv --reuid="$uid" --regid="$gid" --clear-groups \
        env HOME=/cache/home CARGO_HOME=/cache/cargo RUSTUP_HOME="$RUSTUP_HOME" \
        PATH="/opt/cargo/bin:/cache/cargo/bin:$PATH" CARGO_TARGET_DIR=/cache/target \
        CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}" \
        RUSTUP_TOOLCHAIN="$rust_toolchain" ZED_COMMIT_SHA="$commit_sha" \
        /bin/bash /work/build-dist.sh --package-as-user
}

package_build() {
    local artifact_dir=${ZED_BUILD_DIST_ARTIFACT_DIR:-/out}
    local build_dir=${CARGO_TARGET_DIR:-/cache/target}
    local commit_sha=${ZED_COMMIT_SHA:?ZED_COMMIT_SHA is required}
    local worktree_dirty=${ZED_WORKTREE_DIRTY:-false}
    local app_directory
    local release_version
    local channel
    local suffix
    local binary
    local dependency
    local dependency_name
    local required_glibc
    local maximum_glibc=0
    local readelf_output
    local zed_ldd_output
    local cli_ldd_output
    local dependency_list

    mkdir -p "$HOME" "$CARGO_HOME" "$build_dir" "$artifact_dir"
    temporary_directory=$(mktemp -d)
    trap 'rm -rf -- "$temporary_directory"' EXIT

    export CARGO_TARGET_DIR="$build_dir"
    export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:?RUSTUP_TOOLCHAIN is required}"
    export ZED_COMMIT_SHA="$commit_sha"
    export ZED_BUNDLE=true
    export CC=clang
    export MOLD=/usr/bin/mold

    channel=$(<crates/zed/RELEASE_CHANNEL)
    release_version=$(script/get-crate-version zed)
    export RELEASE_VERSION="$release_version"

    cargo about --version | grep -q '^cargo-about 0\.8\.2$' || cargo install cargo-about@0.8.2
    script/generate-licenses

    cargo --config .cargo/bundle-config.toml --config profile.release.debug=0 rustc \
        --release --target x86_64-unknown-linux-gnu --package zed --bin zed \
        --features remote/build-remote-server-binary -- \
        -C linker="$CC" -C llvm-args=-addrsig \
        -C link-arg=-fuse-ld=mold -C link-arg=--ld-path="$MOLD" \
        -C link-arg=-Wl,--icf=safe

    cargo --config .cargo/bundle-config.toml --config profile.release.debug=0 rustc \
        --release --target x86_64-unknown-linux-gnu --package cli --bin cli -- \
        -C linker="$CC" -C link-arg=-fuse-ld=mold -C link-arg=--ld-path="$MOLD"

    CC_x86_64_unknown_linux_musl=musl-gcc cargo \
        --config .cargo/bundle-config.toml --config profile.release.debug=0 rustc \
        --release --package remote_server --bin remote-server \
        --target x86_64-unknown-linux-musl -- \
        -C linker="$CC" -C link-arg=-fuse-ld=mold -C link-arg=--ld-path="$MOLD"

    local zed_binary="$build_dir/x86_64-unknown-linux-gnu/release/zed"
    local cli_binary="$build_dir/x86_64-unknown-linux-gnu/release/cli"
    local remote_binary="$build_dir/x86_64-unknown-linux-musl/release/remote-server"
    for binary in "$zed_binary" "$cli_binary" "$remote_binary"; do
        if [[ ! -x "$binary" ]]; then
            printf 'Build output is missing: %s\n' "$binary" >&2
            exit 1
        fi
    done

    suffix=""
    if [[ "$channel" != stable ]]; then
        suffix="-$channel"
    fi
    app_directory="$temporary_directory/zed-custom.app"
    mkdir -p "$app_directory/bin" "$app_directory/libexec" "$app_directory/lib" \
        "$app_directory/share/icons/hicolor/512x512/apps" \
        "$app_directory/share/icons/hicolor/1024x1024/apps" \
        "$app_directory/share/applications"

    llvm-objcopy --strip-unneeded "$zed_binary" "$app_directory/libexec/zed-editor"
    llvm-objcopy --strip-debug --discard-all "$cli_binary" "$app_directory/bin/zed"
    llvm-objcopy --strip-debug --discard-all "$remote_binary" "$app_directory/libexec/remote_server"
    chmod 755 "$app_directory/libexec/zed-editor" "$app_directory/bin/zed" \
        "$app_directory/libexec/remote_server"

    cat > "$app_directory/bin/run-zed" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
bundle_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export ZED_COPY_REMOTE_SERVER="${ZED_COPY_REMOTE_SERVER:-$bundle_directory/libexec/remote_server}"
exec "$bundle_directory/bin/zed" "$@"
EOF
    chmod 755 "$app_directory/bin/run-zed"

    for binary in "$zed_binary" "$cli_binary"; do
        if ! ldd_output=$(ldd "$binary"); then
            printf 'ldd failed for %s\n' "$binary" >&2
            exit 1
        fi
        if grep -q 'not found' <<< "$ldd_output"; then
            printf 'Unresolved shared library for %s:\n%s\n' "$binary" "$ldd_output" >&2
            exit 1
        fi
        if [[ "$binary" == "$zed_binary" ]]; then
            zed_ldd_output=$ldd_output
        else
            cli_ldd_output=$ldd_output
        fi
    done
    dependency_list=$(printf '%s\n%s\n' "$zed_ldd_output" "$cli_ldd_output" | awk '
        $2 == "=>" && $3 ~ /^\// { print $3 }
        $1 ~ /^\// { print $1 }
    ' | sort -u)
    while IFS= read -r dependency; do
        dependency_name=${dependency##*/}
        case "$dependency_name" in
            ld-linux*.so*|libc.so*|libc-*.so*|libgcc_s.so*|libm.so*|libpthread.so*|\
                libdl.so*|librt.so*|libutil.so*|libanl.so*|libnss_*.so*|libasound.so*|\
                libglib-2.0.so*|libgobject-2.0.so*|libgio-2.0.so*|libgmodule-2.0.so*|\
                libpcre.so*|libpcre2-8.so*|libmount.so*|libblkid.so*|libselinux.so*|\
                libffi.so*|libresolv.so*|libz.so*)
                ;;
            *)
                cp --dereference --preserve=mode,timestamps "$dependency" "$app_directory/lib/$dependency_name"
                ;;
        esac
    done <<< "$dependency_list"

    for binary in "$app_directory/libexec/zed-editor" "$app_directory/bin/zed"; do
        local ldd_output
        if ! ldd_output=$(ldd "$binary"); then
            printf 'ldd failed for %s\n' "$binary" >&2
            exit 1
        fi
        if grep -q 'not found' <<< "$ldd_output"; then
            printf 'Unresolved shared library for %s:\n%s\n' "$binary" "$ldd_output" >&2
            exit 1
        fi
    done

    for binary in "$app_directory/libexec/zed-editor" "$app_directory/bin/zed" "$app_directory/lib"/*; do
        [[ -f "$binary" ]] || continue
        if ! readelf -h "$binary" >/dev/null 2>&1; then
            continue
        fi
        readelf_output=$(readelf --dyn-syms --wide "$binary" | awk '
            / UND / && match($0, /GLIBC_[0-9]+[.][0-9]+([.][0-9]+)?/) {
                version = substr($0, RSTART, RLENGTH)
                sub(/^GLIBC_/, "", version)
                print version
            }
        ')
        while IFS= read -r required_glibc; do
            [[ -n "$required_glibc" ]] || continue
            if dpkg --compare-versions "$required_glibc" gt 2.39; then
                printf 'glibc 2.39 check failed: %s requires GLIBC_%s\n' \
                    "$binary" "$required_glibc" >&2
                exit 1
            fi
            if dpkg --compare-versions "$required_glibc" gt "$maximum_glibc"; then
                maximum_glibc=$required_glibc
            fi
        done <<< "$readelf_output"
    done

    if ! readelf -h "$app_directory/libexec/remote_server" >/dev/null 2>&1; then
        printf 'remote_server is not an ELF executable.\n' >&2
        exit 1
    fi
    if readelf -l "$app_directory/libexec/remote_server" | grep -q INTERP \
        || readelf -d "$app_directory/libexec/remote_server" 2>/dev/null | grep -q NEEDED; then
        printf 'remote_server is not statically linked.\n' >&2
        exit 1
    fi

    "$app_directory/bin/zed" --help >/dev/null
    "$app_directory/bin/zed" --version >/dev/null
    "$app_directory/bin/run-zed" --version >/dev/null
    "$app_directory/libexec/zed-editor" --help >/dev/null
    "$app_directory/libexec/remote_server" version >/dev/null
    "$app_directory/libexec/remote_server" --help >/dev/null

    cp "crates/zed/resources/app-icon$suffix.png" \
        "$app_directory/share/icons/hicolor/512x512/apps/zed.png"
    cp "crates/zed/resources/app-icon$suffix@2x.png" \
        "$app_directory/share/icons/hicolor/1024x1024/apps/zed.png"
    export DO_STARTUP_NOTIFY=true APP_CLI=zed APP_ICON=zed APP_ARGS=%U
    case "$channel" in
        preview)
            export APP_NAME='Zed Preview'
            app_id=dev.zed.Zed-Preview
            ;;
        nightly)
            export APP_NAME='Zed Nightly'
            app_id=dev.zed.Zed-Nightly
            ;;
        dev)
            export APP_NAME='Zed Devel'
            app_id=dev.zed.Zed-Dev
            ;;
        *)
            export APP_NAME=Zed
            app_id=dev.zed.Zed
            ;;
    esac
    envsubst < crates/zed/resources/zed.desktop.in > "$app_directory/share/applications/$app_id.desktop"
    chmod +x "$app_directory/share/applications/$app_id.desktop"
    cp assets/licenses.md "$app_directory/licenses.md"
    cat > "$app_directory/README.md" <<'EOF'
# Zed custom Linux build

This x86_64 bundle was built on Ubuntu 24.04 and requires glibc 2.39 or newer.
It carries the Zed editor, CLI, and a static musl remote server. It does not
install files into your home directory or system directories.

Extract the archive, then run:

    ./zed-custom.app/bin/run-zed

Pass a project path as usual, for example ./zed-custom.app/bin/run-zed .
The launcher selects the bundled remote server automatically. The CLI binary is
also available at zed-custom.app/bin/zed; set
ZED_COPY_REMOTE_SERVER="$PWD/zed-custom.app/libexec/remote_server" when using
the CLI directly if you want it to select the bundled remote server.

The editor uses your system graphics, audio, font, and desktop libraries. The
bundle includes its non-system runtime libraries, but it must run on Linux with
x86_64 and glibc 2.39 or newer.
EOF

    tar --create --gzip --file="$artifact_dir/zed-custom-linux-x86_64.tar.gz" \
        --directory="$temporary_directory" zed-custom.app
    gzip --best --stdout "$app_directory/bin/zed" > "$artifact_dir/zed-cli-linux-x86_64.gz"
    gzip --best --stdout "$app_directory/libexec/zed-editor" > "$artifact_dir/zed-editor-linux-x86_64.gz"
    gzip --best --stdout "$app_directory/libexec/remote_server" \
        > "$artifact_dir/zed-remote-server-linux-x86_64-musl.gz"

    local build_date
    build_date=$(date --utc +%Y-%m-%dT%H:%M:%SZ)
    jq --null-input \
        --arg commit "$commit_sha" \
        --arg date "$build_date" \
        --arg release_version "$release_version" \
        --arg rustc "$(rustc --version)" \
        --arg maximum_glibc "$maximum_glibc" \
        --arg channel "$channel" \
        --arg worktree_dirty "$worktree_dirty" \
        --arg build_image 'ubuntu:24.04 (glibc 2.39)' \
        '{commit: $commit, build_date_utc: $date, release_version: $release_version, release_channel: $channel, rustc: $rustc, build_image: $build_image, maximum_required_glibc: $maximum_glibc, worktree_dirty: ($worktree_dirty == "true"), targets: ["x86_64-unknown-linux-gnu", "x86_64-unknown-linux-musl"], assets: ["zed-custom-linux-x86_64.tar.gz", "zed-cli-linux-x86_64.gz", "zed-editor-linux-x86_64.gz", "zed-remote-server-linux-x86_64-musl.gz"]}' \
        > "$artifact_dir/BUILD-INFO.json"

    (
        cd "$artifact_dir"
        sha256sum zed-custom-linux-x86_64.tar.gz zed-cli-linux-x86_64.gz \
            zed-editor-linux-x86_64.gz zed-remote-server-linux-x86_64-musl.gz \
            BUILD-INFO.json > SHA256SUMS
        sha256sum --check SHA256SUMS
    )

    gzip --test "$artifact_dir/zed-custom-linux-x86_64.tar.gz" \
        "$artifact_dir/zed-cli-linux-x86_64.gz" \
        "$artifact_dir/zed-editor-linux-x86_64.gz" \
        "$artifact_dir/zed-remote-server-linux-x86_64-musl.gz"
    printf 'Packaged artifacts in %s\n' "$artifact_dir"
}

if [[ "${1:-}" == --package ]]; then
    container_build \
        "${BUILD_UID:?BUILD_UID is required}" \
        "${BUILD_GID:?BUILD_GID is required}" \
        "${RUST_TOOLCHAIN:?RUST_TOOLCHAIN is required}" \
        "${ZED_COMMIT_SHA:?ZED_COMMIT_SHA is required}"
    exit 0
fi
if [[ "${1:-}" == --package-as-user ]]; then
    package_build
    exit 0
fi

upload=true
while (($#)); do
    case "$1" in
        --no-upload)
            upload=false
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            show_help >&2
            exit 2
            ;;
    esac
done

if [[ "$(uname -m)" != x86_64 ]]; then
    printf 'This script currently supports x86_64 Linux hosts only.\n' >&2
    exit 1
fi
require_command docker
require_command git
require_command tar
require_command mktemp
if "$upload"; then
    require_command gh
    gh release view "$release_tag" --repo "$release_repository" >/dev/null
fi

rust_toolchain=$(sed -nE 's/^channel = "([^"]+)"/\1/p' "$repository_root/rust-toolchain.toml")
if [[ -z "$rust_toolchain" ]]; then
    printf 'Could not read the Rust toolchain from rust-toolchain.toml.\n' >&2
    exit 1
fi
commit_sha=$(git -C "$repository_root" rev-parse HEAD)
if [[ -n $(git -C "$repository_root" status --porcelain) ]]; then
    worktree_dirty=true
else
    worktree_dirty=false
fi

mkdir -p "$build_cache" "$artifact_directory"
mkdir -p "$build_cache/home" "$build_cache/cargo" "$build_cache/target"
snapshot_directory=$(mktemp -d "${TMPDIR:-/tmp}/zed-build-dist-source.XXXXXX")
files_file=$(mktemp "${TMPDIR:-/tmp}/zed-build-dist-files.XXXXXX")
trap 'rm -rf -- "$snapshot_directory"; rm -f -- "$files_file"' EXIT
prepare_source_snapshot "$snapshot_directory" "$files_file"

docker run --rm --platform linux/amd64 \
    --mount "type=bind,src=$snapshot_directory,dst=/work" \
    --mount "type=bind,src=$build_cache,dst=/cache" \
    --mount "type=bind,src=$artifact_directory,dst=/out" \
    --workdir /work \
    --env BUILD_UID="$(id -u)" \
    --env BUILD_GID="$(id -g)" \
    --env RUST_TOOLCHAIN="$rust_toolchain" \
    --env ZED_COMMIT_SHA="$commit_sha" \
    --env ZED_WORKTREE_DIRTY="$worktree_dirty" \
    --env CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}" \
    ubuntu:24.04 /bin/bash /work/build-dist.sh --package

if "$upload"; then
    gh release upload "$release_tag" \
        "$artifact_directory/zed-custom-linux-x86_64.tar.gz" \
        "$artifact_directory/zed-cli-linux-x86_64.gz" \
        "$artifact_directory/zed-editor-linux-x86_64.gz" \
        "$artifact_directory/zed-remote-server-linux-x86_64-musl.gz" \
        "$artifact_directory/SHA256SUMS" \
        "$artifact_directory/BUILD-INFO.json" \
        --clobber --repo "$release_repository"
    printf 'Uploaded build artifacts to https://github.com/%s/releases/tag/%s\n' \
        "$release_repository" "$release_tag"
fi
