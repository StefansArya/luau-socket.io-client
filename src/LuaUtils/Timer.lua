local Timer = {}
Timer.task = nil

if task then Timer.task = task -- Roblox have this in global variable
else
	pcall(function () Timer.task = require("@lune/task") end) -- Lune
end

-- setTimeout(msDelay: number) → Promise<void>
function Timer.setTimeout(callback, delay)
	if Timer.task == nil then
		print("Timer.setTimeout> Unable to find 'task' library")
		return
	end

	local running = true
	Timer.task.delay(delay / 1e3, function()
		if running then callback() end
	end)
	return function() running = false end
end

-- setInterval(callback: () → (), interval: number) → cancel: () → ()
function Timer.setInterval(callback, msInterval)
	if Timer.task == nil then
		print("Timer.setInterval> Unable to find 'task' library")
		return
	end

	local running = true
	Timer.task.spawn(function()
		local interval = msInterval / 1e3
		while running do
			Timer.task.wait(interval)
			if running then callback() end
		end
	end)
	return function() running = false end
end

local function clearTimer(callback)
	if callback then callback() end
end

Timer.clearTimeout = clearTimer
Timer.clearInterval = clearTimer

return Timer