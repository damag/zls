const std = @import("std");
const builtin = @import("builtin");
const tres = @import("tres");

const ConfigOption = struct {
    /// Name of config option
    name: []const u8,
    /// (used in doc comments & schema.json)
    description: []const u8,
    /// zig type in string form. e.g "u32", "[]const u8", "?usize"
    type: []const u8,
    /// used in Config.zig as the default initializer
    default: []const u8,
};

const Config = struct {
    options: []ConfigOption,
};

const Schema = struct {
    @"$schema": []const u8 = "http://json-schema.org/schema",
    title: []const u8 = "ZLS Config",
    description: []const u8 = "Configuration file for the zig language server (ZLS)",
    type: []const u8 = "object",
    properties: std.StringArrayHashMap(SchemaEntry),
};

const SchemaEntry = struct {
    description: []const u8,
    type: []const u8,
    default: []const u8,
};

fn zigTypeToTypescript(ty: []const u8) ![]const u8 {
    return if (std.mem.eql(u8, ty, "?[]const u8"))
        "string"
    else if (std.mem.eql(u8, ty, "bool"))
        "boolean"
    else if (std.mem.eql(u8, ty, "usize"))
        "integer"
    else
        error.UnsupportedType;
}

fn generateConfigFile(allocator: std.mem.Allocator, config: Config, path: []const u8) !void {
    _ = allocator;

    const config_file = try std.fs.createFileAbsolute(path, .{});
    defer config_file.close();

    var buff_out = std.io.bufferedWriter(config_file.writer());

    _ = try buff_out.write(
        \\//! DO NOT EDIT
        \\//! Configuration options for zls.
        \\//! If you want to add a config option edit
        \\//! src/config_gen/config.zig and run `zig build gen`
        \\//! GENERATED BY src/config_gen/config_gen.zig
        \\
    );

    for (config.options) |option| {
        try buff_out.writer().print(
            \\
            \\/// {s}
            \\{s}: {s} = {s},
            \\
        , .{
            std.mem.trim(u8, option.description, &std.ascii.whitespace),
            std.mem.trim(u8, option.name, &std.ascii.whitespace),
            std.mem.trim(u8, option.type, &std.ascii.whitespace),
            std.mem.trim(u8, option.default, &std.ascii.whitespace),
        });
    }

    _ = try buff_out.write(
        \\
        \\// DO NOT EDIT
        \\
    );

    try buff_out.flush();
}

