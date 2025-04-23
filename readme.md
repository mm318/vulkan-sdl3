# Game of Life Zig

This app uses Zig, SDL3 and DVUI and supports WEB target.

You can play it here <https://knightpp.codeberg.page/game-of-life-zig/@pages>.

## Building

### Web/Wasm

`--sysroot` should be a path to emscripten sdk. You can activate flake's shell to get the `$SYSROOT`
env var.

```shell
zig build run -Dtarget=wasm32-emscripten --sysroot $SYSROOT --release=small
# or
zig build run -Dtarget=wasm64-emscripten --sysroot $SYSROOT --release=small
```

### Everything else

```shell
zig build
```
