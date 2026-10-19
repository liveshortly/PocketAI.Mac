#!/bin/bash
# Run the Mac XCUITest suite (MAC-02/03/05/08/11, UI-09/11).
# Ad-hoc signs the runner so it clears Gatekeeper without a Dev ID. The ONE
# remaining prerequisite is the automation/Accessibility authorization:
#   sudo DevToolsSecurity -enable      # one time, then this script runs green
# (or approve the Accessibility prompt macOS shows for the test runner).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild build-for-testing -scheme PocketAI -destination 'platform=macOS' \
  -derivedDataPath build-uitest \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual GENERATE_INFOPLIST_FILE=YES
xcodebuild test-without-building -scheme PocketAI -destination 'platform=macOS' \
  -only-testing:PocketAIUITests -derivedDataPath build-uitest \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120
