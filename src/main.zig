const std = @import("std");
const builtin = @import("builtin");
const ncurses = @cImport({
    @cInclude("curses.h");
});

const winapi = switch (builtin.os.tag) {
    .windows => @cImport({
        @cInclude("fileapi.h");
    }),
    else => undefined,
};
const WinApiError = error{
    Generic,
};

const STDIN = 0;
const STDOUT = 1;
const STDERR = 2;

// Virtual key codes for vscode integrated terminal
const VIRTUAL_KEY_DOWN = 456;
const VIRTUAL_KEY_UP = 450;
const VIRTUAL_KEY_RIGHT = 454;
const VIRTUAL_KEY_LEFT = 452;
const VIRTUAL_KEY_BACKSPACE = 3;

//TODO: understand if this is the proper way
fn ctrl(comptime key: comptime_int) comptime_int {
    return ((key) & 0x1f);
}

const NcursesError = error{
    Generic,
};

const WormholeErrors = error{
    NoParent,
    NoDir,
    UnsupportedPath,
    FullBuffer,
};

const File = struct {
    path: []u8,
    kind: std.fs.File.Kind,
};

const DirExplorer = struct {
    const Self = @This();
    current_dir_alloc_size: usize,
    current_dir: []u8,
    allocator: std.mem.Allocator,
    contents: std.ArrayList(File),
    look_depth: usize = 0,
    show_hidden: bool = false,
    last_err: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator, start_dir: []const u8) !DirExplorer {
        const cwd = try std.fs.cwd().realpathAlloc(allocator, start_dir);
        defer allocator.free(cwd);
        str_replace(cwd, '\\', '/'); //force forward slashes, also on windows

        const current_dir = try std.fmt.allocPrint(allocator, "{s}/", .{cwd});
        return DirExplorer{
            .current_dir_alloc_size = current_dir.len,
            .current_dir = current_dir,
            .contents = try listdir(allocator, start_dir, .{ .recurse_depth = 0, .show_hidden = false }),
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *Self) void {
        self.current_dir.len = self.current_dir_alloc_size;
        self.allocator.free(self.current_dir);
        self.free_contents();
    }

    pub fn set_look_depth(self: *Self, new_depth: usize) !void {
        self.look_depth = new_depth;
        try self.refresh();
    }

    pub fn set_show_hidden(self: *Self, new_val: bool) !void {
        self.show_hidden = new_val;
        try self.refresh();
    }

    fn free_contents(self: *Self) void {
        for (self.contents.items) |value| {
            self.allocator.free(value.path);
        }
        self.contents.deinit();
        self.contents.items.len = 0;
    }

    fn refresh(self: *Self) !void {
        self.free_contents();
        self.contents = listdir(self.allocator, self.current_dir, .{
            .recurse_depth = self.look_depth,
            .show_hidden = self.show_hidden,
        }) catch |err| {
            self.contents = std.ArrayList(File).init(self.allocator);
            return err;
        };
    }

    pub fn go_up(self: *Self) !void {
        const last_dir_len = self.current_dir.len;
        var i = self.current_dir.len -| 2;
        self.current_dir.len = while (i > 0) : (i -= 1) {
            if (self.current_dir[i - 1] == '/') {
                break i;
            }
        } else 0;
        self.look_depth = 0; //reset look depth, maybe rethink
        self.refresh() catch |err| {
            // reset length, otherwise we may get stuck at '/' if we don't have access there
            self.current_dir.len = last_dir_len;
            self.last_err = err;
            try self.refresh(); // should always succeed
        };
        return;
    }

    const EnterResultKind = enum {
        NewDir,
        IsFile,
    };

    const EnterResult = union(EnterResultKind) {
        NewDir: void,
        IsFile: []u8,
    };

    pub fn enter(self: *Self, target_dir: File) !EnterResult {
        switch (target_dir.kind) {
            .directory => {
                var last_dir = self.current_dir; // must be freed at the end ONLY if successful!

                self.current_dir = try std.fmt.allocPrint(self.allocator, "{s}{s}/", .{ self.current_dir, target_dir.path });
                self.refresh() catch |err| {
                    self.last_err = err;
                    self.allocator.free(self.current_dir);
                    self.current_dir = last_dir;
                    try self.refresh(); // should never fail, we're in the previous directory
                    return .NewDir;
                };
                last_dir.len = self.current_dir_alloc_size; //to properly free... but this sucks
                self.current_dir_alloc_size = self.current_dir.len;
                self.look_depth = 0; //reset look depth, maybe rethink
                self.allocator.free(last_dir);
                return .NewDir;
            },
            .file => {
                const file_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.current_dir, target_dir.path });
                return .{ .IsFile = file_path };
            },
            else => return WormholeErrors.UnsupportedPath,
        }
    }

    pub fn currentDirOwned(self: *Self) ![]u8 {
        return self.alloc.dupe(u8, self.current_dir);
    }
};

