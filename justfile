set dotenv-load

# Package name. The no-TLS build gets a distinct name so both can coexist in the
# package repository.
export PACKAGE_NAME := env("PACKAGE_NAME", if WITH_TLS == "true" { "tedge-mosquitto" } else { "tedge-mosquitto-notls" })

# Build mosquitto with TLS support. Accepts either 'true' or 'false'.
export WITH_TLS := env("WITH_TLS", "true")

# How OpenSSL is linked into the GNU builds (see src/build.zig). Accepts:
#   static  - bundle ~3MB of OpenSSL into every binary (self-contained)
#   shared  - build & ship one libssl.so.3/libcrypto.so.3 shared by all binaries
#             (much smaller, still self-contained, works cross-compiled) [default]
#   system  - link the target's system OpenSSL (native builds only)
export OPENSSL := env("OPENSSL", "shared")

# Version used for local/snapshot builds. Real releases derive the version from
# the git tag being pushed; this only affects the file names of local builds.
VERSION := env("VERSION", "2.1.2")

# output directory for the linux packages and tarballs
OUTPUT_DIR := "dist"

# Build and package all artifacts as a snapshot (never publishes). This is what
# local development and the PR checks use.
build *ARGS='':
    GORELEASER_CURRENT_TAG={{VERSION}} goreleaser release --clean --snapshot --parallelism 1 --skip=announce,publish,validate {{ARGS}}

# Full release: goreleaser derives the version from the pushed git tag, builds
# every artifact and creates the (draft) GitHub release. Run by CI on a tag.
# Note: --parallelism 1 works around an openssl-dependency race when building
# multiple targets in parallel.
release *ARGS='':
    goreleaser release --clean --auto-snapshot --parallelism 1 {{ARGS}}

# Build using the native zig command for the host target (helps with debugging
# the build.zig itself).
build-native *ARGS='':
    cd src && zig build --release=small -Doptimize=ReleaseSmall -DWITH_TLS={{WITH_TLS}} {{ARGS}}
    @echo
    @echo "Build OK. Execute the binary using"
    @echo ""
    @echo "  ./src/zig-out/bin/mosquitto"
    @echo

# Smoke test the freshly built host (amd64) artifacts: start the broker and do a
# publish/subscribe round trip with the bundled clients.
smoke-test *ARGS='':
    ./ci/smoke-test.sh --path "{{OUTPUT_DIR}}" {{ARGS}}

# Remove the build outputs
clean:
    rm -rf {{OUTPUT_DIR}}

# Publish the linux packages (*.deb/*.rpm/*.apk/...) and tarballs to Cloudsmith
publish *args="":
    ./ci/publish.sh --path "{{OUTPUT_DIR}}" {{args}}
