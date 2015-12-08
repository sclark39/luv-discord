exports.name = "sclark39/luv-discord"
exports.version = "0.0.1"
exports.description = "A library for creating a Discord client"
exports.tags = {"discord"}
exports.author = { name = "Skyler Clark" }
exports.homepage = "https://github.com/sclark39/luv-discord"
exports.dependencies = {
	"luvit/json@2.5.1",
	"luvit/utils@1.0.0-4",
	"luvit/timer@1.0.0-4",
	"creationix/coro-http@1.2.1-1",
	"creationix/coro-wrapper@1.0.0",
	"creationix/websocket-client@1.0.0",
}

return require('./discord')