-- BEGIN spice-guest-tools managed mode
-- SPICE owns virtual output modes and layout. Scale follows Omarchy.
do
  local home = os.getenv("HOME")
  local state_home = os.getenv("XDG_STATE_HOME") or (home .. "/.local/state")
  local state = io.open(state_home .. "/spice-guest-tools/display.state", "r")

  if state then
    local legacy = {}
    local monitors = {}

    for line in state:lines() do
      local index, key, value = line:match("^monitor%.(%d+)%.([%w_]+)=(.*)$")
      if index and key and value then
        index = tonumber(index)
        monitors[index] = monitors[index] or {}
        monitors[index][key] = value
      else
        local legacy_key, legacy_value = line:match("^([%w_]+)=(.*)$")
        if legacy_key and legacy_value then
          legacy[legacy_key] = legacy_value
        end
      end
    end
    state:close()

    if legacy.output and legacy.modeline and not next(monitors) then
      monitors[0] = {
        output = legacy.output,
        modeline = legacy.modeline,
        x = "0",
        y = "0",
      }
    end

    local indexes = {}
    for index in pairs(monitors) do
      table.insert(indexes, index)
    end
    table.sort(indexes)

    local state_version = tonumber(legacy.version) or 1

    local function legacy_logical_position(raw_value)
      local scaled = raw_value / omarchy_monitor_scale
      if scaled < 0 then
        return math.ceil(scaled - 0.5)
      end
      return math.floor(scaled + 0.5)
    end

    for _, index in ipairs(indexes) do
      local monitor = monitors[index]
      local output = monitor.output
      local modeline = monitor.modeline
      local raw_x = tonumber(monitor.x)
      local raw_y = tonumber(monitor.y)
      local valid_output = output and output:match("^[%w%._%-]+$")
      local valid_modeline = modeline and modeline:match("^[%w%.%s%+%-]+$")

      if valid_output and valid_modeline and raw_x and raw_y then
        local position
        if state_version >= 3 then
          position = raw_x .. "x" .. raw_y
        else
          position = legacy_logical_position(raw_x) .. "x" .. legacy_logical_position(raw_y)
        end
        local config = {
          output = output,
          mode = "modeline " .. modeline,
          position = position,
          scale = (state_version >= 4 and tonumber(monitor.scale)) or omarchy_monitor_scale,
        }
        hl.monitor(config)
      end
    end
  end
end
-- END spice-guest-tools managed mode
