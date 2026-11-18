local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local serverCode, clientCode, transcriptPath = process.args[1], process.args[2], process.args[3]

local Instance = roblox.Instance
local game = Instance.new("DataModel")

local function noop() end

local function signal(): { Connect: (any, (...any) -> ()) -> () }
	return { Connect = noop }
end

local clientHandlers: { [string]: (...any) -> () } = {}
local sent: { any } = {}
local players = {}

for index = 1, 3 do
	local player = Instance.new("Folder")
	player.Name = `Player{index}`
	table.insert(players, player)
end

local function hex(buff: buffer): string
	local digits = table.create(buffer.len(buff))
	for index = 0, buffer.len(buff) - 1 do
		table.insert(digits, string.format("%02x", buffer.readu8(buff, index)))
	end
	return table.concat(digits, " ")
end

local function names(instances: { any }): string
	local list = {}
	for _, instance in instances do
		table.insert(list, instance.Name)
	end
	return `[{table.concat(list, ", ")}]`
end

local function record(method: string, remote: any, to: string, buff: buffer, instances: { any })
	table.insert(sent, {
		method = method,
		remote = remote.Name,
		to = to,
		bytes = hex(buff),
		instances = names(instances),
		buff = buffer.fromstring(buffer.tostring(buff)),
		instanceList = table.clone(instances),
		order = #sent,
	})
end

roblox.implementMethod("Instance", "WaitForChild", function(self, ...)
	return self:FindFirstChild(...)
end)
roblox.implementMethod("RunService", "IsRunning", function()
	return true
end)
roblox.implementMethod("RunService", "IsClient", function()
	return debug.info(2, "s") == "Client"
end)
roblox.implementMethod("RunService", "IsServer", function()
	return debug.info(2, "s") == "Server"
end)
roblox.implementProperty("RunService", "Heartbeat", signal)
roblox.implementProperty("Players", "PlayerRemoving", signal)
roblox.implementMethod("Players", "GetPlayers", function()
	return table.clone(players)
end)

for _, class in { "RemoteEvent", "UnreliableRemoteEvent" } do
	roblox.implementProperty(class, "OnServerEvent", signal)
	roblox.implementProperty(class, "OnClientEvent", function(remote)
		return {
			Connect = function(_, handler)
				clientHandlers[remote.Name] = handler
			end,
		}
	end)
	roblox.implementMethod(class, "FireClient", function(remote, player, buff, instances)
		record("FireClient", remote, player.Name, buff, instances)
	end)
	roblox.implementMethod(class, "FireAllClients", function(remote, buff, instances)
		record("FireAllClients", remote, "everyone", buff, instances)
	end)
end

local environment = {
	game = game,
	Instance = Instance,
	CFrame = roblox.CFrame,
	vector = {
		create = function(x: number, y: number, z: number)
			return (vector :: any)(x, y, z)
		end,
	},
	task = task,
}

local server = luau.load(serverCode, { debugName = "Server", codegenEnabled = true, environment = environment })()
_G.__ZAP = {}
local client = luau.load(clientCode, { debugName = "Client", codegenEnabled = true, environment = environment })()

local function show(value: any): string
	local kind = typeof(value)
	if kind == "table" then
		local keys = {}
		for key in value do
			table.insert(keys, key)
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		local parts = {}
		for _, key in keys do
			table.insert(parts, `{show(key)}={show(value[key])}`)
		end
		return `\{{table.concat(parts, ", ")}\}`
	elseif kind == "vector" then
		return `vector({value.x}, {value.y}, {value.z})`
	elseif kind == "Instance" then
		return value.Name
	elseif kind == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
end

local received: { string } = {}

local function listen(path: string, event: any)
	event.On(function(...)
		local values = table.pack(...)
		local shown = {}
		for index = 1, values.n do
			table.insert(shown, show(values[index]))
		end
		table.insert(received, `{path}({table.concat(shown, ", ")})`)
	end)
end

listen("Detailed", client.Detailed)
listen("Pair", client.Pair)
listen("Ping", client.Ping)
listen("Moved", client.Moved)
listen("Ordered", client.Ordered)
listen("Tick", client.Tick)
listen("Nested.Note", client.Nested.Note)

local owner = Instance.new("Folder")
owner.Name = "Owner"
local part = Instance.new("Folder")
part.Name = "Part"

