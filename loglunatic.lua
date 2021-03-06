#!/usr/bin/env luajit

--[[
loglunatic -- logstash for lunatics
Copyright (c) 2013, Alex Wilson, the University of Queensland
Distributed under a BSD license -- see the LICENSE file in the root of the distribution.
]]

local function usage()
	io.write("Usage: ./loglunatic.lua [-d|--daemon] [-p|--pidfile <file>] [-l|--logfile <file>] <config>\n")
	os.exit(1)
end

local fname = nil
local lastarg = nil
local logfile = "lunatic.log"
local pidfile = "lunatic.pid"
local foreground = true

for i,v in ipairs(arg) do
	if v == "--daemon" or v == "-d" then
		foreground = false
	elseif lastarg == "--logfile" or lastarg == "-l" then
		logfile = v
	elseif lastarg == "--pidfile" or lastarg == "-p" then
		pidfile = v
	else
		fname = v
	end
	lastarg = v
end
if fname == nil then
	usage()
end
local f, err = loadfile(fname)
if f == nil then
	io.write("Could not process config file " .. fname .. "\n")
	io.write(err .. "\n")
	os.exit(1)
end

local lpeg = assert(require('lpeg'))
local ffi = assert(require('ffi'))
local bit = assert(require('bit'))
local l = assert(require('lunatic'))

ffi.cdef[[
int fork(void);
int setsid(void);
int close(int);
typedef void (*sig_t)(int);
sig_t signal(int sig, sig_t func);
int dup2(int from, int to);
int open(const char *path, int oflag, ...);
int fsync(int);
]]

local O_WRONLY = 0x01
local O_APPEND = 0x08
local O_CREAT = 0x0200
if ffi.os == "Linux" then
	O_CREAT = 0x40
	O_APPEND = 0x400
end
if ffi.os == "POSIX" then
	O_CREAT = 0x100
end

local function daemonize()
	assert(io.open(logfile, "w"))

	local r = ffi.C.fork()
	if r < 0 then
		print("fork failed: " .. ffi.errno)
		os.exit(1)
	elseif r > 0 then
		local pidfile = io.open(pidfile, "w")
		pidfile:write(r .. "\n")
		pidfile:close()
		os.exit(0)
	end

	ffi.C.setsid()

	local fd = ffi.C.open(logfile, bit.bor(O_WRONLY, O_APPEND))
	local nullfd = ffi.C.open("/dev/null", bit.bor(O_WRONLY, O_APPEND))
	assert(fd >= 0)
	assert(nullfd >= 0)

	assert(ffi.C.dup2(nullfd, 0) >= 0)
	assert(ffi.C.dup2(fd, 1) >= 0)
	assert(ffi.C.dup2(fd, 2) >= 0)

	ffi.C.fsync(fd)
	ffi.C.close(fd)
	ffi.C.close(nullfd)

	print("\ndaemonized ok, ready to go")
	ffi.C.fsync(1)
end

if not foreground then
	daemonize()
end

local rtor = l.Reactor.new()

local env = {}
env.string = string
env.table = table
env.math = math

env.os = {}
env.os.time = os.time
env.os.date = os.date

for k,v in pairs(lpeg) do
	env[k] = v
end

env.inputs = {}
for k,v in pairs(l.inputs) do
	env.inputs[k] = function(tbl)
		tbl.reactor = rtor
		local chan = v(tbl)
		if tbl.restart then
			print("loglunatic: setting up restarter on input '" .. k .. "'")
			chan.old_close = chan.on_close
			chan.on_close = function(ch, rt)
				print("loglunatic: restarting closed input '" .. k .. "'")
				ch:old_close(rt)
				tbl.reactor = rt
				local newchan = v(tbl)
				newchan.old_close = newchan.on_close
				newchan.on_close = ch.on_close
				rt:add(newchan)
				local newinp = l.filters.input{ channel = newchan, reactor = rt }
				newchan.inp = newinp
				newinp.sink = ch.inp.sink
			end
		end
		rtor:add(chan)
		chan.inp = l.filters.input{ channel = chan, reactor = rtor }
		return chan.inp
	end
end

local reactorwrap = function(orig)
	return function(tbl)
		tbl.reactor = rtor
		return orig(tbl)
	end
end

local function wraptbl(dest, src)
	for k,v in pairs(src) do
		if type(v) == "table" then
			dest[k] = {}
			wraptbl(dest[k], v)
		else
			dest[k] = reactorwrap(v)
		end
	end
end

wraptbl(env, l.filters)

env.outputs = {}
wraptbl(env.outputs, l.outputs)

env.link = l.link

f = setfenv(f, env)
f()

print("starting reactor..")
rtor:run()
