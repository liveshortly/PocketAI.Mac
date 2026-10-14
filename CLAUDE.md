# PocketAI for Mac

SwiftUI app. Shared code lives in ../PocketAI.Core/swift (PocketKit, PocketUI).
Design spec: ../strategy/02-design-system.md. Tasks: ../strategy/06-tasks-mac.md.

## Build & test
- Build Core first: `cd ../PocketAI.Core && scripts/build-xcframework.sh`
- Generate project: `xcodegen generate`
- Build: `xcodebuild -scheme PocketAI -destination 'platform=macOS' build`
- Tests: `xcodebuild test -scheme PocketAI -destination 'platform=macOS'`

## Rules
- Never edit PocketAI.xcodeproj by hand; edit project.yml.
- Colors, fonts, spacing only from PocketUI tokens.
- Consume PocketUI; request missing components from L5 via issues.
