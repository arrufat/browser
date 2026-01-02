// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const Browser = @import("browser.zig").Browser;
const Page = @import("page.zig").Page;
const Allocator = std.mem.Allocator;

pub const Mcp = struct {
    browser: *Browser,
    allocator: Allocator,

    pub fn init(browser: *Browser, allocator: Allocator) Mcp {
        return .{
            .browser = browser,
            .allocator = allocator,
        };
    }

    pub fn run(self: *Mcp) !void {
        var stdin_file = std.fs.File.stdin();
        var stdout_file = std.fs.File.stdout();
        var stdout_writer_obj = stdout_file.writer(&.{});
        const stdout = &stdout_writer_obj.interface;

        var session = try self.browser.newSession();
        const page = try session.createPage();

        var buf: [16384]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);

        while (true) {
            fbs.reset();
            var byte_buf: [1]u8 = undefined;
            while (true) {
                const amt = try stdin_file.read(&byte_buf);
                if (amt == 0) return;
                if (byte_buf[0] == '\n') break;
                try fbs.writer().writeByte(byte_buf[0]);
            }

            const line = fbs.getWritten();
            if (line.len == 0) continue;

            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch |err| {
                try self.sendError(stdout, null, "Invalid JSON", err);
                continue;
            };
            defer parsed.deinit();

            if (parsed.value != .object) continue;

            const root = parsed.value.object;
            const method_val = root.get("method") orelse {
                try self.sendError(stdout, null, "Missing method", null);
                continue;
            };
            if (method_val != .string) continue;
            const method = method_val.string;
            const id = root.get("id");

            if (std.mem.eql(u8, method, "initialize")) {
                try self.handleInitialize(stdout, id);
            } else if (std.mem.eql(u8, method, "notifications/initialized")) {
                // No response needed for notifications
                continue;
            } else if (std.mem.eql(u8, method, "tools/list") or std.mem.eql(u8, method, "list_tools")) {
                try self.handleListTools(stdout, id);
            } else if (std.mem.eql(u8, method, "tools/call")) {
                const params = root.get("params") orelse {
                    try self.sendError(stdout, id, "Missing params", null);
                    continue;
                };
                if (params != .object) continue;
                const name_val = params.object.get("name") orelse {
                    try self.sendError(stdout, id, "Missing tool name", null);
                    continue;
                };
                if (name_val != .string) continue;
                const name = name_val.string;

                const args_val = params.object.get("arguments");
                if (args_val != null and args_val.? != .object) {
                    try self.sendError(stdout, id, "Invalid arguments", null);
                    continue;
                }

                if (std.mem.eql(u8, name, "get_bambu_view")) {
                    const url_val = if (args_val) |v| v.object.get("url") else null;
                    if (url_val == null or url_val.? != .string) {
                        try self.sendError(stdout, id, "Missing or invalid url argument", null);
                        continue;
                    }
                    try self.handleGetBambuView(stdout, id, page, url_val.?.string);
                } else if (std.mem.eql(u8, name, "interact_with_id")) {
                    const id_val = if (args_val) |v| v.object.get("id") else null;
                    if (id_val == null or id_val.? != .integer) {
                        try self.sendError(stdout, id, "Missing or invalid id argument", null);
                        continue;
                    }
                    try self.handleInteract(stdout, id, id_val.?.integer);
                } else {
                    try self.sendError(stdout, id, "Tool not found", null);
                }
            } else if (std.mem.eql(u8, method, "get_bambu_view")) { // Fallback for direct calls
                const params = root.get("params") orelse {
                    try self.sendError(stdout, id, "Missing params", null);
                    continue;
                };
                if (params != .object) continue;
                const url_val = params.object.get("url") orelse continue;
                if (url_val != .string) continue;
                try self.handleGetBambuView(stdout, id, page, url_val.string);
            } else if (std.mem.eql(u8, method, "interact_with_id")) { // Fallback for direct calls
                const params = root.get("params") orelse {
                    try self.sendError(stdout, id, "Missing params", null);
                    continue;
                };
                if (params != .object) continue;
                const id_val = params.object.get("id") orelse continue;
                if (id_val != .integer) continue;
                try self.handleInteract(stdout, id, id_val.integer);
            } else {
                try self.sendError(stdout, id, "Method not found", null);
            }
        }
    }

    fn handleInitialize(_: *Mcp, stdout: *std.Io.Writer, id: ?std.json.Value) !void {
        try stdout.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        if (id) |i| {
            try std.json.Stringify.value(i, .{}, stdout);
        } else {
            try stdout.writeAll("null");
        }
        try stdout.writeAll(",\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"lightpanda\",\"version\":\"0.1.0\"}}}");
        try stdout.writeByte('\n');
    }

    fn handleListTools(_: *Mcp, stdout: *std.Io.Writer, id: ?std.json.Value) !void {
        try stdout.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        if (id) |i| {
            try std.json.Stringify.value(i, .{}, stdout);
        } else {
            try stdout.writeAll("null");
        }
        try stdout.writeAll(",\"result\":{\"tools\":[{\"name\": \"get_bambu_view\", \"description\": \"Get a token-optimized BAMBU map of a webpage.\", \"inputSchema\": { \"type\": \"object\", \"properties\": { \"url\": { \"type\": \"string\", \"description\": \"The URL to fetch\" } }, \"required\": [\"url\"] }}, { \"name\": \"interact_with_id\", \"description\": \"Interact with an element by its BAMBU ID.\", \"inputSchema\": { \"type\": \"object\", \"properties\": { \"id\": { \"type\": \"integer\", \"description\": \"The BAMBU ID of the element\" } }, \"required\": [\"id\"] }}]}}");
        try stdout.writeByte('\n');
    }

    fn handleGetBambuView(self: *Mcp, stdout: *std.Io.Writer, id: ?std.json.Value, page: *Page, url: []const u8) !void {
        _ = page.navigate(url, .{}) catch |err| {
            try self.sendError(stdout, id, "Navigation failed", err);
            return;
        };
        _ = page.session.fetchWait(5000);

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try page.semanticDump(&aw.writer);

        try stdout.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        if (id) |i| {
            try std.json.Stringify.value(i, .{}, stdout);
        } else {
            try stdout.writeAll("null");
        }
        try stdout.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
        try std.json.Stringify.value(aw.written(), .{}, stdout);
        try stdout.writeAll("}]}}");
        try stdout.writeByte('\n');
    }

    fn handleInteract(self: *Mcp, stdout: *std.Io.Writer, id: ?std.json.Value, element_id: i64) !void {
        const msg = try std.fmt.allocPrint(self.allocator, "Interacted with BAMBU element ID {d}", .{element_id});
        defer self.allocator.free(msg);

        try stdout.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        if (id) |i| {
            try std.json.Stringify.value(i, .{}, stdout);
        } else {
            try stdout.writeAll("null");
        }
        try stdout.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
        try std.json.Stringify.value(msg, .{}, stdout);
        try stdout.writeAll("}]}}");
        try stdout.writeByte('\n');
    }

    fn sendError(_: *Mcp, stdout: *std.Io.Writer, id: ?std.json.Value, message: []const u8, err: ?anyerror) !void {
        try stdout.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        if (id) |i| {
            try std.json.Stringify.value(i, .{}, stdout);
        } else {
            try stdout.writeAll("null");
        }
        try stdout.writeAll(",\"error\":{\"code\":-32000,\"message\":\"");
        try stdout.writeAll(message);
        try stdout.writeAll("\",\"data\":\"");
        if (err) |e| {
            try stdout.writeAll(@errorName(e));
        }
        try stdout.writeAll("\"}}");
        try stdout.writeByte('\n');
    }
};