-- steam-game-audio: make Steam game recordings capture only game audio.
--
-- Steam's recorder is a `Stream/Input/Audio` node of the `steam` binary that
-- listens to a sink monitor (whole system audio). While at least one game is
-- running, this script unlinks it from sinks and links it to the game's
-- output streams instead. Works for native and Wine/Proton games.
--
-- WirePlumber's Lua sandbox has no `io`, so games are detected from PipeWire
-- properties only. A stream counts as a game if any of these holds:
--   * its binary is a Wine preloader (Proton and plain Wine),
--   * its `media.role` is "Game" (set by SDL and most native engines),
--   * its binary is listed in EXTRA_BINARIES below (escape hatch for games
--     that set no role, e.g. add "mygame").

local log = Log.open_topic("steam-game-audio")

local WINE_BINARIES = { ["wine64-preloader"] = true, ["wine-preloader"] = true }
local EXTRA_BINARIES = {}

local games = {}  -- node id -> node (game output streams)
local steams = {} -- node id -> node (Steam recording input streams)
local made = {}   -- "outPort:inPort" -> { link, out = node id, inn = node id }

local function id_of(obj)
  return tonumber(obj.properties["object.id"])
end

---------------------------------------------------------------- detection

-- Native PipeWire streams carry only `client.id`; the process info lives on
-- the client object.
clients_om = ObjectManager { Interest { type = "client" } }

local function client_props(node)
  local cid = node.properties["client.id"]
  if not cid then return {} end
  local client = clients_om:lookup {
    Constraint { "object.id", "equals", tostring(cid) },
  }
  return client and client.properties or {}
end

local function is_game(node)
  local props, cprops = node.properties, client_props(node)
  local bin = props["application.process.binary"]
      or cprops["application.process.binary"] or ""
  if bin:find("^steam") then return false end
  if WINE_BINARIES[bin] or EXTRA_BINARIES[bin] then return true end

  local role = props["media.role"] or cprops["media.role"] or ""
  return role:lower() == "game"
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
  games[id] = nil
  drop_links_of(id)
end)

ports_om:connect("object-added", function(_, port)
  local node_id = tonumber(port.properties["node.id"])
  -- Retry detection for streams whose client was unknown when they appeared.
  if not games[node_id] then
    local node = streams_om:lookup {
      Constraint { "object.id", "equals", tostring(node_id) },
    }
    if node and is_game(node) then
      log:info("Game stream detected (on ports): node " .. node_id)
      games[node_id] = node
    end
  end
  if games[node_id] or steams[node_id] then reconcile() end
end)

links_om:connect("object-added", function(_, link)
  maybe_drop_sink_link(link)
end)

log:info("steam-game-audio loaded")

clients_om:activate()
sinks_om:activate()
steam_om:activate()
streams_om:activate()
ports_om:activate()
links_om:activate()
