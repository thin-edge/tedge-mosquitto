const std = @import("std");
const zon = @import("build.zig.zon");

// How OpenSSL is linked into the broker, plugins and tools.
//   - static (default): the vendored OpenSSL is statically linked into every
//     binary — fully self-contained but ~3MB of OpenSSL per binary.
//   - shared: the vendored static OpenSSL is converted into shared libcrypto.so
//     /libssl.so (one copy, shipped alongside the binaries and found via rpath)
//     so all binaries share it. Self-contained AND small; works cross-compiled.
//   - system: link the target's system libssl/libcrypto (smallest; runtime must
//     provide OpenSSL). Relies on pkg-config, so it is native-build only.
const OpensslMode = enum { static, shared, system };

const OpensslLink = struct {
    mode: OpensslMode,
    // headers: vendored include tree (static/shared). null for system (pkg-config).
    include_tree: ?std.Build.LazyPath = null,
    // static: vendored static libraries linked directly into each binary.
    libssl: ?*std.Build.Step.Compile = null,
    libcrypto: ?*std.Build.Step.Compile = null,
    // shared: the converted shared libraries, linked dynamically.
    ssl_so: ?std.Build.LazyPath = null,
    crypto_so: ?std.Build.LazyPath = null,
    // Debian-style multiarch triple (e.g. "aarch64-linux-gnu") used to add the
    // distro's arch-specific lib dir to the rpath as a system fallback. null when
    // OpenSSL is not linked dynamically (static mode).
    multiarch: ?[]const u8 = null,
    // Whether the target is 64-bit (controls the lib64 fallback used by the RPM
    // family: Fedora / RHEL / Amazon Linux / openSUSE).
    lib64: bool = false,

    fn apply(self: OpensslLink, m: *std.Build.Module) void {
        switch (self.mode) {
            .static => {
                m.addIncludePath(self.include_tree.?);
                m.linkLibrary(self.libssl.?);
                m.linkLibrary(self.libcrypto.?);
            },
            .shared => {
                m.addIncludePath(self.include_tree.?);
                // Link the shared .so files dynamically (DT_NEEDED via their
                // SONAMEs). rpath covers both the installed package layout
                // (binaries in /usr/bin, libs in /usr/lib/mosquitto) and a
                // relocatable archive layout ($ORIGIN-relative).
                m.addObjectFile(self.ssl_so.?);
                m.addObjectFile(self.crypto_so.?);
                m.addRPathSpecial("$ORIGIN"); // plugin .so sitting next to the openssl .so
                m.addRPathSpecial("$ORIGIN/lib"); // archive layout: binary at root, libs in lib/
                m.addRPathSpecial("$ORIGIN/../lib/mosquitto"); // package layout: /usr/bin -> /usr/lib/mosquitto
                m.addRPathSpecial("/usr/lib/mosquitto");
                self.addSystemFallbackRpaths(m);
            },
            .system => {
                m.linkSystemLibrary("ssl", .{});
                m.linkSystemLibrary("crypto", .{});
                self.addSystemFallbackRpaths(m);
            },
        }
    }

    // Add the common distro lib dirs to the rpath so the system OpenSSL is found
    // as a fallback without needing LD_LIBRARY_PATH. These come AFTER the packaged
    // paths, so a shipped .so still wins, and any dir that doesn't exist on a
    // given distro is simply skipped by the loader. Covers:
    //   - Debian/Ubuntu multiarch:        /usr/lib/<triple>, /lib/<triple>
    //   - RPM family (Fedora/RHEL/AL/SUSE): /usr/lib64, /lib64  (64-bit only)
    //   - Arch/Alpine/generic & 32-bit:    /usr/lib, /lib
    fn addSystemFallbackRpaths(self: OpensslLink, m: *std.Build.Module) void {
        const b = m.owner;
        if (self.multiarch) |ma| {
            m.addRPathSpecial(b.fmt("/usr/lib/{s}", .{ma}));
            m.addRPathSpecial(b.fmt("/lib/{s}", .{ma}));
        }
        if (self.lib64) {
            m.addRPathSpecial("/usr/lib64");
            m.addRPathSpecial("/lib64");
        }
        m.addRPathSpecial("/usr/lib");
        m.addRPathSpecial("/lib");
    }
};

// Convert a vendored static OpenSSL archive into a shared library by force-
// loading every object (--whole-archive) and exporting its symbols. extra_sos
// are additional shared libs to link (libssl.so needs libcrypto.so), recorded
// as DT_NEEDED via their SONAMEs.
fn opensslStaticToShared(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    static_lib: *std.Build.Step.Compile,
    soname: []const u8,
    extra_sos: []const std.Build.LazyPath,
) std.Build.LazyPath {
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    const cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-target", triple, "-shared", "-Wl,-s" });
    cmd.addArg("-Wl,--whole-archive");
    cmd.addFileArg(static_lib.getEmittedBin());
    cmd.addArg("-Wl,--no-whole-archive");
    for (extra_sos) |so| cmd.addFileArg(so);
    cmd.addArg(b.fmt("-Wl,-soname,{s}", .{soname}));
    cmd.addArg("-o");
    return cmd.addOutputFileArg(soname);
}

