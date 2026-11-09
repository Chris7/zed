#!/usr/bin/env bash

set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

export CC=${CC:-$(command -v clang)}
mold=${MOLD:-mold}
if ! mold=$(command -v "$mold"); then
    echo "mold not found. Install mold or set MOLD to its executable path." >&2
    exit 1
fi

cargo rustc --release --package zed --bin zed --features remote/build-remote-server-binary -- -C linker="$CC" -C llvm-args=-addrsig -C link-arg=-fuse-ld=mold -C link-arg=--ld-path="$mold" -C link-arg=-Wl,--icf=safe
cargo rustc --release --package cli --bin cli -- -C linker="$CC" -C link-arg=-fuse-ld=mold -C link-arg=--ld-path="$mold"
CC_x86_64_unknown_linux_musl="${CC_x86_64_unknown_linux_musl:-musl-gcc}" \
    RUSTFLAGS="-C target-feature=+crt-static" cargo rustc --release --package remote_server --bin remote_server --target x86_64-unknown-linux-musl -- -C linker="$CC" -C link-arg=-fuse-ld=mold -C link-arg=--ld-path="$mold"
llvm-objcopy --strip-debug target/x86_64-unknown-linux-musl/release/remote_server

install -d "$HOME/.local/bin" "$HOME/.local/libexec"
staging_directory=$(mktemp -d "$HOME/.local/bin/.zed-install.XXXXXX")
trap 'rm -rf -- "$staging_directory"' EXIT

# Replace the binaries atomically so rebuilding works while Zed is running.
install -m 755 target/release/zed "$staging_directory/zed-editor"
install -m 755 target/release/cli "$staging_directory/zed"
install -m 755 target/x86_64-unknown-linux-musl/release/remote_server "$staging_directory/remote_server"
ln -s ../bin/zed-editor "$staging_directory/editor-link"
mv -Tf -- "$staging_directory/zed-editor" "$HOME/.local/bin/zed-editor"
mv -Tf -- "$staging_directory/zed" "$HOME/.local/bin/zed"
mv -Tf -- "$staging_directory/remote_server" "$HOME/.local/bin/remote_server"
mv -Tf -- "$staging_directory/editor-link" "$HOME/.local/libexec/zed-editor"
