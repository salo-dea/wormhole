# wormhole

Fast directory navigation using ncurses

## Build
- requires:
  - zig 0.11.0
  - ncurses 
- do `zig build` or `zig build run` in the main directory

## Usage
create Shell wrapper e.g. for bash:
 - `cd $(wormhole)`
 - navigate to the desired folder -> `Esc` to exit and change directory to there, `Ctrl+C` to exit without changing directory

### Keybinds
- `Left Arrow` -> go up
- `Right Arrow` or `Return` -> enter folder
- `Esc` -> exit and print the current directory (so that cd can use it)
- `Other keys` -> type to instantly filter folder contents
