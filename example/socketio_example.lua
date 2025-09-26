-- Import the Socket.IO client, make sure to only uncomment one of below
local SocketIO = require("../dist/socketio") -- For Luau
-- local SocketIO = require(game.ServerScriptService.Library.SocketIO) -- For Roblox

-- Create a new Socket.IO client
local socket = SocketIO.new("http://localhost:2345", {
	maxReconnectionAttempts = 10,
	reconnectionDelay = 1000,
	reconnectionDelayMax = 5000
})

-- Event handlers
socket:on("connect", function()
	print("Connected to Socket.IO server!")

	-- Emit an event
	socket:emit("message", "Hello from Lua client!")
end)

socket:on("disconnect", function(reason)
	print("Disconnected from server:", reason)
end)

socket:on("error", function(err)
	print("Socket error:", err)
end)

socket:on("message", function(data)
	print("Received message:", data)
end)

socket:on("custom-event", function(arg1, arg2)
	print("Received custom event with args:", arg1, arg2)
end)

socket:on('test-ack', function(data, ack)
	print(data)
	ack({ myAckData = 123})
end)

-- Example of how to handle reconnection
socket:on("reconnecting", function(attempts)
	print("Reconnecting... Attempt", attempts)
end)

socket:on("reconnect_failed", function()
	print("Failed to reconnect after maximum attempts")
end)

-- Connect to the server
socket:connect()

-- Example of sending events after connection
-- Note: These will be queued if sent before connection is established
socket:emit("cli-message", "Hello everyone!", function(nyaho)
	print("Get ack from server:")
	print(nyaho)
end)

-- Example of how to clean up
-- socket:disconnect()