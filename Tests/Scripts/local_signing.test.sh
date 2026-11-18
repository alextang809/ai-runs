#!/usr/bin/env bash
# Exercises copies of the signing scripts with fake macOS commands only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/airuns-signing-tests.XXXXXX")"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT
passed=0
failed=0

new_case() {
    AIRUNS_TEST_ROOT="$TEST_ROOT/$1"
    AIRUNS_TEST_LOG="$AIRUNS_TEST_ROOT/commands"
    export AIRUNS_TEST_ROOT AIRUNS_TEST_LOG
    export AIRUNS_TEST_IDENTITIES=present AIRUNS_TEST_SIGN_FAIL=0 AIRUNS_TEST_VERIFY_FAIL=0 AIRUNS_TEST_ALLOW_INSTALL=0
    mkdir -p "$AIRUNS_TEST_ROOT/repo/Scripts" "$AIRUNS_TEST_ROOT/stubs"
    cp "$ROOT/Scripts/"{make_signing_identity,install_local,package_app}.sh "$AIRUNS_TEST_ROOT/repo/Scripts/"
    : > "$AIRUNS_TEST_LOG"
    cat > "$AIRUNS_TEST_ROOT/stubs/security" <<'STUB'
#!/bin/bash
printf 'security %s\n' "$1" >> "$AIRUNS_TEST_LOG"
case "$1" in
find-identity)
    case "$AIRUNS_TEST_IDENTITIES" in
    present) echo '1) EXAMPLE "AI Runs Local Signing" (CSSMERR_TP_NOT_TRUSTED)' ;;
    absent) echo '0 identities found' ;;
    large)
        echo '1) EXAMPLE "AI Runs Local Signing" (CSSMERR_TP_NOT_TRUSTED)'
        /usr/bin/awk 'BEGIN { for (i=0; i<10000; i++) print "2) EXAMPLE unrelated identity" }' ;;
    error) exit 1 ;;
    esac ;;
import) exit 0 ;;
*) echo 'Unexpected keychain command' >&2; exit 91 ;;
esac
STUB
    cat > "$AIRUNS_TEST_ROOT/stubs/codesign" <<'STUB'
#!/bin/bash
if [[ " $* " == *' --verify '* ]]; then
    echo 'codesign verify' >> "$AIRUNS_TEST_LOG"
    exit "$AIRUNS_TEST_VERIFY_FAIL"
fi
if [[ " $* " == *' --sign - '* ]]; then
    echo 'codesign adhoc' >> "$AIRUNS_TEST_LOG"
else
    echo 'codesign identity' >> "$AIRUNS_TEST_LOG"
fi
last_argument="${!#}"
if [[ "${last_argument##*/}" == "signing-check" ]]; then
    /usr/bin/grep -q 'Always Allow' "$AIRUNS_TEST_ROOT/output" || exit 93
fi
exit "$AIRUNS_TEST_SIGN_FAIL"
STUB
    cat > "$AIRUNS_TEST_ROOT/stubs/mktemp" <<'STUB'
#!/bin/bash
path="$(/usr/bin/mktemp -d "$AIRUNS_TEST_ROOT/check.XXXXXX")"
printf '%s\n' "$path" >> "$AIRUNS_TEST_ROOT/temp-created"
printf '%s\n' "$path"
STUB
    cat > "$AIRUNS_TEST_ROOT/stubs/rm" <<'STUB'
#!/bin/bash
for argument in "$@"; do
    case "$argument" in
    -* ) ;;
    '/Applications/AI Runs.app')
        if [[ "$AIRUNS_TEST_ALLOW_INSTALL" == "1" ]]; then
            echo 'remove installed' >> "$AIRUNS_TEST_LOG"
            exit 0
        fi
        echo 'forbidden removal' >> "$AIRUNS_TEST_LOG"; exit 92 ;;
    "$AIRUNS_TEST_ROOT"/* | build/* ) ;;
    *) echo 'forbidden removal' >> "$AIRUNS_TEST_LOG"; exit 92 ;;
    esac
done
/bin/rm "$@"
STUB
    for command in osascript pkill ditto open sleep; do
        cat > "$AIRUNS_TEST_ROOT/stubs/$command" <<'STUB'
#!/bin/bash
printf '%s\n' "${0##*/}" >> "$AIRUNS_TEST_LOG"
STUB
    done
    chmod +x "$AIRUNS_TEST_ROOT/stubs/"*
}

run_script() {
    (cd "$AIRUNS_TEST_ROOT/repo" && PATH="$AIRUNS_TEST_ROOT/stubs:$PATH" bash "Scripts/$1") > "$AIRUNS_TEST_ROOT/output" 2>&1
}