fn generateSchemaFile(allocator: std.mem.Allocator, config: Config, path: []const u8) !void {
    const schema_file = try std.fs.openFileAbsolute(path, .{
        .mode = .write_only,
    });
    defer schema_file.close();

    var buff_out = std.io.bufferedWriter(schema_file.writer());

    var properties = std.StringArrayHashMapUnmanaged(SchemaEntry){};
    defer properties.deinit(allocator);
    try properties.ensureTotalCapacity(allocator, config.options.len);

    for (config.options) |option| {
        properties.putAssumeCapacityNoClobber(option.name, .{
            .description = option.description,
            .type = try zigTypeToTypescript(option.type),
            .default = option.default,
        });
    }

    _ = try buff_out.write(
        \\{
        \\    "$schema": "http://json-schema.org/schema",
        \\    "title": "ZLS Config",
        \\    "description": "Configuration file for the zig language server (ZLS)",
        \\    "type": "object",
        \\    "properties": 
    );

    try tres.stringify(properties, .{
        .whitespace = .{
            .indent_level = 1,
        },
    }, buff_out.writer());

    _ = try buff_out.write("\n}\n");
    try buff_out.flush();
    try schema_file.setEndPos(try schema_file.getPos());
}

fn updateREADMEFile(allocator: std.mem.Allocator, config: Config, path: []const u8) !void {
    var readme_file = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
    defer readme_file.close();

    var readme = try readme_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(readme);

    const start_indicator = "<!-- DO NOT EDIT | THIS SECTION IS AUTO-GENERATED | DO NOT EDIT -->";
    const end_indicator = "<!-- DO NOT EDIT -->";

    const start = start_indicator.len + (std.mem.indexOf(u8, readme, start_indicator) orelse return error.SectionNotFound);
    const end = std.mem.indexOfPos(u8, readme, start, end_indicator) orelse return error.SectionNotFound;

    try readme_file.seekTo(0);
    var writer = readme_file.writer();

    try writer.writeAll(readme[0..start]);

    try writer.writeAll(
        \\
        \\| Option | Type | Default value | What it Does |
        \\| --- | --- | --- | --- |
        \\
    );

    for (config.options) |option| {
        try writer.print(
            \\| `{s}` | `{s}` | `{s}` | {s} |
            \\
        , .{
            std.mem.trim(u8, option.name, &std.ascii.whitespace),
            std.mem.trim(u8, option.type, &std.ascii.whitespace),
            std.mem.trim(u8, option.default, &std.ascii.whitespace),
            std.mem.trim(u8, option.description, &std.ascii.whitespace),
        });
    }

    try writer.writeAll(readme[end..]);

    try readme_file.setEndPos(try readme_file.getPos());
}

const ConfigurationProperty = struct {
    scope: []const u8 = "resource",
    type: []const u8,
    description: []const u8,
    @"enum": ?[]const []const u8 = null,
    format: ?[]const u8 = null,
    default: ?std.json.Value = null,
};

fn generateVSCodeConfigFile(allocator: std.mem.Allocator, config: Config, path: []const u8) !void {
    var config_file = try std.fs.createFileAbsolute(path, .{});
    defer config_file.close();

    const predefined_configurations: usize = 3;
    var configuration: std.StringArrayHashMapUnmanaged(ConfigurationProperty) = .{};
    try configuration.ensureTotalCapacity(allocator, predefined_configurations + @intCast(u32, config.options.len));
    defer {
        for (configuration.keys()[predefined_configurations..]) |name| allocator.free(name);
        configuration.deinit(allocator);
    }

    configuration.putAssumeCapacityNoClobber("trace.server", .{
        .scope = "window",
        .type = "string",
        .@"enum" = &.{ "off", "message", "verbose" },
        .description = "Traces the communication between VS Code and the language server.",
        .default = .{ .String = "off" },
    });
    configuration.putAssumeCapacityNoClobber("check_for_update", .{
        .type = "boolean",
        .description = "Whether to automatically check for new updates",
        .default = .{ .Bool = true },
    });
    configuration.putAssumeCapacityNoClobber("path", .{
        .type = "string",
        .description = "Path to `zls` executable. Example: `C:/zls/zig-cache/bin/zls.exe`.",
        .format = "path",
        .default = null,
    });

    for (config.options) |option| {
        const name = try std.fmt.allocPrint(allocator, "zls.{s}", .{option.name});

        var parser = std.json.Parser.init(allocator, false);
        const default = (try parser.parse(option.default)).root;

        configuration.putAssumeCapacityNoClobber(name, .{
            .type = try zigTypeToTypescript(option.type),
            .description = option.description,
            .format = if (std.mem.indexOf(u8, option.name, "path") != null) "path" else null,
            .default = if (default == .Null) null else default,
        });
    }

    var buffered_writer = std.io.bufferedWriter(config_file.writer());
    var writer = buffered_writer.writer();

    try tres.stringify(configuration, .{
        .whitespace = .{},
        .emit_null_optional_fields = false,
    }, writer);

    try buffered_writer.flush();
}

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    var gpa = general_purpose_allocator.allocator();

    var arg_it = try std.process.argsWithAllocator(gpa);
    defer arg_it.deinit();

    _ = arg_it.next() orelse @panic("");
    const config_path = arg_it.next() orelse @panic("first argument must be path to Config.zig");
    const schema_path = arg_it.next() orelse @panic("second argument must be path to schema.json");
    const readme_path = arg_it.next() orelse @panic("third argument must be path to README.md");
    const maybe_vscode_config_path = arg_it.next();

    const parse_options = std.json.ParseOptions{
        .allocator = gpa,
    };
    var token_stream = std.json.TokenStream.init(@embedFile("config.json"));
    const config = try std.json.parse(Config, &token_stream, parse_options);
    defer std.json.parseFree(Config, config, parse_options);

    try generateConfigFile(gpa, config, config_path);
    try generateSchemaFile(gpa, config, schema_path);
    try updateREADMEFile(gpa, config, readme_path);

    if (maybe_vscode_config_path) |vscode_config_path| {
        try generateVSCodeConfigFile(gpa, config, vscode_config_path);
    }

    if (builtin.os.tag == .windows) {
        std.log.warn("Running on windows may result in CRLF and LF mismatch", .{});
    }

    try std.io.getStdOut().writeAll(
        \\If you have added a new configuration option and it should be configuration through the config wizard, then edit `src/setup.zig`
        \\
        \\Changing configuration options may also require editing the `package.json` from zls-vscode at https://github.com/zigtools/zls-vscode/blob/master/package.json
        \\You can use `zig build gen -Dvscode-config-path=/path/to/output/file.json` to generate the new configuration properties which you can then copy into `package.json`
        \\
    );
}