const DirView = struct {
    const Self = @This();

    exp: *DirExplorer,
    filter: EditableString,
    visible_files: std.ArrayList(File),
    cursor: usize = 0,
    view_start_idx: usize = 0,

    const Direction = enum { Down, Up };

    const DirectionMove = union(Direction) {
        Down: usize,
        Up: usize,
    };

    pub fn init(allocator: std.mem.Allocator, dir_exp: *DirExplorer) !DirView {
        return DirView{
            .exp = dir_exp,
            .filter = try EditableString.init(allocator, 255),
            .visible_files = try dir_exp.contents.clone(),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        //TODO: paths that visible_files are referring to are actually owned by the dir_exp (janky)
        self.filter.deinit(allocator);
        self.visible_files.deinit();
    }

    pub fn reset_filter(self: *DirView) void {
        self.filter.reset();
    }

    pub fn apply_filter(self: *DirView, thresh: usize) !void {
        //we want to apply the last cursor position , if the element that was previously highlighted,
        //is still there, it should have the cursor again - otherwise the one before it
        //TODO this needs to be reworked.. if the underlying dir_exp is refreshed then this pointer has been freed already
        // and a new string allocated --> need some persistent state where we don't completely re-read all the dirs -> tree structure!
        var current_file_ptr: ?[*]u8 = null;
        if (self.visible_files.items.len > self.cursor) {
            current_file_ptr = self.visible_files.items[self.cursor].path.ptr;
        }

        self.visible_files.resize(0) catch unreachable;

        var new_cursor: usize = 0;

        //main filter stuff here
        for (self.exp.contents.items) |file| {
            const match_score = str_match(file.path, self.filter.cur);
            if (match_score > thresh) {
                try self.visible_files.append(file);
            }
            if (current_file_ptr) |cur_file_ptr| {
                if (cur_file_ptr == file.path.ptr and self.visible_files.items.len != 0) {
                    new_cursor = self.visible_files.items.len - 1;
                }
            }
        }
        self.cursor = new_cursor;
    }

    pub fn move_cursor(self: *Self, move: DirectionMove) void {
        const max_cursor = self.visible_files.items.len;
        if (max_cursor == 0) {
            self.cursor = 0;
            return;
        }

        const moved = switch (move) {
            .Up => |val| if (self.cursor == 0) max_cursor - 1 else self.cursor -| val,
            .Down => |val| self.cursor +| val,
        };
        self.cursor = @mod(moved, max_cursor);
    }

    pub fn move_page(self: *Self, move: DirectionMove, num_lines_reserve: usize) !void {
        const result = ncurses.getmaxy(ncurses.stdscr);
        if (result < 0) {
            return NcursesError.Generic;
        }
        const term_lines: usize = @intCast(result);
        if (term_lines < num_lines_reserve) {
            return; //this means we cannot print anything...
        }

        const used_viewport_space = term_lines - num_lines_reserve;
        const prev_start_idx = self.view_start_idx;

        self.view_start_idx = switch (move) {
            .Up => |val| self.view_start_idx -| (val * used_viewport_space),
            .Down => |val| @min(self.view_start_idx +| (val * used_viewport_space), self.visible_files.items.len -| used_viewport_space),
        };
        self.cursor = switch (move) {
            .Up => self.cursor -| (prev_start_idx - self.view_start_idx),
            .Down => @min(self.cursor +| (self.view_start_idx - prev_start_idx), self.visible_files.items.len - 1),
        };
    }

    pub fn print(self: *Self, alloc: std.mem.Allocator, num_lines_reserve: usize) !void {
        //TODO: issue - at the end the "..." correctly disappears to show that there are no more
        //              entries, but it doesn't get filled by an entry, pulling the search bar up
        const result = ncurses.getmaxy(ncurses.stdscr);
        if (result < 0) {
            return NcursesError.Generic;
        }
        const term_lines: usize = @intCast(result);
        if (term_lines < num_lines_reserve) {
            return; //this means we cannot print anything...
        }

        const used_viewport_space = term_lines -| num_lines_reserve -| 1; //-1 to reserve space for "..."

        //handling of view_start_idx_being further down than it needs to be
        if (self.view_start_idx + used_viewport_space > self.visible_files.items.len) {
            self.view_start_idx = self.visible_files.items.len -| used_viewport_space;
        }

        //handling of cursor exiting the screen at the top or bottom
        if (self.cursor >= self.view_start_idx + used_viewport_space) {
            self.view_start_idx = self.cursor -| used_viewport_space + 1;
        } else if (self.cursor < self.view_start_idx) {
            self.view_start_idx = self.cursor;
        }

        const max_viewport_idx = self.view_start_idx + used_viewport_space;
        const max = @min(max_viewport_idx, self.visible_files.items.len);
        for (self.view_start_idx..max) |i| {
            const dir = self.visible_files.items[i];
            const highlighted: bool = i == self.cursor;

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
        if (max_viewport_idx < self.visible_files.items.len) {
            const remaining_files = self.visible_files.items.len - max_viewport_idx;
            try ncurse_print(alloc, "[..{d}]\n", .{remaining_files});
        }
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
        self.cur.len = self.max_size; //the size DOES matter!
        allocator.free(self.cur);
    }

    pub fn reset(self: *Self) void {
        self.cur.len = 0;
    }

    pub fn backspace(self: *Self) void {
        self.cur.len -|= 1;
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
    //var alloc = std.heap.page_allocator; // std.heap.GeneralPurposeAllocator(.{}).allocator();
    var alloc = std.heap.GeneralPurposeAllocator(.{}){};

    try print_dir_contents(alloc.allocator());
    _ = alloc.detectLeaks();
}

fn getch() NcursesError!usize {
    const val = ncurses.getch();
    if (val < 0) {
        return NcursesError.Generic;
    } else {
        return @intCast(val);
    }
}

fn ncurse_print(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const buf = try std.fmt.allocPrintZ(alloc, fmt, args);
    defer alloc.free(buf);
    _ = ncurses.printw(buf.ptr);
}

fn str_match(str: []const u8, pattern: []const u8) usize {
    const minlen: usize = @min(str.len, pattern.len);
    for (str[0..minlen], pattern[0..minlen], 0..) |a, b, idx| {
        if (b == '*') {
            var new_pat = pattern;
            new_pat.ptr += idx + 1;
            new_pat.len -= idx + 1;

            var new_str = str;
            new_str.ptr += idx;
            new_str.len -= idx;

            const sub_match = str_match(new_str, new_pat);
            return @max(idx, sub_match);
        }

        if (std.ascii.toLower(a) != std.ascii.toLower(b)) {
            var new_str = str;
            new_str.ptr += 1;
            new_str.len -= 1;

            const sub_match = str_match(new_str, pattern);
            return @max(idx, sub_match);
        }
    }
    return if (pattern.len == minlen) std.math.maxInt(usize) else minlen; //complete match
}

const UserAction = enum {
    FilterBackspace,
    CursorDown,
    CursorUp,
    GoUp,
    HiddenToggle,
    Open,
    PageDown,
    PageUp,
    RecurseDecrease,
    RecurseIncrease,
    RecurseToggle,
    ExitCd,
    ExitNoCd,
    FilterAddChar,
    Unknown,
};

fn map_key(key: usize) UserAction {
    return switch (key) {
        ncurses.KEY_DOWN, VIRTUAL_KEY_DOWN => .CursorDown,
        ncurses.KEY_UP, VIRTUAL_KEY_UP => .CursorUp,
        ncurses.KEY_RIGHT, VIRTUAL_KEY_RIGHT, '\n' => .Open,
        ncurses.KEY_LEFT, VIRTUAL_KEY_LEFT => .GoUp,
        ncurses.KEY_PPAGE => .PageUp,
        ncurses.KEY_NPAGE => .PageDown,
        ncurses.KEY_BACKSPACE, VIRTUAL_KEY_BACKSPACE, std.ascii.control_code.bs => .FilterBackspace,
        std.ascii.control_code.esc => .ExitCd,
        ctrl('s') => .RecurseIncrease,
        ctrl('a') => .RecurseDecrease,
        ctrl('r') => .RecurseToggle,
        ctrl('y') => .HiddenToggle,
        ctrl('x') => .ExitNoCd,
        else => if (key <= std.math.maxInt(u8) and !std.ascii.isControl(@intCast(key))) .FilterAddChar else .Unknown,
    };
}

fn navigate(alloc: std.mem.Allocator) ![]u8 {
    var dir_exp = try DirExplorer.init(alloc, ".");
    defer dir_exp.deinit();

    var dir_view = try DirView.init(alloc, &dir_exp);
    defer dir_view.deinit(alloc); //must happen before DirExplorer deinit

    while (true) {
        _ = ncurses.clear();

        _ = ncurses.move(0, 0); //reset cursor
        const lines_used = 2; //lines printed directly by this function

        // print error information, if available
        if (dir_exp.last_err) |err| {
            try ncurse_print(alloc, "[ERR: {s} ] ", .{@errorName(err)});
            dir_exp.last_err = null;
        }
        try ncurse_print(alloc, "[r={d}, h={any}] -> {s} \n", .{ dir_exp.look_depth, dir_exp.show_hidden, dir_exp.current_dir });

        try dir_view.print(alloc, lines_used);

        //const maxy = ncurses.getmaxy(win);
        //_ = ncurses.move(maxy - 1, 0);
        try ncurse_print(alloc, "> {s}", .{dir_view.filter.cur});

        _ = ncurses.refresh();
        const key: usize = getch() catch 255;

        const action = map_key(key);
        switch (action) {
            .Open => {
                if (dir_view.visible_files.items.len != 0) {
                    const target_file = dir_view.visible_files.items[dir_view.cursor];
                    const enter_res = try dir_exp.enter(target_file);
                    switch (enter_res) {
                        .NewDir => try dir_view.new_dir(),
                        .IsFile => |file| return file,
                    }
                }
            },
            .GoUp => {
                try dir_exp.go_up();
                try dir_view.new_dir();
            },
            .CursorDown => dir_view.move_cursor(.{ .Down = 1 }),
            .CursorUp => dir_view.move_cursor(.{ .Up = 1 }),
            .ExitCd => return try alloc.dupe(u8, dir_exp.current_dir),
            .ExitNoCd => return try alloc.dupe(u8, "."), //exit without dirchange
            .FilterAddChar => dir_view.filter.add_char(@intCast(key)) catch {},
            .FilterBackspace => dir_view.filter.backspace(),
            .HiddenToggle => try dir_exp.set_show_hidden(!dir_exp.show_hidden),
            .PageDown => try dir_view.move_page(.{ .Down = 1 }, lines_used), //page down
            .PageUp => try dir_view.move_page(.{ .Up = 1 }, lines_used), //page up
            .RecurseDecrease => try dir_exp.set_look_depth(dir_exp.look_depth -| 1),
            .RecurseIncrease => try dir_exp.set_look_depth(dir_exp.look_depth +| 1),
            .RecurseToggle => try dir_exp.set_look_depth(if (dir_exp.look_depth == 0) 5 else 0),
            .Unknown => std.debug.print("UNKNOWN KEY: {d} \n", .{key}),
        }

        try dir_view.apply_filter(500);
    }
}

fn print_dir_contents(alloc: std.mem.Allocator) !void {
    //init ncurses with newterm like this -> ncurses outputs to stderr, and we can print to stdout for directory change
    const screen = switch (builtin.os.tag) {
        .windows => ncurses.newterm(null, STDERR, STDIN),
        else => ncurses.newterm(null, ncurses.stdout, ncurses.stdin),
    };
    _ = screen;

    _ = ncurses.keypad(ncurses.stdscr, true);
    _ = ncurses.noecho();

    const target_file = try navigate(alloc);
    defer alloc.free(target_file);

    _ = ncurses.endwin();

    // print the current directory to special file so that the calling script can cd to it
    var file = try std.fs.cwd().createFile(".fastnav-wormhole", .{});
    defer file.close();
    _ = try file.write(target_file);
}

fn str_less_than(context: void, str_a: []const u8, str_b: []const u8, comptime case_sensitive: bool) bool {
    _ = context;
    const minlen: usize = @min(str_a.len, str_b.len);
    for (str_a[0..minlen], str_b[0..minlen]) |a, b| {
        var a_ = a;
        var b_ = b;
        if (case_sensitive) {
            a_ = std.ascii.toLower(a);
            b_ = std.ascii.toLower(b);
        }

        if (a_ != b_) {
            return a_ < b_;
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
    return str_less_than(context, file_a.path, file_b.path, true);
}

fn str_replace(str: []u8, from: u8, to: u8) void {
    for (0..str.len) |i| {
        if (str[i] == from) {
            str[i] = to;
        }
    }
}

const ListdirOptions = struct {
    recurse_depth: usize = 0,
    show_hidden: bool = true,
};

fn listdir(alloc: std.mem.Allocator, dirname: []const u8, options: ListdirOptions) !std.ArrayList(File) {

    //handle case of drive letters
    if (builtin.os.tag == .windows and dirname.len == 0) {
        return list_drive_letters(alloc);
    }

    // var dir = std.fs.cwd().openDir(dirname, .{ .iterate = true }) catch |err| switch (err) {
    //     std.fs.Dir.OpenError.AccessDenied => return std.ArrayList(File).init(alloc), //empty list
    //     else => return err,
    // };
    var dir = try std.fs.cwd().openDir(dirname, .{ .iterate = true });
    defer dir.close();

    var iterator = dir.iterate();
    var dirlist: std.ArrayList(File) = std.ArrayList(File).init(alloc);
    errdefer dirlist.deinit();

    while (try iterator.next()) |path| {
        if (!options.show_hidden and path.name[0] == '.') {
            //skip hidden files/folders if desired
            //TODO: understand how to get file attributes on windows
            continue;
        }

        try dirlist.append(File{
            .path = try alloc.dupe(u8, path.name),
            .kind = path.kind,
        });

        if (path.kind == .directory and options.recurse_depth > 0) {
            const subfolder = try std.fmt.allocPrint(alloc, "{s}{s}/", .{ dirname, path.name });
            defer alloc.free(subfolder);

            var subfolder_paths = try listdir(alloc, subfolder, .{
                .recurse_depth = options.recurse_depth - 1,
                .show_hidden = options.show_hidden,
            });
            defer subfolder_paths.deinit();

            for (subfolder_paths.items) |*subitem| {
                const subitem_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ path.name, subitem.path });
                alloc.free(subitem.path);
                subitem.path = subitem_path;
            }
            try dirlist.appendSlice(subfolder_paths.items);
        }
    }
    std.sort.block(File, dirlist.items, {}, file_less_than);
    return dirlist;
}

fn list_drive_letters(alloc: std.mem.Allocator) !std.ArrayList(File) {
    var dirlist: std.ArrayList(File) = std.ArrayList(File).init(alloc);
    errdefer dirlist.deinit();

    const drv_bitmask = winapi.GetLogicalDrives();
    if (drv_bitmask == 0) {
        return WinApiError.Generic;
    }
    const one: @TypeOf(drv_bitmask) = 1;
    var i: u5 = 0;
    //forgive me for hardcoding the number of letters in the alphabet
    while (i < 26) : (i += 1) {
        if ((drv_bitmask & (one << i)) != 0) {
            const letter: u8 = 'A' + @as(u8, i);
            try dirlist.append(File{
                .path = try std.fmt.allocPrint(alloc, "{c}:", .{letter}),
                .kind = .directory,
            });
        }
    }
    return dirlist;
}
