#!/usr/bin/env bash
set -euo pipefail

readonly QEMU_SOURCE_COMMIT=cac3fb4414778eab741a5e58ca0a30f1edc9528a
readonly QEMU_SOURCE_SHA256=72874fe9c395ced0c7fd7c22c43744072697f7ee1926a72237bd81784b2faf62
readonly QEMU_PATCH_SHA256=6da6ac4782d3e643abf94c23b39e8cd18a538ad12e83bbd083ed5adc033f467d
readonly QEMU_VERSION=9.2.1

qemu_config_for_arch() {
  case "$1" in
    amd64) printf 'x86_64 x86_64-softmmu q35\n' ;;
    arm64) printf 'aarch64 aarch64-softmmu virt\n' ;;
    *) return 1 ;;
  esac
}

test_architecture_mapping() {
  while read -r host_arch expected_target expected_configure_target expected_machine; do
    read -r target configure_target machine < <(qemu_config_for_arch "${host_arch}")
    test "${target}" = "${expected_target}"
    test "${configure_target}" = "${expected_configure_target}"
    test "${machine}" = "${expected_machine}"
  done <<'EOF'
amd64 x86_64 x86_64-softmmu q35
arm64 aarch64 aarch64-softmmu virt
EOF
}

if [[ ${1:-} == --test-architecture-mapping ]]; then
  test_architecture_mapping
  exit 0
fi

read -r target configure_target machine < <(qemu_config_for_arch "$(dpkg --print-architecture)") || {
  echo "Unsupported QEMU host architecture: $(dpkg --print-architecture)" >&2
  exit 1
}

readonly cache_root="${HOME}/.cache/bootc-qemu/${target}"
readonly source_tar="${cache_root}/qemu-${QEMU_VERSION}.tar.xz"
readonly source_dir="${cache_root}/qemu-${QEMU_VERSION}"
readonly binary="${cache_root}/qemu-system-${target}"
readonly metadata="${cache_root}/metadata"
readonly patch_file="${GITHUB_ACTION_PATH}/qemu-vhost-user-sync.patch"

mkdir -p "${cache_root}"
sha256sum -c <(printf '%s  %s\n' "${QEMU_PATCH_SHA256}" "${patch_file}")

if [[ ! -f "${source_tar}" ]]; then
  curl --fail --location --retry 3 --output "${source_tar}" \
    "https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz"
fi
sha256sum -c <(printf '%s  %s\n' "${QEMU_SOURCE_SHA256}" "${source_tar}")

if [[ ! -x "${binary}" ]]; then
  rm -rf "${source_dir}"
  mkdir -p "${source_dir}"
  tar -xJf "${source_tar}" --strip-components=1 -C "${source_dir}"
  git -C "${source_dir}" apply --check --unidiff-zero --whitespace=error "${patch_file}"
  git -C "${source_dir}" apply --unidiff-zero --whitespace=error "${patch_file}"
  grep -q 'bool reply_supported = virtio_has_feature' "${source_dir}/hw/virtio/vhost-user.c"
  grep -q 'return process_message_reply(dev, &msg);' "${source_dir}/hw/virtio/vhost-user.c"
  cd "${source_dir}"
  ./configure --prefix=/usr --target-list="${configure_target}" \
    --enable-kvm --enable-slirp --disable-modules --disable-werror --disable-docs \
    --disable-gtk --disable-sdl --disable-spice --disable-opengl --disable-virglrenderer \
    --disable-xen --disable-user --disable-tools --disable-guest-agent \
    --disable-vnc --disable-curl --disable-capstone \
    --disable-libssh --disable-vde --disable-png --disable-libdw
  ninja -C "${source_dir}/build" qemu-system-"${target}"
  install -m 0755 "${source_dir}/build/qemu-system-${target}" "${binary}"
  cd - >/dev/null
  rm -rf "${source_dir}"
  printf 'source=%s\npatch=%s\nbinary=%s\n' \
    "${QEMU_SOURCE_SHA256}" "${QEMU_PATCH_SHA256}" "$(sha256sum "${binary}" | cut -d' ' -f1)" > "${metadata}"
fi

# The cache is trusted within this GHA job; metadata is only a consistency
# check, not an independent security boundary. Re-hash the binary regardless.
test -f "${metadata}"
grep -Fxq "source=${QEMU_SOURCE_SHA256}" "${metadata}"
grep -Fxq "patch=${QEMU_PATCH_SHA256}" "${metadata}"
grep -Fxq "binary=$(sha256sum "${binary}" | cut -d' ' -f1)" "${metadata}"
version_line=
while IFS= read -r line; do version_line="${line}"; break; done < <("${binary}" --version)
test "${version_line}" = "QEMU emulator version ${QEMU_VERSION}"
echo "QEMU source commit: ${QEMU_SOURCE_COMMIT}"
echo "QEMU patch SHA256: ${QEMU_PATCH_SHA256}"
preselected_sha=$(sha256sum "${binary}" | cut -d' ' -f1)
if [[ ${EUID} -eq 0 ]]; then
  install -m 0755 "${binary}" "/usr/bin/qemu-system-${target}"
else
  sudo install -m 0755 "${binary}" "/usr/bin/qemu-system-${target}"
fi
selected_binary="/usr/bin/qemu-system-${target}"
selected_sha=$(sha256sum "${selected_binary}" | cut -d' ' -f1)
test "${selected_sha}" = "${preselected_sha}"
echo "QEMU cached binary SHA256: ${preselected_sha}"
echo "QEMU selected binary SHA256: ${selected_sha}"
echo "QEMU selected binary: ${selected_binary}"
version_line=
while IFS= read -r line; do version_line="${line}"; break; done < <("${selected_binary}" --version)
test "${version_line}" = "QEMU emulator version ${QEMU_VERSION}"
"${selected_binary}" -machine help | grep -q "^${machine} "
"${selected_binary}" -device vhost-user-fs-pci,help >/dev/null
smoke_dir=$(mktemp -d)
timeout 10 "${selected_binary}" -machine none -nodefaults -display none -S \
  -netdev user,id=net0 \
  -qmp "unix:${smoke_dir}/qmp.sock,server=on,wait=off" >/dev/null 2>&1 &
smoke_pid=$!
sleep 1
if ! kill -0 "${smoke_pid}" 2>/dev/null; then
  printf 'QEMU network smoke test exited before it could be stopped\n' >&2
  exit 1
fi
kill "${smoke_pid}"
set +e
wait "${smoke_pid}"
smoke_status=$?
set -e
rm -rf "${smoke_dir}"
case "${smoke_status}" in 0|143) ;; *) exit "${smoke_status}" ;; esac
printf 'QEMU libraries:\n'
ldd "${selected_binary}"
