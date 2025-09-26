# Socket.IO Client for Luau

A Socket.IO client implementation for Luau, support both Roblox and Lune environments. This library provides a simple interface for connecting to Socket.IO server.

## Features

- ✅ **Connection Management**: Connect, disconnect, and automatic reconnection
- ✅ **Event System**: Emit and receive events with data
- ✅ **Acknowledgments**: Support for ACK callbacks
- ✅ **Message Queuing**: Queues messages when disconnected and data throttle
- ✅ **Heartbeat/Ping-Pong**: Automatic connection health checks
- ✅ **Environment Support**: Works in both Roblox and Lune environments

### Limitations

- ❌ **Namespaces**: Not supported
- ❌ **Rooms**: Not supported
- ❌ **Binary Events**: Not supported
- **WebSocket Transport**: Currently only polling transport is implemented

## Installation

Make sure to compile first if you clone this repository
```sh
$ npm i
$ npm run compile
```

### For Roblox
Copy `dist/socketio.lua` to your Roblox project and require it:

```lua
local SocketIO = require(script.Parent.SocketIO)
```

## Quick Start

```lua
local SocketIO = require("path/to/SocketIO")

-- Create a new Socket.IO client
local socket = SocketIO.new("http://localhost:3000", {
    maxReconnectionAttempts = 10,
    reconnectionDelay = 1000,
    reconnectionDelayMax = 5000
})

-- Event handlers
socket:on("connect", function()
    print("Connected to server!")

    -- Emit an event
    socket:emit("message", "Hello from client!")
end)

socket:on("disconnect", function(reason)
    print("Disconnected:", reason)
end)

socket:on("message", function(data)
    print("Received:", data)
end)

-- Connect to the server
socket:connect()
-- socket:disconnect()
```

## API Reference

### Event Methods

#### `socket:on(event, callback)`
Register an event handler.

**Parameters:**
- `event` (string): Event name
- `callback` (function): Handler function

**Available Events:**
- `connect`: Fired when connected to server
- `disconnect`: Fired when disconnected from server
- `error`: Fired on connection errors
- `reconnecting`: Fired when attempting to reconnect
- `reconnect_failed`: Fired when reconnection attempts exhausted

#### `socket:off(event, callback)`
Remove an event handler.

**Parameters:**
- `event` (string): Event name
- `callback` (function): Handler function to remove (optional)

### Data Transmission

#### `socket:emit(event, data, ack)`
Emit an event to the server.

**Parameters:**
- `event` (string): Event name
- `data`: Data to send (can be any JSON-serializable type)
- `ack` (function): Optional acknowledgment callback

**Example:**
```lua
-- Simple emit
socket:emit("message", "Hello!")

-- Emit with acknowledgment
socket:emit("request", { id = 123 }, function(response)
    print("Server response:", response)
end)
```

### Event Handling

#### Event Callbacks

Event callbacks receive parameters based on the event type:

**Connect Event:**
```lua
socket:on("connect", function()
    -- No parameters
end)
```

**Disconnect Event:**
```lua
socket:on("disconnect", function(reason)
    -- reason: string - Disconnection reason
end)
```

**Custom Events:**
```lua
socket:on("custom-event", function(data, ack)
    -- data: any - Event data
    -- ack: function - Optional acknowledgment callback
end)
```

**Error Event:**
```lua
socket:on("error", function(err)
    -- err: string - Error message
end)
```

## Examples

### Error Handling

```lua
socket:on("error", function(err)
    print("Socket error:", err)
end)

socket:on("reconnecting", function(attempts)
    print("Reconnecting... Attempt", attempts)
end)

socket:on("reconnect_failed", function()
    print("Failed to reconnect")
end)
```

## License
MIT License
