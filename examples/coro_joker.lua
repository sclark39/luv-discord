local uv = require 'uv'
local bot = require 'discord' ( { email = BOT_EMAIL, password = BOT_PASSWORD } )

local ready = false
local timer

function read( self )
	ready = true
	local event, args = coroutine.yield()
	ready = false
	return event, args
end

function timeout( ms )
	local coro = coroutine.running()
	timer = uv.new_timer()  	
	uv.timer_start(timer, ms, 0, function() coroutine.resume( coro, 'timeout' ) end )
end 

function clear_timeout()
	uv.timer_stop(timer)
	uv.close(timer)
	timer = nil	
end
 
local main = coroutine.create( function( self )
	local event, args
	repeat
		::next::
		
		repeat event, args = read( self ) until 
			event == "message" and string.lower(args.message) == "knock knock" 
			
		local targetUser, targetChannel = args.id, args.channel
		
		self:sendMessage( args.channel, "Who's there?", { fakeType = true } )
		
		timeout( 10 * 1000 ) 
		repeat event, args = read( self ) until
			event == "timeout" or 
			event == "message" and args.id == targetUser and args.channel == targetChannel
		clear_timeout() 
		
		if event == "timeout" then
			self:sendMessage( targetChannel, "No one?", { fakeType = true } )
			goto next
		end
		self:sendMessage( targetChannel, args.message .. " who?", { fakeType = true } )
		
		timeout( 10 * 1000 ) 
		repeat event, args = read( self ) until 
			event == "timeout" or 
			event == "message" and args.id == targetUser and args.channel == targetChannel
		clear_timeout()
		
		if event == timeout then
			self:sendMessage( targetChannel, "Where'd you go?", { fakeType = true } )
			goto next
		end
		self:sendMessage( targetChannel, "HA HA HA", { fakeType = true } )
		
	until nil
	
end )

bot:on( 'message', function( self, user, id, channel, message )
		if ready then
			coroutine.resume( main, 'message', { message = message, user = user, id = id, channel = channel } )
		end
	end )

coroutine.resume( main, bot )
uv.run()