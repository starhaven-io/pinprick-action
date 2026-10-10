# Check

# Run all checks
check:
    ruby .github/scripts/check.rb

# Install locked repository test dependencies
setup:
    bundle install

# Run Ruby release-policy tests
test:
    bundle exec ruby -e 'Dir["test/*_test.rb"].sort.each { |file| require File.expand_path(file) }'

# fleet:block audit
audit:
    zizmor --strict-collection --persona auditor .github/workflows/
# fleet:end

# fleet:block pinprick-audit
pinprick-audit:
    pinprick audit .
# fleet:end

# Check README links
lychee:
    lychee --config lychee.toml README.md RELEASING.md SECURITY.md

# Setup

# fleet:block install-hooks
# Install git hooks (AI trailer guard + DCO sign-off + pre-push checks). Run once per clone.
install-hooks:
    git config core.hooksPath .githooks
# fleet:end
