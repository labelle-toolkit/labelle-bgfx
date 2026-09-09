const std = @import("std");

/// Preserve an existing TGA suffix; bare paths retain the historical suffix.
pub fn tgaPath(buffer: []u8, path: []const u8) error{NoSpaceLeft}![:0]u8 {
    const has_suffix = path.len >= 4 and std.ascii.eqlIgnoreCase(path[path.len - 4 ..], ".tga");
    return std.fmt.bufPrintZ(buffer, "{s}{s}", .{ path, if (has_suffix) "" else ".tga" });
}

test "TGA paths preserve existing extensions and reject overflow" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("shot.tga", try tgaPath(&buffer, "shot"));
    try std.testing.expectEqualStrings("shot.tga", try tgaPath(&buffer, "shot.tga"));
    try std.testing.expectEqualStrings("shot.TGA", try tgaPath(&buffer, "shot.TGA"));
    try std.testing.expectEqualStrings("folder.tga/shot.tga", try tgaPath(&buffer, "folder.tga/shot"));
    var exact: [9]u8 = undefined;
    try std.testing.expectEqualStrings("shot.tga", try tgaPath(&exact, "shot.tga"));
    var small: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, tgaPath(&small, "shot.tga"));
}