has_command() { /usr/bin/grep -qxF "$1" "$AIRUNS_TEST_LOG"; }
expect() {
    if "$@"; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: $*"; fi
}
no_command() { ! has_command "$1"; }
before_command() {
    local first second
    first="$(/usr/bin/grep -nFx "$1" "$AIRUNS_TEST_LOG" | /usr/bin/sed -n '1s/:.*//p')"
    second="$(/usr/bin/grep -nFx "$2" "$AIRUNS_TEST_LOG" | /usr/bin/sed -n '1s/:.*//p')"
    [[ -n "$first" && -n "$second" && "$first" -lt "$second" ]]
}
temp_cleaned() {
    [[ -f "$AIRUNS_TEST_ROOT/temp-created" ]] || return 1
    while IFS= read -r path; do [[ ! -e "$path" ]] || return 1; done < "$AIRUNS_TEST_ROOT/temp-created"
}
setup_fake_package() {
    cat > "$AIRUNS_TEST_ROOT/repo/Scripts/package_app.sh" <<'STUB'
#!/bin/bash
echo 'package' >> "$AIRUNS_TEST_LOG"
printf 'package-policy %s %s\n' "${REQUIRE_SIGN_IDENTITY:-unset}" "${SIGN_IDENTITY:-unset}" >> "$AIRUNS_TEST_LOG"
mkdir -p 'build/AI Runs.app'
STUB
    chmod +x "$AIRUNS_TEST_ROOT/repo/Scripts/package_app.sh"
}

new_case created
export AIRUNS_TEST_IDENTITIES=absent
expect run_script make_signing_identity.sh
expect has_command 'security import'
expect has_command 'codesign identity'
expect has_command 'codesign verify'
expect temp_cleaned
expect /usr/bin/grep -q 'Created' "$AIRUNS_TEST_ROOT/output"

new_case reused
expect run_script make_signing_identity.sh
expect has_command 'codesign identity'
expect has_command 'codesign verify'
expect no_command 'security import'
expect temp_cleaned
expect /usr/bin/grep -q 'Always Allow' "$AIRUNS_TEST_ROOT/output"

new_case denied
export AIRUNS_TEST_SIGN_FAIL=1
if run_script make_signing_identity.sh; then expect false; else expect true; fi
expect has_command 'codesign identity'
expect no_command 'codesign verify'
expect no_command 'security import'
expect temp_cleaned

new_case verification_denied
export AIRUNS_TEST_VERIFY_FAIL=1
if run_script make_signing_identity.sh; then expect false; else expect true; fi
expect has_command 'codesign identity'
expect has_command 'codesign verify'
expect no_command 'security import'
expect temp_cleaned

new_case query_error
export AIRUNS_TEST_IDENTITIES=error
if run_script make_signing_identity.sh; then expect false; else expect true; fi
expect no_command 'security import'
expect no_command 'codesign identity'

new_case missing
setup_fake_package
export AIRUNS_TEST_IDENTITIES=absent
if run_script install_local.sh; then expect false; else expect true; fi
expect no_command package
expect no_command osascript
expect no_command pkill
expect no_command ditto

new_case install_query_error
setup_fake_package
export AIRUNS_TEST_IDENTITIES=error
if run_script install_local.sh; then expect false; else expect true; fi
expect no_command package
expect no_command osascript
expect no_command pkill

new_case corrupt
setup_fake_package
export AIRUNS_TEST_VERIFY_FAIL=1
if run_script install_local.sh; then expect false; else expect true; fi
expect has_command package
expect has_command 'codesign verify'
expect no_command osascript
expect no_command pkill
expect no_command ditto

new_case install_success
setup_fake_package
export AIRUNS_TEST_ALLOW_INSTALL=1
expect run_script install_local.sh
expect has_command 'package-policy 1 AI Runs Local Signing'
expect has_command 'codesign verify'
expect before_command 'codesign verify' osascript
expect before_command 'codesign verify' pkill
expect before_command 'codesign verify' 'remove installed'
expect before_command 'remove installed' ditto
expect has_command open

new_case ci_package
export AIRUNS_TEST_IDENTITIES=absent
mkdir -p "$AIRUNS_TEST_ROOT/repo/Resources" "$AIRUNS_TEST_ROOT/repo/BrowserExtension" "$AIRUNS_TEST_ROOT/products"
printf 'example' > "$AIRUNS_TEST_ROOT/products/AIRuns"
printf 'example' > "$AIRUNS_TEST_ROOT/products/airuns-hook"
printf 'example' > "$AIRUNS_TEST_ROOT/repo/Resources/AppIcon.icns"
cat > "$AIRUNS_TEST_ROOT/stubs/swift" <<'STUB'
#!/bin/bash
if [[ " $* " == *' --show-bin-path '* ]]; then echo "$AIRUNS_TEST_ROOT/products"; fi
STUB
cat > "$AIRUNS_TEST_ROOT/stubs/iconutil" <<'STUB'
#!/bin/bash
while [[ $# -gt 0 ]]; do
    if [[ "$1" == -o ]]; then shift; printf 'example' > "$1"; exit 0; fi
    shift
done
STUB
chmod +x "$AIRUNS_TEST_ROOT/stubs/"{swift,iconutil}
expect run_script package_app.sh
expect has_command 'codesign adhoc'
: > "$AIRUNS_TEST_LOG"
export REQUIRE_SIGN_IDENTITY=1
if run_script package_app.sh; then expect false; else expect true; fi
expect no_command 'codesign adhoc'
expect no_command 'codesign identity'
export AIRUNS_TEST_IDENTITIES=error
: > "$AIRUNS_TEST_LOG"
if run_script package_app.sh; then expect false; else expect true; fi
expect no_command 'codesign adhoc'
expect no_command 'codesign identity'

export AIRUNS_TEST_IDENTITIES=large
: > "$AIRUNS_TEST_LOG"
expect run_script package_app.sh
expect has_command 'codesign identity'
expect no_command 'codesign adhoc'
unset REQUIRE_SIGN_IDENTITY

printf 'local signing: %s checks passed, %s failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
