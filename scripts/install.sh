#!/bin/sh
set -eu

artifacts_base_url="${DASH_ARTIFACTS_BASE_URL:-https://hutch.blackboard.sh}"
hutch_home="${HUTCH_HOME:-${DASH_HOME:-$HOME/.hutch}}"
channel="production"
version=""
build=""
modify_path="true"

usage() {
  cat <<'EOF'
Install Hutch

Usage:
  install.sh [--channel production|stable|canary]
  install.sh --version <semver> [--channel production|stable|canary]
  install.sh --build <full-revision> [--channel production|stable|canary]
  install.sh [--hutch-home <path>]
  install.sh [--no-modify-path]
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --channel)
      channel="${2:?missing value for --channel}"
      shift 2
      ;;
    --version)
      version="${2:?missing value for --version}"
      shift 2
      ;;
    --build)
      build="${2:?missing value for --build}"
      shift 2
      ;;
    --hutch-home|--dash-home)
      hutch_home="${2:?missing value for $1}"
      shift 2
      ;;
    --no-modify-path)
      modify_path="false"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "hutch installer: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "$channel" = "stable" ]; then
  channel="production"
fi
if [ "$channel" != "production" ] && [ "$channel" != "canary" ]; then
  echo "hutch installer: channel must be production, stable, or canary" >&2
  exit 1
fi
if [ -n "$version" ] && [ -n "$build" ]; then
  echo "hutch installer: --version and --build are mutually exclusive" >&2
  exit 1
fi

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64|Darwin-aarch64) platform="macos-arm64" ;;
  Linux-x86_64|Linux-amd64) platform="linux-x64" ;;
  Linux-arm64|Linux-aarch64) platform="linux-arm64" ;;
  *)
    echo "hutch installer: unsupported platform: $(uname -s) $(uname -m)" >&2
    exit 1
    ;;
esac

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
manifest_path="$tmp_dir/manifest.json"

download() {
  url="$1"
  output="$2"
  case "$artifacts_base_url" in
    https://*)
      curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
        "$url" --output "$output"
      ;;
    http://127.0.0.1*|http://localhost*)
      curl --fail --silent --show-error --location "$url" --output "$output"
      ;;
    *)
      echo "hutch installer: artifact base URL must use HTTPS" >&2
      exit 1
      ;;
  esac
}

json_string() {
  key="$1"
  file="$2"
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -n 1
}

