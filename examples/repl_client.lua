local uv = require 'uv'
local utils = require 'utils'
local repl = require 'repl'

local bot = require 'discord' ( { email = BOT_EMAIL, password = BOT_PASSWORD } )
local debug_verbose = true

bot:on( 'ready', function( self ) print('Connected.') end )
bot:on( 'debug', function( self, data ) p( test ); if debug_verbose then p { [data.t] = data.d } end end )
bot:on( 'message', function( self, user, id, channel, message )	print( user .. ": " .. message ) end )
	
_G.bot = bot
_G.set_verbose = function ( set )
	debug_verbose = set
end

coroutine.wrap( function()
	repl(utils.stdin, utils.stdout, "").start("")
end )()

uv.run()