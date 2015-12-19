local D = {}

local uv = require('uv')
local json = require('json')
local querystring = require('querystring')
local utils = require('utils')
local timer = require('timer')

local http = require('coro-http')
local websocket = require('websocket-client')
local wrapper = require('coro-wrapper')

local DS = require('./datastore')

local init
local trigger

local version = '0.0.1'
local headers =
{
	{ "accept", "*/*" },
	{ "accept-encoding", "gzip, deflate" },
	{ "accept-language", "en-US;q=0.8" },
	{ "content-type", "application/json" },
	{ "dnt", "1" },
	{ "origin", "https://discordapp.com" },
	{ "user-agent", "DiscordBot (https://github.com/sclark39/luv-discord, v"..version..")" }	
}

local HTTP_CREATED = 201

local wrap,yield,resume = coroutine.wrap, coroutine.yield, coroutine.resume

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
				split[fill[i]] = assert( select(i, ...), "param "..i.." not found: "..s )
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
		
	get_messages = { method = "GET", endpoint = EP("https://discordapp.com/api/channels/:channel_id/messages" ) },
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
D.permissions = permissions


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
	
	local init = wrap( init )
	self.threading = {
		resume = init,
		busy = false,
		block = false,
		yield = nil,
	}
	init( self, options )
	
	return self
end

function getauthcache( self )
	self.token, self.gateway = dofile( "auth-cache.lua" )
	self.headers = { { "content-type", "application/json" }, { "authorization", self.token } }
end
	

function auth( self, options )
	self.headers = { { "content-type", "application/json" } }
	
	do -- auth
		print 'Authenticating'
		local body = json.stringify( { email = options.email, password = options.password } )
		local head, data = http.request( api.login.method, api.login.endpoint(), { { "content-type", "application/json" } }, body )		
		data = json.decode( data )
		self.token = data.token
		self.headers = { { "content-type", "application/json" }, { "authorization", self.token } }
	end
	
	do -- find gateway
		print 'Finding Gateway'
		local head, data = http.request( api.gateway.method, api.gateway.endpoint(), self.headers )
		data = json.decode( data )
		self.gateway = data.url
	end	
end

function connect( self, options )
	print 'Connecting'
	local read, write, socket = websocket( self.gateway )
	self.ws = { socket = socket, read = read, write = write }
	
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
	if message.opcode == 8 then
		print 'Disconnected'
		p{ erorr = message.payload }
		return false, message
	end
	
	-- save working token/gateway
	local f = io.output( "auth-cache.lua" )
	f:write( string.format( "return '%s', '%s'", self.token, self.gateway ) )
	f:close()
		
	return true, message
end
	
	
function init( self, options )
		
	local success,message
	if pcall( getauthcache, self ) then
		success, message = connect( self, options )	
	end
	if not success then
		auth( self, options )
		success, message = connect( self, options )
	end
	if not success then
		print 'Failed to connect'
		return
	end
	
	local data = json.decode( message.payload )
	assert( data.t == 'READY' )
	assert( data.d.heartbeat_interval )
	
	-- Heartbeat
	self.heartbeat = timer.setInterval( data.d.heartbeat_interval, 
		coroutine.wrap( function()
				while true do
					write( json.stringify( { op = 1, d = os.time() * 1000 } ) ) 
					yield()
				end
			end 
		) 
	)
	
	-- Parse ready message.
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

	for message in self.ws.read do
		while self.threading.busy do 
			print "waiting to read, busy"
			self.threading.waiting = true
			yield() 
		end
		self.threading.busy = true
		
		local data = json.decode( message.payload )
		trigger( self, 'debug', data )
		if data.d and ws_events[data.t] then
			ws_events[ data.t ]( self, data.d )
		end
					
		self.threading.busy = false
		if self.threading.yieldTo then
			print "done working, yielding to..."
			local coro = self.threading.yieldTo 
			self.threading.yieldTo = nil
			resume( coro )
		end
	end	
	
end


function D.lock( self )
	print "lock"
	if self.threading.busy then
		self.threading.yieldTo = coroutine.running()
		print "yielding timer"
		coroutine.yield()
	end
	self.threading.busy = true
end

function D.unlock( self )
	print "unlock"
	self.threading.busy = false
	if self.threading.waiting then
		self.threading.waiting = nil
		print "resuming main"
		self.threading.resume()
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
	if head.code ~= 200 then
		print( 'sendMessage response: ' .. head.code )
	elseif head.code == 429 then
		print 'rate limit hit'
		local data = json.decode( data )		
		timer.sleep( data['Retry-After'] )
		return D.sendMessage( self, channel, message, options )
	end
	
	return json.decode( data )
end

function scopy(t)
	local r = {}
	for k,v in pairs(t) do
		r[k] = v
	end
	return r
end

function D.setRoles( self, guild, user, roles )
	local body = json.stringify(  { roles = roles } )
	local head, data = http.request( api.edit_member.method, api.edit_member.endpoint(guild,user), self.headers, body )
	return json.decode( data )
end

function D.createChannel( self, guild, name, isVoice )
	local body = json.stringify(  { name = name, type = isVoice and 'voice' or 'text' } )
	local head, data = http.request( api.create_channel.method, api.create_channel.endpoint(guild), self.headers, body )
	
	data = json.decode( data )
	if head.code == HTTP_CREATED then		
		ws_events['CHANNEL_CREATE']( self, scopy( data ) )
	end	
	return data
end

function D.deleteChannel( self, channel )
	local head, data = http.request( api.delete_channel.method, api.delete_channel.endpoint(channel), self.headers )
	return json.decode( data )
end

function D.setPermissions( self, channel, target, allow, deny )
	local gid = self:guildFromChannel( channel )
	local targetType = self.guilds[gid].members[target] and 'member' or 'role'
	local body = json.stringify(  { id = target, type = targetType, allow = allow, deny = deny } )
	
	local head, data = http.request( api.set_permission.method, api.set_permission.endpoint( channel, target ), self.headers, body )
	p{ head = head, data = data, body = body, method = api.set_permission.method, endpoint = api.set_permission.endpoint( channel, target ) }
	return json.decode( data )
end
	
function D.getMessages( self, channel, options )
	local qs = options and '?'..querystring.stringify { before = options.before, after = options.after, limit = options.limit } or ""
	local head, data = http.request( api.get_messages.method, api.get_messages.endpoint(channel)..qs, self.headers )
	return json.decode( data )
end

function D.deleteMessage( self, channel, id )
	local head, data = http.request( api.delete_message.method, api.delete_message.endpoint(channel,id), self.headers )
	return json.decode( data )
end

return setmetatable( {}, { __call = new } )