platform_field() {
  key="$1"
  file="$2"
  awk -v platform="\"$platform\"" -v key="\"$key\"" '
    index($0, platform) { in_platform = 1; next }
    in_platform && index($0, key) {
      line = $0
      sub(/^[^:]*:[[:space:]]*/, "", line)
      gsub(/[",[:space:]]/, "", line)
      print line
      exit
    }
  ' "$file"
}

if [ -n "$version" ]; then
  manifest_url="$artifacts_base_url/hutch/releases/$version/manifest.json"
elif [ -n "$build" ]; then
  manifest_url="$artifacts_base_url/hutch/builds/$build/manifest.json"
else
  channel_manifest="$tmp_dir/channel.json"
  download "$artifacts_base_url/hutch/channels/$channel.json" "$channel_manifest"
  manifest_url="$(json_string url "$channel_manifest")"
  if [ -z "$manifest_url" ]; then
    echo "hutch installer: channel manifest did not contain a release URL" >&2
    exit 1
  fi
fi

download "$manifest_url" "$manifest_path"

release_version="$(json_string version "$manifest_path")"
revision="$(json_string revision "$manifest_path")"
archive_url="$(platform_field url "$manifest_path")"
expected_sha256="$(platform_field sha256 "$manifest_path")"
expected_size="$(platform_field size "$manifest_path")"
if [ -z "$release_version" ] || [ -z "$revision" ] || [ -z "$archive_url" ] ||
   [ -z "$expected_sha256" ] || [ -z "$expected_size" ]; then
  echo "hutch installer: release manifest is incomplete for $platform" >&2
  exit 1
fi

archive="$tmp_dir/hutch.tar.gz"
download "$archive_url" "$archive"

if command -v sha256sum >/dev/null 2>&1; then
  actual_sha256="$(sha256sum "$archive" | awk '{print $1}')"
else
  actual_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
fi
actual_size="$(wc -c < "$archive" | tr -d '[:space:]')"
if [ "$actual_sha256" != "$expected_sha256" ]; then
  echo "hutch installer: archive checksum mismatch" >&2
  exit 1
fi
if [ "$actual_size" != "$expected_size" ]; then
  echo "hutch installer: archive size mismatch" >&2
  exit 1
fi

install_root="$hutch_home/products/hutch/$release_version/$revision/$platform"
install_parent="$(dirname "$install_root")"
extract_root="$tmp_dir/extracted"
mkdir -p "$extract_root" "$install_parent"
tar -xzf "$archive" --strip-components=1 -C "$extract_root"
test -x "$extract_root/bin/hutch"
test -x "$extract_root/bin/hutch-engine"
test -f "$extract_root/hutch-release.json"
grep -F "\"version\": \"$release_version\"" "$extract_root/hutch-release.json" >/dev/null
grep -F "\"revision\": \"$revision\"" "$extract_root/hutch-release.json" >/dev/null
grep -F "\"platform\": \"$platform\"" "$extract_root/hutch-release.json" >/dev/null
printf '%s' "$expected_sha256" > "$extract_root/.dash-installed"

rm -rf "$install_root"
mv "$extract_root" "$install_root"

channel_dir="$hutch_home/channels/hutch"
bin_dir="$hutch_home/bin"
mkdir -p "$channel_dir" "$bin_dir"
pointer_tmp="$channel_dir/$channel.tmp"
printf '%s\n' "$install_root" > "$pointer_tmp"
mv "$pointer_tmp" "$channel_dir/$channel"

command_name="hutch"
if [ "$channel" = "canary" ]; then
  command_name="hutch-canary"
fi
command_path="$bin_dir/$command_name"
command_tmp="$command_path.tmp"
cp "$install_root/bin/hutch" "$command_tmp"
chmod 755 "$command_tmp"
mv "$command_tmp" "$command_path"

echo "Installed Hutch $release_version ($channel) at $install_root"

quote_for_shell() {
  escaped="$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
  printf "'%s'" "$escaped"
}

append_path_once() {
  profile="$1"
  path_line="$2"
  profile_dir="$(dirname "$profile")"

  if [ -f "$profile" ] && grep -F "$path_line" "$profile" >/dev/null 2>&1; then
    return 0
  fi
  if ! mkdir -p "$profile_dir"; then
    return 1
  fi
  if [ -s "$profile" ] && ! printf '\n' >> "$profile"; then
    return 1
  fi
  if ! printf '%s\n%s\n' "# Hutch" "$path_line" >> "$profile"; then
    return 1
  fi
}

configure_path() {
  quoted_bin_dir="$(quote_for_shell "$bin_dir")"
  posix_path_line="export PATH=$quoted_bin_dir:\"\$PATH\""
  shell_path="${SHELL:-}"
  shell_name="${shell_path##*/}"
  profile=""
  path_line="$posix_path_line"
  activate_command="$posix_path_line"

  case "$shell_name" in
    zsh)
      profile="${ZDOTDIR:-$HOME}/.zshrc"
      ;;
    bash)
      if [ "$(uname -s)" = "Darwin" ]; then
        profile="$HOME/.bash_profile"
      else
        profile="$HOME/.bashrc"
      fi
      ;;
    fish)
      profile="${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish"
      path_line="fish_add_path --global $quoted_bin_dir"
      activate_command="$path_line"
      ;;
    sh|ash|dash|ksh)
      profile="$HOME/.profile"
      ;;
  esac

  if [ "$modify_path" = "true" ] && [ -n "$profile" ]; then
    if append_path_once "$profile" "$path_line"; then
      echo "Configured $bin_dir in $profile."
    else
      echo "Could not update $profile; add Hutch to PATH manually." >&2
    fi
  elif [ "$modify_path" = "true" ]; then
    echo "Could not detect a supported shell profile for ${SHELL:-unknown}."
  fi

  echo "Open a new terminal, or activate Hutch in this terminal:"
  printf '  %s\n' "$activate_command"
}

case ":${PATH:-}:" in
  *":$bin_dir:"*) ;;
  *) configure_path ;;
esac
