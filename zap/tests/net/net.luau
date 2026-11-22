local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local serverCode, clientCode, looseClientCode, schemaCode, seedText, reportPath =
	process.args[1], process.args[2], process.args[3], process.args[4], process.args[5], process.args[6]

local SCHEMA = (luau.load("return " .. schemaCode, { debugName = "Schema" }) :: any)()

local SAMPLES = 12
local HOSTILE_SAMPLES = 8
local FUZZ_BUFFERS = 300
local MAX_DEPTH = 3
local SLOW_MESSAGE_SECONDS = 0.5

local Instance = roblox.Instance
local game = Instance.new("DataModel")

local report: { string } = {}
local failures: { string } = {}

local function line(text: string)
	table.insert(report, text)
end

local function fail(text: string)
	table.insert(failures, text)
end

local function finish()
	local text = table.concat(report, "\n") .. "\n"
	if #failures > 0 then
		text ..= "\nFAILURES\n" .. table.concat(failures, "\n") .. "\n"
	end
	fs.writeFile(reportPath, text)
	if #failures > 0 then
		error(`{#failures} network check(s) failed:\n{table.concat(failures, "\n")}`)
	end
end

-- Park-Miller minimal standard generator; every step stays exact in a double.
local state = tonumber(seedText) :: number
local function random(): number
	state = (state * 48271) % 2147483647
	return state / 2147483647
end

local function integer(low: number, high: number): number
	return low + math.floor(random() * (high - low + 1))
end

local function chance(p: number): boolean
	return random() < p
end

