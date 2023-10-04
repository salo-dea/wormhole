//TODO:
// text search for fast nav?

const std = @import("std");
const ncurses = @cImport({
    @cInclude("ncurses.h");
});

const NcursesError = error{
    Generic,
};

const WormholeErrors = error{ NoParent, NoDir };

const File = struct {
    path: []u8,
    kind: std.fs.File.Kind,
};

const DirExplorer = struct {
    const Self = @This();
    current_dir: []u8,
    allocator: std.mem.Allocator,
    contents: std.ArrayList(File),
    cursor: i32 = 0,

    pub fn init(allocator: std.mem.Allocator, start_dir: []const u8) !DirExplorer {
        return DirExplorer{ .current_dir = try std.fs.cwd().realpathAlloc(allocator, "."), .contents = try listdir(allocator, start_dir), .allocator = allocator };
    }
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.current_dir);
        self.contents.deinit();
    }

    fn refresh(self: *Self) !void {
        self.contents.deinit();
        self.contents = try listdir(self.allocator, self.current_dir);
        self.cursor = 0;
    }

    pub fn move_cursor(self: *Self, move: i32) void {
        const max_cursor: i32 = @intCast(self.contents.items.len);
        self.cursor = @mod(self.cursor + move, max_cursor);
    }

    pub fn get_cursor(self: Self) usize {
        return @intCast(self.cursor);
    }

    pub fn go_up(self: *Self) !void {
        var i = self.current_dir.len - 1;
        while (i > 0) : (i -= 1) {
            if (self.current_dir[i] == '/') {
                self.current_dir.len = i;
                try self.refresh();
                return;
            }
        }
        return WormholeErrors.NoParent;
    }

    pub fn enter(self: *Self, target_dir: File) !void {
        if (target_dir.kind == std.fs.File.Kind.directory) {
            const last_dir = self.current_dir;
            defer self.allocator.free(last_dir);

            self.current_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.current_dir, target_dir.path });
            try self.refresh();
        } else {
            return WormholeErrors.NoDir;
        }
    }
};

pub fn main() !void {
    //try mytest();
    var alloc = std.heap.page_allocator; // std.heap.GeneralPurposeAllocator(.{}).allocator();
    try print_dir_contents(alloc);
}

fn getch() NcursesError!usize {
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

fn print_dir_contents(alloc: std.mem.Allocator) !void {
    var win = ncurses.initscr();
    _ = win;
    defer _ = ncurses.endwin();

    _ = ncurses.keypad(ncurses.stdscr, true);
    _ = ncurses.noecho();
    _ = ncurses.cbreak();

    var dir_exp = try DirExplorer.init(alloc, ".");
    defer dir_exp.deinit();

    main_loop: while (true) {
        try ncurse_print(alloc, "-> {s} \n", .{dir_exp.current_dir});

        const dirs = &dir_exp.contents;
        for (0.., dirs.items) |i, dir| {
            //defer alloc.free(cstring);
            const highlighted: bool = i == dir_exp.cursor;

            if (highlighted) {
                _ = ncurses.attron(ncurses.COLOR_PAIR(5) | ncurses.A_BOLD);
            }

            switch (dir.kind) {
                .directory => try ncurse_print(alloc, "[{d}] {s} \n", .{ i, dir.path }),
                else => try ncurse_print(alloc, " - {s} \n", .{dir.path}),
            }

            if (highlighted) {
                _ = ncurses.attroff(ncurses.COLOR_PAIR(5) | ncurses.A_BOLD);
            }
        }
        _ = ncurses.refresh();
        var key: usize = getch() catch 255;
        _ = ncurses.move(0, 0); //reset cursor
        _ = ncurses.clear();

        switch (key) {
            '0'...'9' => {
                const idx = key - '0';
                try dir_exp.enter(dirs.items[idx]);
            },
            ncurses.KEY_DOWN => dir_exp.move_cursor(1),
            ncurses.KEY_UP => dir_exp.move_cursor(-1),
            '\n' => try dir_exp.enter(dirs.items[dir_exp.get_cursor()]),
            ncurses.KEY_LEFT, ncurses.KEY_BACKSPACE => try dir_exp.go_up(),
            std.ascii.control_code.esc => break :main_loop,
            else => std.debug.print("UNKNOWN KEY: {d} \n", .{key}),
        }

        //_ = ncurses.mvchgat(selection, 0, -1, ncurses.A_UNDERLINE, @intCast(ncurses.COLOR_PAIR(ncurses.COLOR_WHITE)), null);
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

fn file_less_than(context: void, file_a: File, file_b: File) bool {

    //directories first
    if (file_a.kind != file_b.kind and (file_a.kind == std.fs.File.Kind.directory or file_b.kind == std.fs.File.Kind.directory)) {
        return file_a.kind == std.fs.File.Kind.directory;
    }
    // everything else sorted by name
    return str_less_than(context, file_a.path, file_b.path);
}

fn listdir(alloc: std.mem.Allocator, dirname: []const u8) !std.ArrayList(File) {
    const dir = try std.fs.cwd().openIterableDir(dirname, .{});
    var iterator = dir.iterate();
    var dirlist: std.ArrayList(File) = std.ArrayList(File).init(alloc);

    while (try iterator.next()) |path| {
        try dirlist.append(File{ .path = try std.fmt.allocPrint(alloc, "{s}", .{path.name}), .kind = path.kind });
    }
    std.sort.block(File, dirlist.items, {}, file_less_than);
    return dirlist;
}
