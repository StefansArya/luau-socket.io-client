local SocketIO = {}
SocketIO.__index = SocketIO

-- Import utilities
local Timer = require("@src/LuaUtils/Timer.lua")

-- poll every 2 second, 60/2 = 30 polling request per minute (for get data only)
-- there are 3 type of request: ping-pong, get data, send data
-- send data also throttled to 2 seconds, while ping-pong can triggered randomly
SocketIO.pollingTime = 2000
SocketIO.throttleDataSend = 2000

local isRoblox = false
local isLune = false
if game and game.GetService then
	isRoblox = true
else
	local success, response = pcall(function()
		return require("@lune/serde")
	end)

	if not success then error("Unsupported environment: Neither Roblox nor Lune detected") end
	isLune = true
end

-- Utility methods
local robloxJSONDep = nil
local luneJSONDep = nil
local function encodeJSON(data)
	if isRoblox then
		if robloxJSONDep == nil then robloxJSONDep = game:GetService("HttpService") end
		return robloxJSONDep:JSONEncode(data)
	else
		if luneJSONDep == nil then luneJSONDep = require("@lune/serde") end
		return luneJSONDep.encode("json", data)
	end
end

local function decodeJSON(json)
	local success, result = pcall(function()
		if isRoblox then
			if robloxJSONDep == nil then robloxJSONDep = game:GetService("HttpService") end
			return robloxJSONDep:JSONDecode(json)
		else
			if luneJSONDep == nil then luneJSONDep = require("@lune/serde") end
				return luneJSONDep.decode("json", json)
		end
	end)

	if success then
		return result
	else
		print("[Error] ", result, json)
		error("JSON decode error")
		return nil
	end
end

-- Environment detection
local function detectEnvironment()
	if isRoblox then return "roblox"
	elseif isLune then return "lune" end
end

