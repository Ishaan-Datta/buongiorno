
# [buongiorno]

A modal TUI greeter for [greetd] written in [zig] using [spoon].

![screenshot](./screenshot.png)

## Installation

If your system uses `systemd-tmpfiles`:

```
zig build --release=safe -Dsystemd
sudo zig build --release=safe -Dsystemd --prefix /usr
```

Otherwise, you will have to manually install the cache directory:

```
zig build --release=safe
sudo zig build --release=safe --prefix /usr
sudo install -d /var/cache/buongiorno -o greeter -g greeter
```

## Usage

For a machine with exactly one connected native DRM output, no new option is needed.

For a machine with multiple connected outputs, pass the connector explicitly, for example:

```sh
buongiorno -o DP-1 -u ishaan -c startplasma-wayland
```

List connected connectors with:

```sh
for output in /sys/class/drm/card*-*; do
  [ -f "$output/status" ] || continue
  [ "$(cat "$output/status")" = connected ] || continue
  printf '%s: ' "$(basename "$output")"
  head -n1 "$output/modes"
done
```

The `-o` value is the connector portion such as `DP-1`, `HDMI-A-1`, or `eDP-1`, not `card0-DP-1`.


## Configuration

The following `/etc/greetd/config.toml` sets "andrea" as the dafault user and
tells buongiorno to launch the command `compositor` after a successful login.

```
[default_session]
command = "buongiorno -c compositor -u andrea"
```

## Contributing

[buongiorno]: https://sr.ht/~andreafeletto/buongiorno
[greetd]: https://sr.ht/~kennylevinsen/greetd
[zig]: https://ziglang.org
[spoon]: https://sr.ht/~leon_plickat/zig-spoon