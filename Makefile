.PHONY: test lint format bundle release clean

# Release build: the pixel loops are slow unoptimised (the suite takes
# 30 s from clean in release, 2.5 min in debug).
test:
	swift test -c release

lint:
	swift format lint --strict --recursive Sources Tests Package.swift

format:
	swift format --in-place --recursive Sources Tests Package.swift

bundle:
	./bundle.sh

release:
	./release.sh

clean:
	swift package clean && rm -rf PaperPress.app PaperPress.dmg