local function pick<T>(list: { T }): T
	return list[integer(1, #list)]
end

local function axisOf(value: any, axis: string): number
	if axis == "x" then
		return value.x
	elseif axis == "y" then
		return value.y
	end
	return value.z
end

local function toF32(value: number): number
	local buff = buffer.create(4)
	buffer.writef32(buff, 0, value)
	return buffer.readf32(buff, 0)
end

local NUMTY_LIMITS = {
	u8 = { 0, 255 },
	u16 = { 0, 65535 },
	u32 = { 0, 4294967295 },
	i8 = { -128, 127 },
	i16 = { -32768, 32767 },
	i32 = { -2147483648, 2147483647 },
	f32 = { -math.huge, math.huge },
	f64 = { -math.huge, math.huge },
}

local NUMTY_BOUNDS = {
	u8 = { 0, 255 },
	u16 = { 0, 65535 },
	u32 = { 0, 4294967295 },
	i8 = { -128, 127 },
	i16 = { -32768, 32767 },
	i32 = { -2147483648, 2147483647 },
	f32 = { -1e6, 1e6 },
	f64 = { -1e9, 1e9 },
}

local function isFloat(numty: string): boolean
	return numty == "f32" or numty == "f64"
end

local function numberBounds(desc): (number, number)
	local bounds = NUMTY_BOUNDS[desc.numty]
	local low, high = desc.range.min, desc.range.max
	if low and not high then
		high = if isFloat(desc.numty) then low + bounds[2] else bounds[2]
	elseif high and not low then
		low = if isFloat(desc.numty) then high + bounds[1] else bounds[1]
	elseif not low and not high then
		low, high = bounds[1], bounds[2]
	end
	if not isFloat(desc.numty) then
		low, high = math.max(low, bounds[1]), math.min(high, bounds[2])
	end
	return low, high
end

local function lengthBounds(range, spread: number): (number, number)
	local low = range.min or 0
	local high = range.max or (low + spread)
	return low, math.min(high, low + spread)
end

local players = {}
for index = 1, 3 do
	local player = Instance.new("Folder")
	player.Name = `Player{index}`
	players[index] = player
end
local P1, P2, P3 = players[1], players[2], players[3]

local instancePool: { [string]: { Instance } } = {}
local function instanceOf(class: string): Instance
	local pool = instancePool[class]
	if not pool then
		pool = {}
		for index = 1, 3 do
			local instance = Instance.new(class)
			instance.Name = `{class}{index}`
			table.insert(pool, instance)
		end
		instancePool[class] = pool
	end
	return pick(pool)
end

local ALIGNED = {
	roblox.CFrame.Angles(0, 0, 0),
	roblox.CFrame.Angles(math.rad(90), 0, 0),
	roblox.CFrame.Angles(0, math.rad(180), math.rad(180)),
	roblox.CFrame.Angles(math.rad(-90), 0, 0),
	roblox.CFrame.Angles(0, math.rad(180), math.rad(90)),
	roblox.CFrame.Angles(0, math.rad(90), math.rad(90)),
	roblox.CFrame.Angles(0, 0, math.rad(90)),
	roblox.CFrame.Angles(0, math.rad(-90), math.rad(90)),
}

local DateTimeShim = {}
local dateTimeMeta = {
	__eq = function(a, b)
		return a.UnixTimestampMillis == b.UnixTimestampMillis
	end,
	__tostring = function(self)
		return `DateTime({self.UnixTimestampMillis})`
	end,
}

function DateTimeShim.fromUnixTimestampMillis(millis: number)
	return setmetatable({ UnixTimestampMillis = millis, UnixTimestamp = millis // 1000 }, dateTimeMeta)
end

function DateTimeShim.fromUnixTimestamp(seconds: number)
	return setmetatable({ UnixTimestampMillis = seconds * 1000, UnixTimestamp = seconds }, dateTimeMeta)
end

local DateTime = (roblox :: any).DateTime or DateTimeShim

local function typeOf(value: any): string
	if typeof(value) == "table" and getmetatable(value) == dateTimeMeta then
		return "DateTime"
	end
	return typeof(value)
end

local HAS_DATETIME = true

local function needsUnavailable(desc, seen: { [string]: boolean }?): string?
	local visited = seen or {}
	local kind = desc.kind
	if (kind == "DateTime" or kind == "DateTimeMillis") and not HAS_DATETIME then
		return "DateTime"
	elseif kind == "ref" then
		if visited[desc.name] then
			return nil
		end
		visited[desc.name] = true
		return needsUnavailable(SCHEMA.types[desc.name], visited)
	end
	for _, child in { desc.item, desc.key, desc.value, desc.inner, desc.x, desc.y, desc.z } do
		local missing = needsUnavailable(child, visited)
		if missing then
			return missing
		end
	end
	for _, list in { desc.members, desc.fields } do
		for _, member in list do
			local missing = needsUnavailable(member.ty or member, visited)
			if missing then
				return missing
			end
		end
	end
	for _, variant in desc.variants or {} do
		for _, field in variant.fields do
			local missing = needsUnavailable(field.ty, visited)
			if missing then
				return missing
			end
		end
	end
	return nil
end

local generate: (any, number) -> any

local function generateNumber(desc): number
	local low, high = numberBounds(desc)
	if not isFloat(desc.numty) then
		low, high = math.ceil(low), math.floor(high)
		if chance(0.2) then
			return if chance(0.5) then low else high
		end
		return integer(low, high)
	end
	for _ = 1, 16 do
		local value
		if chance(0.2) then
			value = if chance(0.5) then low else high
		elseif chance(0.3) then
			value = math.floor(low + random() * (high - low))
		else
			value = low + random() * (high - low)
		end
		if desc.numty == "f32" then
			value = toF32(value)
		end
		if value >= low and value <= high then
			return value
		end
	end
	return toF32(low)
end

local WIDEST_UTF8_CHARACTER = "\u{1f6eb}"
local UTF8_PIECES = { "a", "Z", "7", " ", "\u{e9}", "\u{20ac}", WIDEST_UTF8_CHARACTER }

local function generateString(desc, length: number): string
	if not desc.utf8 then
		local bytes = table.create(length)
		for index = 1, length do
			bytes[index] = string.char(integer(0, 255))
		end
		return table.concat(bytes)
	end
	if chance(0.2) then
		return string.rep(WIDEST_UTF8_CHARACTER, length)
	end
	local pieces = table.create(length)
	for index = 1, length do
		pieces[index] = pick(UTF8_PIECES)
	end
	return table.concat(pieces)
end

local function hashable(desc): boolean
	local kind = desc.kind
	if kind == "ref" then
		return hashable(SCHEMA.types[desc.name])
	end
	return kind == "num" or kind == "str" or kind == "enum" or kind == "boolean" or kind == "instance"
end

local function generateFields(fields, depth: number, into)
	for _, field in fields do
		into[field.name] = generate(field.ty, depth)
	end
	return into
end

local PRIMITIVE_TYPEOF = {
	num = "number",
	str = "string",
	buf = "buffer",
	boolean = "boolean",
	enum = "string",
	instance = "Instance",
	arr = "table",
	map = "table",
	set = "table",
	struct = "table",
	tagged = "table",
}

local function generateUnknown(taken: { [string]: boolean }?): any
	local options = {}
	for _, value in { 7, -2.5, "unknown", true, instanceOf("Folder") } do
		if not (taken and taken[typeof(value)]) then
			table.insert(options, value)
		end
	end
	return pick(options)
end

generate = function(desc, depth: number): any
	local kind = desc.kind
	if kind == "num" then
		return generateNumber(desc)
	elseif kind == "str" then
		local low, high = lengthBounds(desc.range, 12)
		return generateString(desc, integer(low, high))
	elseif kind == "buf" then
		local low, high = lengthBounds(desc.range, 12)
		return buffer.fromstring(generateString({ utf8 = false }, integer(low, high)))
	elseif kind == "vector" then
		return vector.create(
			generateNumber(desc.x),
			generateNumber(desc.y),
			if desc.z then generateNumber(desc.z) else 0
		)
	elseif kind == "arr" then
		local low, high = lengthBounds(desc.range, 3)
		local length = if depth >= MAX_DEPTH then low else integer(low, high)
		local item = if desc.item.kind == "opt" then desc.item.inner else desc.item
		local list = table.create(length)
		for index = 1, length do
			list[index] = generate(item, depth + 1)
		end
		return list
	elseif kind == "map" or kind == "set" then
		local result = {}
		if depth >= MAX_DEPTH or not hashable(desc.key) then
			return result
		end
		for _ = 1, integer(0, 3) do
			local key = generate(desc.key, depth + 1)
			if result[key] == nil then
				result[key] = if kind == "map" then generate(desc.value, depth + 1) else true
			end
		end
		return result
	elseif kind == "opt" then
		if depth >= MAX_DEPTH or chance(0.3) then
			return nil
		end
		return generate(desc.inner, depth + 1)
	elseif kind == "ref" then
		return generate(SCHEMA.types[desc.name], depth + 1)
	elseif kind == "enum" then
		return pick(desc.values)
	elseif kind == "tagged" then
		local variant = pick(desc.variants)
		return generateFields(variant.fields, depth + 1, { [desc.tag] = variant.name })
	elseif kind == "struct" then
		return generateFields(desc.fields, depth + 1, {})
	elseif kind == "or" then
		if desc.optional and chance(0.25) then
			return nil
		end
		local chosen = pick(desc.members)
		if chosen.kind == "unknown" or (chosen.kind == "opt" and chosen.inner.kind == "unknown") then
			local taken = {}
			for _, other in desc.members do
				local resolved = other
				while resolved.kind == "ref" do
					resolved = SCHEMA.types[resolved.name]
				end
				if PRIMITIVE_TYPEOF[resolved.kind] then
					taken[PRIMITIVE_TYPEOF[resolved.kind]] = true
				end
			end
			return generateUnknown(taken)
		end
		return generate(chosen, depth + 1)
	elseif kind == "instance" then
		return instanceOf(desc.class or pick({ "Folder", "Part", "Model" }))
	elseif kind == "unknown" then
		return generateUnknown()
	elseif kind == "BrickColor" then
		return roblox.BrickColor.new(pick({ 1, 21, 23, 24, 26, 194, 199, 1001, 1004 }))
	elseif kind == "DateTimeMillis" then
		return DateTime.fromUnixTimestampMillis(integer(0, 2e12))
	elseif kind == "DateTime" then
		return DateTime.fromUnixTimestamp(integer(0, 2e9))
	elseif kind == "Color3" then
		return roblox.Color3.fromRGB(integer(0, 255), integer(0, 255), integer(0, 255))
	elseif kind == "Vector2" then
		return roblox.Vector3.new(toF32(random() * 200 - 100), toF32(random() * 200 - 100), 0)
	elseif kind == "Vector3" then
		return roblox.Vector3.new(toF32(random() * 200 - 100), toF32(random() * 200 - 100), toF32(random() * 200 - 100))
	elseif kind == "AlignedCFrame" then
		return roblox.CFrame.new(integer(-500, 500), integer(-500, 500), integer(-500, 500)) * pick(ALIGNED)
	elseif kind == "CFrame" then
		return roblox.CFrame.new(integer(-500, 500), integer(-500, 500), integer(-500, 500))
			* roblox.CFrame.Angles(random() * 3, random() * 3, random() * 3)
	elseif kind == "boolean" then
		return chance(0.5)
	end
	error(`no generator for {kind}`)
end

local function show(value: any, depth: number?): string
	local level = depth or 0
	local kind = typeof(value)
	if kind == "table" and level < 4 then
		local keys = {}
		for key in value do
			table.insert(keys, key)
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		local parts = {}
		for _, key in keys do
			table.insert(parts, `{show(key, level + 1)}={show(value[key], level + 1)}`)
		end
		return `\{{table.concat(parts, ", ")}\}`
	elseif kind == "string" then
		return string.format("%q", value)
	elseif kind == "buffer" then
		return `buffer({string.format("%q", buffer.tostring(value))})`
	elseif kind == "Instance" then
		return `{value.ClassName}:{value.Name}`
	end
	return `{kind}({tostring(value)})`
end

local function deepEqual(a: any, b: any): boolean
	if rawequal(a, b) then
		return true
	end
	if typeof(a) ~= typeof(b) then
		return false
	end
	if typeof(a) == "buffer" then
		return buffer.tostring(a) == buffer.tostring(b)
	end
	if typeof(a) ~= "table" then
		return a == b
	end
	for key, value in a do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local equal: (any, any, any) -> boolean

local function fieldsEqual(fields, a, b): boolean
	for _, field in fields do
		if not equal(field.ty, a[field.name], b[field.name]) then
			return false
		end
	end
	return true
end

equal = function(desc, a: any, b: any): boolean
	local kind = desc.kind
	if kind == "opt" then
		if a == nil or b == nil then
			return a == nil and b == nil
		end
		return equal(desc.inner, a, b)
	elseif kind == "ref" then
		return equal(SCHEMA.types[desc.name], a, b)
	elseif kind == "arr" then
		if typeof(b) ~= "table" or #a ~= #b then
			return false
		end
		for index = 1, #a do
			if not equal(desc.item, a[index], b[index]) then
				return false
			end
		end
		return true
	elseif kind == "map" or kind == "set" then
		if typeof(b) ~= "table" then
			return false
		end
		for key, value in a do
			if b[key] == nil or (kind == "map" and not equal(desc.value, value, b[key])) then
				return false
			end
		end
		for key in b do
			if a[key] == nil then
				return false
			end
		end
		return true
	elseif kind == "struct" then
		return typeof(b) == "table" and fieldsEqual(desc.fields, a, b)
	elseif kind == "tagged" then
		if typeof(b) ~= "table" or a[desc.tag] ~= b[desc.tag] then
			return false
		end
		for _, variant in desc.variants do
			if variant.name == a[desc.tag] then
				return fieldsEqual(variant.fields, a, b)
			end
		end
		return false
	elseif kind == "vector" then
		return typeof(b) == typeof(a) and a.x == b.x and a.y == b.y and a.z == b.z
	elseif kind == "CFrame" then
		if typeof(b) ~= "CFrame" then
			return false
		end
		local left, right = { a:GetComponents() }, { b:GetComponents() }
		for index = 1, 12 do
			if math.abs(left[index] - right[index]) > 1e-3 then
				return false
			end
		end
		return true
	elseif kind == "buf" then
		return typeof(b) == "buffer" and buffer.tostring(a) == buffer.tostring(b)
	elseif kind == "num" then
		return typeof(b) == "number" and (a == b or (a ~= a and b ~= b))
	elseif kind == "or" or kind == "unknown" then
		return deepEqual(a, b)
	end
	return typeOf(a) == typeOf(b) and a == b
end

local function difference(desc, a: any, b: any, path: string): string?
	if equal(desc, a, b) then
		return nil
	end
	local kind = desc.kind
	if kind == "ref" then
		return difference(SCHEMA.types[desc.name], a, b, path)
	elseif kind == "opt" and a ~= nil and b ~= nil then
		return difference(desc.inner, a, b, path)
	elseif kind == "struct" and typeof(b) == "table" then
		for _, field in desc.fields do
			local found = difference(field.ty, a[field.name], b[field.name], `{path}.{field.name}`)
			if found then
				return found
			end
		end
	elseif kind == "tagged" and typeof(b) == "table" and a[desc.tag] == b[desc.tag] then
		for _, variant in desc.variants do
			if variant.name == a[desc.tag] then
				for _, field in variant.fields do
					local found = difference(field.ty, a[field.name], b[field.name], `{path}.{field.name}`)
					if found then
						return found
					end
				end
			end
		end
	elseif kind == "arr" and typeof(b) == "table" and #a == #b then
		for index = 1, #a do
			local found = difference(desc.item, a[index], b[index], `{path}[{index}]`)
			if found then
				return found
			end
		end
	end
	return `{path}: sent {show(a)}, received {show(b)}`
end

local conforms: (any, any) -> (boolean, string?)

local function fieldsConform(fields, value): (boolean, string?)
	for _, field in fields do
		local ok, why = conforms(field.ty, value[field.name])
		if not ok then
			return false, `{field.name}: {why}`
		end
	end
	return true
end

local function lengthConforms(range, length: number): (boolean, string?)
	if range.min and length < range.min then
		return false, `length {length} is below {range.min}`
	end
	if range.max and length > range.max then
		return false, `length {length} is above {range.max}`
	end
	return true
end

local function numberConforms(desc, value: any): (boolean, string?)
	if typeof(value) ~= "number" then
		return false, `expected a number, got {typeof(value)}`
	end
	if not isFloat(desc.numty) then
		local bounds = NUMTY_LIMITS[desc.numty]
		if value ~= math.floor(value) or value < bounds[1] or value > bounds[2] then
			return false, `{value} is not a {desc.numty}`
		end
	end
	if desc.range.min and not (value >= desc.range.min) then
		return false, `{value} is below {desc.range.min}`
	end
	if desc.range.max and not (value <= desc.range.max) then
		return false, `{value} is above {desc.range.max}`
	end
	return true
end

local TYPEOF_KINDS = {
	BrickColor = "BrickColor",
	DateTime = "DateTime",
	DateTimeMillis = "DateTime",
	Color3 = "Color3",
	Vector2 = "Vector3",
	Vector3 = "Vector3",
	AlignedCFrame = "CFrame",
	CFrame = "CFrame",
	boolean = "boolean",
}

conforms = function(desc, value: any): (boolean, string?)
	local kind = desc.kind
	if kind == "opt" then
		if value == nil then
			return true
		end
		return conforms(desc.inner, value)
	elseif kind == "ref" then
		return conforms(SCHEMA.types[desc.name], value)
	elseif kind == "num" then
		return numberConforms(desc, value)
	elseif kind == "str" then
		if typeof(value) ~= "string" then
			return false, `expected a string, got {typeof(value)}`
		end
		if not desc.utf8 then
			return lengthConforms(desc.range, #value)
		end
		local characters = utf8.len(value)
		if characters == nil then
			return false, "invalid utf-8"
		end
		return lengthConforms(desc.range, characters)
	elseif kind == "buf" then
		if typeof(value) ~= "buffer" then
			return false, `expected a buffer, got {typeof(value)}`
		end
		return lengthConforms(desc.range, buffer.len(value))
	elseif kind == "vector" then
		if typeof(value) ~= "vector" and typeof(value) ~= "Vector3" then
			return false, `expected a vector, got {typeof(value)}`
		end
		for _, axis in { "x", "y", "z" } do
			local component = desc[axis]
			if component then
				local ok, why = numberConforms(component, axisOf(value, axis))
				if not ok then
					return false, `{axis}: {why}`
				end
			end
		end
		return true
	elseif kind == "arr" then
		if typeof(value) ~= "table" then
			return false, `expected an array, got {typeof(value)}`
		end
		local length = 0
		for key in value do
			if typeof(key) ~= "number" or key ~= math.floor(key) or key < 1 then
				return false, `{show(key)} is not an array index`
			end
			length = math.max(length, key)
		end
		local ok, why = lengthConforms({ max = desc.range.max }, length)
		if not ok then
			return false, why
		end
		if desc.item.kind ~= "opt" then
			local lengthOk, lengthWhy = lengthConforms(desc.range, length)
			if not lengthOk then
				return false, lengthWhy
			end
		end
		for index = 1, length do
			local itemOk, itemWhy = conforms(desc.item, value[index])
			if not itemOk then
				return false, `[{index}]: {itemWhy}`
			end
		end
		return true
	elseif kind == "map" or kind == "set" then
		if typeof(value) ~= "table" then
			return false, `expected a table, got {typeof(value)}`
		end
		for key, item in value do
			local ok, why = conforms(desc.key, key)
			if not ok then
				return false, `key: {why}`
			end
			if kind == "set" and item ~= true then
				return false, "set value is not true"
			elseif kind == "map" then
				local itemOk, itemWhy = conforms(desc.value, item)
				if not itemOk then
					return false, `value: {itemWhy}`
				end
			end
		end
		return true
	elseif kind == "enum" then
		if table.find(desc.values, value) == nil then
			return false, `{show(value)} is not an enum value`
		end
		return true
	elseif kind == "tagged" then
		if typeof(value) ~= "table" then
			return false, `expected a table, got {typeof(value)}`
		end
		for _, variant in desc.variants do
			if variant.name == value[desc.tag] then
				return fieldsConform(variant.fields, value)
			end
		end
		return false, `{show(value[desc.tag])} is not a variant`
	elseif kind == "struct" then
		if typeof(value) ~= "table" then
			return false, `expected a table, got {typeof(value)}`
		end
		return fieldsConform(desc.fields, value)
	elseif kind == "or" then
		if value == nil then
			return desc.optional, "nil is not allowed"
		end
		for _, member in desc.members do
			if conforms(member, value) then
				return true
			end
		end
		return false, `{show(value)} matches no member`
	elseif kind == "instance" then
		if typeof(value) ~= "Instance" then
			return false, `expected an Instance, got {typeof(value)}`
		end
		if desc.class and not value:IsA(desc.class) then
			return false, `{value.ClassName} is not a {desc.class}`
		end
		return true
	elseif kind == "unknown" then
		return true
	end
	local expected = TYPEOF_KINDS[kind]
	if typeOf(value) ~= expected then
		return false, `expected {expected}, got {typeOf(value)}`
	end
	return true
end

local invalid: (any, number) -> (any, string?)

local function invalidNumber(desc): (number?, string?)
	local bounds = NUMTY_LIMITS[desc.numty]
	local float = isFloat(desc.numty)
	local step = if float then 0.5 else 1
	if desc.range.min and (float or desc.range.min - step >= bounds[1]) then
		local value = desc.range.min - step
		if desc.numty == "f32" then
			value = toF32(value)
		end
		if value < desc.range.min then
			return value, `below {desc.range.min}`
		end
	end
	if desc.range.max and (float or desc.range.max + step <= bounds[2]) then
		local value = desc.range.max + step
		if desc.numty == "f32" then
			value = toF32(value)
		end
		if value > desc.range.max then
			return value, `above {desc.range.max}`
		end
	end
	return nil
end

local function invalidLength(range, cap: number?): number?
	if range.max and cap and range.max + 1 <= cap then
		return range.max + 1
	end
	return nil
end

local function invalidFields(fields, depth: number, build: () -> any): (any, string?)
	local order = {}
	for index = 1, #fields do
		order[index] = index
	end
	for index = #order, 2, -1 do
		local swap = integer(1, index)
		order[index], order[swap] = order[swap], order[index]
	end
	for _, index in order do
		local field = fields[index]
		local bad, why = invalid(field.ty, depth + 1)
		if why then
			local value = build()
			value[field.name] = bad
			return value, `{field.name}: {why}`
		end
	end
	return nil
end

invalid = function(desc, depth: number): (any, string?)
	if depth > MAX_DEPTH then
		return nil
	end
	local kind = desc.kind
	if kind == "num" then
		return invalidNumber(desc)
	elseif kind == "str" or kind == "buf" then
		local length = invalidLength(desc.range, desc.cap)
		if length then
			local text = string.rep("a", length)
			if kind == "buf" then
				return buffer.fromstring(text), `length {length}`
			end
			return text, if desc.utf8 then `{length} characters` else `length {length}`
		end
		if kind == "str" and desc.utf8 and (desc.range.max == nil or desc.range.max >= 1) then
			local low = math.max(desc.range.min or 0, 1)
			return string.rep("a", low - 1) .. "\xff", "invalid utf-8"
		end
		return nil
	elseif kind == "vector" then
		for _, axis in { "x", "y", "z" } do
			local component = desc[axis]
			local bad, why = if component then invalidNumber(component) else nil
			if why then
				local value = { x = generateNumber(desc.x), y = generateNumber(desc.y), z = if desc.z then generateNumber(desc.z) else 0 }
				value[axis] = bad
				return vector.create(value.x, value.y, value.z), `{axis} {why}`
			end
		end
		return nil
	elseif kind == "arr" then
		local length = invalidLength(desc.range, desc.cap)
		if length then
			local list = table.create(length)
			for index = 1, length do
				list[index] = generate(desc.item, MAX_DEPTH)
			end
			return list, `length {length}`
		end
		local low, high = lengthBounds(desc.range, 3)
		if high >= 1 then
			local bad, why = invalid(desc.item, depth + 1)
			if why then
				local list = table.create(math.max(low, 1))
				for index = 1, math.max(low, 1) do
					list[index] = generate(desc.item, MAX_DEPTH)
				end
				list[integer(1, #list)] = bad
				return list, `item: {why}`
			end
		end
		return nil
	elseif kind == "map" then
		local badKey, keyWhy = invalid(desc.key, depth + 1)
		if keyWhy and hashable(desc.key) then
			return { [badKey] = generate(desc.value, MAX_DEPTH) }, `key: {keyWhy}`
		end
		local badValue, valueWhy = invalid(desc.value, depth + 1)
		if valueWhy and hashable(desc.key) then
			return { [generate(desc.key, MAX_DEPTH)] = badValue }, `value: {valueWhy}`
		end
		return nil
	elseif kind == "set" then
		local badKey, keyWhy = invalid(desc.key, depth + 1)
		if keyWhy and hashable(desc.key) then
			return { [badKey] = true }, `key: {keyWhy}`
		end
		return nil
	elseif kind == "opt" then
		local inner = desc.inner
		if inner.kind == "instance" and inner.class then
			return instanceOf(if inner.class == "Folder" then "Part" else "Folder"), `not a {inner.class}`
		end
		return invalid(inner, depth + 1)
	elseif kind == "ref" then
		return invalid(SCHEMA.types[desc.name], depth + 1)
	elseif kind == "struct" then
		return invalidFields(desc.fields, depth, function()
			return generateFields(desc.fields, MAX_DEPTH, {})
		end)
	elseif kind == "tagged" then
		for _, variant in desc.variants do
			local bad, why = invalidFields(variant.fields, depth, function()
				return generateFields(variant.fields, MAX_DEPTH, { [desc.tag] = variant.name })
			end)
			if why then
				return bad, `{variant.name}.{why}`
			end
		end
		return nil
	elseif kind == "instance" then
		if desc.class and chance(0.5) then
			return instanceOf(if desc.class == "Folder" then "Part" else "Folder"), `not a {desc.class}`
		end
		return nil, "a missing Instance"
	end
	return nil
end

local NAMES = {
	Pascal = {
		Fire = "Fire",
		FireAll = "FireAll",
		FireExcept = "FireExcept",
		FireList = "FireList",
		FireSet = "FireSet",
		On = "On",
		SetCallback = "SetCallback",
		Call = "Call",
		Iter = "Iter",
		SendEvents = "SendEvents",
		SetPacketRefusedCallback = "SetPacketRefusedCallback",
	},
	Camel = {
		Fire = "fire",
		FireAll = "fireAll",
		FireExcept = "fireExcept",
		FireList = "fireList",
		FireSet = "fireSet",
		On = "on",
		SetCallback = "setCallback",
		Call = "call",
		Iter = "iter",
		SendEvents = "sendEvents",
		SetPacketRefusedCallback = "setPacketRefusedCallback",
	},
	Snake = {
		Fire = "fire",
		FireAll = "fire_all",
		FireExcept = "fire_except",
		FireList = "fire_list",
		FireSet = "fire_set",
		On = "on",
		SetCallback = "set_callback",
		Call = "call",
		Iter = "iter",
		SendEvents = "send_events",
		SetPacketRefusedCallback = "set_packet_refused_callback",
	},
}
local N = NAMES[SCHEMA.casing]

type Message = { remote: string, from: string, to: Instance?, buff: buffer, inst: { any } }

local handlers: { [string]: { [string]: (...any) -> () } } = { Server = {}, Client = {}, LooseClient = {} }
local toClients: { Message } = {}
local toServer: { Message } = {}
local serverErrors: { string } = {}

local function copyMessage(remote: any, from: string, to: Instance?, buff: buffer, inst: { any }?): Message
	return {
		remote = remote.Name,
		from = from,
		to = to,
		buff = buffer.fromstring(buffer.tostring(buff)),
		inst = if inst then table.clone(inst) else {},
	}
end

local function noopSignal()
	return { Connect = function() end }
end

roblox.implementMethod("Instance", "WaitForChild", function(self, ...)
	return self:FindFirstChild(...)
end)
roblox.implementMethod("RunService", "IsRunning", function()
	return true
end)
local CLIENT_CHUNKS = { Client = true, LooseClient = true }

local function chunk(level: number): string
	local source = debug.info(level + 1, "s")
	return string.match(source, '^%[string "(.*)"%]$') or source
end

roblox.implementMethod("RunService", "IsServer", function()
	return not CLIENT_CHUNKS[chunk(2)]
end)
roblox.implementMethod("RunService", "IsClient", function()
	return CLIENT_CHUNKS[chunk(2)] == true
end)
local heartbeats: { [string]: { () -> () } } = { Server = {}, Client = {}, LooseClient = {} }
roblox.implementProperty("RunService", "Heartbeat", function()
	return {
		Connect = function(_, handler)
			table.insert(heartbeats[chunk(2)], handler)
		end,
	}
end)

local function nextServerFrame()
	for _, handler in heartbeats.Server do
		handler()
	end
end
roblox.implementProperty("Players", "PlayerRemoving", noopSignal)
roblox.implementMethod("Players", "GetPlayers", function()
	return table.clone(players)
end)

for _, class in { "RemoteEvent", "UnreliableRemoteEvent" } do
	for _, property in { "OnServerEvent", "OnClientEvent" } do
		roblox.implementProperty(class, property, function(remote)
			return {
				Connect = function(_, handler)
					handlers[chunk(2)][remote.Name] = handler
				end,
			}
		end)
	end
	roblox.implementMethod(class, "FireClient", function(remote, player, buff, inst)
		table.insert(toClients, copyMessage(remote, "Server", player, buff, inst))
	end)
	roblox.implementMethod(class, "FireAllClients", function(remote, buff, inst)
		for _, player in players do
			table.insert(toClients, copyMessage(remote, "Server", player, buff, inst))
		end
	end)
	roblox.implementMethod(class, "FireServer", function(remote, buff, inst)
		table.insert(toServer, copyMessage(remote, chunk(2), nil, buff, inst))
	end)
end

-- Roblox's CFrame.fromAxisAngle normalizes its axis, and Zap's CFrame decoding relies on that, but
-- Lune's does not, so the environment normalizes it the way Roblox does.
local CFrameWithRobloxAxisAngle = setmetatable({
	fromAxisAngle = function(axis, angle)
		return roblox.CFrame.fromAxisAngle(axis.Unit, angle)
	end,
}, { __index = roblox.CFrame })

local environment = {
	game = game,
	Instance = Instance,
	CFrame = CFrameWithRobloxAxisAngle,
	Vector3 = roblox.Vector3,
	Vector2 = roblox.Vector2,
	Color3 = roblox.Color3,
	BrickColor = roblox.BrickColor,
	DateTime = DateTime,
	task = task,
	debug = setmetatable({ profilebegin = function() end, profileend = function() end }, { __index = debug }),
	vector = {
		create = function(x: number, y: number, z: number?)
			return (vector :: any)(x, y, z or 0)
		end,
	},
}

local function load(code: string, name: string)
	_G.__ZAP = {}
	return (luau.load(code, { debugName = name, codegenEnabled = true, environment = environment }) :: any)()
end

local server = load(serverCode, "Server")
local client = load(clientCode, "Client")
local looseClient = load(looseClientCode, "LooseClient")

local function member(module, path: { string })
	local node = module
	for _, segment in path do
		node = node[segment]
	end
	return node
end

local function pathName(path: { string }): string
	return table.concat(path, ".")
end

local function deliverToServer(message: Message)
	local handler = handlers.Server[message.remote]
	if not handler then
		fail(`no server handler for {message.remote}`)
		return
	end
	local sender = if message.from == "LooseClient" then P2 elseif message.from == "Fuzz" then P3 else P1
	local started = os.clock()
	local ok, why = pcall(handler, sender, message.buff, message.inst)
	if os.clock() - started > SLOW_MESSAGE_SECONDS then
		fail(`the server took {os.clock() - started}s to read a {buffer.len(message.buff)} byte message`)
	end
	if not ok then
		table.insert(serverErrors, tostring(why))
	end
end

local recipients: { [string]: number } = {}

local function pump()
	for _ = 1, 8 do
		nextServerFrame()
		server[N.SendEvents]()
		client[N.SendEvents]()
		looseClient[N.SendEvents]()
		if #toClients == 0 and #toServer == 0 then
			task.wait()
			if #toClients == 0 and #toServer == 0 then
				return
			end
		end
		local clientMessages, serverMessages = toClients, toServer
		toClients, toServer = {}, {}
		for _, message in clientMessages do
			recipients[message.to.Name] = (recipients[message.to.Name] or 0) + 1
			if message.to == P1 then
				local handler = handlers.Client[message.remote]
				if handler then
					handler(message.buff, message.inst)
				else
					fail(`no client handler for {message.remote}`)
				end
			end
		end
		for _, message in serverMessages do
			deliverToServer(message)
		end
	end
	fail("the network never went quiet")
end

local function generateArgs(params, depth: number?): { n: number, [number]: any }
	local values = { n = #params }
	for index, desc in params do
		values[index] = generate(desc, depth or 0)
	end
	return values
end

local function argsEqual(params, expected, actual): boolean
	for index, desc in params do
		if not equal(desc, expected[index], actual[index]) then
			return false
		end
	end
	return true
end

local function argsDifference(params, expected, actual): string
	for index, desc in params do
		local found = difference(desc, expected[index], actual[index], `arg{index}`)
		if found then
			return found
		end
	end
	return "no difference"
end

local function showArgs(values): string
	local parts = {}
	for index = 1, values.n or #values do
		parts[index] = show(values[index])
	end
	return table.concat(parts, ", ")
end

type Received = { player: Instance?, values: { n: number, [number]: any } }

local received: { [any]: { Received } } = {}

local function listen(event, side: string, api)
	received[event] = {}
	local function record(...)
		if side == "Server" then
			local packed = table.pack(...)
			table.insert(received[event], { player = packed[1], values = table.pack(select(2, ...)) })
		else
			table.insert(received[event], { values = table.pack(...) })
		end
	end
	if event.call == "SingleSync" or event.call == "SingleAsync" then
		api[N.SetCallback](record)
	elseif event.call == "ManySync" or event.call == "ManyAsync" then
		api[N.On](record)
	end
end

local function collect(event, side: string, api): { Received }
	if event.call == "Polling" then
		for _, a, b, c, d, e, f, g, h in api[N.Iter]() do
			local all = table.pack(a, b, c, d, e, f, g, h)
			if side == "Server" then
				table.insert(received[event], { player = all[1], values = table.pack(table.unpack(all, 2, 1 + #event.params)) })
			else
				table.insert(received[event], { values = table.pack(table.unpack(all, 1, #event.params)) })
			end
		end
	end
	local inbox = received[event]
	received[event] = {}
	return inbox
end

local function receiverOf(event)
	if event.from == "Server" then
		return "Client", member(client, event.path)
	end
	return "Server", member(server, event.path)
end

local runnable = {}
for _, event in SCHEMA.events do
	local missing
	for _, desc in event.params do
		missing = missing or needsUnavailable(desc)
	end
	if missing then
		line(`skip {pathName(event.path)}: Lune has no {missing}`)
	else
		table.insert(runnable, event)
		local side, api = receiverOf(event)
		listen(event, side, api)
	end
end

local FIRE_METHODS = { "Fire", "FireAll", "FireExcept", "FireList", "FireSet" }

local function expectedRecipients(method: string): string
	if method == "Fire" then
		return "Player1"
	elseif method == "FireAll" then
		return "Player1,Player2,Player3"
	elseif method == "FireExcept" then
		return "Player1,Player3"
	elseif method == "FireList" then
		return "Player1,Player3"
	end
	return "Player1,Player2"
end

local function fireFromServer(api, method: string, values)
	if method == "Fire" then
		api[N.Fire](P1, table.unpack(values, 1, values.n))
	elseif method == "FireAll" then
		api[N.FireAll](table.unpack(values, 1, values.n))
	elseif method == "FireExcept" then
		api[N.FireExcept](P2, table.unpack(values, 1, values.n))
	elseif method == "FireList" then
		api[N.FireList]({ P1, P3 }, table.unpack(values, 1, values.n))
	else
		api[N.FireSet]({ [P1] = true, [P2] = true }, table.unpack(values, 1, values.n))
	end
end

local function recipientList(): string
	local names = {}
	for name in recipients do
		table.insert(names, name)
	end
	table.sort(names)
	recipients = {}
	return table.concat(names, ",")
end

local capturedClientMessages: { Message } = {}

local function serverErrorText(): string
	if #serverErrors == 0 then
		return ""
	end
	return `; the server raised: {table.concat(serverErrors, " | ")}`
end

local function roundTrip(event)
	local name = pathName(event.path)
	local sender = if event.from == "Server" then member(server, event.path) else member(client, event.path)
	local side, receiver = receiverOf(event)
	local methods = {}
	if event.from == "Server" then
		for _, method in FIRE_METHODS do
			if not SCHEMA.disabled[method] then
				table.insert(methods, method)
			end
		end
	end
	local passed = 0
	for sample = 1, SAMPLES do
		local values = generateArgs(event.params)
		local method = if event.from == "Server" then methods[(sample - 1) % #methods + 1] else "Fire"
		recipients = {}
		serverErrors = {}
		local ok, why = pcall(function()
			if event.from == "Server" then
				fireFromServer(sender, method, values)
			else
				sender[N.Fire](table.unpack(values, 1, values.n))
				client[N.SendEvents]()
				for _, message in toServer do
					table.insert(capturedClientMessages, copyMessage({ Name = message.remote }, message.from, nil, message.buff, message.inst))
				end
			end
			pump()
		end)
		if not ok then
			fail(`{name} {method}({showArgs(values)}) raised: {why}`)
			continue
		end
		local inbox = collect(event, side, receiver)
		local sent = recipientList()
		if event.from == "Server" and sent ~= expectedRecipients(method) then
			fail(`{name} {method} reached {sent}, expected {expectedRecipients(method)}`)
		elseif #inbox ~= 1 then
			fail(`{name} {method}({showArgs(values)}) arrived {#inbox} times{serverErrorText()}`)
		elseif side == "Server" and inbox[1].player ~= P1 then
			fail(`{name} arrived from {show(inbox[1].player)}, expected Player1`)
		elseif not argsEqual(event.params, values, inbox[1].values) then
			fail(`{name} {method} changed a value: {argsDifference(event.params, values, inbox[1].values)}`)
		else
			passed += 1
		end
	end
	line(`round trip {name} ({event.from}, {event.reliability}, {event.call}): {passed}/{SAMPLES}`)
end

local function burst()
	local reliable = {}
	for _, event in runnable do
		if event.reliability == "Reliable" and event.call ~= "Polling" then
			table.insert(reliable, event)
		end
	end
	if #reliable == 0 then
		return
	end
	for _, direction in { "Server", "Client" } do
		local pool = {}
		for _, event in reliable do
			if event.from == direction then
				table.insert(pool, event)
			end
		end
		if #pool > 0 then
			local sent = {}
			for _ = 1, 20 do
				local event = pick(pool)
				local values = generateArgs(event.params)
				local api = member(if direction == "Server" then server else client, event.path)
				if direction == "Server" then
					api[N.Fire](P1, table.unpack(values, 1, values.n))
				else
					api[N.Fire](table.unpack(values, 1, values.n))
				end
				table.insert(sent, { event = event, values = values })
			end
			pump()
			local arrivals = {}
			local seen = {}
			for _, entry in sent do
				if not seen[entry.event] then
					seen[entry.event] = true
					local side, api = receiverOf(entry.event)
					arrivals[entry.event] = collect(entry.event, side, api)
				end
			end
			local cursor = {}
			local mismatches = 0
			for _, entry in sent do
				local index = (cursor[entry.event] or 0) + 1
				cursor[entry.event] = index
				local item = arrivals[entry.event][index]
				if not item or not argsEqual(entry.event.params, entry.values, item.values) then
					mismatches += 1
				end
			end
			for event, list in arrivals do
				if #list ~= (cursor[event] or 0) then
					mismatches += 1
				end
			end
			if mismatches > 0 then
				fail(`a burst of 20 {direction} events in one frame had {mismatches} mismatches`)
			end
			line(`burst of 20 {direction} events in one frame: {if mismatches == 0 then "all arrived in order" else "MISMATCH"}`)
		end
	end
end

local functionInbox: { [any]: { Received } } = {}
local functionReplies: { [any]: { n: number, [number]: any } } = {}
local callableFunctions = {}

for _, fn in SCHEMA.functions do
	local name = pathName(fn.path)
	local missing
	for _, desc in fn.args do
		missing = missing or needsUnavailable(desc)
	end
	for _, desc in fn.rets do
		missing = missing or needsUnavailable(desc)
	end
	if not SCHEMA.yields then
		line(`skip function {name}: yield type is not yield`)
	elseif missing then
		line(`skip function {name}: Lune has no {missing}`)
	else
		table.insert(callableFunctions, fn)
		functionInbox[fn] = {}
		functionReplies[fn] = generateArgs(fn.rets)
		member(server, fn.path)[N.SetCallback](function(player, ...)
			table.insert(functionInbox[fn], { player = player, values = table.pack(...) })
			local reply = functionReplies[fn]
			return table.unpack(reply, 1, reply.n)
		end)
	end
end

local function takeFunctionInbox(fn): { Received }
	local inbox = functionInbox[fn]
	functionInbox[fn] = {}
	return inbox
end

local function functionCalls(fn)
	local name = pathName(fn.path)
	local clientApi = member(client, fn.path)
	local passed = 0
	for _ = 1, SAMPLES do
		local args = generateArgs(fn.args)
		local reply = generateArgs(fn.rets)
		functionReplies[fn] = reply
		local result
		task.spawn(function()
			result = table.pack(clientApi[N.Call](table.unpack(args, 1, args.n)))
		end)
		pump()
		local inbox = takeFunctionInbox(fn)
		if #inbox ~= 1 then
			fail(`{name}({showArgs(args)}) reached the server {#inbox} times`)
		elseif inbox[1].player ~= P1 or not argsEqual(fn.args, args, inbox[1].values) then
			fail(`{name} changed an argument: {argsDifference(fn.args, args, inbox[1].values)}`)
		elseif not result then
			fail(`{name}({showArgs(args)}) never returned`)
		elseif not argsEqual(fn.rets, reply, result) then
			fail(`{name} changed a return value: {argsDifference(fn.rets, reply, result)}`)
		else
			passed += 1
		end
	end
	line(`function {name} ({fn.call}): {passed}/{SAMPLES}`)
end

local function hostileFunction(fn)
	local name = pathName(fn.path)
	local loose = member(looseClient, fn.path)
	local refused, attempts = 0, 0
	for _ = 1, HOSTILE_SAMPLES do
		local args = generateArgs(fn.args, MAX_DEPTH)
		local bad, why, at
		for _ = 1, #fn.args do
			local index = integer(1, #fn.args)
			bad, why = invalid(fn.args[index], 0)
			if why then
				at = index
				break
			end
		end
		if not why then
			continue
		end
		attempts += 1
		args[at] = bad
		serverErrors = {}
		task.spawn(function()
			pcall(loose[N.Call], table.unpack(args, 1, args.n))
		end)
		pump()
		local inbox = takeFunctionInbox(fn)
		if #inbox > 0 then
			fail(`{name}: the server accepted an argument that is {why}: ({showArgs(inbox[1].values)})`)
		elseif #serverErrors == 0 then
			fail(`{name}: an argument that is {why} vanished without an error`)
		else
			refused += 1
		end
	end
	if attempts == 0 then
		line(`hostile function {name}: nothing to break`)
	else
		line(`hostile function {name}: refused {refused} of {attempts}`)
	end
end

local function hostile(event)
	local name = pathName(event.path)
	local side, receiver = receiverOf(event)
	local loose = member(looseClient, event.path)
	local strict = member(client, event.path)
	local refused, unsendable, attempts = 0, 0, 0
	local reasons = {}
	for _ = 1, HOSTILE_SAMPLES do
		local values = generateArgs(event.params, MAX_DEPTH)
		local order = {}
		for index = 1, #event.params do
			order[index] = index
		end
		local bad, why, at
		for _ = 1, #order do
			local index = pick(order)
			bad, why = invalid(event.params[index], 0)
			if why then
				at = index
				break
			end
		end
		if not why then
			continue
		end
		attempts += 1
		values[at] = bad
		serverErrors = {}
		local sentOk = pcall(function()
			loose[N.Fire](table.unpack(values, 1, values.n))
			pump()
		end)
		local inbox = collect(event, side, receiver)
		if not sentOk then
			unsendable += 1
		elseif #inbox > 0 then
			fail(`{name}: the server accepted a value that is {why}: ({showArgs(inbox[1].values)})`)
		elseif #serverErrors == 0 then
			fail(`{name}: a value that is {why} vanished without an error`)
		else
			refused += 1
			reasons[why] = true
		end
		local good = generateArgs(event.params)
		strict[N.Fire](table.unpack(good, 1, good.n))
		pump()
		local after = collect(event, side, receiver)
		if #after ~= 1 or not argsEqual(event.params, good, after[1].values) then
			fail(`{name}: the server did not recover after refusing a value that is {why}`)
		end
	end
	if attempts == 0 then
		line(`hostile {name}: nothing to break`)
	else
		line(`hostile {name}: refused {refused} of {attempts}, {unsendable} not sendable`)
	end
end

local function resolve(desc)
	while desc.kind == "ref" do
		desc = SCHEMA.types[desc.name]
	end
	return desc
end

local function utf8Slots(params)
	local slots = {}
	for index, param in params do
		local desc = resolve(param)
		if desc.kind == "str" and desc.utf8 then
			table.insert(slots, { index = index, desc = desc, label = `argument {index}` })
		elseif desc.kind == "struct" then
			for _, field in desc.fields do
				local fieldDesc = resolve(field.ty)
				if fieldDesc.kind == "str" and fieldDesc.utf8 then
					table.insert(slots, { index = index, field = field.name, desc = fieldDesc, label = `argument {index} field {field.name}` })
				end
			end
		end
	end
	return slots
end

local function withSlot(params, slot, text: string)
	local values = generateArgs(params)
	if slot.field then
		values[slot.index][slot.field] = text
	else
		values[slot.index] = text
	end
	return values
end

local function utf8Cases(range): ({ { text: string, label: string } }, { { text: string, label: string } })
	local accepted, refused = {}, {}
	if range.max then
		table.insert(accepted, { text = string.rep(WIDEST_UTF8_CHARACTER, range.max), label = `{range.max} four-byte` })
		table.insert(refused, { text = string.rep("a", range.max + 1), label = `{range.max + 1} one-byte` })
		table.insert(refused, { text = string.rep("\u{e9}", range.max + 1), label = `{range.max + 1} two-byte` })
	end
	if range.min and range.min > 0 and range.min ~= range.max then
		table.insert(accepted, { text = string.rep(WIDEST_UTF8_CHARACTER, range.min), label = `{range.min} four-byte` })
	end
	if range.min and range.min >= 2 then
		table.insert(refused, { text = string.rep(WIDEST_UTF8_CHARACTER, range.min - 1), label = `{range.min - 1} four-byte` })
	end
	return accepted, refused
end

local function utf8Limits(event)
	local name = pathName(event.path)
	local side, receiver = receiverOf(event)
	for _, slot in utf8Slots(event.params) do
		local accepted, refused = utf8Cases(slot.desc.range)
		if #accepted == 0 and #refused == 0 then
			continue
		end
		local outcome = { accepted = {}, refused = {} }
		for _, case in accepted do
			local values = withSlot(event.params, slot, case.text)
			serverErrors = {}
			local ok, why = pcall(function()
				if event.from == "Server" then
					member(server, event.path)[N.Fire](P1, table.unpack(values, 1, values.n))
				else
					member(client, event.path)[N.Fire](table.unpack(values, 1, values.n))
				end
				pump()
			end)
			local inbox = collect(event, side, receiver)
			if not ok then
				fail(`{name} {slot.label}: sending {case.label} characters raised {why}`)
			elseif #inbox ~= 1 or not argsEqual(event.params, values, inbox[1].values) then
				fail(`{name} {slot.label}: {case.label} characters arrived {#inbox} times{serverErrorText()}`)
			else
				table.insert(outcome.accepted, case.label)
			end
		end
		for _, case in refused do
			local values = withSlot(event.params, slot, case.text)
			local strictOk = pcall(function()
				if event.from == "Server" then
					member(server, event.path)[N.Fire](P1, table.unpack(values, 1, values.n))
				else
					member(client, event.path)[N.Fire](table.unpack(values, 1, values.n))
				end
			end)
			server[N.SendEvents]()
			client[N.SendEvents]()
			toServer, toClients = {}, {}
			if strictOk then
				fail(`{name} {slot.label}: write checks let {case.label} characters through`)
			end
			if event.from == "Client" then
				serverErrors = {}
				member(looseClient, event.path)[N.Fire](table.unpack(values, 1, values.n))
				pump()
				local inbox = collect(event, side, receiver)
				if #inbox > 0 then
					fail(`{name} {slot.label}: the server accepted {case.label} characters`)
				elseif #serverErrors == 0 then
					fail(`{name} {slot.label}: {case.label} characters vanished without an error`)
				elseif not strictOk then
					table.insert(outcome.refused, case.label)
				end
			elseif not strictOk then
				table.insert(outcome.refused, case.label)
			end
		end
		line(`utf8 {name} {slot.label} ({slot.desc.range.min or ""}..{slot.desc.range.max or ""}): accepted [{table.concat(outcome.accepted, ", ")}], refused [{table.concat(outcome.refused, ", ")}]`)
	end
end

local function fuzz()
	local remotes = {}
	for remote in handlers.Server do
		table.insert(remotes, remote)
	end
	table.sort(remotes)
	if #remotes == 0 then
		return
	end
	local accepted, rejected = 0, 0
	local pool = { instanceOf("Folder"), instanceOf("Part"), instanceOf("Model") }
	for attempt = 1, FUZZ_BUFFERS do
		local buff
		local seedMessage = if #capturedClientMessages > 0 and chance(0.5) then pick(capturedClientMessages) else nil
		local remote = if seedMessage then seedMessage.remote else pick(remotes)
		if seedMessage then
			local bytes = buffer.tostring(seedMessage.buff)
			local mode = integer(1, 3)
			if mode == 1 and #bytes > 0 then
				local at = integer(1, #bytes)
				bytes = bytes:sub(1, at - 1) .. string.char(integer(0, 255)) .. bytes:sub(at + 1)
			elseif mode == 2 then
				bytes = bytes:sub(1, integer(0, #bytes))
			else
				bytes ..= generateString({ utf8 = false }, integer(1, 8))
			end
			buff = buffer.fromstring(bytes)
		else
			buff = buffer.fromstring(generateString({ utf8 = false }, integer(0, 40)))
		end
		local inst = {}
		for index = 1, integer(0, 3) do
			inst[index] = if chance(0.8) then pick(pool) else nil
		end
		serverErrors = {}
		nextServerFrame()
		deliverToServer({ remote = remote, from = "Fuzz", buff = buff, inst = inst })
		local arrived = false
		for _, fn in callableFunctions do
			for _, item in takeFunctionInbox(fn) do
				arrived = true
				for index, desc in fn.args do
					local ok, why = conforms(desc, item.values[index])
					if not ok then
						fail(`fuzz {attempt}: function {pathName(fn.path)} handed game code a bad argument {index}: {why}`)
					end
				end
			end
		end
		for _, event in runnable do
			if event.from == "Client" then
				local side, api = receiverOf(event)
				for _, item in collect(event, side, api) do
					arrived = true
					for index, desc in event.params do
						local ok, why = conforms(desc, item.values[index])
						if not ok then
							fail(`fuzz {attempt}: {pathName(event.path)} handed game code a bad argument {index}: {why}`)
						end
					end
				end
			end
		end
		if arrived then
			accepted += 1
		else
			rejected += 1
		end
	end
	line(`fuzz: {FUZZ_BUFFERS} messages, {accepted} reached game code and all matched their types, {rejected} refused`)
end

local LIMITS = SCHEMA.limits
local CAP = LIMITS.eventsPerFrame
local BYTES = LIMITS.packetBytes
local FLOOD_BYTES = 1048576

type Refusal = { player: Instance, reason: string }

local refusals: { Refusal } = {}
if CAP or BYTES then
	server[N.SetPacketRefusedCallback](function(player, reason)
		table.insert(refusals, { player = player, reason = reason })
	end)
end

local function takeRefusals(): string
	local counts = {}
	for _, refusal in refusals do
		local key = `{refusal.player.Name} {refusal.reason}`
		counts[key] = (counts[key] or 0) + 1
	end
	refusals = {}
	local names = {}
	for key, count in counts do
		table.insert(names, if count == 1 then key else `{key} x{count}`)
	end
	table.sort(names)
	return table.concat(names, ", ")
end

local function sendWithoutDelivering(sender, event, count: number): { Message }
	local api = member(sender, event.path)
	for _ = 1, count do
		local values = generateArgs(event.params)
		api[N.Fire](table.unpack(values, 1, values.n))
	end
	sender[N.SendEvents]()
	local messages = toServer
	toServer = {}
	return messages
end

local function deliverInOneFrame(...: { Message })
	nextServerFrame()
	serverErrors = {}
	for _, messages in { ... } do
		for _, message in messages do
			deliverToServer(message)
		end
	end
end

local function countBySender(inbox: { Received }, player: Instance): number
	local count = 0
	for _, item in inbox do
		if item.player == player then
			count += 1
		end
	end
	return count
end

local function expectFlood(label: string, counted: { { event: any, player: Instance, expected: number } }, expectedRefusals: string)
	local parts = {}
	local mismatched = false
	local inboxes = {}
	for _, entry in counted do
		if not inboxes[entry.event] then
			inboxes[entry.event] = collect(entry.event, receiverOf(entry.event))
		end
	end
	for _, entry in counted do
		local arrived = countBySender(inboxes[entry.event], entry.player)
		table.insert(parts, `{arrived} {pathName(entry.event.path)} from {entry.player.Name}`)
		if arrived ~= entry.expected then
			mismatched = true
			fail(`{label}: {arrived} {pathName(entry.event.path)} arrived from {entry.player.Name}, expected {entry.expected}`)
		end
	end
	local refused = takeRefusals()
	if refused ~= expectedRefusals then
		fail(`{label}: refused [{refused}], expected [{expectedRefusals}]`)
	elseif #serverErrors > 0 then
		fail(`{label}: the server raised {table.concat(serverErrors, " | ")}`)
	end
	line(`{label}: {table.concat(parts, ", ")} arrived; refused [{refused}]{if mismatched then " MISMATCH" else ""}`)
end

local function rawPacket(remote: string, bytes: string): { Message }
	return { { remote = remote, from = "LooseClient", buff = buffer.fromstring(bytes), inst = {} } }
end

local function firstClientEvent(reliability: string): any?
	local best
	for _, event in runnable do
		if event.from == "Client" and (event.reliability == reliability or (reliability == "Unreliable" and event.reliability == "OrderedUnreliable")) then
			if not best or #event.params < #best.params then
				best = event
			end
		end
	end
	return best
end

local function floodLimits()
	if not CAP and not BYTES then
		return
	end
	local reliable = firstClientEvent("Reliable")
	local unreliable = firstClientEvent("Unreliable")
	if CAP and reliable then
		deliverInOneFrame(sendWithoutDelivering(looseClient, reliable, CAP + 10), sendWithoutDelivering(client, reliable, 1))
		expectFlood(
			`one packet of {CAP + 10} events beside another player's event`,
			{ { event = reliable, player = P2, expected = CAP }, { event = reliable, player = P1, expected = 1 } },
			"Player2 TooManyEvents"
		)
		deliverInOneFrame(sendWithoutDelivering(looseClient, reliable, CAP))
		expectFlood(`the next frame, exactly {CAP} events`, { { event = reliable, player = P2, expected = CAP } }, "")
		deliverInOneFrame(sendWithoutDelivering(looseClient, reliable, CAP - 3), sendWithoutDelivering(looseClient, reliable, 10))
		expectFlood(`two packets of {CAP - 3} and 10 events in one frame`, { { event = reliable, player = P2, expected = CAP } }, "Player2 TooManyEvents")
	end
	if CAP and unreliable then
		deliverInOneFrame(sendWithoutDelivering(looseClient, unreliable, CAP + 3))
		expectFlood(`{CAP + 3} unreliable packets in one frame`, { { event = unreliable, player = P2, expected = CAP } }, "Player2 TooManyEvents x3")
		if reliable then
			deliverInOneFrame(sendWithoutDelivering(looseClient, unreliable, CAP - 1), sendWithoutDelivering(looseClient, reliable, 5))
			expectFlood(
				`{CAP - 1} unreliable packets then a reliable packet of 5 events in one frame`,
				{ { event = unreliable, player = P2, expected = CAP - 1 }, { event = reliable, player = P2, expected = 1 } },
				"Player2 TooManyEvents"
			)
		end
	end
	if reliable then
		local one = sendWithoutDelivering(looseClient, reliable, 1)[1]
		local unit = buffer.tostring(one.buff)
		if #reliable.params == 0 then
			local flood = string.rep(unit, math.ceil(FLOOD_BYTES / #unit))
			deliverInOneFrame(rawPacket(one.remote, flood))
			expectFlood(
				`a {#flood} byte packet of {#flood // #unit} events`,
				{ { event = reliable, player = P2, expected = if BYTES then 0 else math.min(CAP, #flood // #unit) } },
				if BYTES then "Player2 PacketTooLarge" else "Player2 TooManyEvents"
			)
		end
		if BYTES then
			local fitting = BYTES // #unit
			deliverInOneFrame(rawPacket(one.remote, string.rep(unit, fitting)))
			expectFlood(
				`a {fitting * #unit} byte packet within the {BYTES} byte limit`,
				{ { event = reliable, player = P2, expected = if CAP then math.min(CAP, fitting) else fitting } },
				if CAP and fitting > CAP then "Player2 TooManyEvents" else ""
			)
			deliverInOneFrame(rawPacket(one.remote, string.rep("\0", BYTES + 1)))
			expectFlood(`a reliable packet of {BYTES + 1} bytes`, { { event = reliable, player = P2, expected = 0 } }, "Player2 PacketTooLarge")
		end
	end
	if BYTES and unreliable then
		local one = sendWithoutDelivering(looseClient, unreliable, 1)[1]
		collect(unreliable, receiverOf(unreliable))
		deliverInOneFrame(rawPacket(one.remote, string.rep("\0", BYTES + 1)))
		expectFlood(`an unreliable packet of {BYTES + 1} bytes`, { { event = unreliable, player = P2, expected = 0 } }, "Player2 PacketTooLarge")
	end
end

local function deliverMalformed(remote: string, buff: any, inst: any)
	nextServerFrame()
	serverErrors = {}
	local ok, why = pcall(handlers.Server[remote], P2, buff, inst)
	if not ok then
		table.insert(serverErrors, tostring(why))
	end
end

local function malformedPackets()
	if not CAP and not BYTES then
		return
	end
	for _, reliability in { "Reliable", "Unreliable" } do
		local event = firstClientEvent(reliability)
		if event then
			local real = sendWithoutDelivering(looseClient, event, 1)[1]
			local kind = string.lower(reliability)
			local article = if reliability == "Reliable" then "a" else "an"
			local cases = {
				{ label = "no buffer", buff = nil, inst = {} },
				{ label = "a string buffer", buff = buffer.tostring(real.buff), inst = {} },
				{ label = "a number buffer", buff = 7, inst = {} },
				{ label = "no instances", buff = real.buff, inst = nil },
				{ label = "a string for its instances", buff = real.buff, inst = "instances" },
				{ label = "an Instance for its instances", buff = real.buff, inst = Instance.new("Folder") },
			}
			collect(event, receiverOf(event))
			for _, case in cases do
				deliverMalformed(real.remote, case.buff, case.inst)
				expectFlood(`{article} {kind} packet with {case.label}`, { { event = event, player = P2, expected = 0 } }, "Player2 MalformedPacket")
			end
			deliverInOneFrame({ real })
			expectFlood(`the real {kind} packet after them`, { { event = event, player = P2, expected = 1 } }, "")
		end
	end
end

for _, event in runnable do
	roundTrip(event)
end
burst()
for _, fn in callableFunctions do
	functionCalls(fn)
end
for _, event in runnable do
	if event.from == "Client" then
		hostile(event)
	end
end
for _, fn in callableFunctions do
	hostileFunction(fn)
end
for _, event in runnable do
	utf8Limits(event)
end
fuzz()
if CAP or BYTES then
	local refused = takeRefusals()
	if refused ~= "" then
		fail(`ordinary traffic was refused: {refused}`)
	end
	line(`ordinary traffic: {if refused == "" then "nothing refused" else "REFUSED"}`)
end
floodLimits()
malformedPackets()
finish()
