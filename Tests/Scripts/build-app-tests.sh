#!/bin/zsh
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
fixture_bin="$repository_root/Tests/Scripts/Fixtures/bin"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/batteries-included-build-tests.XXXXXX")"
test_directory="$(cd "$test_directory" && pwd -P)"
trap 'rm -rf -- "$test_directory"' EXIT

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

prepare_repository() {
  local destination="$1"
  mkdir -p "$destination/scripts" "$destination/Resources"
  cp "$repository_root/scripts/build-app.sh" "$destination/scripts/build-app.sh"
  cp "$repository_root/Resources/Info.plist" "$destination/Resources/Info.plist"
  chmod +x "$destination/scripts/build-app.sh"
}

run_signing_case() {
  local label="$1"
  local identity="$2"
  local expected_timestamp="$3"
  local expected_identity="$4"
  local case_root="$test_directory/$label"
  local test_repository="$case_root/repository"
  local codesign_log="$case_root/codesign.log"

  prepare_repository "$test_repository"

  if [[ "$identity" == "__UNSET__" ]]; then
    env -u CODE_SIGN_IDENTITY \
      PATH="$fixture_bin:$PATH" \
      SWIFT_EXECUTABLE="$fixture_bin/swift" \
      CODESIGN_EXECUTABLE="$fixture_bin/codesign" \
      BUILD_APP_CODESIGN_LOG="$codesign_log" \
      "$test_repository/scripts/build-app.sh"
  else
    CODE_SIGN_IDENTITY="$identity" \
      PATH="$fixture_bin:$PATH" \
      SWIFT_EXECUTABLE="$fixture_bin/swift" \
      CODESIGN_EXECUTABLE="$fixture_bin/codesign" \
      BUILD_APP_CODESIGN_LOG="$codesign_log" \
      "$test_repository/scripts/build-app.sh"
  fi

  [[ -f "$codesign_log" ]] || fail "$label did not invoke the configured codesign executable"

  local app_bundle="$test_repository/dist/Batteries Included.app"
  local expected_sign="--force|--options|runtime|$expected_timestamp|--sign|$expected_identity|$app_bundle"
  local expected_verify="--verify|--deep|--strict|--verbose=2|$app_bundle"
  local actual_sign="$(sed -n '1p' "$codesign_log")"
  local actual_verify="$(sed -n '2p' "$codesign_log")"
  [[ "$actual_sign" == "$expected_sign" ]] || \
    fail "$label planned the wrong signing command: expected '$expected_sign', got '$actual_sign'"
  [[ "$actual_verify" == "$expected_verify" ]] || \
    fail "$label planned the wrong verification command: expected '$expected_verify', got '$actual_verify'"
  [[ "$(wc -l < "$codesign_log" | tr -d ' ')" == "2" ]] || \
    fail "$label invoked codesign an unexpected number of times"
}

test_signing_modes() {
  run_signing_case "ad-hoc-unset" "__UNSET__" "--timestamp=none" "-"
  run_signing_case "ad-hoc-explicit" "-" "--timestamp=none" "-"
  run_signing_case \
    "developer-id" \
    "Developer ID Application: Test Example (TESTTEAM)" \
    "--timestamp" \
    "Developer ID Application: Test Example (TESTTEAM)"
}

test_symlinked_dist_guard() {
  local case_root="$test_directory/symlinked-dist"
  local test_repository="$case_root/repository"
  local outside_directory="$case_root/outside"
  local outside_app="$outside_directory/Batteries Included.app"
  local output="$case_root/build-output.log"

  prepare_repository "$test_repository"
  mkdir -p "$outside_app"
  touch "$outside_directory/outside-sentinel" "$outside_app/original-app-sentinel"
  ln -s "$outside_directory" "$test_repository/dist"

  set +e
  PATH="$fixture_bin:$PATH" \
    SWIFT_EXECUTABLE="$fixture_bin/swift" \
    CODESIGN_EXECUTABLE="$fixture_bin/codesign" \
    BUILD_APP_CODESIGN_LOG="$case_root/codesign.log" \
    "$test_repository/scripts/build-app.sh" > "$output" 2>&1
  local exit_status=$?
  set -e

  [[ -f "$outside_directory/outside-sentinel" ]] || fail "outside sentinel was removed"
  [[ -f "$outside_app/original-app-sentinel" ]] || fail "outside app was removed or replaced"
  [[ "$exit_status" -ne 0 ]] || fail "symlinked dist directory was accepted"
}

case "${1:-all}" in
  signing)
    test_signing_modes
    ;;
  symlink)
    test_symlinked_dist_guard
    ;;
  all)
    test_signing_modes
    test_symlinked_dist_guard
    ;;
  *)
    fail "unknown test selection: $1"
    ;;
esac

print -- "build-app script tests passed"
