-- fsm-companion: manager-facing console commands.
--
-- The manager installs this mod, writes it into the server's mods directory and
-- keeps it enabled. Removing it disables the manager's companion features, but
-- nothing here is destructive on its own.
--
-- Reports are built one scope at a time rather than as one big document: a
-- body has to survive RCON, which caps a frame at 4096 bytes, so the manager
-- asks for exactly the slice a page is showing and the mod chunks it.

local MOD_NAME = "fsm-companion"

-- Blueprint simulator surfaces carry no meaningful production and are excluded
-- from every report, along with space platforms.
local IGNORED_PREFIX = "bpsb-lab-"

-- The eight windows the game's statistics GUI offers, plus "all" (the cumulative
-- `input_counts`/`output_counts`, which is not a precision index).
local WINDOWS = {
  ["5s"] = defines.flow_precision_index.five_seconds,
  ["1m"] = defines.flow_precision_index.one_minute,
  ["10m"] = defines.flow_precision_index.ten_minutes,
  ["1h"] = defines.flow_precision_index.one_hour,
  ["10h"] = defines.flow_precision_index.ten_hours,
  ["50h"] = defines.flow_precision_index.fifty_hours,
  ["250h"] = defines.flow_precision_index.two_hundred_fifty_hours,
  ["1000h"] = defines.flow_precision_index.one_thousand_hours,
}

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

-- Every accessor is wrapped: LuaObjects raise on an unknown key rather than
-- returning nil, and one bad guess must not take down a whole report.
local function safe(fn, fallback)
  local ok, value = pcall(fn)
  if ok then
    return value
  end
  return fallback
end

