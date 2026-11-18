--!strict
local Players = game:GetService("Players")
local server = require("./server")
local client = require("./client")

local player = Players:GetPlayers()[1]

server.Scored.Fire(player, { points = 3, kind = "Small" })
server.Scored.FireAll({ points = 3, kind = "Large", note = "hello" })
server.Scored.FireList({ player }, { points = 1, kind = "Small" })
server.Moved.Fire(player, 1.5, -2)
server.Moved.FireAll(0, 0)

client.Pressed.Fire("Large")
client.Polled.Fire("label")

server.Pressed.SetCallback(function(from: Player, kind: "Small" | "Large") end)

client.Scored.On(function(value)
	local points: number = value.points
	local kind: "Small" | "Large" = value.kind
	local note: string? = value.note
end)

client.Moved.On(function(x, z)
	local total: number = x + z
end)

for index, from, label in server.Polled.Iter() do
	local text: string = label
	local sender: Player = from
end

server.Buy.SetCallback(function(from: Player, item: string, count: number)
	return true, nil
end)

local accepted, receipt = client.Buy.Call("hat", 2)
local acceptedBoolean: boolean = accepted
local receiptNumber: number? = receipt

local stopHearingRefusals = server.SetPacketRefusedCallback(function(from: Player, reason: "PacketTooLarge" | "TooManyEvents")
	local refusedName: string = from.Name
end)
stopHearingRefusals()
