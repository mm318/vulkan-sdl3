# Sample GPU Application

This app uses Zig and Vulkan in the backend (and SDL3 and DVUI for the frontend).

![Screenshot](screenshot.png)

## Building and Running

`slangc` is required to compile the shaders (installation instructions at https://shader-slang.org/slang/user-guide/get-started.html).

To build and run the program:
```shell
zig build run                         # for debug build
zig build -Doptimize=ReleaseSafe run  # for release build
```

To build and run unit tests:
```bash
zig build test --summary all                         # for debug build
zig build -Doptimize=ReleaseSafe test --summary all  # for release build
```

Tested with Ubuntu 24.04, zig 0.15.2, and slangc 2025.23.1.

## Credits

This is a mix of the following sources put together:
- https://github.com/spanzeri/vkguide-zig
- https://github.com/Deins/s3-vk / https://github.com/Deins/dvui_vk
- https://codeberg.org/knightpp/game-of-life-zig
