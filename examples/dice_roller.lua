local uv = require 'uv'
local bot =  require 'discord' ( { email = BOT_EMAIL, password = BOT_PASSWORD } )
math.randomseed( os.time() )

bot:on( 'ready', function( self ) print('Connected.') end )
bot:on( 'message', function( self, user, id, channel, message )
		print( user .. ": " .. message )
		local count,sides = message:match("!roll (%d+)d(%d+)")
		if count then			
			count = math.min( math.max( 1, tonumber(count) ), 20 )
			sides = math.min( math.max( 2, tonumber(sides) ), 100 )
			
			local sum, dice = 0, {}
			for i=1,count do
				local v = math.random(sides)
				dice[i] = '['..v..']'
				sum = sum + v					
			end			
			local payload = string.format( "*rolled %dd%d*\n`%d = %s`", count, sides, sum, table.concat( dice, " " ) )
			self:sendMessage( channel, payload, { fakeType = true } )
		end
	end )	

uv.run()