# fsm-companion

Companion mod for the [Factorio Server Manager](https://github.com/NovaProtocol/factorio-server-manager).
It gives the manager a stable set of in-game commands to read the factory from and
to act on it, and it does nothing on its own: with no manager installed, nothing
calls it.

Install it through the manager. The manager pins one version, fetches it from this
repository's GitHub release, and removes any other copy, so the mod and the manager
never drift apart. Installing it by hand works too: drop the zip in the server's
`mods/` directory and enable it.

## Commands

| Command | What it does |
|---|---|
| `/companion-report <scope> [args]` | Builds one report and caches it, returning a manifest. Scopes: `overview`, `production <surface> <window>`, `power <surface> <window>`, `science <surface> <window>`, `graph <surface> <category> <series> <window>` |
| `/companion-chunk <token> <index>` | Returns one slice of the cached report. The token makes a clobbered fetch fail loudly instead of assembling somebody else's body |
| `/companion-tick` | The game tick and the current game speed as one small JSON body. The manager samples it every five seconds and divides by wall time to report the real UPS |
| `/companion-speed <speed>` | Sets the game speed (`max_ups = speed x 60`). The value is kept in the save's storage and re-applied after a save load, since `game.speed` resets on load |

Everything the manager calls is a **plain mod command**. None of them is a script
command (`/c`, `/sc`, `/silent-command`), so using the manager never stops
achievements for a save. That rule is why the speed control lives here rather than
in a console command.

Reports travel over RCON, which caps a frame near 4 KB, so anything larger is
chunked and fetched in pieces.

## Windows

The report scopes take the game's own statistics windows: `5s 1m 10m 1h 10h 50h
250h 1000h`, plus `all` for the cumulative counts.

## Structure

    info.json      mod metadata
    control.lua    command registration and handlers
    changelog.txt  release notes
    LICENSE        MIT

## License

MIT, see [LICENSE](LICENSE).
