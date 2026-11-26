-- steam-game-audio: make Steam game recordings capture only game audio.
--
-- Steam's recorder is a `Stream/Input/Audio` node of the `steam` binary that
-- listens to a sink monitor (whole system audio). While at least one Steam game
-- is running, this script unlinks it from sinks and links it to the game's
-- output streams instead. Works for native and Wine/Proton games.
--
-- A stream counts as a game if its process has SteamGameId/SteamAppId in its
-- environment (set by Steam for every game it launches), or if its binary is a
-- Wine preloader (covers Wine games launched outside Steam).

local log = Log.open_topic("steam-game-audio")

local WINE_BINARIES = { ["wine64-preloader"] = true, ["wine-preloader"] = true }

local games = {}  -- node id -> node (game output streams)
local steams = {} -- node id -> node (Steam recording input streams)
local made = {}   -- "outPort:inPort" -> { link, out = node id, inn = node id }
local env_cache = {} -- node id -> boolean

local function id_of(obj)
  return tonumber(obj.properties["object.id"])
end

---------------------------------------------------------------- detection

local function has_steam_env(pid)
  if not pid then return false end
  local ok, found = pcall(function()
    local f = io.open("/proc/" .. pid .. "/environ", "rb")
    if not f then return false end
    local data = f:read("a") or ""
    f:close()
    return data:find("SteamGameId=", 1, true) ~= nil
        or data:find("SteamAppId=", 1, true) ~= nil
  end)
  return ok and found or false
end

local function is_game(node)
  local props = node.properties
  local bin = props["application.process.binary"] or ""
  if bin:find("^steam") then return false end
  if WINE_BINARIES[bin] then return true end

  local id = id_of(node)
  local cached = env_cache[id]
  if cached == nil then
    cached = has_steam_env(tonumber(props["application.process.id"]))
    env_cache[id] = cached
  end
  return cached
end

---------------------------------------------------------------- linking

local function ports_of(node, direction)
  local list = {}
  for port in ports_om:iterate {
    Constraint { "node.id", "equals", tostring(id_of(node)) },
    Constraint { "port.direction", "equals", direction },
  } do
    list[#list + 1] = port
  end
  return list
end

local function link_ports(out_port, in_port, out_node, in_node)
  local key = out_port.properties["object.id"] .. ":" .. in_port.properties["object.id"]
  if made[key] then return end

  local link = Link("link-factory", {
    ["link.output.node"] = out_port.properties["node.id"],
    ["link.output.port"] = out_port.properties["object.id"],
    ["link.input.node"]  = in_port.properties["node.id"],
    ["link.input.port"]  = in_port.properties["object.id"],
    ["node.description"] = "Link created by steam-game-audio",
  })
  link:activate(1)
  made[key] = { link = link, out = out_node, inn = in_node }
  log:info("Linked game node " .. out_node .. " -> steam node " .. in_node)
end

local function connect(game, steam)
  local outs, ins = ports_of(game, "out"), ports_of(steam, "in")
  local gid, sid = id_of(game), id_of(steam)

  for _, out in ipairs(outs) do
    local channel = out.properties["audio.channel"]
    local matched = false
    for _, inp in ipairs(ins) do
      if inp.properties["audio.channel"] == channel then
        link_ports(out, inp, gid, sid)
        matched = true
      end
    end
    -- Mono on either side: no channel matches, feed every port.
    if not matched and (#ins == 1 or #outs == 1) then
      for _, inp in ipairs(ins) do link_ports(out, inp, gid, sid) end
    end
  end
end

local function drop_links_of(node_id)
  for key, entry in pairs(made) do
    if entry.out == node_id or entry.inn == node_id then
      pcall(function() entry.link:request_destroy() end)
      made[key] = nil
    end
  end
end

---------------------------------------------------------------- sink links

sinks_om = ObjectManager {
  Interest {
    type = "node",
    Constraint { "media.class", "matches", "Audio/Sink*" },
  }
}

local function is_sink(node_id)
  return sinks_om:lookup {
    Constraint { "object.id", "equals", tostring(node_id) },
  } ~= nil
end

-- Destroy links that feed a Steam recorder from a sink (system audio).
local function maybe_drop_sink_link(link)
  if not next(games) then return end
  local props = link.properties
  if steams[tonumber(props["link.input.node"])]
      and is_sink(props["link.output.node"]) then
    log:info("Dropping system audio link to steam node " .. props["link.input.node"])
    pcall(function() link:request_destroy() end)
  end
end

---------------------------------------------------------------- managers

steam_om = ObjectManager {
  Interest {
    type = "node",
    Constraint { "application.process.binary", "equals", "steam", type = "pw" },
    Constraint { "media.class", "equals", "Stream/Input/Audio", type = "pw" },
  }
}

streams_om = ObjectManager {
  Interest {
    type = "node",
    Constraint { "media.class", "equals", "Stream/Output/Audio", type = "pw" },
  }
}

ports_om = ObjectManager { Interest { type = "port" } }
links_om = ObjectManager { Interest { type = "link" } }

local function reconcile()
  if not next(games) then return end
  for _, steam in pairs(steams) do
    for _, game in pairs(games) do connect(game, steam) end
  end
  for link in links_om:iterate() do maybe_drop_sink_link(link) end
end

steam_om:connect("object-added", function(_, node)
  log:info("Steam recording node: " .. id_of(node))
  steams[id_of(node)] = node
  reconcile()
end)
steam_om:connect("object-removed", function(_, node)
  local id = id_of(node)
  steams[id] = nil
  drop_links_of(id)
end)

streams_om:connect("object-added", function(_, node)
  local p = node.properties
  log:debug(string.format("Stream seen: node=%s binary=%s pid=%s name=%s",
    p["object.id"], p["application.process.binary"], p["application.process.id"],
    p["application.name"]))
  if is_game(node) then
    local id = id_of(node)
    log:info("Game stream detected: node " .. id)
    games[id] = node
    reconcile()
  end
end)
streams_om:connect("object-removed", function(_, node)
  local id = id_of(node)
  games[id], env_cache[id] = nil, nil
  drop_links_of(id)
end)

ports_om:connect("object-added", function(_, port)
  local node_id = tonumber(port.properties["node.id"])
  if games[node_id] or steams[node_id] then reconcile() end
end)

links_om:connect("object-added", function(_, link)
  maybe_drop_sink_link(link)
end)

log:info("steam-game-audio loaded")

sinks_om:activate()
steam_om:activate()
streams_om:activate()
ports_om:activate()
links_om:activate()
