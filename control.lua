-- fsm-companion: manager-facing console commands.
--
-- The Factorio Server Manager embeds this mod, writes it into the server's mods
-- directory and keeps it enabled. Removing it disables the manager's companion
-- features, but nothing here is destructive on its own.

local MOD_NAME = "fsm-companion"

local function respond(event, text)
  if event.player_index then
    local player = game.get_player(event.player_index)
    if player then
      player.print(text)
    end
  elseif rcon then
    rcon.print(text)
  end
end

commands.add_command(
  "companion-test",
  "Confirms the FSM companion mod is loaded and responding.",
  function(event)
    local version = script.active_mods[MOD_NAME] or "unknown"
    respond(event, "fsm-companion OK (v" .. version .. ")")
  end
)
