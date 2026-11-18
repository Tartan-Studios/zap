--!strict
local Players = game:GetService("Players")
local server = require("./server")
local client = require("./client")

local player = Players:GetPlayers()[1]

server.Scored.Fire(player, 5) --> error
server.Scored.Fire(player, { points = "3", kind = "Small" }) --> error
server.Scored.Fire(player, { points = 3, kind = "Huge" }) --> error
server.Scored.Fire(player, { kind = "Small" }) --> error
server.Scored.FireExcept(player, { points = 3, kind = "Small" }) --> error
server.Scored.FireSet({ [player] = true }, { points = 3, kind = "Small" }) --> error
server.Scored.FireList(player, { points = 3, kind = "Small" }) --> error
server.Moved.Fire(player, "fast", 2) --> error
client.Pressed.Fire("Medium") --> error
client.Polled.Fire(10) --> error
client.Scored.On(function(value) local points: string = value.points end) --> error
local accepted: string = client.Buy.Call("hat", 2) --> error
client.Buy.Call(5, 2) --> error
