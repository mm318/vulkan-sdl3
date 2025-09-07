# Sample GPU Application

This app uses Zig and Vulkan in the backend (and SDL3 and DVUI for the frontend).

## Building and Running

```shell
zig build run                          # for debug build
# zig build -Doptimize=ReleaseSafe run # Dependencies have issues with ReleaseSafe
zig build -Doptimize=ReleaseFast run   # for release build
```
