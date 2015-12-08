local DS = {}

function DS.add( ds, v )
	local uid = loadstring( 'return function(v) return v.'..ds.key..'; end' )()(v)
	local search = ds.name and loadstring( 'return function(v) return v.'..ds.name..'; end' )()(v)
	if uid then
		ds[uid] = v
		if search then
			local lookup = ds.lookup[search] or setmetatable( {}, { __mode = 'v' } )
			ds.lookup[search] = lookup
			lookup[#lookup+1] = v
		end
	end
end

function DS.remove( ds, uid )
	local search = ds.name and loadstring( 'return function(v) return v.'..ds.name..'; end' )()( ds[uid] )
	ds[uid] = nil
	if search then
		local lookup = ds.lookup[search]
		assert( lookup )
		if ( #lookup == 0 ) then
			ds.lookup[search] = nil
		end
	end
end

--[[local function update_deep( dst, src )
	for k,v in pairs(src) do
		if type(v) == 'table' then
			update_deep( dst[k], v )
		else
			dst[k] = v
		end
	end
end]]

function DS.update( ds, uid, data )
	local entry = ds[uid]
	for k,v in pairs(data) do
		entry[k] = v
	end
	--update_deep( ds[uid], data )
	p{ after_update = ds[uid] }
end

function DS.fromList( list, key, name )
	local ds = { key = key }
	if name then
		ds.name = name
		ds.lookup = {}
	end
	for i=1,#list do 
		local v = list[i]
		DS.add( ds, v )
	end
	return ds
end

return DS