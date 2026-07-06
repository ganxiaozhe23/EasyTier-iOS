#!/bin/sh

set -e

if command -v rustup >/dev/null 2>&1; then
    rustup target add aarch64-apple-ios
else
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y -t aarch64-apple-ios
fi

if [ -f "${HOME}/.cargo/env" ]; then
    . "${HOME}/.cargo/env"
fi

PROTOC_VERSION="$(curl -sSfL https://api.github.com/repos/protocolbuffers/protobuf/releases/latest \
  | sed -n 's/ *"tag_name": "v\([^"]*\)".*/\1/p')"
PROTOC_OSX_ZIP="protoc-${PROTOC_VERSION}-osx-universal_binary.zip"
PROTOC_URL="https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/${PROTOC_OSX_ZIP}"
curl -sSfL "${PROTOC_URL}" -o "${PROTOC_OSX_ZIP}"
mkdir -p "${HOME}/.local"
unzip -o "${PROTOC_OSX_ZIP}" -d "${HOME}/.local"
rm -f "${PROTOC_OSX_ZIP}"