local function words(text)
  local out = {}
  for word in string.gmatch(text or "", "%S+") do
    out[#out + 1] = word
  end
  return out
end

-- An omitted argument must keep its position. The manager sends "-" for "unset"
-- rather than leaving a gap, because a gap would collapse when the line is split
-- into words and shift every argument after it.
local function arg_or(value, fallback)
  if value == nil or value == "" or value == "-" then
    return fallback
  end
  return value
end

local function wanted(surface)
  return surface.platform == nil and surface.name:sub(1, #IGNORED_PREFIX) ~= IGNORED_PREFIX
end

local function main_force()
  return game.forces["player"] or game.forces[1]
end

local function surface_named(name)
  local surface = name and game.surfaces[name]
  if surface and wanted(surface) then
    return surface
  end
  -- Fall back rather than fail: a stale name in the browser must not break a page.
  for _, candidate in pairs(game.surfaces) do
    if wanted(candidate) then
      return candidate
    end
  end
  return game.surfaces[1]
end

-- Rows sorted by value, biggest first, so the manager can slice a top-N without
-- knowing anything about the game.
local function ranked(totals)
  local out = {}
  for name, value in pairs(totals) do
    out[#out + 1] = {name = name, value = value}
  end
  table.sort(out, function(a, b) return a.value > b.value end)
  return out
end

local function accumulate(totals, name, value)
  totals[name] = (totals[name] or 0) + value
end

local function surfaces_summary()
  local force = main_force()
  local out = {}

  for _, surface in pairs(game.surfaces) do
    if wanted(surface) then
      local items = safe(function() return force.get_item_production_statistics(surface).input_counts end, {})
      local kills = safe(function() return force.get_kill_count_statistics(surface).input_counts end, {})
      local builds = safe(function() return force.get_entity_build_count_statistics(surface).input_counts end, {})

      local kinds, killTotal, buildTotal = 0, 0, 0
      for _ in pairs(items) do kinds = kinds + 1 end
      for _, count in pairs(kills) do killTotal = killTotal + count end
      for _, count in pairs(builds) do buildTotal = buildTotal + count end

      out[#out + 1] = {
        name = surface.name,
        platform = surface.platform ~= nil,
        item_kinds = kinds,
        kills = killTotal,
        builds = buildTotal,
      }
    end
  end

  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

local function research_report()
  local force = main_force()
  local researched, total = 0, 0
  for _, technology in pairs(force.technologies) do
    total = total + 1
    if technology.researched then
      researched = researched + 1
    end
  end

  return {
    current = safe(function() return force.current_research.name end, nil),
    progress = safe(function() return force.research_progress end, nil),
    queued = safe(function() return #force.research_queue end, nil),
    researched = researched,
    total = total,
    rockets_launched = safe(function() return force.rockets_launched end, nil),
  }
end

-- One prototype's numbers for the chosen window. A window gives the average rate
-- and the count inside it; "all" only has the cumulative count.
local function entry_for(stats, category, name, window)
  local precision = WINDOWS[window]
  local entry = {name = name}

  if precision then
    entry.rate = stats.get_flow_count{name = name, category = category, precision_index = precision}
    entry.count = stats.get_flow_count{name = name, category = category, precision_index = precision, count = true}
  else
    local counts = (category == "input") and stats.input_counts or stats.output_counts
    entry.count = counts[name]
  end

  return entry
end

local function flow_entries(stats, category, window)
  local out = {}
  if not stats then
    return out
  end

  local source = (category == "input") and stats.input_counts or stats.output_counts
  for name in pairs(source) do
    out[#out + 1] = entry_for(stats, category, name, window)
  end

  return out
end

-- Power for one surface, summed over its networks.
--
-- The numbers are energy per tick, exactly as the game reports them; the manager
-- turns them into watts. For a window the value is already an average; for "all"
-- the cumulative counts are summed instead and the manager divides by the tick
-- count to get a lifetime average, which is why `tick` is included.
--
-- `with_lists` adds the per-prototype breakdown, which only the surface being
-- looked at needs: the all-planets summary above it wants the totals alone.
local function measure_power(surface, window, with_lists)
  local seen = {}
  local consumers, generators = {}, {}
  local networks, production, consumption = 0, 0, 0
  local maxProduction, maxConsumption = 0, 0
  local accumulatorEnergy, accumulatorCapacity = 0, 0
  local detail = {}

  local function add(map, name, value)
    if with_lists then
      accumulate(map, name, value)
    end
  end

  for _, pole in pairs(surface.find_entities_filtered{type = "electric-pole"}) do
    local sub = safe(function() return pole.electric_network end, nil)
    local id = sub and safe(function() return sub.id end, nil)

    if id and not seen[id] then
      seen[id] = true
      local parent = safe(function() return sub.parent_network end, nil)

      if parent then
        networks = networks + 1
        local stats = safe(function() return parent.statistics end, nil)

        if stats then
          if WINDOWS[window] then
            for name in pairs(stats.input_counts) do
              local value = stats.get_flow_count{name = name, category = "input", precision_index = WINDOWS[window]}
              add(consumers, name, value)
              consumption = consumption + value
            end
            for name in pairs(stats.output_counts) do
              local value = stats.get_flow_count{name = name, category = "output", precision_index = WINDOWS[window]}
              add(generators, name, value)
              production = production + value
            end
          else
            for name, value in pairs(stats.input_counts) do
              add(consumers, name, value)
              consumption = consumption + value
            end
            for name, value in pairs(stats.output_counts) do
              add(generators, name, value)
              production = production + value
            end
          end
        end

        -- The tick snapshot carries what the windows cannot: the ceilings
        -- (maximum_production/consumption) and accumulator charge.
        local flow = safe(function() return parent.flow_last_tick end, nil)
        if flow then
          local networkProduction = flow.maximum_production or 0
          local networkConsumption = flow.maximum_consumption or 0

          maxProduction = maxProduction + networkProduction
          maxConsumption = maxConsumption + networkConsumption

          detail[#detail + 1] = {
            load = networkConsumption,
            capacity = networkProduction,
            production = flow.production_satisfaction or 1,
            consumption = flow.consumption_satisfaction or 1,
          }

          accumulatorEnergy = accumulatorEnergy + (flow.accumulator_energy or 0)
          accumulatorCapacity = accumulatorCapacity + (flow.accumulator_capacity or 0)
        end
      end
    end
  end

  -- Satisfaction is a ratio, so it cannot be summed, and the tightest grid is what
  -- browns out. Two things disqualify a grid from setting the headline:
  --
  --   * being too small to matter — the tightest of 63 grids is otherwise a couple
  --     of solar panels reading 0 at night;
  --   * having no generators, or nothing drawing. A fragment with demand and no
  --     supply always reads 0, but that is a piece of wire connected to nothing,
  --     not a brownout, and it made whole planets report 0% while the game showed
  --     them perfectly satisfied.
  local consumptionThreshold = maxConsumption * 0.01
  local productionThreshold = maxProduction * 0.01
  local productionSatisfaction, consumptionSatisfaction = 1, 1

  for _, network in pairs(detail) do
    if network.load >= consumptionThreshold and network.load > 0 and network.capacity > 0 then
      consumptionSatisfaction = math.min(consumptionSatisfaction, network.consumption)
    end

    if network.capacity >= productionThreshold and network.capacity > 0 and network.load > 0 then
      productionSatisfaction = math.min(productionSatisfaction, network.production)
    end
  end

  return {
    networks = networks,
    production = production,
    consumption = consumption,
    max_production = maxProduction,
    max_consumption = maxConsumption,
    production_satisfaction = productionSatisfaction,
    consumption_satisfaction = consumptionSatisfaction,
    accumulator_energy = accumulatorEnergy,
    accumulator_capacity = accumulatorCapacity,
    consumers = ranked(consumers),
    generators = ranked(generators),
  }
end

-- The whole picture: every planet's totals, then the selected planet in full.
-- The summary is what the page shows first, so no surface has to be picked from a
-- dropdown before anything is visible.
local function power_report(surface, window)
  local report = measure_power(surface, window, true)

  report.surface = surface.name
  report.window = window
  report.tick = game.tick

  local summary = {}
  for _, candidate in pairs(game.surfaces) do
    if wanted(candidate) then
      local totals = measure_power(candidate, window, false)
      summary[#summary + 1] = {
        name = candidate.name,
        networks = totals.networks,
        production = totals.production,
        consumption = totals.consumption,
        max_production = totals.max_production,
        production_satisfaction = totals.production_satisfaction,
        consumption_satisfaction = totals.consumption_satisfaction,
      }
    end
  end

  table.sort(summary, function(a, b) return a.name < b.name end)
  report.planets = summary

  return report
end

-- Per-surface production totals: how much each planet is actually making, so the
-- page can open on all of them rather than one picked from a dropdown. `items` is
-- the all-time count, `items_rate` the windowed rate, both summed over every kind.
local function production_summary(window)
  local force = main_force()
  local precision = WINDOWS[window]
  local out = {}

  for _, surface in pairs(game.surfaces) do
    if wanted(surface) then
      local itemStats = safe(function() return force.get_item_production_statistics(surface) end, nil)
      local fluidStats = safe(function() return force.get_fluid_production_statistics(surface) end, nil)
      local kills = safe(function() return force.get_kill_count_statistics(surface).input_counts end, {})
      local builds = safe(function() return force.get_entity_build_count_statistics(surface).input_counts end, {})

      local entry = {
        name = surface.name,
        item_kinds = 0,
        fluid_kinds = 0,
        items = 0,
        items_rate = 0,
        kills = 0,
        builds = 0,
      }

      if itemStats then
        for name, value in pairs(itemStats.input_counts) do
          entry.item_kinds = entry.item_kinds + 1
          entry.items = entry.items + value
          if precision then
            entry.items_rate = entry.items_rate +
              itemStats.get_flow_count{name = name, category = "input", precision_index = precision}
          end
        end
      end

      if fluidStats then
        for _ in pairs(fluidStats.input_counts) do
          entry.fluid_kinds = entry.fluid_kinds + 1
        end
      end

      for _, value in pairs(kills) do entry.kills = entry.kills + value end
      for _, value in pairs(builds) do entry.builds = entry.builds + value end

      out[#out + 1] = entry
    end
  end

  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

local function production_report(surface, window)
  local force = main_force()

  return {
    surface = surface.name,
    window = window,
    items = flow_entries(safe(function() return force.get_item_production_statistics(surface) end, nil), "input", window),
    fluids = flow_entries(safe(function() return force.get_fluid_production_statistics(surface) end, nil), "input", window),
    planets = production_summary(window),
  }
end

-- The last research sample, kept between commands so the real research rate can be
-- measured from the progress bar. The last good rate is kept too: a dedicated
-- server with auto_pause on advances no ticks at all, and a rate measured before
-- the pause is still the best answer available.
local last_research_sample = nil
local last_research_rate = nil

-- Science is read off the item statistics rather than a hardcoded list, so new
-- packs (Space Age or modded) appear on their own.
--
-- Science per minute is the rate a *full set* of the packs is consumed, which is
-- the slowest of the packs the current research actually needs. Taking the slowest
-- of everything produced instead reports an unused pack: researching something
-- that needs six of the eleven packs would be quoted at the rate of one it does
-- not touch.
--
-- The progress bar also moves faster than the packs are consumed when labs run
-- productivity, so the real rate is measured from the bar and reported alongside.
local function science_report(surface, window)
  local force = main_force()
  local stats = safe(function() return force.get_item_production_statistics(surface) end, nil)
  local research = safe(function() return force.current_research end, nil)
  local precision = WINDOWS[window]

  local required = {}
  for _, ingredient in pairs(safe(function() return research.research_unit_ingredients end, {}) or {}) do
    required[ingredient.name] = ingredient.amount
  end

  -- Every pack with any data: produced, consumed, or merely required. A pack that
  -- only ever arrives from another planet has no production entry at all — space
  -- science is consumed on nauvis but never made there — so walking input_counts
  -- alone left it out of the report entirely.
  local names = {}
  if stats then
    for name in pairs(stats.input_counts) do
      if string.find(name, "science%-pack") then names[name] = true end
    end
    for name in pairs(stats.output_counts) do
      if string.find(name, "science%-pack") then names[name] = true end
    end
  end
  for name in pairs(required) do
    names[name] = true
  end

  local packs = {}
  for name in pairs(names) do
    local pack = {name = name, needed = required[name] or 0}
    if stats and precision then
      pack.produced = stats.get_flow_count{name = name, category = "input", precision_index = precision}
      pack.consumed = stats.get_flow_count{name = name, category = "output", precision_index = precision}
    elseif stats then
      pack.produced = stats.input_counts[name] or 0
      pack.consumed = stats.output_counts[name] or 0
    end
    packs[#packs + 1] = pack
  end
  table.sort(packs, function(a, b) return a.name < b.name end)

  local spm
  if precision then
    for _, pack in pairs(packs) do
      if pack.needed > 0 then
        local units = (pack.consumed or 0) / pack.needed
        if not spm or units < spm then
          spm = units
        end
      end
    end
  end

  -- The measured rate needs two samples and a game that is actually ticking: a
  -- server paused for want of players advances no ticks at all. The last good
  -- reading is therefore kept and reused, so a pause does not blank the number.
  local measured, ratio, measured_at = nil, nil, nil
  if research and precision then
    local sample = {tick = game.tick, name = research.name, progress = force.research_progress}
    local previous = last_research_sample

    if previous and previous.name == sample.name then
      local ticks = sample.tick - previous.tick
      local delta = sample.progress - previous.progress
      if ticks >= 120 and delta > 0 then
        last_research_rate = {
          name = sample.name,
          rate = delta * (research.research_unit_count or 0) / (ticks / 3600),
          tick = sample.tick,
        }
      end
    end

    last_research_sample = sample

    -- A new research invalidates the old reading: it has its own unit count.
    if last_research_rate and last_research_rate.name == sample.name then
      measured = last_research_rate.rate
      measured_at = sample.tick - last_research_rate.tick
      if spm and spm > 0 then
        ratio = measured / spm
      end
    end
  end

  return {
    surface = surface.name,
    window = window,
    packs = packs,
    spm = spm,
    research_rate = measured,
    research_rate_age_ticks = measured_at,
    productivity_ratio = ratio,
    research = safe(research_report, {}),
  }
end

-- The 300 samples behind one series, which is the data the in-game graph draws.
-- Both directions come back together so a panel can overlay them, which is how the
-- game's own statistics screen shows production and consumption.
--
-- Items call the left column "input" and the right one "output"; an electric
-- network is the other way round, because what it *draws* is the left column. Both
-- are reported as production and consumption so the panel can label them alike.
-- `series = "all"` sums every prototype — the grid total for power, everything the
-- surface makes for items or fluids.
local function graph_report(surface, category, series, window)
  local force = main_force()
  local precision = WINDOWS[window] or defines.flow_precision_index.one_thousand_hours
  local production, consumption = {}, {}
  local everything = (series == nil or series == "" or series == "all")

  local madeCategory, usedCategory = "input", "output"
  local sources = {}

  if category == "power" then
    madeCategory, usedCategory = "output", "input"

    local seen = {}
    for _, pole in pairs(surface.find_entities_filtered{type = "electric-pole"}) do
      local sub = safe(function() return pole.electric_network end, nil)
      local id = sub and safe(function() return sub.id end, nil)
      if id and not seen[id] then
        seen[id] = true
        local parent = safe(function() return sub.parent_network end, nil)
        if parent then
          sources[#sources + 1] = safe(function() return parent.statistics end, nil)
        end
      end
    end
  elseif category == "fluid" then
    sources[1] = safe(function() return force.get_fluid_production_statistics(surface) end, nil)
  else
    sources[1] = safe(function() return force.get_item_production_statistics(surface) end, nil)
  end

  for i = 1, 300 do
    local made, used = 0, 0

    for _, source in pairs(sources) do
      if source then
        local madeCounts = (madeCategory == "input") and source.input_counts or source.output_counts
        local usedCounts = (usedCategory == "input") and source.input_counts or source.output_counts

        if everything then
          for name in pairs(madeCounts) do
            made = made + source.get_flow_count{name = name, category = madeCategory,
                                                 precision_index = precision, sample_index = i}
          end
          for name in pairs(usedCounts) do
            used = used + source.get_flow_count{name = name, category = usedCategory,
                                                 precision_index = precision, sample_index = i}
          end
        else
          -- Only ask about a direction the prototype actually appears in: a
          -- consumer has no output entry, and asking anyway raises rather than
          -- returning zero.
          if madeCounts[series] then
            made = made + source.get_flow_count{name = series, category = madeCategory,
                                                 precision_index = precision, sample_index = i}
          end
          if usedCounts[series] then
            used = used + source.get_flow_count{name = series, category = usedCategory,
                                                 precision_index = precision, sample_index = i}
          end
        end
      end
    end

    production[i] = made
    consumption[i] = used
  end

  return {
    surface = surface.name,
    series = series,
    category = category,
    window = window,
    production = production,
    consumption = consumption,
  }
end

local function overview_report()
  local out = {tick = game.tick, force = main_force().name}
  out.research = safe(research_report, {})
  out.surfaces = safe(surfaces_summary, {})
  return out
end

commands.add_command(
  "companion-test",
  "Confirms the FSM companion mod is loaded and responding.",
  function(event)
    local version = script.active_mods[MOD_NAME] or "unknown"
    respond(event, "fsm-companion OK (v" .. version .. ")")
  end
)

local REPORT_CHUNK = 3500

-- One report is cached at a time, so a second caller would overwrite the first
-- mid-fetch. The manifest carries a token that /companion-chunk must echo: a
-- clobbered fetch then fails loudly instead of assembling someone else's body.
local cached_report = nil
local cached_token = 0
local next_token = 0

commands.add_command(
  "companion-report",
  "Builds one report scope and caches it. Returns a manifest; fetch the body with companion-chunk. "
  .. "Scopes: overview | production <surface> <window> | power <surface> <window> | "
  .. "science <surface> <window> | graph <surface> <category> <series> <window>.",
  function(event)
    local args = words(event.parameter)
    local scope = arg_or(args[1], "overview")

    -- Nothing in here may throw. A Lua error in a command handler is fatal to the
    -- whole server, so a bad argument has to come back as a report, not an
    -- exception.
    local ok, report = pcall(function()
      if scope == "production" then
        return production_report(surface_named(arg_or(args[2], nil)), arg_or(args[3], "1h"))
      elseif scope == "power" then
        return power_report(surface_named(arg_or(args[2], nil)), arg_or(args[3], "1h"))
      elseif scope == "science" then
        return science_report(surface_named(arg_or(args[2], nil)), arg_or(args[3], "1h"))
      elseif scope == "graph" then
        return graph_report(surface_named(arg_or(args[2], nil)),
                            arg_or(args[3], "item-input"),
                            arg_or(args[4], "all"),
                            arg_or(args[5], "1h"))
      end
      return overview_report()
    end)

    if not ok then
      log("[fsm-companion] companion-report " .. tostring(event.parameter) .. " failed: " .. tostring(report))
      report = {error = tostring(report)}
    elseif type(report) ~= "table" then
      report = {error = "a scope returned no report"}
    end

    report.scope = scope
    report.surfaces = report.surfaces or safe(surfaces_summary, {})

    local encoded, json = pcall(function() return helpers.table_to_json(report) end)
    if not encoded then
      respond(event, helpers.table_to_json({error = tostring(json)}))
      return
    end

    next_token = next_token + 1
    cached_token = next_token
    cached_report = json

    respond(event, helpers.table_to_json({
      token = cached_token,
      length = #json,
      chunk_size = REPORT_CHUNK,
      chunks = math.ceil(#json / REPORT_CHUNK),
    }))
  end
)

commands.add_command(
  "companion-chunk",
  "Returns one slice of the report built by companion-report. Usage: /companion-chunk <token> <index>.",
  function(event)
    local args = words(event.parameter)
    local token = tonumber(args[1])
    local index = tonumber(args[2])

    if not token or not index or index < 0 then
      respond(event, "usage: /companion-chunk <token> <index>")
      return
    end

    if not cached_report then
      respond(event, "no report cached; run /companion-report first")
      return
    end

    if token ~= cached_token then
      respond(event, string.format("stale report: asked for token %d, current is %d", token, cached_token))
      return
    end

    respond(event, cached_report:sub(index * REPORT_CHUNK + 1, (index + 1) * REPORT_CHUNK))
  end
)

-- Game speed. The speed is a runtime fact and resets to 1 with every save load,
-- so the manager remembers nothing: the mod keeps the last set value in its own
-- save-scoped storage and re-applies it lazily — the next command after a load
-- (the manager asks something every 5 seconds while a page is open) restores it.
-- Nothing here is a script command: speed is set from the mod's own context,
-- like the in-game speed-button mods do, so achievements are never stopped.
local companionMinSpeed = 0.01
local companionMaxSpeed = 3

local function apply_remembered_speed()
  local wanted = safe(function() return storage.companion_speed end, nil)
  if not wanted then
    return
  end

  local current = safe(function() return game.speed end, nil)
  if current ~= wanted then
    pcall(function() game.speed = wanted end)
  end
end

local function speed_payload()
  local speed = safe(function() return game.speed end, 1)
  return {
    speed = speed,
    max_ups = speed * 60,
    min_speed = companionMinSpeed,
    max_speed = companionMaxSpeed,
  }
end

commands.add_command(
  "companion-tick",
  "Returns the game tick and current speed as one small JSON body.",
  function(event)
    apply_remembered_speed()
    respond(event, helpers.table_to_json({
      tick = safe(function() return game.tick end, 0),
      speed = safe(function() return game.speed end, 1),
    }))
  end
)

commands.add_command(
  "companion-speed",
  "Sets the game speed. Max UPS is speed x 60, so 0.5 = 30 UPS. Range "
    .. "0.01 to 3 (0.6 to 180 max UPS). Usage: /companion-speed <speed>.",
  function(event)
    local value = tonumber(words(event.parameter)[1])

    local payload = speed_payload()
    if not value then
      payload.error = "give a speed as a number"
      respond(event, helpers.table_to_json(payload))
      return
    end

    if value < companionMinSpeed or value > companionMaxSpeed then
      payload.error = "speed must be between "
        .. companionMinSpeed .. " (" .. companionMinSpeed * 60 .. " max UPS) and "
        .. companionMaxSpeed .. " (" .. companionMaxSpeed * 60 .. " max UPS)"
      respond(event, helpers.table_to_json(payload))
      return
    end

    local ok, err = pcall(function() game.speed = value end)
    if not ok then
      respond(event, helpers.table_to_json({error = tostring(err)}))
      return
    end

    safe(function() storage.companion_speed = game.speed end)
    respond(event, helpers.table_to_json(speed_payload()))
  end
)
