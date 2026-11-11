--!strict
local idl = require(script.Parent.Idl)
local actions = {}
local validators = {}
local context = { sender = nil :: Player?, connected = nil :: { [Player]: any }? }
local reasons = table.freeze({
	RateLimited = 'RateLimited',
	Cooldown = 'Cooldown',
	UnknownAction = 'UnknownAction',
	InvalidArguments = 'InvalidArguments',
	Unavailable = 'Unavailable',
	Timeout = 'Timeout',
	Rejected = 'Rejected',
})
local presets = table.freeze({
	fast = table.freeze({ rate = 20, burst = 40 }),
	normal = table.freeze({ rate = 5, burst = 10 }),
	slow = table.freeze({ rate = 1, burst = 3 }),
	rare = table.freeze({ rate = 0.2, burst = 2 }),
})
local optionNames = { rate = true, burst = true, maxArgs = true, validate = true, args = true, cooldown = true, requires = true }
local guidPattern = '^' .. string.rep('%x', 8) .. '%-' .. string.rep('%x', 4) .. '%-' .. string.rep('%x', 4) .. '%-' .. string.rep('%x', 4) .. '%-' .. string.rep('%x', 12) .. '$'
local maxSafeInteger = 9007199254740991
local defaultPreset = 'normal'
local defaultMaxArgs = 8
local summaryArgs = 4
local summaryChars = 16
actions.validators = validators
actions.reasons = reasons
actions.presets = presets
actions.context = context

export type Validator = (value: any) -> boolean
export type Middleware = { name: string, run: (player: Player, actionName: string, ...any) -> (boolean, string?) }
export type Action = {
	handler: (player: Player, ...any) -> (boolean, string?),
	validate: ((...any) -> boolean)?,
	maxArgs: number,
	rate: number,
	burst: number,
	cooldown: number?,
	requires: { Middleware }?,
	tuple: any,
	spec: string?,
	warned: boolean,
}

local function toSet(list: { [any]: any }): { [any]: any }
	if list[1] == nil then
		return table.clone(list)
	end

	local set = {}
	for _, value in list do
		set[value] = true
	end

	return set
end

local function isPositive(value: any): boolean
	return type(value) == 'number' and value > 0 and value < math.huge
end

local function isConnected(value: any): boolean
	if typeof(value) ~= 'Instance' or not value:IsA('Player') then
		return false
	end

	local connected = context.connected
	if connected then
		return connected[value] ~= nil
	end

	return value.Parent ~= nil
end

