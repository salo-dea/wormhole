# wormhole
[![.github/workflows/main.yml](https://github.com/salo-dea/wormhole/actions/workflows/main.yml/badge.svg)](https://github.com/salo-dea/wormhole/actions/workflows/main.yml)

Fast directory navigation using ncurses

## Build 
- requires:
  - zig 0.14.0 (master: https://ziglang.org/download/)
  - ncurses (only needed on linux)
- do `zig build` or `zig build run` in the main directory

## Usage
See scripts in `shell/` (require wormhole executable to be available in PATH)

- Operation:
    - navigate to the desired folder -> `Esc` to exit and change directory to there (`Ctrl+X` to exit without changing directory)
   - wormhole will create a file called `.fastnav-wormhole` upon exit that contains the target path
   - the calling shell may use the file content to change directory/attempt opening a file


### Keybinds
- `Left Arrow` -> go up
- `Right Arrow` or `Return` -> enter folder
- `Esc` -> exit and go to selected directory
- `Ctrl+X` -> exit without changing directory
- `Ctrl+Y` -> toggle showing hidden files (currently only .files are respected as hidden)
- `Ctrl+S`/`Ctrl+A` -> increase/decrease depth for recursive listing of subfolder contents
- `Ctrl+R` -> toggle recursive subfolder listing between 0 and 5 (reasonable depth to quickly find something without slowing down the operation too much)
- `Other keys` -> type to instantly filter folder contents

## Known issues
- will crash when trying to navigate through symlinks 
