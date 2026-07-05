# Check

# Run all checks
check:
    #!/usr/bin/env bash
    set -euo pipefail
    failed=0
    skipped=()
    run() {
        echo "--- $1 ---"
        shift
        if ! "$@"; then
            failed=1
        fi
    }
    skip() {
        echo "--- $1 --- skipped ($2 not found)"
        skipped+=("$2 (brew install $3)")
    }
    run diff git diff --check
    if command -v zizmor &>/dev/null; then
        run audit zizmor --persona auditor .
    else
        skip audit zizmor zizmor
    fi
    if command -v pinprick &>/dev/null; then
        run pinprick-audit pinprick audit .
    else
        skip pinprick-audit pinprick pinprick
    fi
    if command -v lychee &>/dev/null; then
        run lychee lychee --config lychee.toml README.md
    else
        skip lychee lychee lychee
    fi
    if [ ${#skipped[@]} -gt 0 ]; then
        echo ""
        echo "Checks skipped due to missing tools:"
        for tool in "${skipped[@]}"; do
            echo "  - $tool"
        done
        failed=1
    fi
    exit "$failed"

# fleet:block audit
audit:
    zizmor --persona auditor .github/workflows/
# fleet:end

# fleet:block pinprick-audit
pinprick-audit:
    pinprick audit .
# fleet:end

# Check README links
lychee:
    lychee --config lychee.toml README.md

# Setup

# fleet:block install-hooks
# Install git hooks (DCO sign-off + pre-push checks). Run once per clone.
install-hooks:
    git config core.hooksPath .githooks
# fleet:end