local function describe(value: any): string
	local valueType = typeof(value)
	if valueType == 'string' then
		if #value > summaryChars then
			return ('string(%d)'):format(#value)
		end

		return ('%q'):format(value)
	elseif valueType == 'number' or valueType == 'boolean' or valueType == 'nil' then
		return tostring(value)
	end

	return valueType
end

local function fail(name: string, message: string): never
	error(('network action %s: %s'):format(name, message), 5)
end

local function checkShape(name: any, options: any, handler: any)
	if type(name) ~= 'string' or #name == 0 then
		error('network action name must be a non-empty string', 4)
	end

	if type(handler) ~= 'function' then
		fail(name, 'missing handler')
	end

	if type(options) ~= 'table' then
		fail(name, 'options must be a table')
	end

	for key in options do
		if not optionNames[key] then
			fail(name, 'unknown option ' .. tostring(key))
		end
	end

	local cooldown, maxArgs = options.cooldown, options.maxArgs
	if cooldown ~= nil and not isPositive(cooldown) then
		fail(name, 'cooldown must be a positive number of seconds')
	end

	if maxArgs ~= nil and not (type(maxArgs) == 'number' and maxArgs >= 0 and maxArgs % 1 == 0) then
		fail(name, 'maxArgs must be a whole number of at least 0')
	end
end

local function resolveRate(name: string, rate: any, burst: any): (number, number)
	if rate == nil then
		rate = defaultPreset
	end

	if type(rate) == 'string' then
		local preset = (presets :: { [string]: { rate: number, burst: number } })[rate]
		if not preset then
			fail(name, ('unknown rate preset %q (use fast, normal, slow, rare or a number)'):format(rate))
		end

		rate = preset.rate
		burst = burst or preset.burst
	elseif not isPositive(rate) then
		fail(name, 'rate must be a preset name or a positive number')
	end

	if burst == nil then
		burst = math.max(1, math.ceil(rate * 2))
	elseif not isPositive(burst) or burst < 1 then
		fail(name, 'burst must be a number of at least 1')
	end

	return rate, burst
end

local function resolveArgs(name: string, options: any, aliases: { [string]: any }): (((...any) -> boolean)?, number, any, string?)
	local args, validate, maxArgs = options.args, options.validate, options.maxArgs
	if args ~= nil and validate ~= nil then
		fail(name, 'pass either args or validate, not both')
	end

	if args == nil then
		if validate ~= nil and type(validate) ~= 'function' then
			fail(name, 'validate must be a function')
		end

		return validate, maxArgs or defaultMaxArgs, nil, nil
	end

	if type(args) == 'string' then
		local success, tuple = pcall(idl.parseTuple, args, aliases)
		if not success then
			fail(name, tostring(tuple))
		end

		return nil, tuple.count, tuple, args
	end

	if type(args) ~= 'table' then
		fail(name, 'args must be a list of validators or an IDL tuple string')
	end

	local checks = table.clone(args)
	local count = #checks
	for index = 1, count do
		if type(checks[index]) ~= 'function' then
			fail(name, ('args[%d] must be a validator function'):format(index))
		end
	end

	return function(...)
		for index = 1, count do
			if not checks[index]((select(index, ...))) then
				return false
			end
		end

		return true
	end, maxArgs or count, nil, nil
end

local function resolveRequires(name: string, list: any, middlewares: { [string]: Middleware }): { Middleware }?
	if list == nil then
		return nil
	end

	if type(list) ~= 'table' then
		fail(name, 'requires must be a list of middleware names')
	end

	local requires = {}
	for index, middlewareName in list do
		local middleware = middlewares[middlewareName]
		if not middleware then
			fail(name, ('requires unknown middleware %s'):format(tostring(middlewareName)))
		end

		requires[index] = middleware
	end

	return requires
end

function validators.integer(min: number?, max: number?): Validator
	local low = min or -maxSafeInteger
	local high = max or maxSafeInteger
	return function(value)
		return type(value) == 'number' and value >= low and value <= high and value % 1 == 0
	end
end

function validators.string(maxLength: number, allowed: { [any]: any }?): Validator
	local lookup = if allowed then toSet(allowed) else nil
	return function(value)
		if type(value) ~= 'string' or #value > maxLength then
			return false
		end

		if lookup then
			return lookup[value] ~= nil
		end

		return utf8.len(value) ~= nil
	end
end

function validators.guid(value: any): boolean
	return type(value) == 'string' and #value == 36 and string.find(value, guidPattern) ~= nil
end

function validators.optional(inner: Validator): Validator
	return function(value)
		return value == nil or inner(value)
	end
end

function validators.oneOf(set: { [any]: any }): Validator
	local lookup = toSet(set)
	return function(value)
		return value ~= nil and lookup[value] ~= nil
	end
end

function validators.player(value: any): boolean
	return isConnected(value)
end

function validators.otherPlayer(value: any): boolean
	return value ~= context.sender and isConnected(value)
end

function validators.boolean(value: any): boolean
	return type(value) == 'boolean'
end

function validators.vector3(maxMagnitude: number): Validator
	return function(value)
		return typeof(value) == 'Vector3' and value.Magnitude <= maxMagnitude
	end
end

function actions.summarize(...: any): string
	local count = select('#', ...)
	if count == 0 then
		return 'no args'
	end

	local parts = {}
	for index = 1, math.min(count, summaryArgs) do
		parts[index] = describe((select(index, ...)))
	end

	if count > summaryArgs then
		table.insert(parts, ('+%d more'):format(count - summaryArgs))
	end

	return table.concat(parts, ', ')
end

function actions.compile(name: any, options: any, handler: any, middlewares: { [string]: Middleware }, aliases: { [string]: any }): Action
	options = if options == nil then {} else options
	checkShape(name, options, handler)
	local rate, burst = resolveRate(name, options.rate, options.burst)
	local validate, maxArgs, tuple, spec = resolveArgs(name, options, aliases)
	return {
		handler = handler,
		validate = validate,
		maxArgs = maxArgs,
		rate = rate,
		burst = burst,
		cooldown = options.cooldown,
		requires = resolveRequires(name, options.requires, middlewares),
		tuple = tuple,
		spec = spec,
		warned = false,
	}
end

table.freeze(validators)
return actions
