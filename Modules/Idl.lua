local codec = require(script.Parent.Codec)
local idl = {}
local primitiveAliases = {
	vec3 = 'vector3',
	vec2 = 'vector2',
	boolean = 'bool',
	double = 'f64',
	float = 'f32',
	integer = 'int',
	unknown = 'any',
}

local function tokenize(source)
	local tokens = {}
	local count = 0
	local at = 1
	local line = 1
	local length = #source
	while at <= length do
		local char = string.sub(source, at, at)
		if char == '\n' then
			line += 1
			at += 1
		elseif string.find(char, '^%s') then
			at += 1
		elseif string.sub(source, at, at + 1) == '--' then
			at = string.find(source, '\n', at, true) or length + 1
		elseif string.find(char, '^[%a_]') then
			local _, stop = string.find(source, '^[%w_]+', at)
			count += 1
			tokens[count] = { kind = 'name', value = string.sub(source, at, stop), line = line }
			at = stop + 1
		elseif string.find(char, '^%d') then
			local _, stop = string.find(source, '^%d+%.%d+', at)
			if not stop then
				_, stop = string.find(source, '^%d+', at)
			end

			count += 1
			tokens[count] = { kind = 'number', value = tonumber(string.sub(source, at, stop)), line = line }
			at = stop + 1
		elseif char == '"' or char == "'" then
			local stop = string.find(source, char, at + 1, true)
			if not stop then
				error(('idl error on line %d: unterminated string'):format(line), 0)
			end

			count += 1
			tokens[count] = { kind = 'string', value = string.sub(source, at + 1, stop - 1), line = line }
			at = stop + 1
		elseif string.sub(source, at, at + 1) == '..' then
			count += 1
			tokens[count] = { kind = 'symbol', value = '..', line = line }
			at += 2
		elseif string.find(char, '^[{}%(%)%[%]:,%?=%.]') then
			count += 1
			tokens[count] = { kind = 'symbol', value = char, line = line }
			at += 1
		else
			error(('idl error on line %d: unexpected character %q'):format(line, char), 0)
		end
	end

	tokens[count + 1] = { kind = 'eof', value = '<eof>', line = line }
	return tokens
end