pub fn build(b: *std.Build) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    const alloc = gpa.allocator();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const with_tls = b.option(bool, "WITH_TLS", "Build mosquitto with TLS") orelse true;
    const openssl_mode = b.option(OpensslMode, "OPENSSL", "How to link OpenSSL: 'static' (bundled into every binary, default), 'shared' (build & ship one shared libssl/libcrypto for all binaries), or 'system' (link the target's system OpenSSL — native builds only)") orelse .static;
    const version = b.option([]const u8, "version", "mosquitto version string") orelse zon.version;
    const with_dynamic_security = b.option(bool, "WITH_DYNAMIC_SECURITY", "Build dynamic-security plugin .so") orelse true;
    const with_persist_sqlite = b.option(bool, "WITH_PERSIST_SQLITE", "Build persist-sqlite plugin .so") orelse true;
    const with_acl_file_plugin = b.option(bool, "WITH_ACL_FILE_PLUGIN", "Build acl-file plugin .so") orelse true;
    const with_password_file_plugin = b.option(bool, "WITH_PASSWORD_FILE_PLUGIN", "Build password-file plugin .so") orelse true;
    const with_sparkplug_aware = b.option(bool, "WITH_SPARKPLUG_AWARE", "Build sparkplug-aware plugin .so") orelse true;

    // Additional mosquitto CLI tools (clients + apps). Each can be toggled
    // independently. Note: mosquitto_passwd and mosquitto_ctrl require TLS
    // (OpenSSL) upstream and are skipped automatically when WITH_TLS=false.
    const with_client_pub = b.option(bool, "WITH_CLIENT_PUB", "Build mosquitto_pub") orelse true;
    const with_client_sub = b.option(bool, "WITH_CLIENT_SUB", "Build mosquitto_sub") orelse true;
    const with_client_rr = b.option(bool, "WITH_CLIENT_RR", "Build mosquitto_rr") orelse true;
    const with_app_passwd = b.option(bool, "WITH_APP_PASSWD", "Build mosquitto_passwd (requires TLS)") orelse true;
    const with_app_ctrl = b.option(bool, "WITH_APP_CTRL", "Build mosquitto_ctrl (requires TLS)") orelse true;
    const with_app_db_dump = b.option(bool, "WITH_APP_DB_DUMP", "Build mosquitto_db_dump") orelse true;
    const with_app_signal = b.option(bool, "WITH_APP_SIGNAL", "Build mosquitto_signal") orelse true;

    const mosquitto = b.addExecutable(.{
        .name = "mosquitto",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });

    const mosquitto_dep = b.dependency("mosquitto_src", .{});

    mosquitto.root_module.addIncludePath(mosquitto_dep.path(""));
    mosquitto.root_module.addIncludePath(mosquitto_dep.path("src"));
    mosquitto.root_module.addIncludePath(mosquitto_dep.path("common"));
    mosquitto.root_module.addIncludePath(mosquitto_dep.path("lib"));
    mosquitto.root_module.addIncludePath(mosquitto_dep.path("libcommon"));
    mosquitto.root_module.addIncludePath(mosquitto_dep.path("deps"));
    // builtin websockets: http_client.c/http_serv.c do #include "picohttpparser.h"
    mosquitto.root_module.addIncludePath(mosquitto_dep.path("deps/picohttpparser"));
    mosquitto.root_module.addIncludePath(mosquitto_dep.path("include"));

    const cjson_dep = b.dependency("cjson", .{});
    const mkdir_cjson = b.addSystemCommand(&[_][]const u8{ "mkdir", "-p", "cjson" });
    const copy_cjson = b.addSystemCommand(&[_][]const u8{"cp"});
    copy_cjson.addFileArg(cjson_dep.path("cJSON.h"));
    copy_cjson.addArg("cjson/cJSON.h");
    copy_cjson.step.dependOn(&mkdir_cjson.step);
    mosquitto.step.dependOn(&copy_cjson.step);
    mosquitto.root_module.addIncludePath(b.path("."));
    mosquitto.root_module.addCSourceFile(.{ .file = cjson_dep.path("cJSON.c"), .flags = &.{} });

    const sqlite_dep = b.dependency("sqlite", .{});
    mosquitto.root_module.addIncludePath(sqlite_dep.path("."));
    mosquitto.root_module.addCSourceFile(.{ .file = sqlite_dep.path("sqlite3.c"), .flags = &.{} });

    const microhttpd = b.dependency("microhttpd", .{});
    mosquitto.root_module.addIncludePath(microhttpd.path("src/include"));

    // openssl_link describes how OpenSSL is linked; it is reused by the broker,
    // plugins and tools. null when TLS is disabled. The vendored OpenSSL is built
    // once and shared by all binaries: in 'static' mode each statically links it;
    // in 'shared' mode it is converted to .so files all binaries link; in
    // 'system' mode no OpenSSL is built (the target's system OpenSSL is used).
    // Debian-style multiarch triple (arch-linux-abi, e.g. aarch64-linux-gnu),
    // used as a system-OpenSSL fallback rpath for the dynamically-linked modes.
    const multiarch = b.fmt("{s}-linux-{s}", .{
        @tagName(target.result.cpu.arch),
        @tagName(target.result.abi),
    });
    const lib64 = target.result.ptrBitWidth() == 64;
    var openssl_link: ?OpensslLink = null;
    if (with_tls) {
        switch (openssl_mode) {
            .system => openssl_link = .{ .mode = .system, .multiarch = multiarch, .lib64 = lib64 },
            .static => {
                const openssl = b.dependency("openssl", .{ .target = target, .optimize = optimize });
                const libssl = openssl.artifact("ssl");
                openssl_link = .{
                    .mode = .static,
                    .include_tree = libssl.getEmittedIncludeTree(),
                    .libssl = libssl,
                    .libcrypto = openssl.artifact("crypto"),
                };
            },
            .shared => {
                const openssl = b.dependency("openssl", .{ .target = target, .optimize = optimize });
                const libssl = openssl.artifact("ssl");
                const libcrypto = openssl.artifact("crypto");
                // libcrypto.so.3 first; libssl.so.3 links it (DT_NEEDED).
                const crypto_so = opensslStaticToShared(b, target, libcrypto, "libcrypto.so.3", &.{});
                const ssl_so = opensslStaticToShared(b, target, libssl, "libssl.so.3", &.{crypto_so});
                openssl_link = .{
                    .mode = .shared,
                    .include_tree = libssl.getEmittedIncludeTree(),
                    .ssl_so = ssl_so,
                    .crypto_so = crypto_so,
                    .multiarch = multiarch,
                    .lib64 = lib64,
                };
                b.getInstallStep().dependOn(&b.addInstallLibFile(crypto_so, "libcrypto.so.3").step);
                b.getInstallStep().dependOn(&b.addInstallLibFile(ssl_so, "libssl.so.3").step);
            },
        }
        openssl_link.?.apply(mosquitto.root_module);
    }

    // note: Ideally the source code files should be sorted and the unused files should
    // be commented out rather than deleted from the list to make it easier to see what
    // is and isn't used
    const mosquitto_sources = [_][]const u8{
        "common/json_help.c",

        "libcommon/base64_common.c",
        "libcommon/cjson_common.c",
        "libcommon/file_common.c",
        "libcommon/memory_common.c",
        "libcommon/mqtt_common.c",
        "libcommon/password_common.c",
        "libcommon/property_common.c",
        "libcommon/random_common.c",
        "libcommon/strings_common.c",
        "libcommon/time_common.c",
        "libcommon/topic_common.c",
        "libcommon/utf8_common.c",

        "lib/alias_mosq.c",
        "lib/handle_ping.c",
        "lib/handle_pubackcomp.c",
        "lib/handle_pubrec.c",
        "lib/handle_pubrel.c",
        "lib/handle_suback.c",
        "lib/handle_unsuback.c",
        "lib/net_mosq_ocsp.c",
        "lib/net_mosq.c",
        "lib/net_ws.c",
        "lib/packet_datatypes.c",
        "lib/packet_mosq.c",
        "lib/property_mosq.c",
        "lib/send_mosq.c",
        "lib/send_connect.c",
        "lib/send_disconnect.c",
        "lib/send_publish.c",
        "lib/send_subscribe.c",
        "lib/send_unsubscribe.c",
        "lib/tls_mosq.c",
        "lib/util_mosq.c",
        "lib/will_mosq.c",

        "plugins/acl-file/acl_check.c",
        "plugins/acl-file/acl_parse.c",
        "plugins/password-file/password_check.c",
        "plugins/password-file/password_parse.c",

        "src/acl_file.c",
        "src/bridge.c",
        "src/bridge_topic.c",
        "src/broker_control.c",
        "src/conf.c",
        "src/conf_includedir.c",
        "src/context.c",
        "src/control.c",
        "src/control_common.c",
        "src/database.c",
        "src/handle_auth.c",
        "src/handle_connack.c",
        "src/handle_connect.c",
        "src/handle_disconnect.c",
        "src/handle_publish.c",
        "src/handle_subscribe.c",
        "src/handle_unsubscribe.c",
        "src/http_api.c",
        "src/http_serv.c",
        "src/keepalive.c",
        "src/listeners.c",
        "src/logging.c",
        "src/loop.c",
        "src/mosquitto.c",
        "src/mux.c",
        "src/mux_epoll.c",
        "src/mux_kqueue.c",
        "src/mux_poll.c",
        "src/net.c",
        "src/password_file.c",
        "src/persist_read.c",
        "src/persist_read_v234.c",
        "src/persist_read_v5.c",
        "src/persist_write.c",
        "src/persist_write_v5.c",
        "src/plugin_acl_check.c",
        "src/plugin_basic_auth.c",
        "src/plugin_callbacks.c",
        "src/plugin_cleanup.c",
        "src/plugin_client_offline.c",
        "src/plugin_connect.c",
        "src/plugin_disconnect.c",
        "src/plugin_extended_auth.c",
        "src/plugin_init.c",
        "src/plugin_message.c",
        "src/plugin_persist.c",
        "src/plugin_psk_key.c",
        "src/plugin_public.c",
        "src/plugin_reload.c",
        "src/plugin_subscribe.c",
        "src/plugin_tick.c",
        "src/plugin_unsubscribe.c",
        "src/plugin_v2.c",
        "src/plugin_v3.c",
        "src/plugin_v4.c",
        "src/plugin_v5.c",
        "src/property_broker.c",
        "src/proxy_v1.c",
        "src/proxy_v2.c",
        "src/psk_file.c",
        "src/read_handle.c",
        "src/retain.c",
        "src/security_default.c",
        "src/send_auth.c",
        "src/send_connack.c",
        "src/send_suback.c",
        "src/send_unsuback.c",
        "src/service.c",
        "src/session_expiry.c",
        "src/signals.c",
        "src/subs.c",
        "src/sys_tree.c",
        "src/topic_tok.c",
        "src/watchdog.c",
        "src/websockets.c",
        "src/will_delay.c",
        "src/xtreport.c",

        // builtin websockets HTTP parser (WITH_WEBSOCKETS=WS_IS_BUILTIN);
        // compiles to unused code when websockets are disabled.
        "deps/picohttpparser/picohttpparser.c",
    };

    // construct build arguments
    var mosquitto_flags: std.ArrayList([]const u8) = .empty;
    defer mosquitto_flags.deinit(alloc);

    // optional flags
    if (with_tls) {
        try mosquitto_flags.append(alloc, "-DWITH_TLS");
        // TLS-PSK support (upstream default). Gated by TLS; config.h only
        // derives FINAL_WITH_TLS_PSK when WITH_TLS is also set.
        try mosquitto_flags.append(alloc, "-DWITH_TLS_PSK");
        // Builtin websockets (no libwebsockets dependency), matching upstream's
        // default. Upstream requires WITH_TLS for websockets, so it is gated
        // here; without this define net_ws.c/websockets.c/http_client.c compile
        // to no-ops and mosquitto reports "Websockets support NOT available".
        // Needs the bundled picohttpparser (added to the sources below).
        try mosquitto_flags.append(alloc, "-DWITH_WEBSOCKETS=WS_IS_BUILTIN");
    }

    // common flags
    try mosquitto_flags.append(alloc, "-DWITH_BRIDGE");
    try mosquitto_flags.append(alloc, "-DWITH_BROKER");
    try mosquitto_flags.append(alloc, "-DWITH_PERSISTENCE");
    // try mosquitto_flags.append(alloc, "-DWITH_SQLITE");
    // try mosquitto_flags.append(alloc, "-DWITH_HTTP_API");

    // version
    const version_flag = try std.fmt.allocPrint(alloc, "-DVERSION=\"{s}\"", .{version});
    defer alloc.free(version_flag);
    try mosquitto_flags.append(alloc, version_flag);

    try mosquitto_flags.append(alloc, "-Wall");
    try mosquitto_flags.append(alloc, "-W");

    for (mosquitto_sources) |src| {
        mosquitto.root_module.addCSourceFile(.{ .file = mosquitto_dep.path(src), .flags = mosquitto_flags.items });
    }
    mosquitto.root_module.link_libc = true;

    // Export the broker's global symbols into the dynamic symbol table so that
    // plugins loaded at runtime via dlopen() can resolve broker API functions
    // (e.g. mosquitto_broker_publish_copy, mosquitto_callback_register). Without
    // -rdynamic these symbols live only in the regular symbol table and the
    // dynamic loader reports "undefined symbol" when loading a plugin .so.
    mosquitto.rdynamic = true;

    b.installArtifact(mosquitto);

    // -------------------------------------------------------------------------
    // Plugins — built as loadable shared libraries (.so / .dylib)
    // libcommon sources are compiled directly into each plugin to avoid a
    // runtime dependency on a separate libmosquitto_common.so.
    // -------------------------------------------------------------------------

    // libcommon split by external dependency:
    // core: no special deps beyond mosquitto headers — safe for every plugin
    const libcommon_core_sources = [_][]const u8{
        "libcommon/base64_common.c",
        "libcommon/file_common.c",
        "libcommon/memory_common.c",
        "libcommon/mqtt_common.c",
        "libcommon/property_common.c",
        "libcommon/strings_common.c",
        "libcommon/time_common.c",
        "libcommon/topic_common.c",
        "libcommon/utf8_common.c",
    };
    // json: requires <cjson/cJSON.h> — only include when cJSON is compiled in
    const libcommon_json_sources = [_][]const u8{
        "common/json_help.c",
        "libcommon/cjson_common.c",
    };
    // crypto: guarded by #ifdef WITH_TLS — only include when OpenSSL is linked
    const libcommon_crypto_sources = [_][]const u8{
        "libcommon/password_common.c",
        "libcommon/random_common.c",
    };
    // combined sets used per plugin
    const libcommon_full_sources = libcommon_core_sources ++ libcommon_json_sources ++ libcommon_crypto_sources;
    const libcommon_json_only_sources = libcommon_core_sources ++ libcommon_json_sources;
    const libcommon_crypto_only_sources = libcommon_core_sources ++ libcommon_crypto_sources;

    var plugin_flags: std.ArrayList([]const u8) = .empty;
    defer plugin_flags.deinit(alloc);
    if (with_tls) {
        try plugin_flags.append(alloc, "-DWITH_TLS");
    }
    const plugin_version_flag = try std.fmt.allocPrint(alloc, "-DVERSION=\"{s}\"", .{version});
    defer alloc.free(plugin_version_flag);
    try plugin_flags.append(alloc, plugin_version_flag);
    try plugin_flags.append(alloc, "-Wall");
    try plugin_flags.append(alloc, "-W");
    // Flags for plugins that do not need TLS/crypto (no -DWITH_TLS → OpenSSL
    // headers are not needed, password_common.c compiles as a no-op stub).
    var plugin_flags_notls: std.ArrayList([]const u8) = .empty;
    defer plugin_flags_notls.deinit(alloc);
    try plugin_flags_notls.append(alloc, plugin_version_flag);
    try plugin_flags_notls.append(alloc, "-Wall");
    try plugin_flags_notls.append(alloc, "-W");

    if (with_dynamic_security) {
        b.installArtifact(buildPlugin(
            b,
            "mosquitto_dynamic_security",
            mosquitto_dep,
            "plugins/dynamic-security",
            cjson_dep,
            &copy_cjson.step,
            null,
            target,
            optimize,
            &libcommon_full_sources,
            &[_][]const u8{
                "plugins/dynamic-security/acl.c",
                "plugins/dynamic-security/auth.c",
                "plugins/dynamic-security/clientlist.c",
                "plugins/dynamic-security/clients.c",
                "plugins/dynamic-security/config.c",
                "plugins/dynamic-security/config_init.c",
                "plugins/dynamic-security/control.c",
                "plugins/dynamic-security/default_acl.c",
                "plugins/dynamic-security/details.c",
                "plugins/dynamic-security/grouplist.c",
                "plugins/dynamic-security/groups.c",
                "plugins/dynamic-security/kicklist.c",
                "plugins/dynamic-security/plugin.c",
                "plugins/dynamic-security/rolelist.c",
                "plugins/dynamic-security/roles.c",
                "plugins/dynamic-security/tick.c",
            },
            plugin_flags.items,
            openssl_link,
        ));
    }

    if (with_persist_sqlite) {
        b.installArtifact(buildPlugin(
            b,
            "mosquitto_persist_sqlite",
            mosquitto_dep,
            "plugins/persist-sqlite",
            cjson_dep,       // persist-sqlite uses <cjson/cJSON.h>
            &copy_cjson.step,
            sqlite_dep,
            target,
            optimize,
            &libcommon_json_only_sources,
            &[_][]const u8{
                "plugins/persist-sqlite/base_msgs.c",
                "plugins/persist-sqlite/client_msgs.c",
                "plugins/persist-sqlite/clients.c",
                "plugins/persist-sqlite/common.c",
                "plugins/persist-sqlite/init.c",
                "plugins/persist-sqlite/plugin.c",
                "plugins/persist-sqlite/restore.c",
                "plugins/persist-sqlite/retain_msgs.c",
                "plugins/persist-sqlite/subscriptions.c",
                "plugins/persist-sqlite/tick.c",
                "plugins/persist-sqlite/will.c",
            },
            plugin_flags_notls.items,  // no password/TLS needed
            null, // no OpenSSL
        ));
    }

    if (with_acl_file_plugin) {
        b.installArtifact(buildPlugin(
            b,
            "mosquitto_acl_file",
            mosquitto_dep,
            "plugins/acl-file",
            null,              // no cJSON.c compilation needed
            &copy_cjson.step,  // still needed: mosquitto.h -> libcommon_cjson.h -> cjson/cJSON.h
            null,
            target,
            optimize,
            &libcommon_core_sources,
            &[_][]const u8{
                "plugins/acl-file/acl_check.c",
                "plugins/acl-file/acl_parse.c",
                "plugins/acl-file/plugin.c",
            },
            plugin_flags_notls.items,  // no password/TLS needed
            null, // no OpenSSL
        ));
    }

    if (with_password_file_plugin) {
        b.installArtifact(buildPlugin(
            b,
            "mosquitto_password_file",
            mosquitto_dep,
            "plugins/password-file",
            null,              // no cJSON.c compilation needed
            &copy_cjson.step,  // still needed: mosquitto.h -> libcommon_cjson.h -> cjson/cJSON.h
            null,
            target,
            optimize,
            &libcommon_crypto_only_sources,  // needs password_common + random_common
            &[_][]const u8{
                "plugins/password-file/password_check.c",
                "plugins/password-file/password_parse.c",
                "plugins/password-file/plugin.c",
            },
            plugin_flags.items,  // -DWITH_TLS enables password hashing
            openssl_link,
        ));
    }

    if (with_sparkplug_aware) {
        b.installArtifact(buildPlugin(
            b,
            "mosquitto_sparkplug_aware",
            mosquitto_dep,
            "plugins/sparkplug-aware",
            null,              // no cJSON.c compilation needed
            &copy_cjson.step,  // still needed: mosquitto.h -> libcommon_cjson.h -> cjson/cJSON.h
            null,
            target,
            optimize,
            &libcommon_core_sources,
            &[_][]const u8{
                "plugins/sparkplug-aware/on_message.c",
                "plugins/sparkplug-aware/plugin.c",
            },
            plugin_flags_notls.items,  // no password/TLS needed
            null, // no OpenSSL
        ));
    }

    // -------------------------------------------------------------------------
    // CLI tools — built as standalone executables. The libmosquitto *client*
    // library (lib/*.c, compiled WITHOUT -DWITH_BROKER) and libcommon sources
    // are compiled directly into each tool to avoid a runtime dependency on a
    // shared libmosquitto.so.
    // -------------------------------------------------------------------------

    // libmosquitto client library sources (the lib/ CMake C_SRC list, including
    // the builtin-websockets picohttpparser dep — see WITH_WEBSOCKETS above).
    const lib_client_sources = [_][]const u8{
        "deps/picohttpparser/picohttpparser.c",
        "lib/actions_publish.c",
        "lib/actions_subscribe.c",
        "lib/actions_unsubscribe.c",
        "lib/alias_mosq.c",
        "lib/callbacks.c",
        "lib/connect.c",
        "lib/extended_auth.c",
        "lib/handle_auth.c",
        "lib/handle_connack.c",
        "lib/handle_disconnect.c",
        "lib/handle_ping.c",
        "lib/handle_pubackcomp.c",
        "lib/handle_publish.c",
        "lib/handle_pubrec.c",
        "lib/handle_pubrel.c",
        "lib/handle_suback.c",
        "lib/handle_unsuback.c",
        "lib/helpers.c",
        "lib/http_client.c",
        "lib/libmosquitto.c",
        "lib/logging_mosq.c",
        "lib/loop.c",
        "lib/messages_mosq.c",
        "lib/net_mosq_ocsp.c",
        "lib/net_mosq.c",
        "lib/net_ws.c",
        "lib/options.c",
        "lib/packet_datatypes.c",
        "lib/packet_mosq.c",
        "lib/property_mosq.c",
        "lib/read_handle.c",
        "lib/send_connect.c",
        "lib/send_disconnect.c",
        "lib/send_mosq.c",
        "lib/send_publish.c",
        "lib/send_subscribe.c",
        "lib/send_unsubscribe.c",
        "lib/socks_mosq.c",
        "lib/srv_mosq.c",
        "lib/thread_mosq.c",
        "lib/tls_mosq.c",
        "lib/util_mosq.c",
        "lib/will_mosq.c",
    };
    // sources shared by every client (mosquitto_pub/sub/rr)
    const client_shared_sources = [_][]const u8{
        "client/client_shared.c",
        "client/client_props.c",
    };

    // Flags for the client tools: client mode (no -DWITH_BROKER), TLS optional.
    var client_flags: std.ArrayList([]const u8) = .empty;
    defer client_flags.deinit(alloc);
    if (with_tls) {
        try client_flags.append(alloc, "-DWITH_TLS");
        try client_flags.append(alloc, "-DWITH_TLS_PSK");
        // builtin websockets — keep the client library in sync with the broker
        // so mosquitto_pub/sub/rr can speak ws:// / wss://.
        try client_flags.append(alloc, "-DWITH_WEBSOCKETS=WS_IS_BUILTIN");
    }
    try client_flags.append(alloc, plugin_version_flag);
    try client_flags.append(alloc, "-Wall");
    try client_flags.append(alloc, "-W");

    if (with_client_pub) {
        b.installArtifact(buildTool(
            b,
            "mosquitto_pub",
            mosquitto_dep,
            cjson_dep,
            &copy_cjson.step,
            target,
            optimize,
            &(lib_client_sources ++ libcommon_full_sources ++ client_shared_sources ++ [_][]const u8{
                "client/pub_client.c",
                "client/pub_shared.c",
            }),
            client_flags.items,
            true, // needs cJSON
            openssl_link,
        ));
    }

    if (with_client_sub) {
        b.installArtifact(buildTool(
            b,
            "mosquitto_sub",
            mosquitto_dep,
            cjson_dep,
            &copy_cjson.step,
            target,
            optimize,
            &(lib_client_sources ++ libcommon_full_sources ++ client_shared_sources ++ [_][]const u8{
                "client/sub_client.c",
                "client/sub_client_output.c",
            }),
            client_flags.items,
            true,
            openssl_link,
        ));
    }

    if (with_client_rr) {
        b.installArtifact(buildTool(
            b,
            "mosquitto_rr",
            mosquitto_dep,
            cjson_dep,
            &copy_cjson.step,
            target,
            optimize,
            &(lib_client_sources ++ libcommon_full_sources ++ client_shared_sources ++ [_][]const u8{
                "client/rr_client.c",
                "client/pub_shared.c",
                "client/sub_client_output.c",
            }),
            client_flags.items,
            true,
            openssl_link,
        ));
    }

    // mosquitto_db_dump — reads the broker persistence file, so it needs the
    // broker persist_read sources and -DWITH_BROKER -DWITH_PERSISTENCE.
    if (with_app_db_dump) {
        var db_dump_flags: std.ArrayList([]const u8) = .empty;
        defer db_dump_flags.deinit(alloc);
        if (with_tls) try db_dump_flags.append(alloc, "-DWITH_TLS");
        try db_dump_flags.append(alloc, "-DWITH_BROKER");
        try db_dump_flags.append(alloc, "-DWITH_PERSISTENCE");
        try db_dump_flags.append(alloc, plugin_version_flag);
        try db_dump_flags.append(alloc, "-Wall");
        try db_dump_flags.append(alloc, "-W");
        b.installArtifact(buildTool(
            b,
            "mosquitto_db_dump",
            mosquitto_dep,
            cjson_dep,
            &copy_cjson.step,
            target,
            optimize,
            &(libcommon_json_only_sources ++ [_][]const u8{
                "apps/db_dump/db_dump.c",
                "apps/db_dump/json.c",
                "apps/db_dump/print.c",
                "apps/db_dump/stubs.c",
                "lib/packet_datatypes.c",
                "lib/property_mosq.c",
                "src/persist_read.c",
                "src/persist_read_v234.c",
                "src/persist_read_v5.c",
                "src/topic_tok.c",
            }),
            db_dump_flags.items,
            true,
            openssl_link,
        ));
    }

    // mosquitto_passwd — requires TLS (OpenSSL) for password hashing.
    if (with_app_passwd and with_tls) {
        b.installArtifact(buildTool(
            b,
            "mosquitto_passwd",
            mosquitto_dep,
            cjson_dep,
            &copy_cjson.step,
            target,
            optimize,
            &(libcommon_crypto_only_sources ++ [_][]const u8{
                "apps/mosquitto_passwd/mosquitto_passwd.c",
                "apps/mosquitto_passwd/get_password.c",
            }),
            client_flags.items,
            false, // no cJSON
            openssl_link,
        ));
    }

    // mosquitto_ctrl — requires TLS. Built without the optional line-editing
    // shell (WITH_CTRL_SHELL) since libedit/readline is not available here.
    if (with_app_ctrl and with_tls) {
        b.installArtifact(buildTool(
            b,
            "mosquitto_ctrl",
            mosquitto_dep,
            cjson_dep,
            &copy_cjson.step,
            target,
            optimize,
            &(lib_client_sources ++ libcommon_full_sources ++ [_][]const u8{
                "apps/mosquitto_ctrl/mosquitto_ctrl.c",
                "apps/mosquitto_ctrl/broker.c",
                "apps/mosquitto_ctrl/client.c",
                "apps/mosquitto_ctrl/dynsec.c",
                "apps/mosquitto_ctrl/dynsec_client.c",
                "apps/mosquitto_ctrl/dynsec_group.c",
                "apps/mosquitto_ctrl/dynsec_role.c",
                "apps/mosquitto_ctrl/options.c",
                "apps/mosquitto_passwd/get_password.c",
                // note: common/json_help.c is already provided by libcommon_full_sources
            }),
            client_flags.items,
            true,
            openssl_link,
        ));
    }

    // mosquitto_signal — standalone, no libmosquitto/libcommon/TLS needed.
    if (with_app_signal) {
        var signal_flags: std.ArrayList([]const u8) = .empty;
        defer signal_flags.deinit(alloc);
        try signal_flags.append(alloc, plugin_version_flag);
        try signal_flags.append(alloc, "-Wall");
        try signal_flags.append(alloc, "-W");
        b.installArtifact(buildTool(
            b,
            "mosquitto_signal",
            mosquitto_dep,
            cjson_dep,
            &copy_cjson.step,
            target,
            optimize,
            &[_][]const u8{
                "apps/mosquitto_signal/mosquitto_signal.c",
                "apps/mosquitto_signal/signal_unix.c",
            },
            signal_flags.items,
            false,
            null,
        ));
    }
}

