local D = {}

local uv = require('uv')
local json = require('json')
local utils = require('utils')
local timer = require('timer')

local http = require('coro-http')
local websocket = require('websocket-client')
local wrapper = require('coro-wrapper')

local DS = require('./datastore')

local init
local trigger

local headers =
{
	{ "accept", "*/*" },
	{ "accept-encoding", "gzip, deflate" },
	{ "accept-language", "en-US;q=0.8" },
	{ "content-type", "application/json" },
	{ "dnt", "1" },
	{ "origin", "https://discordapp.com" },
	{ "user-agent", "LuvitBot (luv-discord) }" }	
}


local function EP( s )
	local split, fill, lastj = {}, {}, 1
	for i,v,j in s:gmatch( "()(:[^/]+)()") do
		split[#split+1], split[#split+2], lastj = s:sub( lastj, i-1 ), v, j
		fill[#fill+1]=#split
	end
	split[#split+1] = s:sub( lastj )
	if #split == 1 then
		return function() return s end
	else
		return function(...)
			for i = 1,#fill do
				split[fill[i]] = assert( select(i, ...) )
			end
			return table.concat(split,"")
		end
	end
end

local api =
{
	login = { method = "POST", endpoint = EP("https://discordapp.com/api/auth/login" ), },
	gateway = { method = "GET", endpoint = EP("https://discordapp.com/api/gateway" ), },
	
	broadcast_typing = { method="POST", endpoint=EP("https://discordapp.com/api/channels/:channel_id/typing") },
		
	send_message = { method = "POST", endpoint = EP("https://discordapp.com/api/channels/:channel_id/messages" ) },
	edit_message = { method = "PATCH", endpoint = EP("https://discordapp.com/api/channels/:channel_id/messages/:id") },
	delete_message = { method = "DELETE", endpoint = EP("https://discordapp.com/api/channels/:channel_id/messages/:id") },
	
	create_channel = { method = "POST", endpoint = EP("https://discordapp.com/api/guilds/:guild_id/channels") },	
	edit_channel = { method = "PATCH", endpoint = EP("https://discordapp.com/api/channels/:channel_id") },
	delete_channel = { method = "DELETE", endpoint = EP("https://discordapp.com/api/channels/:channel_id") },
	
	set_permission = { method = "PUT", endpoint = EP("https://discordapp.com/api/channels/:channel_id/permissions/:target_id") },
	del_permission = { method = "DELETE", endpoint = EP("https://discordapp.com/api/channels/:channel_id/permissions/:target_id") },
	
	edit_member = { method = "PATCH", endpoint = EP("https://discordapp.com/api/guilds/:guild_id/members/:user_id") },
	kick_member = { method = "DELETE", endpoint = EP("https://discordapp.com/api/guilds/:guild_id/members/:user_id") },
	
	create_role = { method = "POST", endpoint = EP("https://discordapp.com/api/guilds/:guild_id/roles") },
	reorder_role = { method = "PATCH", endpoint = EP("https://discordapp.com/api/guilds/:guild_id/roles") },
	edit_role = { method = "PATCH", endpoint = EP("https://discordapp.com/api/guilds/:guild_id/roles/:role_id") },
	delete_role = { method = "DELETE", endpoint = EP("https://discordapp.com/api/guilds/:guild_id/roles/:role_id") },
	
	create_private_channel = { method = "POST", endpoint = EP("https://discordapp.com/api/users/:user_id/channels") },
}

	
function bit_enum(t)
	for k,v in pairs(t) do
		t[k] = bit.lshift(1,v)
	end
	return t
end
local permissions = bit_enum{
	GENERAL_CREATE_INSTANT_INVITE = 0,
	GENERAL_KICK_MEMBERS = 1,
	GENERAL_BAN_MEMBERS = 2,
	GENERAL_MANAGE_ROLES = 3,
	GENERAL_MANAGE_CHANNELS = 4,
	GENERAL_MANAGE_GUILD = 5,
	
	TEXT_READ_MESSAGES = 10,
	TEXT_SEND_MESSAGES = 11,
	TEXT_SEND_TTS_MESSAGE = 12,
	TEXT_MANAGE_MESSAGES = 13,
	TEXT_EMBED_LINKS = 14,
	TEXT_ATTACH_FILES = 15,
	TEXT_READ_MESSAGE_HISTORY = 16,
	TEXT_MENTION_EVERYONE = 17,
	
	VOICE_CONNECT = 20,
	VOICE_SPEAK = 21,
	VOICE_MUTE_MEMBERS = 22,
	VOICE_DEAFEN_MEMBERS = 23,
	VOICE_MOVE_MEMBERS = 24,
	VOICE_USE_VAD = 25,
}


local function noop() end

local function ds_add_helper( locator )
	return function( self, d )
		local guild_id = d.guild_id
		local ds = self.guilds[ d.guild_id ][locator]
		guild_id, d.guild_id = d.guild_id, nil
		DS.add( ds, d ) 
	end
end

local function popGuild( self, d )
	local guild = self.guilds[ d.guild_id ]
	d.guild_id = nil
	return guild
end
	
		
local ws_events =
{
	READY = noop, -- handled by init
	
	MESSAGE_CREATE = function( self, d ) 
			trigger( self, 'message', d.author.username, d.author.id, d.channel_id, d.content ); 
		end,
		
	-- g.presences = DS.fromList( g.presences, 'user.id' )
	PRESENCE_UPDATE = noop,
		
	USER_UPDATE = noop,
		
	GUILD_CREATE = noop,
	GUILD_DELETE = noop,
	
			
	--	g.channels = DS.fromList( g.channels, 'id', 'name' )	
	CHANNEL_CREATE = function( self, d )
			local channels = d.is_private and self.pms or popGuild( self, d ).channels
			DS.add( channels, d )
		end,
	CHANNEL_UPDATE = function( self, d )
			local channels = d.is_private and self.pms or popGuild( self, d ).channels
			DS.update( channels, d.id, d )
		end, 
	CHANNEL_DELETE = function( self, d )
			local channels = d.is_private and self.pms or popGuild( self, d ).channels
			DS.remove( channels, d.id )
		end,
	
	-- 	g.members = DS.fromList( g.members, 'user.id', 'user.username' )
	GUILD_MEMBER_ADD = function( self, d )
			local members = popGuild( self, d ).members
			DS.add( members, d )
		end,
	GUILD_MEMBER_UPDATE = function( self, d )
			local members = popGuild( self, d ).members
			DS.update( members, d.user.id, d )
		end,
	GUILD_MEMBER_REMOVE = function( self, d )
			local members = popGuild( self, d ).members
			DS.remove( members, d.user.id )
		end,		
		
	-- g.roles = DS.fromList( g.roles, 'id', 'name' )		
	GUILD_ROLE_CREATE = function( self, d )
			local members = popGuild( self, d ).roles
			DS.add( members, d.role )
		end,
	GUILD_ROLE_UPDATE = function( self, d )
			local members = popGuild( self, d ).members
			DS.update( members, d.role.id, d.role )
		end,
	GUILD_ROLE_DELETE = function( self, d )
			local members = popGuild( self, d ).members
			DS.remove( members, d.role_id )
		end,
		
	VOICE_STATE_UPDATE = noop,
	TYPING_START = noop,
}



local function new( t, ... )
	local options = ...	
	local self = setmetatable({},{ __index = D })
	
	self.triggerOn = {}
	self.wpm = 90
	
	coroutine.wrap( function() init( self, options ) end )()
	
	return self
end

function init( self, options )
	self.headers = { { "content-type", "application/json" } }
	
	do -- auth
		local body = json.stringify(  { email = options.email, password = options.password } )
		local head, data = http.request( api.login.method, api.login.endpoint(), self.headers, body )
		data = json.decode( data )
		
		self.headers[#self.headers + 1] = { "authorization",  data.token }
		self.token = data.token
	end
		
	do -- find gateway
		local head, data = http.request( api.gateway.method, api.gateway.endpoint(), self.headers )
		data = json.decode( data )
		self.gatewayUrl = data.url
	end
	
	do
		local read, write, socket = websocket( self.gatewayUrl )
		write = wrapper.writer(write, function(item) return { opcode = 1, mask = true, payload = item } end ) -- must write using plain/text opcode and with mask enabled
		write( json.stringify
			{ 
				op = 2, 
				d = 
				{ 
					v = 3,
					token = self.token, 
					compress = false,
					properties =
					{
						["$os"] = require('ffi').os,
						["$browser"] = "",
						["$device"] = "",
						["$referrer"] = "",
						["$referring_domain"] = "",
					}
				} 
			}  
		)
		
		local message = read()	
		local data = json.decode( message.payload )
		assert( data.t == 'READY' )
		assert( data.d.heartbeat_interval )
		
		-- Heartbeat
		local timer = uv.new_timer()
		timer:start( data.d.heartbeat_interval, data.d.heartbeat_interval, function()
			coroutine.wrap( function() write( json.stringify( { op = 1, d = os.time() * 1000 } ) ) end )()
		end )
		
		-- Parse data.
		self.user = data.d.user
		self.guildChannelLookup = {}
			
		self.guilds = data.d.guilds
		for i=1,#self.guilds do					
			local g = self.guilds[i]
			
			for i=1,#g.channels do
				self.guildChannelLookup[ g.channels[i].id ] = g.id
			end
			
			g.channels = DS.fromList( g.channels, 'id', 'name' )
			g.members = DS.fromList( g.members, 'user.id', 'user.username' )
			g.presences = nil--DS.fromList( g.presences, 'user.id' )
			g.roles = DS.fromList( g.roles, 'id', 'name' )			
		end		
		self.guilds = DS.fromList( self.guilds, 'id', 'name' )		
		self.pms = DS.fromList( data.d.private_channels, 'id', 'recipient.id' )
			
		trigger( self, 'ready' )
		
		for message in read do
			local data = json.decode( message.payload )
			trigger( self, 'debug', data )
			if data.d and ws_events[data.t] then
				ws_events[ data.t ]( self, data.d )
			end			
		end	
		
	end
end

function trigger(self,event,...)
	local triggers = self.triggerOn[event] or {}
	for i=1,#triggers do
		triggers[i]( self, ...)
	end
end

function D.guildFromChannel( self, channel )
	return self.guildChannelLookup[ channel ]
end

function D.on(self, event, callback)
	local t = self.triggerOn[event] or {}
	t[#t+1] = callback	
	self.triggerOn[event] = t
end
	
function D.fakeType( self, channel, sleep_time )
	repeat
		http.request( api.broadcast_typing.method, api.broadcast_typing.endpoint(channel), self.headers )
		timer.sleep( math.min( 5000, sleep_time ) )
		sleep_time = sleep_time - 5000
	until sleep_time <= 0
end
	
function D.sendMessage( self, channel, message, options )
	if options and options.fakeType then
		local typing_time = #message * ( 1000 * ( 60 / (( self.wpm or 90 ) * 5 ) ) ) 
		self:fakeType( channel, typing_time )
	end
	local body = json.stringify(  { content = message } )
	local head, data = http.request( api.send_message.method, api.send_message.endpoint(channel), self.headers, body )
	return json.decode( data )
end

function D.setRoles( self, guild, user, roles )
	local body = json.stringify(  { roles = roles } )
	local head, data = http.request( api.edit_member.method, api.edit_member.endpoint(guild,user), self.headers, body )
	return json.decode( data )
end

function D.createChannel( self, guild, name, isVoice )
	local body = json.stringify(  { name = name, type = isVoice and 'voice' or 'text' } )
	local head, data = http.request( api.create_channel.method, api.create_channel.endpoint(guild), self.headers, body )
	return json.decode( data )
end

function D.setPermissions( self, channel, target, isRole, allow, deny )
	local body = json.stringify(  { id = target, type = isRole and 'role' or 'member', allow = allow, deny = deny } )
	local head, data = http.request( api.set_permission.method, api.set_permission.endpoint(guild,channel), self.headers, body )
	return json.decode( data )
end
	

return setmetatable( {}, { __call = new } )