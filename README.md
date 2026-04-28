# zig-protobuf

<img src="logo.svg" width="50%">


## State of the implementation

This repository, so far, only aims at implementing [protocol buffers version 3](https://developers.google.com/protocol-buffers/docs/proto3#simple).

This project is mature enough to be used in production.

json encoding/decoding is considered a beta feature.

## Branches

There are 2 branches you can use for your development.

* `master` is the branch with current developments, working with the latest stable release of zig.
* `zig-master` is a branch that merges the developments in master, but works with the latest-ish master version of zig. 

## How to use

1. Add `protobuf` to your `build.zig.zon`.  
    ```sh
    zig fetch --save "git+https://gitlab.com/devnw/zig/protobuf#master"
    ```
1. Use the `protobuf` module. In your `build.zig`'s build function, add the dependency as module before
`b.installArtifact(exe)`.
    ```zig
    pub fn build(b: *std.Build) !void {
        // first create a build for the dependency
        const protobuf_dep = b.dependency("protobuf", .{
            .target = target,
            .optimize = optimize,
        });

        // and lastly use the dependency as a module
        exe.root_module.addImport("protobuf", protobuf_dep.module("protobuf"));
    }
    ```

## Generating .zig files out of .proto definitions

You can do this programatically as a compilation step for your application. The following snippet shows how to create a `zig build gen-proto` command for your project.

```zig
const protobuf = @import("protobuf");

pub fn build(b: *std.Build) !void {
    // first create a build for the dependency
    const protobuf_dep = b.dependency("protobuf", .{
        .target = target,
        .optimize = optimize,
    });
    
    ...

    const gen_proto = b.step("gen-proto", "generates zig files from protocol buffer definitions");

    const protoc_step = protobuf.RunProtocStep.create(protobuf_dep.builder, target, .{
        // out directory for the generated zig files
        .destination_directory = b.path("src/proto"),
        .source_files = &.{
            "protocol/all.proto",
        },
        .include_directories = &.{},
    });

    gen_proto.dependOn(&protoc_step.step);
}
```

## Observability

zig-protobuf carries an opt-in OpenTelemetry seam exposed at
`protobuf.observability` (and a bootstrap helper at
`protobuf.observability_init`). It is **off by default**; building or
depending on protobuf without any extra flags emits zero
otel/observability symbols and never resolves the otel package.

To compile in the seam:

```sh
zig build test -Dwith_otel=true
# or, when consuming protobuf as a dependency:
zig build -Dwith_otel=true
```

When the flag is on, the otel package is fetched lazily from the pinned
SHA in `build.zig.zon` (`.otel`). When it is off, the verifier
`otel/scripts/verify-consumer-noop.sh` confirms no `otel`/`observability`
symbols leak into protobuf's static link.

**protobuf does not emit any spans of its own.** Encoding and decoding
are value-shape operations with no natural span surface, and adding one
unconditionally would tie protobuf's hot path to OTLP overhead even
when an embedder doesn't want it. The seam is exposed for two reasons:

1. **Forward compatibility**: a future protobuf operation that genuinely
   warrants a span (e.g. a streaming codec with externally observable
   boundaries) can call into the seam without re-plumbing the package
   manifest, build flags, or symbols.
2. **Consumer wiring**: applications that embed protobuf inside an
   OpenTelemetry-aware service can use `protobuf.observability` to
   instrument their own protobuf encode/decode call sites with the
   same conventions and helpers the rest of the devnw/zig stack uses.

See `src/observability.zig` for the seam surface and
`src/observability_init.zig` for the bootstrap helper. The integration
recipe lives at `otel/docs/integration/RECIPE.md` in the otel
repository.

-------

The zig-protobuf logo is licensed under the Attribution 4.0 International (CC BY 4.0).

The logo is inspired by the [official mascots](https://github.com/ziglang/logo?tab=readme-ov-file#official-mascots) of the Zig programming language, themselves licensed under the Attribution 4.0 International (CC BY 4.0)

Original art by vivisector.

-------

If you're really bored, you can buy me a coffee here.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/N4N7VMS4F)
