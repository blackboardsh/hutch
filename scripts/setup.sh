#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUTCH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ZIG_VERSION="0.16.0"

host_arch() {
  case "$(uname -m)" in
    arm64|aarch64) printf 'aarch64' ;;
    x86_64|amd64) printf 'x86_64' ;;
    *) echo "hutch setup: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
}

host_os() {
  case "$(uname -s)" in
    Darwin) printf 'macos' ;;
    Linux) printf 'linux' ;;
    MINGW*|MSYS*|CYGWIN*) printf 'windows' ;;
    *) echo "hutch setup: unsupported platform: $(uname -s)" >&2; exit 1 ;;
  esac
}

zig_binary_name() {
  case "$1" in
    windows) printf 'zig.exe' ;;
    macos|linux) printf 'zig' ;;
    *) echo "hutch setup: unsupported normalized platform: $1" >&2; exit 1 ;;
  esac
}

vendor_zig() {
  local arch os
  arch="$(host_arch)"
  os="$(host_os)"

  local zig_dir="$HUTCH_ROOT/vendors/zig"
  local zig_bin="$zig_dir/$(zig_binary_name "$os")"
  local stamp="$zig_dir/.zig-version"

  if [[ -x "$zig_bin" && -f "$stamp" && "$(tr -d '[:space:]' < "$stamp")" == "$ZIG_VERSION" ]]; then
    echo "OK Zig $ZIG_VERSION already vendored"
    return
  fi

  local folder url
  folder="zig-${arch}-${os}-${ZIG_VERSION}"
  echo "Vendoring Zig $ZIG_VERSION..."
  rm -rf "$zig_dir"
  mkdir -p "$zig_dir"

  if [[ "$os" == "windows" ]]; then
    local archive_path="$HUTCH_ROOT/vendors/zig.zip"
    local extract_dir="$HUTCH_ROOT/vendors/zig-temp"
    url="https://ziglang.org/download/${ZIG_VERSION}/${folder}.zip"

    rm -f "$archive_path"
    rm -rf "$extract_dir"
    curl -fL "$url" -o "$archive_path"
    unzip -q "$archive_path" -d "$extract_dir"
    cp -R "$extract_dir/$folder/." "$zig_dir/"
    rm -f "$archive_path"
    rm -rf "$extract_dir"
  else
    url="https://ziglang.org/download/${ZIG_VERSION}/${folder}.tar.xz"
    curl -fL "$url" | tar -xJ --strip-components=1 -C "$zig_dir" \
      "$folder/zig" \
      "$folder/lib" \
      "$folder/doc"
  fi

  chmod 755 "$zig_bin"
  printf '%s\n' "$ZIG_VERSION" > "$stamp"
  echo "OK Zig $ZIG_VERSION vendored"
}

vendor_zig
