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
* **Unreliable-safe:** unreliable batches are split to stay under the unreliable remote's size limit. A single message too big for an unreliable remote is sent reliably, with a one-time warning.
* **Late-join safe:**
  * Client events that arrive before your `Connect` are queued and delivered on connect, like a normal RemoteEvent.
  * Client sends to names the server has not registered yet are queued until the id is synced.
* **Native codegen:** `--!native` / `--!optimize 2` on the hot modules.

---

## Installation & Setup

* **ReplicatedStorage (`ReplicatedStorage.Network`)**
  * Place the **Modules** folder inside `Network`. It contains `Codec`, `Enums`, `Idl`, `Packet`, `Reader`, `Signal` and `Writer` (all ModuleScripts).
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
* `net.getStats()` returns `{ sentBytes, sentMessages, receivedBytes, receivedMessages, droppedMessages }`.
* `net.codec`, `net.types`: the codec and the built-in type objects.

### Client (`ReplicatedStorage.Network.Client`)

* `net.loadEvent(name, { unreliable?, data?, from? })` returns an event with `:FireServer(...)`, `:Connect`, `:Once`, `:Wait`.
* `net.loadFunction(name, { timeout?, data?, rets?, from? })` returns a function with `:OnInvoke(fn(...) -> ...)` and `:InvokeServer(...) -> (success, ...)`.
* `net.define`, `net.getStats`, `net.codec`, `net.types`.

### Codec (`Modules.Codec`)

* `pack(value) -> buffer, refs?` and `unpack(buffer, refs?) -> value?` (warns and returns `nil` on bad input).
* `encode(type, value) -> buffer, refs?` and `decode(type, buffer, refs?) -> (ok, value)`.
* Type builders: `optional`, `array`, `map`, `struct`, `enum`, `enumType`, `boundedString`, `boundedBuffer`, `instanceOf`, `tuple`.
* `internStrings`, `defineSchema`: kept from the previous version.

### Defaults

| Setting | Value |
|---|---|
| Rate limit per event/function per player | 5/s (token bucket, burst 5). Pass `rateLimit = false` to disable. |
| Function timeout | server 5 s, client 3 s |
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

This version was verified with a 36-test suite: codec, IDL, signal, end-to-end, and exploit/fuzz cases. The suite runs the real server and client modules against an emulated Roblox (instance tree, Players, Heartbeat, remotes with copy semantics, unreliable size cap, unreplicated instances) under [Lune](https://github.com/lune-org/lune). It was also benchmarked against the previous version. The test and benchmark tooling is kept out of this repository.

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
