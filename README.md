# Custom Network Library

A high-performance, lightweight networking and serialization layer designed for robust client-server communication and backend optimization in Luau/Roblox environments. Developed by ethandevelopz.

---

## Overview

All events and functions are multiplexed over two remotes (one reliable, one unreliable). Every message sent in a frame is packed into **one buffer per player per channel** and flushed on `Heartbeat`. Payloads use a compact binary codec. Optionally, a **typed protocol (IDL)** in the style of [Blink](https://github.com/1Axen/blink) and [Zap](https://github.com/red-blox/zap) removes type tags from the wire and **validates every incoming message on the server for free**.

## Features

* **Batched buffers:** one remote call per player per frame, whatever the number of events.
* **Two codecs:**
  * **Dynamic:** send anything, as with a `RemoteEvent`.
  * **Typed:** declare argument types once and get the smallest encoding, plus server-side validation.
* **IDL protocol file:** Blink/Zap-style `event` / `function` / `type` declarations. Unlike Blink and Zap there is no separate compiler step: the schema compiles to specialised serializers at runtime.
* **Instances as real references:** instances travel next to the buffer as remote arguments, the same approach ByteNet and Blink use. Roblox resolves them natively. Unreplicated or streamed-out instances arrive as `nil` (no fragile name paths).
* **Security by default:**
  * Token-bucket rate limits.
  * Bounds-checked decoding that cannot be made to allocate huge tables or strings.
  * Depth limits.
  * Spoof-proof request ids.
  * Concurrency cap on server functions.
  * Direction enforcement (`from: Client` / `from: Server`).
  * A `Violation` signal you can use to kick abusers.
* **Action registry:** `net.bindAction` gives every client request the same pipeline: global and per-action token buckets, argument count and validation, cooldown, middleware, then your handler. See [Actions](#actions).
* **Unreliable-safe:** unreliable batches are split to stay under the unreliable remote's size limit. A single message too big for an unreliable remote is sent reliably, with a one-time warning.
* **Late-join safe:**
  * Client events that arrive before your `Connect` are queued and delivered on connect, like a normal RemoteEvent.
  * Client sends to names the server has not registered yet are queued until the id is synced.
* **Native codegen:** `--!native` / `--!optimize 2` on the hot modules.

---

## Installation & Setup

* **ReplicatedStorage (`ReplicatedStorage.Network`)**
  * Place the **Modules** folder inside `Network`. It contains `Actions`, `Codec`, `Enums`, `Idl`, `Packet`, `Reader`, `Signal` and `Writer` (all ModuleScripts).
  * Place **`Client.lua`** inside `Network` (ModuleScript named `Client`).
  * Create **`__Master`** (`RemoteEvent`) inside `Network`.
  * Create **`__MasterUnreliable`** (`UnreliableRemoteEvent`) inside `Network`.
  * *(Optional)* Create **`Protocol`** (ModuleScript) inside `Network` that returns your IDL string (see below). Server and client load it automatically.

* **ServerScriptService (`ServerScriptService.Network`)**
  * Place **`Server.lua`** inside `Network` (ModuleScript named `Server`).

---

## Quick start (dynamic)

Server:

```lua
local net = require(game.ServerScriptService.Network.Server)
local damage = net.loadEvent('Damage', { rateLimit = 20 })
damage:Connect(function(player, targetId, amount)
	if typeof(targetId) ~= 'number' or typeof(amount) ~= 'number' then
		return
	end
end)
damage:FireAll('boom', Vector3.new(1, 2, 3))

local getCoins = net.loadFunction('GetCoins')
getCoins:OnInvoke(function(player, currency)
	return 100, 'ok'
end)
```

Client:

```lua
local net = require(game.ReplicatedStorage.Network.Client)
net.loadEvent('Damage'):FireServer(42, 10)
local success, coins, status = net.loadFunction('GetCoins'):InvokeServer('gold')
```

## Typed protocol (IDL)

Create `ReplicatedStorage.Network.Protocol`:

```lua
return [[
type Item = {
	id: u32,
	name: string(..32),
	count: u16,
	rarity: enum { Common, Rare, Epic, Legendary },
}

event Move {
	from: Client,
	type: Unreliable,
	rate: 30,
	data: (position: vector3, sprinting: bool),
}

event Inventory {
	from: Server,
	data: (Item[..512]),
}

function Buy {
	rate: 5,
	timeout: 10,
	args: (itemId: u32, amount: u8),
	rets: (bool, string?),
}
]]
```

Then use the names as normal. With `from: Client`, `Move` can only be fired by clients. A malformed `Move` (wrong types, NaN or infinite vector, string too long) is dropped before your handler runs and raises `net.Violation`.

```lua
net.loadEvent('Move'):Connect(function(player, position, sprinting) end)
```

You can also pass a type inline without a Protocol module: `net.loadEvent('Hit', { data = '(Instance(BasePart), u16)' })`. **Both sides must use the same definition.** The Protocol module guarantees that.

### IDL reference

| Syntax | Meaning | Wire size |
|---|---|---|
| `u8 u16 u32 i8 i16 i32` | fixed integers | 1/2/4 B |
| `f32 f64` | floats (NaN/inf rejected on receive) | 4/8 B |
| `uint int` | variable-length integers (53-bit) | 1-8 B |
| `bool` | boolean | 1 B |
| `string`, `string(..N)` | string, optionally capped | len + bytes |
| `buffer`, `buffer(..N)` | buffer | len + bytes |
| `vector3 vector2 cframe color3 udim udim2` | Roblox types (`color3` is 8-bit per channel) | 12/8/28/3/8/16 B |
| `Instance`, `Instance(Class)`, `Player` | instance reference (IsA checked) | 1 B + ref |
| `Enum.KeyCode` | Roblox enum | 1-2 B |
| `enum { A, B, 'C D' }` | string enum | 1 B |
| `{ a: T, b: U }` | struct | sum of fields |
| `{ [K]: V }` | map | count + entries |
| `T[]`, `T[..N]` | array, optionally capped | count + items |
| `T?` | optional | 1 B + T |
| `any` / `unknown` | dynamic codec | tagged |

Declaration options:

* `event`: `from: Client|Server`, `type: Reliable|Unreliable`, `rate: <per second>|none`, `data: (...)`.
* `function`: `from`, `rate`, `timeout`, `args: (...)`, `rets: (...)`.

---

## Actions

An action is a named client request with its checks declared next to the handler. Actions use the same two remotes, Heartbeat batches, codec, rate limiter, `net.Violation` and `net.getStats()` as events and functions. Action names are synced once as varint ids, so no name string travels per call and no rate-limit key is ever built from a client string.

Server:

```lua
local net = require(game.ServerScriptService.Network.Server)
local v = net.validators
local reason = net.ActionReason
local slots = { 'Head', 'Body', 'Feet' }
local loadedProfiles = {}

net.useActionMiddleware('ProfileLoaded', function(player, actionName, ...)
	return loadedProfiles[player] == true, reason.Unavailable
end)

net.bindAction('EquipItem', {
	rate = 'normal',
	cooldown = 0.25,
	requires = { 'ProfileLoaded' },
	args = { v.guid, v.integer(1, 99), v.optional(v.oneOf(slots)) },
}, function(player, itemId, amount, slot)
	if not inventory.owns(player, itemId, amount) then
		return false, 'NotOwned'
	end

	inventory.equip(player, itemId, amount, slot)
	return true
end)

net.bindActions({
	DropItem = { { rate = 'slow', args = '(string(..36), u16)' }, function(player, itemId, amount)
		return inventory.drop(player, itemId, amount)
	end },
	Ping = { { rate = 'fast', maxArgs = 0 }, function(player)
		return true
	end },
	Rename = { { rate = 2, burst = 4, maxArgs = 1, validate = function(name)
		return type(name) == 'string' and #name <= 20
	end }, function(player, name)
		return pets.rename(player, name)
	end },
})

net.Violation:Connect(function(player, why)
	print(player.Name, why)
end)

net.setActionDebug(true)
local equipStats = net.getStats().actions.EquipItem
print(equipStats.calls, equipStats.rejects.Cooldown, equipStats.averageHandlerTime)
net.unbindAction('Ping')
```

Client:

```lua
local net = require(game.ReplicatedStorage.Network.Client)

net.actionFailed:Connect(function(name, why)
	warn(name, 'failed:', why)
end)

net.invokeAction('EquipItem', itemId, 1, 'Head')

local ok, why = net.requestAction('DropItem', itemId, 5)
if not ok and why == net.ActionReason.Timeout then
	warn('server did not answer')
end
```

### Dispatch order

Every incoming action runs these steps. The first one that fails stops the call.

1. The player's global bucket across all actions (50/s, burst 100).
2. The action lookup by id. An unbound action is rejected with `UnknownAction`. An id the server never registered is rejected by the packet layer before this point.
3. The action's own token bucket (`rate`, `burst`), then its `cooldown`.
4. Decoding with the codec (typed when `args` is an IDL string), then the argument count against `maxArgs`, then validation.
5. Middleware listed in `requires`, in order, then the handler. Nothing yields between validation and the handler call, so middleware must not yield.

Steps 1 to 4 are rejections: the call is dropped, `net.Violation` fires with `action <Name>: <Reason>`, and the player is warned about once, at 10 violations. Nobody is kicked. A middleware or handler that returns `false, reason` is an outcome, not a violation: the caller gets `(name, reason)` through `net.actionFailed`, or as the result of `requestAction`.

`requestAction` gets an answer for every rejection except the global bucket, which drops silently so a flood cannot make the server reply.

### Options

| Option | Meaning |
|---|---|
| `rate` | `'fast'` (20/s, burst 40), `'normal'` (5/s, burst 10, the default), `'slow'` (1/s, burst 3), `'rare'` (0.2/s, burst 2), or tokens per second. |
| `burst` | Bucket size. Defaults to the preset's burst, or twice a numeric rate. |
| `cooldown` | Minimum seconds between two accepted calls from one player. Rejected with `Cooldown`. |
| `args` | A list of validators, one per argument (sets `maxArgs`), or an IDL tuple string such as `'(string(..36), u16)'`. With an IDL string the codec types the arguments on both sides and no validator runs. The server sends the tuple to clients, so clients declare nothing. |
| `validate` | `fn(...) -> boolean`, as an alternative to `args`. Passing both is an error. |
| `maxArgs` | Largest accepted argument count. Defaults to the length of `args`, or 8. |
| `requires` | Names of middleware registered with `net.useActionMiddleware`. |

Bad options error when you bind: an unknown preset or option, a missing handler, both `args` and `validate`, unknown middleware in `requires`, a non-positive rate, burst or cooldown, or a name that is already bound.

### Validators (`net.validators`, server and client)

Each one takes a value and returns a boolean, so they combine freely.

| Validator | Accepts |
|---|---|
| `integer(min?, max?)` | A whole number in the range. NaN, infinity and fractions fail. |
| `string(maxLength, allowed?)` | A string up to `maxLength` bytes. With `allowed` (list or set) it must be a member, otherwise it must be valid UTF-8. |
| `guid` | A 36-character GUID without braces. |
| `optional(validator)` | `nil`, or a value the inner validator accepts. |
| `oneOf(listOrSet)` | A member of the set. |
| `player` | A Player connected to this server. |
| `otherPlayer` | A connected Player other than the sender. |
| `boolean` | `true` or `false`. |
| `vector3(maxMagnitude)` | A Vector3 with finite components and a magnitude up to the cap. |

### Failure reasons (`net.ActionReason`)

`RateLimited`, `Cooldown`, `UnknownAction`, `InvalidArguments`, `Unavailable` (middleware said no without a reason, the handler errored, or the player has 16 handlers still running), `Timeout` (client side, `requestAction` got no answer), `Rejected` (the handler returned `false` without a reason). Handlers and middleware can return their own strings, clamped to 96 bytes.

### Debug mode

`net.setActionDebug(enabled)` is on by default in Studio and off in live servers. When on, every rejection prints one line with the reason and a short argument summary, and `net.getStats().actions[name]` holds `{ calls, rejects = { [reason] = count }, averageHandlerTime }`. When off, nothing is counted or formatted.

---

## API

### Server (`ServerScriptService.Network.Server`)

* `net.loadEvent(name, { unreliable?, rateLimit? (number|false), data?, from? })` returns an event with:
  * `:FireClient(player, ...)`, `:FireAll(...)`, `:FireExcept(player, ...)`, `:FireList({players}, ...)`
  * `:Connect(fn(player, ...))`, `:Once(fn)`, `:Wait()`
* `net.loadFunction(name, { rateLimit?, timeout?, data?, rets?, from? })` returns a function with:
  * `:OnInvoke(fn(player, ...) -> ...)`
  * `:InvokeClient(player, ...) -> (success, ...)`. Treat client results as untrusted.
* `net.define(idlStringOrTable)` registers protocol declarations and returns `{ [name] = api }`.
* `net.Violation`: a signal fired with `(player, reason)` for every rejected message (rate limit, malformed, spoofed, wrong direction).
* `net.getStats()` returns `{ sentBytes, sentMessages, receivedBytes, receivedMessages, droppedMessages, actions }`.
* `net.codec`, `net.types`: the codec and the built-in type objects.
* `net.bindAction(name, options?, handler(player, ...) -> (ok, reason?))`, `net.bindActions({ [name] = { options, handler } })`, `net.unbindAction(name) -> boolean`.
* `net.useActionMiddleware(name, fn(player, actionName, ...) -> (ok, reason?))`. Registering a name again replaces it.
* `net.setActionDebug(enabled)`, `net.validators`, `net.ActionReason`.
* Types: `ActionOptions`, `ActionHandler`, `ActionMiddleware`, `ActionValidator`, `ActionRate`, `ActionReason`, `ActionStats`.

### Client (`ReplicatedStorage.Network.Client`)

* `net.loadEvent(name, { unreliable?, data?, from? })` returns an event with `:FireServer(...)`, `:Connect`, `:Once`, `:Wait`.
* `net.loadFunction(name, { timeout?, data?, rets?, from? })` returns a function with `:OnInvoke(fn(...) -> ...)` and `:InvokeServer(...) -> (success, ...)`.
* `net.define`, `net.getStats`, `net.codec`, `net.types`.
* `net.invokeAction(name, ...)`: fire-and-forget.
* `net.requestAction(name, ...) -> (ok, reason?)`: yields until the server answers or the timeout passes.
* `net.setActionTimeout(seconds)`: timeout for `requestAction`, 10 s by default.
* `net.actionFailed`: a signal fired with `(name, reason)` when an `invokeAction` call is turned down by middleware or its handler.
* `net.validators`, `net.ActionReason`.

### Codec (`Modules.Codec`)

* `pack(value) -> buffer, refs?` and `unpack(buffer, refs?) -> value?` (warns and returns `nil` on bad input).
* `encode(type, value) -> buffer, refs?` and `decode(type, buffer, refs?) -> (ok, value)`.
* Type builders: `optional`, `array`, `map`, `struct`, `enum`, `enumType`, `boundedString`, `boundedBuffer`, `instanceOf`, `tuple`.
* `internStrings`, `defineSchema`: kept from the previous version.

### Defaults

| Setting | Value |
|---|---|
| Rate limit per event/function per player | 5/s (token bucket, burst 5). Pass `rateLimit = false` to disable. |
| Action rate | `'normal'`: 5/s, burst 10 per action per player. All actions together: 50/s, burst 100 per player. |
| Function timeout | server 5 s, client 3 s |
| `requestAction` timeout | 10 s |
| Concurrent server invokes per player | 16 |
| Max incoming packet | 64 KB, 256 instance refs |
| Unreliable batch budget | 800 B (Roblox drops unreliable payloads over ~900 B) |

---

## Breaking changes from the previous version

* `OnInvoke` handlers receive **spread arguments** `(player, a, b)` instead of one packed table. `InvokeServer` / `InvokeClient` return **all** return values: `(success, ...)`.
* When a server handler errors, the client receives `false, 'server error'`. The real error is `warn`ed on the server only, so internals don't leak to clients.
* The wire format changed. Update server, client and Modules together.
* `Enums.ext` was removed (tags were reorganised).

---

## Tests & benchmarks

This version was verified with a 56-test suite: codec, IDL, signal, end-to-end, exploit/fuzz and action cases. The suite runs the real server and client modules against an emulated Roblox (instance tree, Players, Heartbeat, remotes with copy semantics, unreliable size cap, unreplicated instances) under [Lune](https://github.com/lune-org/lune). It was also benchmarked against the previous version. The test and benchmark tooling is kept out of this repository.

Highlights (10 players, 120 frames):

| Scenario | Roblox native (model) | Before | After (dynamic) | After (typed) |
|---|---:|---:|---:|---:|
| Entity replication, KB/s per player | 117.2 | 80.7 | 64.5 | **60.0** |
| Player input, KB/s per player | 11.4 | 9.6 | 8.6 | **8.0** |
| Inventory snapshot, delivered correctly | 1200/1200 | **0/1200** | 1200/1200 | 1200/1200 |
| Entity replication, CPU ms | n/a | 676 | 439 | **390** |
| Player input, CPU ms | n/a | 187 | 124 | **94** |

* **Roblox native** bytes are a model, not a measurement. It assumes one remote call per message, about 9 B per-call overhead and community-measured per-type sizes (number 9 B, Vector3 13 B, string 1 + len + bytes, table keys sent as strings).
* CPU numbers come from Lune with a sandboxed environment, which is slower than Roblox for global lookups. Use them as relative numbers only.

---

## Production Showcase / Authorized Environments

This library powers production environments in the following Roblox communities:

* [Georgia State Roleplay](https://www.roblox.com/communities/34436342/Georgia-State-Roleplay)
* [PixelByte Interactive](https://www.roblox.com/communities/984186223/PixelByte-Interactive#!/about)

---

## Contact

* **Discord:** `ethanmracing`
* **Roblox:** [ethandevelopz Profile](https://www.roblox.com/users/281018055/profile)
