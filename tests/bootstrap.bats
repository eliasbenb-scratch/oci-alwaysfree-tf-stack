#!/usr/bin/env bats
# Bats isolates each test; sleep is called indirectly by apt_get.
# shellcheck disable=SC2030,SC2031,SC2329

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../scripts/bootstrap.sh
  source "$REPO_ROOT/scripts/bootstrap.sh"
  work_dir="$BATS_TEST_TMPDIR"
  export APT_TEST_CALLS="$BATS_TEST_TMPDIR/apt-calls"
  export APT_TEST_FAILURES=1
  export APT_TEST_ERROR='E: Could not get lock /var/lib/apt/lists/lock. It is held by process 2124 (apt)'
  export APT_TEST_STATUS=100
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$APT_TEST_CALLS"
if (($(wc -l <"$APT_TEST_CALLS") <= APT_TEST_FAILURES)); then
  printf '%s\n' "$APT_TEST_ERROR" >&2
  exit "$APT_TEST_STATUS"
fi
echo 'Package lists updated'
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/apt-get"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

sleep() {
  # Advance the retry deadline without waiting in tests.
  SECONDS=$((SECONDS + 5))
}

@test "apt update retries a package-list lock and succeeds" {
  run apt_get update

  [ "$status" -eq 0 ]
  [ "$(wc -l <"$APT_TEST_CALLS")" -eq 2 ]
  [[ "$output" == *"retrying in 5 seconds"* ]]
  [[ "$output" == *"Package lists updated"* ]]
  [ "$(head -n 1 "$APT_TEST_CALLS")" = '-o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 update' ]
}

@test "apt install succeeds without retrying" {
  export APT_TEST_FAILURES=0

  run apt_get install -y incus

  [ "$status" -eq 0 ]
  [ "$(wc -l <"$APT_TEST_CALLS")" -eq 1 ]
  [ "$(cat "$APT_TEST_CALLS")" = '-o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 install -y incus' ]
}

@test "apt errors unrelated to locking fail immediately with their exit status" {
  export APT_TEST_ERROR='E: The repository does not have a Release file.'
  export APT_TEST_STATUS=42

  run apt_get update

  [ "$status" -eq 42 ]
  [ "$(wc -l <"$APT_TEST_CALLS")" -eq 1 ]
  [[ "$output" == *"does not have a Release file"* ]]
  [[ "$output" != *"retrying"* ]]
}

@test "apt lock retries stop after the timeout" {
  export APT_TEST_FAILURES=100
  sleep() { SECONDS=$((SECONDS + 300)); }

  run apt_get update

  [ "$status" -eq 100 ]
  [ "$(wc -l <"$APT_TEST_CALLS")" -eq 2 ]
}
