//TODO:
// text search for fast nav?

const std = @import("std");
const builtin = @import("builtin");
const ncurses = @cImport({
    @cInclude("curses.h");
});

const STDIN = 0;
const STDOUT = 1;
const STDERR = 2;

const NcursesError = error{
    Generic,
};

const WormholeErrors = error{
    NoParent,
    NoDir,
    FullBuffer,
};

const File = struct {
    path: []u8,
    kind: std.fs.File.Kind,
};

const DirExplorer = struct {
    const Self = @This();
    current_dir: []u8,
    allocator: std.mem.Allocator,
    contents: std.ArrayList(File),

    pub fn init(allocator: std.mem.Allocator, start_dir: []const u8) !DirExplorer {
        return DirExplorer{
            .current_dir = try std.fs.cwd().realpathAlloc(allocator, "."),
            .contents = try listdir(allocator, start_dir),
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.current_dir);
        self.contents.deinit();
    }

    fn refresh(self: *Self) !void {
        self.contents.deinit();
        self.contents = try listdir(self.allocator, self.current_dir);
    }

    pub fn go_up(self: *Self) !void {
        var i = self.current_dir.len - 1;
        while (i > 0) : (i -= 1) {
            if (self.current_dir[i] == '/' or self.current_dir[i] == '\\') {
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

const DirView = struct {
    const Self = @This();

    exp: *DirExplorer,
    filter: EditableString,
    visible_files: std.ArrayList(File),
    cursor: i32 = 0,

    fn init(allocator: std.mem.Allocator, dir_exp: *DirExplorer) !DirView {
        return DirView{
            .exp = dir_exp,
            .filter = try EditableString.init(allocator, 255),
            .visible_files = try dir_exp.contents.clone(),
        };
    }

    fn reset_filter(self: *DirView) void {
        self.filter.reset();
    }

    fn apply_filter(self: *DirView, thresh: usize) !void {
        self.visible_files.resize(0) catch unreachable;

        for (self.exp.contents.items) |file| {
            const match_score = str_match(file.path, self.filter.cur);
            if (match_score > thresh) {
                try self.visible_files.append(file);
            }
        }

        self.move_cursor(0); //TODO stick cursor to the previously selected entry....
    }

    pub fn move_cursor(self: *Self, move: i32) void {
        const max_cursor: i32 = @intCast(self.visible_files.items.len);

        if (max_cursor != 0) {
            self.cursor = @mod(self.cursor + move, max_cursor);
        } else {
            self.cursor = 0;
        }
    }

    pub fn get_cursor(self: Self) usize {
        return @intCast(self.cursor);
    }

    // call after dir_exp changed to new dir
    // TODO set up some kind of event?
    pub fn new_dir(self: *Self) !void {
        self.cursor = 0;
        self.reset_filter();
    }
};

const EditableString = struct {
    const Self = @This();

    max_size: usize,
    cur: []u8,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) !EditableString {
        var new = EditableString{
            .max_size = max_size,
            .cur = try allocator.alloc(u8, max_size),
        };
        new.cur.len = 0;
        return new;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        //TODO does the size matter for free?
        allocator.free(self.cur);
    }

    pub fn reset(self: *Self) void {
        self.cur.len = 0;
    }

    pub fn backspace(self: *Self) void {
        if (self.cur.len != 0) {
            self.cur.len -= 1;
        }
    }

    pub fn add_char(self: *Self, char: u8) !void {
        if (self.cur.len == self.max_size) {
            return WormholeErrors.FullBuffer;
        }
        self.cur.len += 1;
        self.cur[self.cur.len - 1] = char;
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

fn str_match(str: []const u8, pattern: []const u8) usize {
    var minlen: usize = @min(str.len, pattern.len);
    for (str[0..minlen], pattern[0..minlen], 0..) |a, b, idx| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) {
            var new_str = str;
            new_str.ptr = str.ptr + 1;
            new_str.len = str.len - 1;
            const sub_match = str_match(new_str, pattern);
            return @max(idx, sub_match);
        }
    }
    return if (pattern.len == minlen) std.math.maxInt(usize) else minlen; //complete match
}

fn print_dir_contents(alloc: std.mem.Allocator) !void {
    //init ncurses with newterm like this -> ncurses outputs to stderr, and we can print to stdout for directory change
    var screen = switch (builtin.os.tag) {
        .windows => ncurses.newterm(null, STDERR, STDIN),
        else => ncurses.newterm(null, ncurses.stderr, ncurses.stdin),
    };
    _ = screen;

    _ = ncurses.keypad(ncurses.stdscr, true);
    _ = ncurses.noecho();
    _ = ncurses.cbreak();

    var dir_exp = try DirExplorer.init(alloc, ".");
    defer dir_exp.deinit();

    var dir_view = try DirView.init(alloc, &dir_exp); //TODO deinit

    main_loop: while (true) {
        _ = ncurses.clear();
        const dirs = &dir_view.visible_files;

        _ = ncurses.move(0, 0); //reset cursor
        try ncurse_print(alloc, "-> {s} \n", .{dir_exp.current_dir});

        for (0.., dirs.items) |i, dir| {

            //filter mechanism
            //defer alloc.free(cstring);
            const highlighted: bool = i == dir_view.get_cursor();

            if (highlighted) {
                _ = ncurses.attron(ncurses.A_STANDOUT);
            }

            switch (dir.kind) {
                .directory => try ncurse_print(alloc, "[{d}] {s} \n", .{ i, dir.path }),
                else => try ncurse_print(alloc, " - {s} \n", .{dir.path}),
            }

            if (highlighted) {
                _ = ncurses.attroff(ncurses.A_STANDOUT);
            }
        }
        //const maxy = ncurses.getmaxy(win);
        //_ = ncurses.move(maxy - 1, 0);
        try ncurse_print(alloc, ">> {s}", .{dir_view.filter.cur});

        _ = ncurses.refresh();
        var key: usize = getch() catch 255;

        switch (key) {
            ncurses.KEY_DOWN => dir_view.move_cursor(1),
            ncurses.KEY_UP => dir_view.move_cursor(-1),
            ncurses.KEY_RIGHT, '\n' => {
                try dir_exp.enter(dir_view.visible_files.items[dir_view.get_cursor()]);
                try dir_view.new_dir();
            },
            ncurses.KEY_LEFT => {
                dir_exp.go_up() catch {};
                try dir_view.new_dir();
            },
            ncurses.KEY_BACKSPACE, std.ascii.control_code.bs => dir_view.filter.backspace(),
            std.ascii.control_code.esc => break :main_loop,
            else => std.debug.print("UNKNOWN KEY: {d} \n", .{key}),
        }

        if (key <= std.math.maxInt(u8) and !std.ascii.isControl(@intCast(key))) {
            dir_view.filter.add_char(@intCast(key)) catch {}; //TODO handle error?
        }

        try dir_view.apply_filter(500);
    }

    _ = ncurses.endwin();

    // print the current directory to stdout so that the calling script can cd to it
    try std.io.getStdOut().writer().print("{s}\n", .{dir_exp.current_dir});
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
        try dirlist.append(File{
            .path = try std.fmt.allocPrint(alloc, "{s}", .{path.name}),
            .kind = path.kind,
        });
    }
    std.sort.block(File, dirlist.items, {}, file_less_than);
    return dirlist;
}
