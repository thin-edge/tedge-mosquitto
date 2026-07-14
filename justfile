set dotenv-load

# Build mosquitto with TLS support. Accepts either 'true' or 'false'.
export WITH_TLS := env("WITH_TLS", "true")

# Package base name is normally supplied by each goreleaser config's project_name
# (tedge-mosquitto-musl / -gnu). PACKAGE_NAME overrides it if set in the
# environment; build-libc also sets it for the no-TLS build (tedge-mosquitto-notls-<libc>)
# so that variant gets a distinct name and can coexist in the package repo.

# How OpenSSL is linked into the GNU builds (see src/build.zig). Accepts:
#   static  - bundle ~3MB of OpenSSL into every binary (self-contained)
#   shared  - build & ship one libssl.so.3/libcrypto.so.3 shared by all binaries
#             (much smaller, still self-contained, works cross-compiled) [default]
#   system  - link the target's system OpenSSL (native builds only)
export OPENSSL := env("OPENSSL", "shared")

# Version used for local/snapshot builds. Real releases derive the version from
# the git tag being pushed; this only affects the file names of local builds.
VERSION := env("VERSION", "2.1.2")

# output directories for the linux packages and tarballs. The build is split by
# libc into two goreleaser configs (.goreleaser.musl.yaml / .goreleaser.gnu.yaml)
# so the two flavors can build in parallel CI jobs; each writes to its own dir.
# NOTE: keep these in sync with `dist:` in the respective goreleaser configs
# (used by clean/publish to find each flavor's artifacts).
OUTPUT_DIR := "dist-musl"
GNU_OUTPUT_DIR := "dist-gnu"

# Snapshot-build a single libc flavor (musl|gnu). Never publishes. This is the
# per-flavor unit the CI matrix runs in parallel. For the no-TLS build the
# package name gets a distinct -notls-<libc> suffix (otherwise project_name wins).
build-libc LIBC *ARGS='':
    {{ if WITH_TLS == "true" { "" } else { "PACKAGE_NAME=tedge-mosquitto-notls-" + LIBC } }} GORELEASER_CURRENT_TAG={{VERSION}} goreleaser release --config .goreleaser.{{LIBC}}.yaml --clean --snapshot --parallelism 1 --skip=announce,publish,validate {{ARGS}}

# Build and package all artifacts (both libc flavors) as a snapshot. musl lands
# in {{OUTPUT_DIR}}, gnu in {{GNU_OUTPUT_DIR}} (each output dir is set via `dist:`
# in the respective goreleaser config). This is what local development uses; the
# PR checks run the two flavors as separate `build-libc` matrix jobs instead.
build *ARGS='':
    just build-libc musl {{ARGS}}
    just build-libc gnu {{ARGS}}

# Full release: goreleaser derives the version from the pushed git tag and builds
# every artifact. musl runs first and creates the single (draft) GitHub release;
# gnu runs second and appends its artifacts to that same release (release.mode:
# append in .goreleaser.gnu.yaml). Order matters — the creator must run first.
# Run by CI on a tag. Note: --parallelism 1 works around an openssl-dependency
# race when building multiple targets in parallel.
#
# Do NOT use --auto-snapshot here: this recipe is for real tagged releases only
# (use `just build` for local snapshots). --auto-snapshot silently downgrades a
# run to a snapshot if the working tree is dirty, which skips the GitHub release
# upload entirely — the failure mode that dropped the gnu artifacts. The dirtying
# culprit (the CI zig cache) is now gitignored; --skip=validate on the gnu run is
# belt-and-suspenders so a stray untracked file can never re-trigger it (the musl
# run already validated the git state, so re-validating gnu adds nothing).
release *ARGS='':
    goreleaser release --config .goreleaser.musl.yaml --clean --parallelism 1 {{ARGS}}
    goreleaser release --config .goreleaser.gnu.yaml --clean --parallelism 1 --skip=validate {{ARGS}}

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
# publish/subscribe round trip with the bundled clients. Defaults to the musl
# flavor in {{OUTPUT_DIR}}; for gnu pass e.g. `just smoke-test --libc gnu --path {{GNU_OUTPUT_DIR}}`.
smoke-test *ARGS='':
    ./ci/smoke-test.sh --path "{{OUTPUT_DIR}}" {{ARGS}}

# Remove the build outputs
clean:
    rm -rf {{OUTPUT_DIR}} {{GNU_OUTPUT_DIR}}

# Publish the linux packages (*.deb/*.rpm/*.apk) to Cloudsmith.
# NOTE: for now only the gnu packages are published, and the raw tarballs are
# skipped. To also publish the musl packages, re-add:
#     ./ci/publish.sh --path "{{OUTPUT_DIR}}" {{args}}
# and drop --skip-tarballs to also upload the raw *.tar.gz artifacts.
publish *args="":
    ./ci/publish.sh --path "{{GNU_OUTPUT_DIR}}" --skip-tarballs {{args}}