-- HTTP request handlers for different environments
local function createHTTPRequestHandler()
	if isRoblox then -- Roblox HTTP implementation
		local httpService = game:GetService("HttpService")
		return {
			request = function(url, method, headers, body, callback)
				if body == '' then body = nil end

				headers['Content-Type'] = 'text/plain'

				local options = {
					Url = url,
					Method = method,
					Headers = headers,
					Body = body
				}

				local response = httpService:RequestAsync(options)
				if not response.Success then
					callback(response, nil)
					return
				end

				callback(nil, {
					statusCode = response.StatusCode,
					body = response.Body,
					headers = response.Headers
				})
			end
		}
	elseif isLune then -- Lune HTTP implementation using @lune/net
		local net = require("@lune/net")
		return {
			request = function(url, method, headers, body, callback)
				if not body then body = '' end

				local hostname = url:match("://([^/:]+)")
				local hostport = url:match("://[^/]+:([^/]+)")
				local path = url:sub(#hostname):match("(/[^ ]+)")

				local craftAdd = ''
				if method == 'POST' then
					craftAdd = "\r\nContent-Type: text/plain" .. "\r\nContent-Length: " .. #body
				end

				-- ToDo: change this after Lune upgrade HTTP/1.0 to HTTP/1.1
				local conn = net.tcp.connect(hostname, hostport)
				local craft = method .. " " .. path .. " HTTP/1.1\r\nHost: " .. hostname .. craftAdd .. "\r\n\r\n" .. body;
				conn:write(craft)

				local response = conn:read()
				local contentLength = tonumber(response:match("[Cc]ontent%-[Ll]ength:%s*([0-9]+)"))
				local responseBody = response:match("\r\n\r\n(.*)$")
				while #responseBody < contentLength do
					local data = conn:read()
					if data ~= nil and #data ~= 0 then
						responseBody ..= data
					else
						print("Waiting HTTP response from remote...")
					end
				end
				conn:close()
				-- print(craft)

				local statusCode = tonumber(response:match("HTTP/[^ ]+ ([0-9]+)"))
				if statusCode == 200 then
					-- print(body .. ' -- ' .. responseBody)
					callback(nil, {
						statusCode = statusCode,
						body = responseBody,
						headers = nil
					})
				else
					callback("Request failed: " .. responseBody, nil)
				end
			end
		}
	end
end

-- Socket.IO protocol constants
local PROTOCOL = 4
local TYPES = {
	CONNECT = 0,
	DISCONNECT = 1,
	EVENT = 2,
	ACK = 3,
	ERROR = 4,
	BINARY_EVENT = 5,
	BINARY_ACK = 6,
}

local lastAckId = 1
local pendingAckTable = {}

-- Create new Socket.IO client
function SocketIO.new(url, options)
	local self = setmetatable({}, SocketIO)

	self.url = url or ""
	self.options = options or {}
	self.env = detectEnvironment()
	self.http = createHTTPRequestHandler()

	-- Connection state
	self.connected = false
	self.connecting = false
	self.reconnecting = false

	-- Socket.IO specific
	self.sid = nil
	self.pingInterval = 25000
	self.pingTimeout = 20000
	self.transport = "polling"

	-- Event handlers
	self.handlers = {
		connect = {},
		disconnect = {},
		error = {},
		message = {},
	}

	-- Queue for messages when not connected or throttle data transmission
	self.messageQueue = nil

	-- Reconnection state
	self.reconnectionAttempts = 0
	self.maxReconnectionAttempts = self.options.maxReconnectionAttempts or 5
	self.reconnectionDelay = self.options.reconnectionDelay or 1000
	self.reconnectionDelayMax = self.options.reconnectionDelayMax or 5000

	-- Our custom config
	self.pollingTime = options.pollingTime or SocketIO.pollingTime
	self.throttleDataSend = options.throttleDataSend or SocketIO.throttleDataSend

	return self
end

-- Event handling
function SocketIO:on(event, callback)
	if not self.handlers[event] then
		self.handlers[event] = {}
	end
	table.insert(self.handlers[event], callback)
	return self
end

function SocketIO:off(event, callback)
	if not self.handlers[event] then
		return self
	end

	if callback then
		for i, handler in ipairs(self.handlers[event]) do
			if handler == callback then
				table.remove(self.handlers[event], i)
				break
			end
		end
	else
		self.handlers[event] = {}
	end

	return self
end

function SocketIO:emit(event, data, ack)
	local ackId = ''
	if ack ~= nil then
		lastAckId += 1
		ackId = tostring(lastAckId)
		pendingAckTable[ackId] = ack
	end

	-- Queue the message for later sending
	if self.messageQueue == nil then self.messageQueue = {} end
	table.insert(self.messageQueue, {
		type = TYPES.EVENT,
		data = { event, data },
		id = ackId
	})
	return self
end

function SocketIO:trigger(event, data, ack)
	if not self.handlers[event] then
		return self
	end

	for _, handler in ipairs(self.handlers[event]) do
		handler(data, ack)
	end

	return self
end

-- Connection management
function SocketIO:connect()
	if self.connected or self.connecting then
		return self
	end

	self.connecting = true
	self:trigger("connecting")

	-- Start with polling transport
	self:pollingConnect()

	return self
end

function SocketIO:disconnect()
	if not self.connected then
		return self
	end

	self.connected = false
	self.connecting = false

	-- Clear any pending requests
	if self.pollingRequest then
		self.pollingRequest:Abort()
		self.pollingRequest = nil
	end

	self:sendPacket({
		type = TYPES.DISCONNECT
	})

	self:trigger("disconnect")
	return self
end

function SocketIO:reconnect()
	if self.reconnecting or self.connected then
		return self
	end

	self.reconnecting = true
	self.reconnectionAttempts = 0

	self:reconnectAttempt()
	return self
end

-- Polling transport implementation
function SocketIO:pollingConnect()
	local url = self.url .. "/socket.io/?transport=polling&EIO=4&t=" .. os.time()

	self.http.request(url, "GET", {}, "", function(err, response)
		if err then
			self:handleConnectionError(err)
			return
		end

		if response.statusCode ~= 200 then
			self:handleConnectionError("HTTP " .. response.statusCode)
			return
		end

		local messageType, payload = response.body:match("^(0)(.*)")
		if messageType ~= '0' then error("socket.io server doesn't respond with `0` or our user sid") end

		local connectData = decodeJSON(payload)
		if connectData.sid == nil then error("'sid' was not found from the socket.io server response") end

		self.sid = connectData.sid

		-- Send connect message first then poll once to check if server accept us
		self:pollingSend('40')
		self:pollingPoll()
	end)
end

function SocketIO:pollingSend(data)
	if not self.sid then
		return false, "No session ID"
	end

	local url = self.url .. "/socket.io/?transport=polling&EIO=4&sid=" .. self.sid .. "&t=" .. os.time()

	self.http.request(url, "POST", {
		["Content-Type"] = "application/octet-stream"
	}, data, function(err, response)
		if err then
			self:handleConnectionError(err)
			return
		end

		if response.statusCode ~= 200 then
			self:handleConnectionError("HTTP " .. response.statusCode)
			return
		end

		-- Parse the response
		self:parsePollingResponse(response.body)
	end)
end

function SocketIO:pollingPoll()
	if not self.sid then
		return
	end

	local url = self.url .. "/socket.io/?transport=polling&EIO=4&sid=" .. self.sid .. "&t=" .. os.time()

	self.http.request(url, "GET", {}, "", function(err, response)
		if err then
			self:handleConnectionError(err)
			return
		end

		if response.statusCode ~= 200 then
			self:handleConnectionError("HTTP " .. response.statusCode)
			return
		end

		-- Parse the response
		self:parsePollingResponse(response.body)
	end)
end

local function stringSplit(str, delimiter)
	local result = {}
	for match in str:gmatch("([^" .. delimiter .. "]+)") do
		table.insert(result, match)
	end
	return result
end

-- Response parsing
function SocketIO:parsePollingResponse(body)
	if not body or body == "" then return end

	if body == '2' then
		return self:handlePing()
	end

	if body:find('\x1e') ~= nil then
		local list = stringSplit(body, '\x1e')
		for i = 1, #list, 1 do
			self:parsePollingResponse(list[i])
		end
		return
	end

	local messageType, payload = body:match("^4([0-9])(.*)")
	if not messageType or not payload then return end
	-- print("receive resp: " .. messageType .. ' fd ' .. payload)

	messageType = tonumber(messageType)

	if messageType == TYPES.CONNECT then
		self:handleConnect(payload)
	elseif messageType == TYPES.EVENT then
		self:handleEvent(payload)
	elseif messageType == TYPES.ACK then
		self:handleAck(payload)
	elseif messageType == TYPES.ERROR then
		self:handleError(payload)
	elseif messageType == TYPES.DISCONNECT then
		self:handleDisconnect(payload)
	end
end

-- Message handlers
function SocketIO:handleConnect(data)
	self.connected = true
	self.connecting = false

	-- Start heartbeat
	self:startHeartbeat()

	-- Start polling for messages
	self:startPolling()

	-- Send queued messages
	self:startMessageQueue()
	-- self:sendQueuedMessages()

	self:trigger("connect")
end

function SocketIO:handleEvent(data)
	local ackId, payload = data:match("^([0-9]+)(.*)")
	local ack = nil
	if ackId ~= nil then
		ack = function(retData)
			self:pollingSend(PROTOCOL .. TYPES.ACK .. ackId .. encodeJSON({ retData }))
		end
		data = payload
	end

	local eventData = decodeJSON(data)
	self:trigger(eventData[1], eventData[2], ack)
end

function SocketIO:handleAck(data)
	local ackId, payload = data:match("^([0-9]+)(.*)")

	if payload ~= nil then data = decodeJSON(payload)[1]
	else data = nil end

	ackId = tostring(ackId)
	pendingAckTable[ackId](data)
	pendingAckTable[ackId] = nil
end

function SocketIO:handleError(data)
	self:trigger("error", data)
end

function SocketIO:handleDisconnect(data)
	self:disconnect()
	self:trigger("disconnect", data)
end

function SocketIO:handlePing()
	self:pollingSend('3')
end

function SocketIO:handlePong()
	-- Pong received, connection is alive
end

-- Packet sending
function SocketIO:sendPacket(packet)
	local message = PROTOCOL .. packet.type .. packet.id .. encodeJSON(packet.data)
	self:pollingSend(message)
end
function SocketIO:sendPackets(packets)
	local message = ""
	for i, packet in ipairs(packets) do
		if message ~= "" then message ..= "\x1e" end
		message ..= PROTOCOL .. packet.type .. packet.id .. encodeJSON(packet.data)
	end
	self:pollingSend(message)
end

-- Message queuing
function SocketIO:sendQueuedMessages()
	if self.messageQueue ~= nil then
		local temp = self.messageQueue
		self.messageQueue = nil
		self:sendPackets(temp)
	end
end

-- Polling loop using Timer
function SocketIO:startPolling() -- For getting message from server
	if self.pollingTimer then
		Timer.clearInterval(self.pollingTimer)
	end

	self.pollingTimer = Timer.setInterval(function()
		if self.connected then self:pollingPoll() end
	end, self.pollingTime)
end
function SocketIO:startMessageQueue() -- For sending out queued message to server
	if self.dataSendThrottleTimer then
		Timer.clearInterval(self.dataSendThrottleTimer)
	end

	self.dataSendThrottleTimer = Timer.setInterval(function()
		if self.connected then self:sendQueuedMessages() end
	end, self.throttleDataSend)
end

-- Heartbeat using Timer
function SocketIO:startHeartbeat()
	if self.heartbeatTimer then
		Timer.clearInterval(self.heartbeatTimer)
	end

	self.heartbeatTimer = Timer.setInterval(function()
		if self.connected then self:handlePing() end
	end, self.pingInterval)
end

-- Error handling
function SocketIO:handleConnectionError(err)
	self.connecting = false
	self:trigger("error", err)

	-- Stop polling and heartbeat
	if self.pollingTimer then
		Timer.clearInterval(self.pollingTimer)
		self.pollingTimer = nil
	end
	if self.dataSendThrottleTimer then
		Timer.clearInterval(self.dataSendThrottleTimer)
		self.dataSendThrottleTimer = nil
	end

	if self.heartbeatTimer then
		Timer.clearInterval(self.heartbeatTimer)
		self.heartbeatTimer = nil
	end

	-- Try to reconnect
	if self.reconnectionAttempts < self.maxReconnectionAttempts then
		self.reconnectionAttempts = self.reconnectionAttempts + 1
		local delay = math.min(self.reconnectionDelay * math.pow(2, self.reconnectionAttempts - 1), self.reconnectionDelayMax)

		if self.env == "roblox" then
			game:GetService("RunService").Heartbeat:Wait()
		else
			-- Use Timer for delay in Lune
			Timer.setTimeout(function()
				self:reconnectAttempt()
			end, delay)
		end
	else
		self:trigger("reconnect_failed")
	end
end

function SocketIO:reconnectAttempt()
	self.reconnecting = true
	self:trigger("reconnecting", self.reconnectionAttempts)

	-- Clear session data
	self.sid = nil
	self.connected = false

	-- Try to reconnect
	self:pollingConnect()
end

return SocketIO