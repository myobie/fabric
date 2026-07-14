#!/usr/bin/env sh
set -eu

REPO="myobie/fabric"
REPO_URL="https://github.com/$REPO"
INSTALL_DIR="${FABRIC_BIN_DIR:-${BIN_DIR:-${FABRIC_INSTALL_DIR:-$HOME/.local/bin}}}"

echo "fabric: experimental prototype installer"

install_binary() {
  src="$1"
  target="$INSTALL_DIR/fabric"
  mkdir -p "$INSTALL_DIR"

  if [ -e "$target" ] || [ -L "$target" ]; then
    if ! "$target" --help 2>/dev/null | grep -q "Local socket facade for iroh-backed cross-machine transports"; then
      echo "error: refusing to overwrite non-fabric file at $target" >&2
      exit 1
    fi
    rm -f "$target"
  fi

  cp "$src" "$target"
  chmod 755 "$target"
  echo "installed: $target"
  echo "ensure $INSTALL_DIR is on PATH"

  if found=$(command -v fabric 2>/dev/null); then
    if [ "$found" = "$target" ]; then
      echo "fabric on PATH at $found"
    else
      echo "fabric is on PATH at $found (installed this copy at $target)"
    fi
  else
    echo "fabric is not currently on PATH; add $INSTALL_DIR to PATH"
  fi
}

require_cargo() {
  if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo is required for source installs" >&2
    exit 1
  fi
}

build_from_source_dir() {
  src_dir="$1"
  require_cargo
  echo "building fabric from source: $src_dir"
  cargo build --release --manifest-path "$src_dir/Cargo.toml"
  install_binary "$src_dir/target/release/fabric"
}

detect_target() {
  os=$(uname -s)
  arch=$(uname -m)
  case "$os:$arch" in
    Darwin:arm64|Darwin:aarch64) echo "aarch64-apple-darwin" ;;
    Linux:x86_64|Linux:amd64) echo "x86_64-unknown-linux-gnu" ;;
    Linux:arm64|Linux:aarch64) echo "aarch64-unknown-linux-gnu" ;;
    *) return 1 ;;
  esac
}

fetch() {
  url="$1"
  dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url"
  else
    return 1
  fi
}

install_prebuilt() {
  target="$1"
  tmp=$(mktemp -d)
  archive="$tmp/fabric-$target.tar.gz"
  url="$REPO_URL/releases/latest/download/fabric-$target.tar.gz"

  echo "trying prebuilt release: $target"
  if fetch "$url" "$archive" && tar -xzf "$archive" -C "$tmp" && [ -f "$tmp/fabric" ]; then
    install_binary "$tmp/fabric"
    rm -rf "$tmp"
    return 0
  fi

  rm -rf "$tmp"
  return 1
}

build_from_github() {
  if ! command -v git >/dev/null 2>&1; then
    echo "error: git is required for source fallback installs" >&2
    exit 1
  fi

  tmp=$(mktemp -d)
  git clone --depth 1 "$REPO_URL.git" "$tmp/fabric"
  build_from_source_dir "$tmp/fabric"
  rm -rf "$tmp"
}

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd || pwd)

if [ -f "$SCRIPT_DIR/Cargo.toml" ] && grep -q '^name = "fabric"' "$SCRIPT_DIR/Cargo.toml"; then
  build_from_source_dir "$SCRIPT_DIR"
  exit 0
fi

if target=$(detect_target); then
  if install_prebuilt "$target"; then
    exit 0
  fi
  echo "no matching prebuilt release found; falling back to source build"
else
  echo "unsupported OS/arch for prebuilt release; falling back to source build"
fi

build_from_github
