# tedge-mosquitto

The official [thin-edge.io](https://thin-edge.io) build of the
[mosquitto](https://mosquitto.org) MQTT broker.

thin-edge.io controls this package so that it can be built consistently for all
of the supported target architectures, cross-compiled from a single host using
the [ziglang](https://ziglang.org) toolchain, and shipped with sensible defaults
for edge devices.

Only **one** mosquitto version is supported at a time. The pinned version is
defined in [`src/build.zig.zon`](src/build.zig.zon) and is updated over time as
new mosquitto releases are adopted.

## What you get

- statically linked (musl) broker + client binaries — no runtime dependencies
- a GNU/glibc variant (`tedge-mosquitto-gnu`) that ships a shared OpenSSL
- TLS support (with an option to disable it: `tedge-mosquitto-notls`)
- bridge support enabled
- no websocket / no systemd-notify support
- sensible default configuration under `/etc/mosquitto/conf.d/` (see
  [`packaging/conf`](packaging/conf))

Supported architectures: `amd64`, `arm64`, `armv7` (armhf), `armv6`, `riscv64`.

## Configuration defaults

The package installs `/etc/mosquitto/mosquitto.conf`, which enables persistence
and loads everything from `/etc/mosquitto/conf.d/`. The thin-edge.io defaults are
shipped as individual drop-ins so that upgrading the package never clobbers a
user's own `mosquitto.conf`:

| File | Purpose |
| ---- | ------- |
| `conf.d/10_buffer.conf` | raise the maximum message size |
| `conf.d/20_logging.conf` | log to syslog with sensible log types |
| `conf.d/30_local_listener.conf` | anonymous listener on `127.0.0.1:1883` |

## Build pre-requisites

- [ziglang](https://ziglang.org) (version pinned in [`.zig-version`](.zig-version))
- [just](https://github.com/casey/just) >= 1.15.0
- [goreleaser](https://github.com/goreleaser/goreleaser) >= 2.15 (coordinates the
  build and packaging)

> The mosquitto source code is downloaded automatically by the ziglang build
> system from the URL pinned in [`src/build.zig.zon`](src/build.zig.zon).

## Building

Clone the project and build all targets and packages (as a local snapshot):

```sh
just build
```

Build without TLS:

```sh
just WITH_TLS=false build
```

The resulting linux packages and tarballs are written to `dist/`:

```sh
ls -l dist/

# Using DNF (Fedora, RHEL, AmazonLinux)
dnf install dist/tedge-mosquitto*.rpm

# Using Debian/Ubuntu
apt-get install ./dist/tedge-mosquitto*.deb
```

Smoke test the freshly built host artifacts (starts the broker and does a
publish/subscribe round trip):

```sh
just smoke-test
```

### Building manually

To experiment with the zig build directly:

```sh
cd src
zig build --release=small -Doptimize=ReleaseSmall -DWITH_TLS=true
./zig-out/bin/mosquitto --help
```

## Releasing

Releases are cut by pushing a git tag. Tag the mosquitto version being shipped,
optionally with a packaging revision:

```sh
git tag 2.1.2      # first release of mosquitto 2.1.2
git push origin 2.1.2

git tag 2.1.2-2    # packaging-only rebuild of the same mosquitto version
git push origin 2.1.2-2
```

The [`release`](.github/workflows/release.yaml) workflow then:

1. builds every architecture / variant,
2. creates a **draft** GitHub release with the packages and tarballs attached,
3. publishes the packages and tarballs to the thin-edge.io Cloudsmith
   repository.

### Publishing configuration

Publishing is handled by [`ci/publish.sh`](ci/publish.sh) and driven by the
following secrets:

| Secret | Description | Default |
| ------ | ----------- | ------- |
| `PUBLISH_TOKEN` | Cloudsmith API token (configured org-wide) | — (publish step is skipped when unset) |
| `PUBLISH_OWNER` | Cloudsmith owner | `thinedge` |
| `PUBLISH_REPO` | Cloudsmith repository | `community` |

## CI

- [`build`](.github/workflows/build.yaml) — runs on every pull request: builds
  all targets (with and without TLS) and smoke tests the host artifacts.
- [`release`](.github/workflows/release.yaml) — runs on a pushed tag: builds,
  creates the GitHub release and publishes to Cloudsmith.

## License

The build tooling in this repository is licensed under the MIT license (see
[LICENSE](LICENSE)). mosquitto itself is licensed by the upstream project under
the EPL-1.0 / EDL-1.0 — refer to the mosquitto source for details.
