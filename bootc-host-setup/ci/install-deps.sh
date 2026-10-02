#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

action_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
packages_dir="${action_dir}/packages"
libvirt=${BOOTC_HOST_LIBVIRT:-false}

read_packages() {
  local file=$1 line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    [ -n "$line" ] && packages+=("$line")
  done < "$file"
}

load_os_release() {
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID}:${VERSION_ID}" in
    ubuntu:24.04|ubuntu:26.04|rhel:10|rhel:10.*) ;;
    *) printf 'Unsupported host: ID=%s VERSION_ID=%s\n' "$ID" "$VERSION_ID" >&2; exit 1 ;;
  esac
}

free_ubuntu_disk() {
  local package dir n=0
  local -a unwanted_packages=(aspnetcore-* dotnet-* llvm-* php* mongodb-* mysql-* azure-cli google-chrome-stable firefox mono-devel)
  local -a unwanted_dirs=(/usr/share/dotnet /opt/ghc /usr/local/lib/android /opt/hostedtoolcache/CodeQL)
  sudo df -h
  run_cleanup() { sudo systemd-run -r -u "action-cleanup-${n}" -- "$@"; n=$((n + 1)); }
  run_cleanup docker image prune --all --force
  for dir in "${unwanted_dirs[@]}"; do run_cleanup rm -rf "$dir"; done
  for package in "${unwanted_packages[@]}"; do
    if dpkg -l "$package" >/dev/null 2>&1; then
      /bin/time -f '%E %C' sudo apt-get remove -y "$package"
    fi
  done
}

ubuntu_mirror() {
  if [ "$(dpkg --print-architecture)" = amd64 ]; then
    [ -f /etc/apt/apt-mirrors.txt ] && printf '%s' 'mirror+file:/etc/apt/apt-mirrors.txt' || printf '%s' 'http://archive.ubuntu.com/ubuntu'
  else
    printf '%s' 'http://ports.ubuntu.com/ubuntu-ports'
  fi
}

install_bcvk() {
  [ "$libvirt" = true ] && [ "$(uname -m)" = x86_64 ] || return 0
  # renovate: datasource=github-releases depName=bootc-dev/bcvk
  local bcvk_version=0.19.0 target tmpdir
  target="bcvk-$(uname -m)-unknown-linux-gnu"
  tmpdir=$(mktemp -d)
  curl --fail --show-error --location --retry 5 --retry-delay 10 --retry-max-time 300 --output "${tmpdir}/${target}.tar.gz" "https://github.com/bootc-dev/bcvk/releases/download/v${bcvk_version}/${target}.tar.gz"
  tar -xzf "${tmpdir}/${target}.tar.gz" -C "$tmpdir"
  sudo install -m 0755 "${tmpdir}/${target}" /usr/local/bin/bcvk
  rm -rf "$tmpdir"
  if [ "$ID" = ubuntu ]; then
    sudo sed -i -e 's,^\* hard nofile 65536,* hard nofile 524288,' /etc/security/limits.conf
  fi
  printf 'LIBVIRT_DEFAULT_URI=qemu:///session\n' >> "$GITHUB_ENV"
}

install_ubuntu() {
  local -a packages=()
  free_ubuntu_disk
  if [ "$VERSION_ID" = 24.04 ]; then
    printf 'deb %s plucky universe main\n' "$(ubuntu_mirror)" | sudo tee /etc/apt/sources.list.d/plucky.list >/dev/null
    printf '%s\n' 'Acquire::Retries "5";' | sudo tee /etc/apt/apt.conf.d/80-retries >/dev/null
  fi
  read_packages "${packages_dir}/ubuntu-base"
  /bin/time -f '%E %C' sudo apt-get update
  /bin/time -f '%E %C' sudo apt-get install -y "${packages[@]}"
  if [ "$VERSION_ID" = 24.04 ]; then
    packages=()
    read_packages "${packages_dir}/ubuntu-24.04-base"
    /bin/time -f '%E %C' sudo apt-get install -y --allow-downgrades "${packages[@]/%//plucky}"
  fi
  if [ "$libvirt" = true ]; then
    packages=()
    read_packages "${packages_dir}/ubuntu-libvirt"
    if [ "$VERSION_ID" = 26.04 ]; then
      read_packages "${packages_dir}/ubuntu-26.04-libvirt"
      packages+=(ovmf-amdsev-)
    fi
    /bin/time -f '%E %C' sudo apt-get install -y "${packages[@]}"
  fi
}

install_rhel_just() {
  if sudo dnf install -y just; then return; fi
  # TODO: Remove this fallback once the stock partner image reliably exposes a current EPEL just package.
  # renovate: datasource=github-releases depName=casey/just
  local just_version=1.58.0 just_sha256=4a5cc2f53e6f0f8c59092a6cc38291eb729d46a7dd95d3ae582008881b84931d tmpdir
  tmpdir=$(mktemp -d)
  curl --fail --show-error --location --retry 5 --output "${tmpdir}/just.tar.gz" "https://github.com/casey/just/releases/download/${just_version}/just-${just_version}-x86_64-unknown-linux-musl.tar.gz"
  printf '%s  %s\n' "$just_sha256" "${tmpdir}/just.tar.gz" | sha256sum --check
  tar -xzf "${tmpdir}/just.tar.gz" -C "$tmpdir" just
  sudo install -m 0755 "${tmpdir}/just" /usr/local/bin/just
  rm -rf "$tmpdir"
}

install_rhel() {
  local -a packages=()
  read_packages "${packages_dir}/rhel-base"
  [ "$libvirt" = true ] && read_packages "${packages_dir}/rhel-libvirt"
  sudo dnf install -y "${packages[@]}"
  install_rhel_just
}

main() {
  load_os_release
  # On 24.04 the packages installed below pull in a newer libc6, which in
  # turn upgrades base-files and with it os-release.  Record the host as it
  # was before, for the later steps and as the action's host-os output.
  printf 'host-os=%s-%s\n' "$ID" "$VERSION_ID" >> "$GITHUB_OUTPUT"
  case "$ID" in
    ubuntu) install_ubuntu ;;
    rhel) install_rhel ;;
  esac
  install_bcvk
  printf 'ARCH=%s\n' "$(arch)" >> "$GITHUB_ENV"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