local function newParser(source, aliases)
	local tokens = tokenize(source)
	local index = 1
	local parser = { aliases = aliases or {} }

	local function fail(message)
		local token = tokens[index]
		error(('idl error on line %d near %q: %s'):format(token.line, tostring(token.value), message), 0)
	end

	local function accept(value)
		local token = tokens[index]
		if token.kind == 'symbol' and token.value == value then
			index += 1
			return true
		end

		return false
	end

	local function expect(value)
		if not accept(value) then
			fail('expected ' .. value)
		end
	end

	local function expectName()
		local token = tokens[index]
		if token.kind ~= 'name' then
			fail('expected a name')
		end

		index += 1
		return token.value
	end

	local function expectNumber()
		local token = tokens[index]
		if token.kind ~= 'number' then
			fail('expected a number')
		end

		index += 1
		return token.value
	end

	local parseType

	local function parseBase()
		if accept('{') then
			if accept('[') then
				local keyType = parseType()
				expect(']')
				expect(':')
				local valueType = parseType()
				expect('}')
				return codec.map(keyType, valueType)
			end

			local fields = {}
			while not accept('}') do
				local fieldName = expectName()
				expect(':')
				table.insert(fields, { fieldName, parseType() })
				accept(',')
			end

			return codec.struct(fields)
		end

		local name = expectName()
		if name == 'enum' then
			expect('{')
			local values = {}
			while not accept('}') do
				local token = tokens[index]
				if token.kind ~= 'string' and token.kind ~= 'name' then
					fail('expected an enum value')
				end

				index += 1
				table.insert(values, token.value)
				accept(',')
			end

			return codec.enum(values)
		elseif name == 'Enum' then
			expect('.')
			local enumName = expectName()
			local success, enumType = pcall(function()
				return Enum[enumName]
			end)
			if not success or enumType == nil then
				fail('unknown Enum.' .. enumName)
			end

			return codec.enumType(enumType)
		elseif name == 'Instance' and accept('(') then
			local className = expectName()
			expect(')')
			return codec.instanceOf(className)
		elseif (name == 'string' or name == 'buffer') and accept('(') then
			expect('..')
			local maxLength = expectNumber()
			expect(')')
			return if name == 'string' then codec.boundedString(maxLength) else codec.boundedBuffer(maxLength)
		end

		local alias = parser.aliases[name]
		if alias then
			return alias
		end

		local lowered = string.lower(name)
		local primitive = codec.types[primitiveAliases[lowered] or lowered]
		if not primitive then
			fail('unknown type ' .. name)
		end

		return primitive
	end

	function parseType()
		local current = parseBase()
		while true do
			if accept('?') then
				current = codec.optional(current)
			elseif accept('[') then
				local maxLength
				if accept('..') then
					maxLength = expectNumber()
				end

				expect(']')
				current = codec.array(current, maxLength)
			else
				return current
			end
		end
	end

	local function parseTuple()
		local list = {}
		if accept('(') then
			while not accept(')') do
				if tokens[index].kind == 'name' and tokens[index + 1].kind == 'symbol' and tokens[index + 1].value == ':' then
					index += 2
				end

				table.insert(list, parseType())
				accept(',')
			end
		else
			list[1] = parseType()
		end

		return codec.tuple(list)
	end

	local function parseChoice(choices)
		local value = string.lower(expectName())
		local mapped = choices[value]
		if mapped == nil then
			fail('unexpected value ' .. value)
		end

		return mapped
	end

	local function parseDeclaration(kind, name)
		local definition = { kind = kind, name = name }
		expect('{')
		while not accept('}') do
			local key = string.lower(expectName())
			expect(':')
			if key == 'from' then
				definition.from = parseChoice({ server = 'Server', client = 'Client' })
			elseif key == 'type' or key == 'reliability' then
				definition.unreliable = parseChoice({ reliable = false, unreliable = true })
			elseif key == 'rate' or key == 'ratelimit' then
				if tokens[index].kind == 'name' then
					parseChoice({ none = false })
					definition.rateLimit = false
				else
					definition.rateLimit = expectNumber()
				end
			elseif key == 'timeout' then
				definition.timeout = expectNumber()
			elseif key == 'data' or key == 'args' then
				definition.data = parseTuple()
			elseif key == 'rets' or key == 'returns' then
				definition.rets = parseTuple()
			else
				fail('unknown option ' .. key)
			end

			accept(',')
		end

		return definition
	end

	function parser.parseFile()
		local result = { types = parser.aliases, events = {}, functions = {} }
		while tokens[index].kind ~= 'eof' do
			local keyword = expectName()
			if keyword == 'type' then
				local name = expectName()
				expect('=')
				parser.aliases[name] = parseType()
			elseif keyword == 'event' or keyword == 'function' then
				local name = expectName()
				if result.events[name] or result.functions[name] then
					fail('duplicate declaration ' .. name)
				end

				local definition = parseDeclaration(keyword, name)
				if keyword == 'event' then
					result.events[name] = definition
				else
					result.functions[name] = definition
				end
			else
				fail('expected type, event or function')
			end

			accept(',')
		end

		return result
	end

	function parser.parseTupleOnly()
		local tuple = parseTuple()
		if tokens[index].kind ~= 'eof' then
			fail('unexpected trailing input')
		end

		return tuple
	end

	function parser.parseTypeOnly()
		local typeObject = parseType()
		if tokens[index].kind ~= 'eof' then
			fail('unexpected trailing input')
		end

		return typeObject
	end

	return parser
end

function idl.parse(source)
	return newParser(source).parseFile()
end

function idl.parseTuple(source, aliases)
	return newParser(source, aliases).parseTupleOnly()
end

function idl.parseType(source, aliases)
	return newParser(source, aliases).parseTypeOnly()
end

function idl.resolveTuple(data, aliases)
	if data == nil then
		return nil
	elseif type(data) == 'string' then
		return idl.parseTuple(data, aliases)
	elseif data.writers then
		return data
	elseif data.write then
		return codec.tuple({ data })
	end

	return codec.tuple(data)
end

return idl
