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

const Walker = @import("dom/walker.zig").WalkerChildren;
const Page = @import("page.zig").Page;
const parser = @import("netsurf.zig");

fn indent(depth: u32, writer: *std.Io.Writer) !void {
    for (0..depth) |_| try writer.writeAll("  ");
}

pub const SemanticDistiller = struct {
    page: *Page,
    next_id: u32 = 0,

    pub fn init(page: *Page) SemanticDistiller {
        return .{ .page = page };
    }

    pub fn write(self: *SemanticDistiller, writer: *std.Io.Writer) !void {
        const doc = parser.documentHTMLToDocument(self.page.window.document);
        try self.writeNode(parser.documentToNode(doc), writer, 0);
    }

    fn writeNode(self: *SemanticDistiller, node: *parser.Node, writer: *std.Io.Writer, depth: u32) anyerror!void {
        switch (parser.nodeType(node)) {
            .document => {
                var child = parser.nodeFirstChild(node);
                while (child) |n| {
                    try self.writeNode(n, writer, depth);
                    child = parser.nodeNextSibling(n);
                }
            },
            .element => {
                const tag_type = try parser.nodeHTMLGetTagType(node) orelse .undef;

                // Filter out non-semantic tags
                if (tag_type == .script or tag_type == .style or tag_type == .head or tag_type == .meta or tag_type == .link) {
                    return;
                }

                const tag_name = try parser.nodeLocalName(node);
                const id = self.next_id;
                self.next_id += 1;

                // Get bounding box
                const rect = try self.page.renderer.getRect(@ptrCast(node));

                try indent(depth, writer);
                try writer.print("[{d}] <{s} loc=\"{d:.0},{d:.0},{d:.0},{d:.0}\"", .{
                    id,
                    tag_name,
                    rect.x,
                    rect.y,
                    rect.width,
                    rect.height,
                });

                // Check for clickability
                if (tag_type == .button or tag_type == .a or tag_type == .input) {
                    try writer.writeAll(" action=\"click\"");
                }

                const has_children = parser.nodeFirstChild(node) != null;

                if (has_children) {
                    try writer.writeAll(">\n");

                    // Write children
                    var child: ?*parser.Node = parser.nodeFirstChild(node);
                    while (child) |n| {
                        try self.writeNode(n, writer, depth + 1);
                        child = parser.nodeNextSibling(n);
                    }

                    try indent(depth, writer);
                    try writer.print("</{s}>\n", .{tag_name});
                } else {
                    try writer.print("></{s}>\n", .{tag_name});
                }
            },
            .text => {
                const v = parser.nodeValue(node) orelse return;
                const trimmed = std.mem.trim(u8, v, &std.ascii.whitespace);
                if (trimmed.len > 0) {
                    try indent(depth, writer);
                    try writer.writeAll(trimmed);
                    try writer.writeAll("\n");
                }
            },
            else => {},
        }
    }
};