local detailed = {
	count = 200,
	delta = -123456,
	ratio = 0.1,
	active = true,
	items = {
		{ id = 7, name = "Ticket", kind = "Small", tags = { "a", "bc" }, note = "window" },
		{ id = 65535, name = "", kind = "Large", tags = {}, note = nil },
	},
	scores = { gate = 4 },
	shape = { kind = "Square", side = 12, filled = true },
	position = vector.create(1.5, -2, 3),
	part = part,
	owner = owner,
}

local plain = {
	count = 0,
	delta = 0,
	ratio = -1,
	active = false,
	items = {},
	scores = {},
	shape = { kind = "Circle", radius = 2.5 },
	position = vector.create(0, 0, 0),
	part = nil,
	owner = owner,
}

local transcript: { string } = {}

local function step(name: string, send: () -> ())
	sent = {}
	received = {}
	send()
	server.SendEvents()
	table.sort(sent, function(a, b)
		if a.remote ~= b.remote then
			return a.remote < b.remote
		elseif a.to ~= b.to then
			return a.to < b.to
		end
		return a.order < b.order
	end)
	table.insert(transcript, `== {name}`)
	for _, message in sent do
		table.insert(
			transcript,
			`{message.method} {message.remote} -> {message.to}: {message.bytes} {message.instances}`
		)
		if message.to == "Player1" or message.to == "everyone" then
			clientHandlers[message.remote](message.buff, message.instanceList)
		end
	end
	for _, line in received do
		table.insert(transcript, `  received {line}`)
	end
end

local P1, P2, P3 = players[1], players[2], players[3]

for _, case in { { "Detailed", server.Detailed }, { "Nested.Note", server.Nested.Note } } do
	local name, event = case[1], case[2]
	local first = if name == "Detailed" then detailed else "first note"
	local second = if name == "Detailed" then plain else ""
	step(`{name}.Fire`, function()
		event.Fire(P1, first)
	end)
	step(`{name}.FireAll`, function()
		event.FireAll(second)
	end)
	step(`{name}.FireExcept`, function()
		event.FireExcept(P2, first)
	end)
	step(`{name}.FireList`, function()
		event.FireList({ P1, P3 }, second)
	end)
	step(`{name}.FireSet`, function()
		event.FireSet({ [P1] = true }, first)
	end)
end

step("Pair", function()
	server.Pair.Fire(P1, "boarding", 42)
	server.Pair.FireAll("gate", 7)
	server.Pair.FireExcept(P3, "seat", 1)
	server.Pair.FireList({ P1 }, "bag", 2)
	server.Pair.FireSet({ [P1] = true }, "tray", 3)
end)

step("Ping", function()
	server.Ping.Fire(P1)
	server.Ping.FireAll()
	server.Ping.FireExcept(P1)
	server.Ping.FireList({ P1, P2 })
	server.Ping.FireSet({ [P1] = true })
end)

step("Moved", function()
	server.Moved.Fire(P1, { x = 1.25, z = -8 })
	server.Moved.FireAll({ x = 0, z = 0 })
	server.Moved.FireExcept(P2, { x = 3, z = 4 })
	server.Moved.FireList({ P1, P3 }, { x = 5, z = 6 })
	server.Moved.FireSet({ [P1] = true }, { x = 7, z = 8 })
end)

step("Ordered", function()
	server.Ordered.Fire(P1, 1)
	server.Ordered.Fire(P1, 2)
	server.Ordered.FireAll(3)
	server.Ordered.FireExcept(P2, 4)
	server.Ordered.FireList({ P1, P3 }, 5)
	server.Ordered.FireSet({ [P1] = true }, 6)
end)

step("Tick", function()
	server.Tick.Fire(P1)
	server.Tick.FireAll()
	server.Tick.FireExcept(P3)
	server.Tick.FireList({ P1 })
	server.Tick.FireSet({ [P1] = true })
end)

step("Interleaved", function()
	server.Pair.Fire(P1, "one", 1)
	server.Detailed.Fire(P1, plain)
	server.Ping.FireAll()
	server.Pair.FireList({ P1, P2 }, "two", 2)
end)

fs.writeFile(transcriptPath, table.concat(transcript, "\n") .. "\n")
