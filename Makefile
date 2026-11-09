# ArcLatch build & test entry points. Requires Apple Command Line Tools with
# Swift 6.4 or later (the project builds against the 6.4.2 CLT; Swift Testing
# comes from the CLT, XCTest is not needed and not used).
# The test suite is hermetic: it needs no installed or running provider, no
# personal model paths, and no service-manager calls. Two checks do contact a
# live Splash install and are skipped unless you opt in:
#   ARC_LATCH_LIVE=1 make test   (also works on `swift test` directly)
# `make check` starts from clean so the toolchain-symlink wiping scenario
# (Swift Testing macro plugin missing from the CLT) is caught immediately.
# `build` is .PHONY because a local `build/` directory coexists with it.
.PHONY: check build test check-fallback

check:
	swift package clean
	swift build
	swift test

build:
	swift build

test:
	swift test

# Fallback if a Command Line Tools update wipes the Swift Testing plugin
# symlink: single-job compiles honor the test target's unsafe flag.
check-fallback:
	swift package clean
	SWIFT_ENABLE_EXPLICIT_MODULES=NO swift test
