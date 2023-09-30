//TODO:
// print full cwd
// allow going up
// implement cursor
//  - text search for fast nav?

const std = @import("std");
const ncurses = @cImport({
    @cInclude("ncurses.h");
});

const NcursesError = error{
    Generic,
};

const WormholeErrors = error{
    NoParent,
};

pub fn main() !void {
    //try mytest();
    var alloc = std.heap.c_allocator; // std.heap.GeneralPurposeAllocator(.{}).allocator();
    try print_dir_contents(alloc);
}

fn getch() NcursesError!u8 {
    var val = ncurses.getch();
    if (val < 0) {
        return NcursesError.Generic;
    } else {
        return @intCast(val);
    }
}

fn ncurse_print(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    var buf = try std.fmt.allocPrintZ(alloc, fmt, args);
    defer alloc.free(buf);
    _ = ncurses.printw(buf.ptr);
}

fn go_up(path: *[]u8) !void {
    var i = path.len - 1;
    while (i > 0) : (i -= 1) {
        if (path.*[i] == '/') {
            path.len = i;
            return;
        }
    }
    return WormholeErrors.NoParent;
}

fn print_dir_contents(alloc: std.mem.Allocator) !void {
    var win = ncurses.initscr();
    _ = win;
    defer _ = ncurses.endwin();
    _ = ncurses.noecho();
    _ = ncurses.cbreak();

    var cur_dir = try std.fs.cwd().realpathAlloc(alloc, ".");
    while (true) {
        try ncurse_print(alloc, "-> {s} \n", .{cur_dir});
        var dirs = try listdir(alloc, cur_dir);
        defer dirs.deinit();

        for (0.., dirs.items) |i, dir| {
            //defer alloc.free(cstring);
            try ncurse_print(alloc, "[{d}] {s} \n", .{ i, dir });
        }
        _ = ncurses.refresh();
        var key: usize = getch() catch 255;
        _ = ncurses.move(0, 0); //reset cursor
        _ = ncurses.clear();
        if (key < '0') {
            std.debug.print("BREAK_ERLY \n", .{});
            break;
        }

        if (key == 'u') {
            try go_up(&cur_dir);
            continue;
        }

        key -= '0';

        if (key < dirs.items.len) {
            const last_dir = cur_dir;
            cur_dir = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ cur_dir, dirs.items[key] });
            alloc.free(last_dir);
        } else {
            std.debug.print("BREAK\n", .{});
            break;
        }
    }
}

fn str_less_than(context: void, str_a: []const u8, str_b: []const u8) bool {
    _ = context;
    var minlen: usize = @min(str_a.len, str_b.len);
    for (str_a[0..minlen], str_b[0..minlen]) |a, b| {
        if (a != b) {
            return a < b;
        }
    }
    return str_a.len < str_b.len;
}

fn listdir(alloc: std.mem.Allocator, dirname: []const u8) !std.ArrayList([]const u8) {
    const dir = try std.fs.cwd().openIterableDir(dirname, .{});
    var iterator = dir.iterate();

    var dirlist: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(alloc);

    while (try iterator.next()) |path| {
        //        try dirlist.append(path.name); //try std.fmt.allocPrint(alloc, "{s}", .{path.name}));
        try dirlist.append(try std.fmt.allocPrint(alloc, "{s}", .{path.name}));
    }
    std.sort.block([]const u8, dirlist.items, {}, str_less_than);
    return dirlist;
}

fn mytest() !void {
    var alloc = std.heap.page_allocator;
    var dirs = try listdir(alloc, ".");
    _ = ncurses.initscr();
    defer _ = ncurses.endwin();
    //var dirs2 = try listdir(".");
    //_ = dirs2;
    var buf = try std.fmt.allocPrint(alloc, "{s}", .{dirs.items[0]});
    var bufZ = try std.fmt.allocPrintZ(alloc, "[{d}] {s}", .{ 1, buf });
    std.debug.print("buf : {s}\n", .{buf});
    std.debug.print("bufZ : {s}\n", .{bufZ});
    _ = ncurses.initscr();
    defer _ = ncurses.endwin();
    std.debug.print("buf : {s}\n", .{buf});
    std.debug.print("bufZ : {s}\n", .{bufZ});
}

test "mytest" {
    _ = ncurses.initscr();
    var dirs = try listdir(".");
    _ = ncurses.endwin();
    var alloc = std.heap.page_allocator;
    var buf = try std.fmt.allocPrint(alloc, "{s}", .{dirs.items[0]});
    var bufZ = try std.fmt.allocPrintZ(alloc, "[{d}] {s}", .{ 1, buf });
    std.debug.print("buf : {s}", .{buf});
    std.debug.print("bufZ : {s}", .{bufZ});
    _ = ncurses.initscr();
    defer _ = ncurses.endwin();
    std.debug.print("buf : {s}", .{buf});
    std.debug.print("bufZ : {s}", .{bufZ});
}