fn buildPlugin(
    b: *std.Build,
    name: []const u8,
    mosquitto_dep: *std.Build.Dependency,
    plugin_dir: []const u8,
    opt_cjson_dep: ?*std.Build.Dependency, // null = only need headers, don't compile cJSON.c
    copy_cjson_step: *std.Build.Step,      // always needed: mosquitto.h -> libcommon_cjson.h -> cjson/cJSON.h
    opt_sqlite_dep: ?*std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libcommon_sources: []const []const u8,
    plugin_sources: []const []const u8,
    flags: []const []const u8,
    openssl: ?OpensslLink,
) *std.Build.Step.Compile {
    const plugin = b.addLibrary(.{
        .name = name,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .dynamic,
    });
    plugin.root_module.addIncludePath(mosquitto_dep.path(""));
    plugin.root_module.addIncludePath(mosquitto_dep.path("include"));
    plugin.root_module.addIncludePath(mosquitto_dep.path("src"));
    plugin.root_module.addIncludePath(mosquitto_dep.path("libcommon"));
    plugin.root_module.addIncludePath(mosquitto_dep.path("common"));
    plugin.root_module.addIncludePath(mosquitto_dep.path("deps"));
    plugin.root_module.addIncludePath(mosquitto_dep.path(plugin_dir));
    // mosquitto.h pulls in mosquitto/libcommon_cjson.h which needs <cjson/cJSON.h>.
    // b.path(".") provides that via the cjson/ subdirectory created by copy_cjson_step.
    plugin.root_module.addIncludePath(b.path("."));
    plugin.step.dependOn(copy_cjson_step);
    if (opt_cjson_dep) |cjson_dep| {
        // Compile cJSON.c only for plugins that actively call the cJSON API.
        plugin.root_module.addIncludePath(cjson_dep.path(""));
        plugin.root_module.addCSourceFile(.{ .file = cjson_dep.path("cJSON.c"), .flags = &.{} });
    }
    // broker API symbols (e.g. mosquitto_callback_register) are resolved at
    // runtime when the plugin is dlopen'd by mosquitto — allow them to be
    // undefined at link time.
    plugin.linker_allow_shlib_undefined = true;
    if (opt_sqlite_dep) |sqlite_dep| {
        plugin.root_module.addIncludePath(sqlite_dep.path("."));
        plugin.root_module.addCSourceFile(.{ .file = sqlite_dep.path("sqlite3.c"), .flags = &.{} });
    }
    if (openssl) |o| {
        o.apply(plugin.root_module);
    }
    for (libcommon_sources) |src| {
        plugin.root_module.addCSourceFile(.{ .file = mosquitto_dep.path(src), .flags = flags });
    }
    for (plugin_sources) |src| {
        plugin.root_module.addCSourceFile(.{ .file = mosquitto_dep.path(src), .flags = flags });
    }
    plugin.root_module.link_libc = true;
    return plugin;
}

