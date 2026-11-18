#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_ROOT="$BATS_TEST_TMPDIR/root"
  TEST_HOME="$TEST_ROOT/home"
  TEST_BIN="$TEST_ROOT/bin"
  mkdir -p "$TEST_HOME/.oci" "$TEST_BIN"

  cat >"$TEST_BIN/terraform" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == version && "${2:-}" == -json ]]; then
  printf '%s\n' '{"terraform_version":"1.15.8"}'
else
  printf '%s\n' 'Terraform v1.15.8'
fi
EOF

  cat >"$TEST_BIN/oci" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  printf '%s\n' '3.90.3'
fi
exit 0
EOF
  chmod +x "$TEST_BIN/terraform" "$TEST_BIN/oci"

  cat >"$TEST_HOME/.oci/config" <<EOF
user=ocid1.user.test
fingerprint=00:11:22
tenancy=ocid1.tenancy.test
key_file=$TEST_HOME/.oci/oci_api_key.pem
region=us-chicago-1
EOF

  cat >"$TEST_ROOT/terraform.tfvars" <<'EOF'
compartment_id = "ocid1.tenancy.test"
region = "us-chicago-1"
ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest fixture"
EOF
}

run_preflight() {
  cd "$TEST_ROOT"
  run env \
    HOME="$TEST_HOME" \
    PATH="$TEST_BIN:/usr/bin:/bin" \
    OCI_CLI_CONFIG_FILE="$TEST_HOME/.oci/config" \
    "$REPO_ROOT/scripts/preflight.sh"
}

@test "preflight accepts an encrypted PKCS8 private-key footer" {
  cat >"$TEST_HOME/.oci/oci_api_key.pem" <<'EOF'
-----BEGIN ENCRYPTED PRIVATE KEY-----
fixture
-----END ENCRYPTED PRIVATE KEY-----
EOF
  chmod 600 "$TEST_HOME/.oci/oci_api_key.pem"

  run_preflight

  [ "$status" -eq 0 ]
  [[ "$output" == *"private key PEM format is clean"* ]]
  [[ "$output" == *"0 failed"* ]]
}

@test "preflight accepts an inline SSH public key without a key file" {
  cat >"$TEST_HOME/.oci/oci_api_key.pem" <<'EOF'
-----BEGIN PRIVATE KEY-----
fixture
-----END PRIVATE KEY-----
EOF
  chmod 600 "$TEST_HOME/.oci/oci_api_key.pem"
  run_preflight

  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh public key provided directly in terraform.tfvars"* ]]
  [[ "$output" == *"0 failed"* ]]
}

@test "preflight rejects missing and blank SSH public keys" {
  cat >"$TEST_HOME/.oci/oci_api_key.pem" <<'EOF'
-----BEGIN PRIVATE KEY-----
fixture
-----END PRIVATE KEY-----
EOF
  chmod 600 "$TEST_HOME/.oci/oci_api_key.pem"

  for assignment in '' 'ssh_public_key = ""' 'ssh_public_key = "   "' 'ssh_public_key = null' '# ssh_public_key = "commented-out"'; do
    cat >"$TEST_ROOT/terraform.tfvars" <<EOF
compartment_id = "ocid1.tenancy.test"
region = "us-chicago-1"
$assignment
EOF

    run_preflight

    [ "$status" -eq 1 ]
    [[ "$output" == *"set ssh_public_key to your SSH public key string"* ]]
  done
}
