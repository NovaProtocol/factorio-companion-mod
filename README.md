# fsm-companion

Companion mod for the Factorio Server Manager. It gives the manager a stable set
of in-game commands and is embedded in the manager, which installs it and keeps
it enabled.

## What it does

- Registers console commands the manager and admins can call, over RCON or in the
  game console.
- `companion-test` returns a value, so you can confirm the mod is loaded and
  responding.

## Quick start

Drop the mod into the server's `mods/` directory, or let the manager install it,
and enable it. Then run:

    /companion-test

Over RCON the reply goes to the RCON client. In game it prints to the calling
player.

## Structure

    info.json      mod metadata
    control.lua    command registration and handlers
    changelog.txt  release notes

## License

MIT