fn buildTool(
    b: *std.Build,
    name: []const u8,
    mosquitto_dep: *std.Build.Dependency,
    cjson_dep: *std.Build.Dependency,
    copy_cjson_step: *std.Build.Step, // mosquitto.h -> libcommon_cjson.h -> cjson/cJSON.h
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sources: []const []const u8,
    flags: []const []const u8,
    needs_cjson: bool,
    openssl: ?OpensslLink,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addIncludePath(mosquitto_dep.path(""));
    exe.root_module.addIncludePath(mosquitto_dep.path("include"));
    exe.root_module.addIncludePath(mosquitto_dep.path("src"));
    exe.root_module.addIncludePath(mosquitto_dep.path("lib"));
    exe.root_module.addIncludePath(mosquitto_dep.path("libcommon"));
    exe.root_module.addIncludePath(mosquitto_dep.path("common"));
    exe.root_module.addIncludePath(mosquitto_dep.path("deps"));
    // builtin websockets: http_client.c does #include "picohttpparser.h"
    exe.root_module.addIncludePath(mosquitto_dep.path("deps/picohttpparser"));
    exe.root_module.addIncludePath(mosquitto_dep.path("client"));
    exe.root_module.addIncludePath(mosquitto_dep.path("apps/mosquitto_passwd"));
    exe.root_module.addIncludePath(mosquitto_dep.path("plugins/common"));
    exe.root_module.addIncludePath(mosquitto_dep.path("plugins/dynamic-security"));
    // b.path(".") provides cjson/cJSON.h (created by copy_cjson_step) for the
    // mosquitto.h -> libcommon_cjson.h include chain.
    exe.root_module.addIncludePath(b.path("."));
    exe.step.dependOn(copy_cjson_step);
    if (needs_cjson) {
        exe.root_module.addIncludePath(cjson_dep.path(""));
        exe.root_module.addCSourceFile(.{ .file = cjson_dep.path("cJSON.c"), .flags = &.{} });
    }
    if (openssl) |o| {
        o.apply(exe.root_module);
    }
    for (sources) |src| {
        exe.root_module.addCSourceFile(.{ .file = mosquitto_dep.path(src), .flags = flags });
    }
    exe.root_module.link_libc = true;
    return exe;
}

