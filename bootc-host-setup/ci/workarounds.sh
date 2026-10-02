#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

libvirt=${BOOTC_HOST_LIBVIRT:-false}
# shellcheck disable=SC1091
. /etc/os-release

setup_ubuntu_kvm() {
  [ "$libvirt" = true ] && [ -c /dev/kvm ] || return 0
  printf '%s\n' 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules >/dev/null
  sudo udevadm control --reload-rules
  sudo udevadm trigger --name-match=kvm
}

setup_ubuntu_apparmor() {
  if sudo test -r /etc/apparmor.d/bwrap-userns-restrict && sudo test -r /sys/kernel/security/apparmor/profiles && sudo grep -qx 'bwrap (enforce)' /sys/kernel/security/apparmor/profiles; then
    sudo tee /etc/apparmor.d/local/bwrap-userns-restrict >/dev/null <<'EOF'
priority=100 allow file rwlkm /**,
priority=100 allow ix /**,
EOF
    sudo apparmor_parser -Q /etc/apparmor.d/bwrap-userns-restrict
    sudo apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict
  fi
}

setup_ubuntu_qemu() {
  [ "$libvirt" = true ] && [ "$VERSION_ID" = 24.04 ] || return 0
  local architecture mirror qemu_package qemu_binary
  architecture=$(dpkg --print-architecture)
  case "$architecture" in
    amd64) qemu_package=qemu-system-x86 ;;
    arm64) qemu_package=qemu-system-arm ;;
    *) printf 'Unsupported architecture for Resolute QEMU: %s\n' "$architecture" >&2; return 1 ;;
  esac
  qemu_binary="qemu-system-$(uname -m)"
  printf '%s\n' 'Package: *' 'Pin: release n=resolute' 'Pin-Priority: 50' | sudo tee /etc/apt/preferences.d/resolute-qemu >/dev/null
  if [ "$architecture" = amd64 ]; then
    [ -f /etc/apt/apt-mirrors.txt ] && mirror='mirror+file:/etc/apt/apt-mirrors.txt' || mirror='http://archive.ubuntu.com/ubuntu'
  else
    mirror='http://ports.ubuntu.com/ubuntu-ports'
  fi
  printf 'deb %s resolute main universe\n' "$mirror" | sudo tee /etc/apt/sources.list.d/resolute-qemu.list >/dev/null
  timeout --foreground --signal=TERM --kill-after=30s 5m sudo apt-get update
  timeout --foreground --signal=TERM --kill-after=30s 5m sudo apt-get -t resolute install -y --no-install-recommends "$qemu_package" qemu-system-common qemu-system-data qemu-utils ipxe-qemu
  "$qemu_binary" --version
}

repair_rhel_openssh_policy() {
  local policy=/etc/crypto-policies/back-ends/openssh.config
  local expected_target=/usr/share/crypto-policies/DEFAULT/openssh.txt target diagnostic expected_diagnostic
  expected_diagnostic="Bad owner or permissions on ${policy}"
  diagnostic=$(mktemp)
  if ssh -G localhost >/dev/null 2>"$diagnostic"; then
    printf '%s\n' 'OpenSSH crypto policy is already valid; skipping partner-image repair.'
    rm -f "$diagnostic"
    return
  fi
  # The partner image's OpenSSH emits CRLF here.  Normalize only line endings
  # before retaining an exact match for the known broken-policy diagnostic.
  if ! tr -d '\r' < "$diagnostic" | grep -Fqx "$expected_diagnostic"; then
    printf '%s\n' 'Unexpected ssh -G failure; refusing to mask it:' >&2
    cat "$diagnostic" >&2
    rm -f "$diagnostic"
    return 1
  fi
  target=$(sudo readlink -e -- "$policy")
  test "$target" = "$expected_target"
  test "$(sudo rpm -qf --qf '%{NAME}' "$target")" = crypto-policies
  sudo chown root:root -- "$target"
  sudo chmod 0644 -- "$target"
  sudo restorecon -- "$target"
  test "$(sudo stat -c '%u:%g:%a' -- "$target")" = 0:0:644
  ssh -G localhost >/dev/null
  rm -f "$diagnostic"
}

setup_rhel_libvirt() {
  [ "$libvirt" = true ] || return 0
  repair_rhel_openssh_policy
  [ -c /dev/kvm ] && sudo setfacl -m "u:$(id -un):rw" /dev/kvm
  local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/libvirt"
  mkdir -p "$config_dir"
  # On the RHEL hosted runner, sVirt labeling conflicts with the readonly
  # virtiofs export of rootless Podman storage. This only disables per-domain
  # sVirt for this ephemeral, unprivileged libvirt session; the host SELinux
  # policy remains enforcing.
  cat > "$config_dir/qemu.conf" <<'EOF'
security_driver = "none"
EOF
  local virtiofsd
  virtiofsd=$(rpm -ql virtiofsd | { grep '/virtiofsd$' || :; } | head -n 1)
  test -n "$virtiofsd"
  sudo ln -sfn "$virtiofsd" /usr/local/bin/virtiofsd
  for firmware in /usr/share/qemu/firmware/*amdsev*.json; do
    [ -e "$firmware" ] || continue
    sudo mv "$firmware" "${firmware}.disabled"
  done
  printf 'LIBVIRT_DEFAULT_URI=qemu:///session\n' >> "$GITHUB_ENV"
}

# The libvirt client auto-spawns the qemu:///session daemon with --timeout=120.
# When that daemon exits on idle it removes its socket before it releases its
# pidfile, and a client connecting in between fails with "Failed to connect
# socket to '.../libvirt-sock': No such file or directory"
# (https://github.com/bootc-dev/bootc/issues/1843).  Keep one daemon for the
# whole job instead: connecting starts it, or finds one already running, and
# virt-admin then turns off its idle timeout.  This runs last so the daemon
# sees the final QEMU and /dev/kvm permissions when it probes capabilities;
# later steps get this daemon, with this step's environment.  Failing here
# only brings the race back, so it is a warning.
keep_ubuntu_libvirt_session() {
  [ "$libvirt" = true ] || return 0
  local daemon output errors=""
  virsh -c qemu:///session uri
  # Ubuntu's client spawns the monolithic libvirtd; virtqemud covers a switch
  # to the modular daemons.
  for daemon in libvirtd virtqemud; do
    if output=$(virt-admin -q -c "${daemon}:///session" daemon-timeout --timeout 0 2>&1); then
      printf 'Turned off the idle timeout of the %s session daemon:\n' "$daemon"
      pgrep -a -u "$(id -u)" -x "$daemon"
      return 0
    fi
    errors+="${daemon}: ${output}"$'\n'
  done
  printf '::warning::Could not turn off the idle timeout of the libvirt session daemon:\n%s' "$errors" >&2
  return 0
}

case "$ID" in
  ubuntu) setup_ubuntu_kvm; setup_ubuntu_qemu; setup_ubuntu_apparmor; keep_ubuntu_libvirt_session ;;
  rhel) setup_rhel_libvirt ;;
  *) printf 'Unsupported host ID: %s\n' "$ID" >&2; exit 1 ;;
esac
