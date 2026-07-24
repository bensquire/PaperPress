.PHONY: test lint format bundle release clean

test:
	swift test

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