fn buildMicrohttpd(
    b: *std.Build,
    dep: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "microhttpd",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });

    lib.root_module.addIncludePath(dep.path("src/include"));
    lib.root_module.addIncludePath(dep.path("src/microhttpd"));
    // MHD_config.h lives alongside build.zig
    lib.root_module.addIncludePath(b.path("."));

    const mhd_flags: []const []const u8 = &.{
        "-std=gnu11",
        "-D_GNU_SOURCE",
        "-DBUILDING_MHD_LIB=1",
        "-DHAVE_POSTPROCESSOR=1",
        "-DHAVE_ANYAUTH=1",
        "-DBAUTH_SUPPORT=1",
        "-DDAUTH_SUPPORT=1",
        "-DCOOKIE_SUPPORT=1",
        "-W",
        "-Wall",
        "-Wno-missing-field-initializers",
        "-Wno-unused-parameter",
        "-Wno-sign-compare",
        "-Wno-tautological-constant-out-of-range-compare",
        "-Wno-shorten-64-to-32",
        "-Wno-implicit-int-conversion",
    };

    const core_sources = [_][]const u8{
        "src/microhttpd/connection.c",
        "src/microhttpd/reason_phrase.c",
        "src/microhttpd/daemon.c",
        "src/microhttpd/internal.c",
        "src/microhttpd/memorypool.c",
        "src/microhttpd/mhd_mono_clock.c",
        "src/microhttpd/mhd_str.c",
        "src/microhttpd/mhd_send.c",
        "src/microhttpd/mhd_sockets.c",
        "src/microhttpd/mhd_itc.c",
        "src/microhttpd/mhd_compat.c",
        "src/microhttpd/mhd_panic.c",
        "src/microhttpd/mhd_threads.c",
        "src/microhttpd/response.c",
        "src/microhttpd/tsearch.c",
        "src/microhttpd/postprocessor.c",
        "src/microhttpd/gen_auth.c",
        "src/microhttpd/basicauth.c",
        "src/microhttpd/digestauth.c",
        "src/microhttpd/md5.c",
        "src/microhttpd/sha256.c",
        "src/microhttpd/sha512_256.c",
        "src/microhttpd/sha1.c",
    };

    for (core_sources) |src| {
        lib.root_module.addCSourceFile(.{
            .file = dep.path(src),
            .flags = mhd_flags,
        });
    }

    lib.root_module.link_libc = true;
    return lib;
}