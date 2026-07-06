#!/bin/sh

set -e

setup_rust() {
    if command -v rustup >/dev/null 2>&1; then
        rustup set profile minimal
        rustup toolchain install stable --profile minimal --target aarch64-apple-ios
        rustup default stable
    else
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --profile minimal --default-toolchain stable -t aarch64-apple-ios
    fi
}

setup_rust

if [ -f "${HOME}/.cargo/env" ]; then
    . "${HOME}/.cargo/env"
fi

rustc --version
cargo --version
rustup target list --installed

if [ -x "/opt/homebrew/bin/brew" ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

if ! command -v protoc >/dev/null 2>&1; then
    echo "error: protoc not found. Install protobuf before running this script." >&2
    exit 1
fi

protoc --version
