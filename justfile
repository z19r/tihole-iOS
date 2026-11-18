# tihole for iOS — task runner
# Run `just` or `just --list` to see recipes.

project := "Tihole.xcodeproj"
scheme := "Tihole"
package := "Packages/TiholeKit"

# Show available recipes
default:
    @just --list

# Generate the Xcode project from project.yml (needs `brew install xcodegen`)
gen:
    xcodegen generate

# Generate the project and open it in Xcode
open: gen
    open {{ project }}

# Run the PiholeKit and TiholeCore tests on the host (no simulator needed)
test *args:
    swift test --package-path {{ package }} {{ args }}

# Build the app for the iOS Simulator
build: gen
    xcodebuild build \
        -project {{ project }} \
        -scheme {{ scheme }} \
        -configuration Debug \
        -destination 'generic/platform=iOS Simulator' \
        CODE_SIGNING_ALLOWED=NO

# Everything CI runs
ci: test build

# Re-render the placeholder app icon
icon:
    python3 scripts/make_icon.py \
        Tihole/Assets.xcassets/AppIcon.appiconset/AppIcon.png

# Run the UI smoke test against the in-process mock Pi-hole
ui-test: gen
    # xcodebuild refuses to overwrite an existing result bundle.
    rm -rf TestResults.xcresult
    xcodebuild test \
        -project {{ project }} \
        -scheme {{ scheme }} \
        -destination "platform=iOS Simulator,id=$(scripts/pick_simulator.py)" \
        -resultBundlePath TestResults.xcresult

# Format the Python scripts (80 columns, see ruff.toml)
fmt:
    uvx ruff format scripts
    uvx ruff check --fix scripts

# Fail if the Python scripts are not formatted or lint-clean
fmt-check:
    uvx ruff format --check scripts
    uvx ruff check scripts

# Serve the website at http://localhost:8000
site:
    python3 scripts/site_data.py
    python3 -m http.server 8000 --directory site
