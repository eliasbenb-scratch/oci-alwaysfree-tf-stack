#!/usr/bin/env bash
# Optional first-boot setup. Add host-specific installation steps here.
set -Eeuo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

readonly HELPER=/usr/local/lib/oci-host/host_config.py
readonly STATE_DIR=/var/lib/oci-host
readonly ZABBLY_FINGERPRINT=4EFC590696CB15B87C73A3AD82CC8797C838DCFD

log() {
  printf '\n[bootstrap-host] %s\n' "$*"
}

apt_get() {
  apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 "$@"
}

host_config() {
  /usr/bin/python3 "$HELPER" "$@"
}

configure_systemd() {
  local pair unit app socket

  for pair in docker:docker containerd:containerd incus:incus incus-startup:incus incus-user:incus; do
    unit=${pair%%:*}
    app=${pair##*:}
    install -d "/etc/systemd/system/$unit.service.d"
    cat >"/etc/systemd/system/$unit.service.d/10-require-storage.conf" <<EOF
[Unit]
RequiresMountsFor=/data /var/lib/$app
AssertPathIsMountPoint=/data
AssertPathIsMountPoint=/var/lib/$app
EOF
  done

  # Network-dependent mounts cannot precede basic.target. Disable the sockets'
  # usual early ordering to avoid a cycle through sockets.target.
  for socket in incus incus-user; do
    install -d "/etc/systemd/system/$socket.socket.d"
    cat >"/etc/systemd/system/$socket.socket.d/20-late-start.conf" <<'EOF'
[Unit]
DefaultDependencies=no
After=basic.target
RequiresMountsFor=/data /var/lib/incus
AssertPathIsMountPoint=/data
AssertPathIsMountPoint=/var/lib/incus
Conflicts=shutdown.target
Before=shutdown.target
EOF
  done

  for unit in docker incus; do
    cat >"/etc/systemd/system/$unit.service.d/20-firewall-order.conf" <<'EOF'
[Unit]
Requires=netfilter-persistent.service
After=netfilter-persistent.service
EOF
  done
  systemctl daemon-reload
}

configure_repositories() {
  local fingerprint

  # Keep package installation from saving transient container firewall chains.
  printf '%s\n' \
    'iptables-persistent iptables-persistent/autosave_v4 boolean false' \
    'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections
  apt_get update
  apt_get install -y ca-certificates curl gpg iptables-persistent
  install -d -m 0755 /etc/apt/keyrings

  curl --fail --silent --show-error --location --retry 5 \
    https://download.docker.com/linux/ubuntu/gpg -o "$work_dir/docker.asc"
  install -m 0644 "$work_dir/docker.asc" /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $VERSION_CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  curl --fail --silent --show-error --location --retry 5 \
    https://pkgs.zabbly.com/key.asc -o "$work_dir/zabbly.asc"
  install -d -m 0700 "$work_dir/gnupg"
  fingerprint=$(gpg --homedir "$work_dir/gnupg" --batch --show-keys --with-colons \
    "$work_dir/zabbly.asc" | awk -F: '$1 == "fpr" && !seen++ { print $10 }')
  if [[ "$fingerprint" != "$ZABBLY_FINGERPRINT" ]]; then
    echo "Unexpected Zabbly signing-key fingerprint: $fingerprint" >&2
    return 1
  fi
  install -m 0644 "$work_dir/zabbly.asc" /etc/apt/keyrings/zabbly.asc
  cat >/etc/apt/sources.list.d/zabbly-incus-lts-7.0.sources <<EOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/lts-7.0
Suites: $VERSION_CODENAME
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF
}

configure_networking() {
  host_config docker
  printf 'net.ipv4.ip_forward = 1\n' >/etc/sysctl.d/90-oci-host.conf
  sysctl -p /etc/sysctl.d/90-oci-host.conf
  host_config firewall
  systemctl enable netfilter-persistent.service
  systemctl restart netfilter-persistent.service
}

install_runtimes() {
  apt_get update
  apt_get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin incus
  systemctl daemon-reload
  systemctl enable --now \
    containerd.service docker.socket docker.service \
    incus.socket incus-user.socket incus-startup.service
  systemctl start incus.service
  host_config incus
  host_config access
}

main() {
  if ((EUID != 0)); then
    echo 'Run this bootstrap as root.' >&2
    return 1
  fi
  exec 9>/run/bootstrap-host.lock
  flock -n 9 || {
    echo 'Another bootstrap is running.' >&2
    return 1
  }
  install -d "$STATE_DIR"
  rm -f "$STATE_DIR/bootstrap-complete"
  work_dir=$(mktemp -d)
  trap 'rm -rf -- "$work_dir"' EXIT
  trap 'echo "Bootstrap failed at line $LINENO; fix the cause and rerun /usr/local/sbin/bootstrap-host" >&2' ERR

  log 'Preparing runtime storage'
  host_config runtime-storage
  configure_systemd

  log 'Configuring Docker stable and Incus 7.0 LTS repositories'
  configure_repositories

  log 'Configuring forwarding and the OCI firewall'
  configure_networking

  log 'Installing and configuring container runtimes'
  install_runtimes

  log 'Verifying daemon readiness'
  docker info >/dev/null
  incus info >/dev/null
  touch "$STATE_DIR/bootstrap-complete"
  log 'Ready. Log in again to use the docker and incus-admin groups.'
}

main "$@"
