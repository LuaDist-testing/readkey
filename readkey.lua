---------------------------------------------------------------------
--     This Lua5 module is Copyright (c) 2010, Peter J Billam      --
--                       www.pjb.com.au                            --
--                                                                 --
--  This module is free software; you can redistribute it and/or   --
--         modify it under the same terms as Lua5 itself.          --
---------------------------------------------------------------------

local M = {} -- public interface
M.Version = '1.2'  -- ReadKey restarts the P.read() after interrupt
M.VersionDate = '22oct2013'

--  luaposix now has tcgetattr and tcsetattr and the constants ECHONL etc !
--  https://github.com/luaposix/luaposix/blob/master/examples/termios.lua
--  http://linux.die.net/man/3/tcsetattr
--  https://github.com/luaposix/luaposix/blob/master/examples/poll.lua
--  http://linux.die.net/man/2/poll
--  http://luaposix.github.io/luaposix/docs/index.html  <== OUT-OF-DATE doc
--  /usr/include/asm-generic/termbits.h
local P = require 'posix'
local B = require 'bit'  -- LuaBitOp http://bitop.luajit.org/api.html

-- require 'DataDumper'

local T   -- check if terminfo module is present...
pcall(function() T = require 'terminfo' ; end )
local RL = require 'readline'

------------------------------ private ------------------------------
local function warn(str) io.stderr:write(str,'\n') end
local function die(str)  io.stderr:write(str,'\n') ;  os.exit(1) end
local function qw(s)  -- t = qw[[ foo  bar  baz ]]
	local t = {} ; for x in s:gmatch("%S+") do t[#t+1] = x end ; return t
end
local function exists(fn)
	-- or check if posix.stat(path) returns non-nil
	local f=io.open(fn,'r')
	if f then f:close(); return true else return false end
end

local function deepcopy(object)  -- http://lua-users.org/wiki/CopyTable
	local lookup_table = {}
	local function _copy(object)
		if type(object) ~= "table" then
			return object
		elseif lookup_table[object] then
			return lookup_table[object]
		end
		local new_table = {}
		lookup_table[object] = new_table
		for index, value in pairs(object) do
			new_table[_copy(index)] = _copy(value)
		end
		return setmetatable(new_table, getmetatable(object))
	end
	return _copy(object)
end

local function save_attributes(fd)  -- also calculates our other settings
	local attrs = {}  -- indexed by mode
	attrs[0] = P.tcgetattr(fd)
	attrs[1] = deepcopy(attrs[0])  -- cooked
	-- (1) brkint ignpar icrnl ixon opost isig  icanon
	attrs[1]['iflag'] = B.bor(attrs[0]['iflag'],
	  P.BRKINT + P.IGNPAR + P.ICRNL + P.IXON)
	attrs[1]['oflag'] = B.bor(attrs[0]['oflag'], P.OPOST)
	attrs[1]['lflag'] = B.bor(attrs[0]['lflag'], P.ISIG + P.ICANON)
	attrs[2] = deepcopy(attrs[1]) -- cooked mode with echo off
	-- (2) -echo -echoe -echok -echoctl -echoke
	attrs[2]['lflag'] = B.band(attrs[1]['lflag'],
	  B.bnot(P.ECHO + P.ECHOE + P.ECHOK + P.ECHOCTL + P.ECHOKE))
	attrs[3] = deepcopy(attrs[2])  -- cbreak mode.
	-- (3) -icanon -echo -echoe -echok -echoctl -echoke
	attrs[3]['lflag'] = B.band(attrs[2]['lflag'], B.bnot(P.ICANON))
	attrs[4] = deepcopy(attrs[3])  -- raw mode
	-- (4) -ixon -isig -icanon -iexten -echo -echoe -echok -echoctl -echoke
	-- IXON=1024 ISIG=1 IEXTEN=32768
	-- (man stty says -ignbrk -brkint -ignpar -parmrk -inpck -istrip -inlcr
	--     -igncr -icrnl -ixon  -ixoff   -iuclc   -ixany  -imaxbel  -opost
	--     -isig -icanon -xcase min 1 time 0 )
	attrs[4]['iflag'] = B.band(attrs[3]['iflag'], B.bnot(P.IXON))
	attrs[4]['lflag'] = B.band(attrs[3]['lflag'],
	  B.bnot(P.ISIG + P.IEXTEN))
	attrs[5] = deepcopy(attrs[4])
	-- ultra-raw mode  (no LF to CR/LF translation)
	-- (5) ignpar -icrnl -ixon -opost -onlcr -isig -icanon -iexten
	--      -echo -echoe -echok noflsh -echoctl -echoke
	-- IGNPAR=4 ICRNL=256 OPOST=1 ONLCR=4 NOFLSH=128
	attrs[5]['iflag'] = B.bor(attrs[4]['iflag'], P.IGNPAR)
	attrs[5]['iflag'] = B.band(attrs[5]['iflag'], B.bnot(P.ICRNL))
	attrs[5]['oflag'] = B.band(attrs[5]['oflag'],
	  B.bnot(P.OPOST + P.ONLCR))
	attrs[5]['lflag'] = B.bor(attrs[5]['lflag'], P.NOFLSH)
	-- link all the control-character tables together (except 0=save)
	attrs[2]['cc'] = attrs[1]['cc']
	attrs[3]['cc'] = attrs[1]['cc']
	attrs[4]['cc'] = attrs[1]['cc']
	attrs[5]['cc'] = attrs[1]['cc']
	return attrs -- will be stored in global SaveAttr[fd] indexed by fd
end

local SaveAttr    = {}  -- SaveAttr[fd][mode]
local CurrentMode = {}  -- CurrentMode[fd]

----------------- from Term::ReadKey ------------------------------
local UseEnv = true
local modes = {
	original=0, restore=0, normal=1, noecho=2, cbreak=3, raw=4,
	["ultra-raw"]=5, [0]=0, [1]=1, [2]=2, [3]=3, [4]=4, [5]=5,
}

--[[debian wheezy /usr/include/asm-generic/termbits.h says:
	/* c_cc characters */
	#define VINTR 0
	#define VQUIT 1
	#define VERASE 2
	#define VKILL 3
	#define VEOF 4
	#define VTIME 5
	#define VMIN 6
	#define VSWTC 7
	#define VSTART 8
	#define VSTOP 9
	#define VSUSP 10
	#define VEOL 11
	#define VREPRINT 12
	#define VDISCARD 13
	#define VWERASE 14
	#define VLNEXT 15
	#define VEOL2 16
]]
local num2ccname = {
	[P.VINTR]    = 'INTERRUPT', -- 0
	[P.VQUIT]    = 'QUIT',      -- 1
	[P.VERASE]   = 'ERASE',     -- 2
	[P.VKILL]    = 'KILL',      -- 3
	[P.VEOF]     = 'EOF',       -- 4
	[P.VTIME]    = 'TIME',      -- 5
	[P.VMIN]     = 'MIN',       -- 6
	-- [P.VSWTC]    = 'SWITCH',  -- not posix, and not supported by linux
	[P.VSTART]   = 'START',     -- 8
	[P.VSTOP]    = 'STOP',      -- 9
	[P.VSUSP]    = 'SUSPEND',   -- 10
	[P.VEOL]     = 'EOL',       -- 11
	[P.VREPRINT] = 'REPRINT',   -- 12 VRPRNT ?
	[P.VDISCARD] = 'DISCARD',   -- 13
	[P.VWERASE]  = 'ERASEWORD', -- 14
	[P.VLNEXT]   = 'QUOTENEXT', -- 15 is this really the corresponding name ?
	[P.VEOL2]    = 'EOL2',      -- 16
	-- [P.VSTATUS]  = 'STATUS', -- what's this? mentioned by Term::ReadKey
}
local ccname2num = {}
for k,v in pairs(num2ccname) do ccname2num[v] = k end  -- reverse

function descriptor2fd(file)
	if     type(file) == 'number' then   -- its a posix int fd
		return file
	elseif type(file) == 'userdata' then -- its a lua filedescriptor
		return P.fileno(file)   -- 20130919 :-)
	else
		return 0
	end
end

local function _debug(s)
    local DEBUG = io.open('/tmp/debug', 'a')
    DEBUG:write(s.."\n")
    DEBUG:close()
end

local function split(s, pattern, maxNb) -- http://lua-users.org/wiki/SplitJoin
	if not s or string.len(s)<2 then return {s} end
	if not pattern then return {s} end
	if maxNb and maxNb <2 then return {s} end
	local result = { }
	local theStart = 1
	local theSplitStart,theSplitEnd = string.find(s,pattern,theStart)
	local nb = 1
	while theSplitStart do
		table.insert( result, string.sub(s,theStart,theSplitStart-1) )
		theStart = theSplitEnd + 1
		theSplitStart,theSplitEnd = string.find(s,pattern,theStart)
		nb = nb + 1
		if maxNb and nb >= maxNb then break end
	end
	table.insert( result, string.sub(s,theStart,-1) )
	return result
end


local function which(s)
	local f
	for i,d in ipairs(split(os.getenv('PATH'), ':')) do
		f=d..'/'..s; if P.access(f, 'x') then return f end
	end
	return nil
end

------------------------------ public ------------------------------

function M.ReadMode( mode, file )
	mode = modes[mode]
	if mode == nil then return false end  -- should complain
	local fd = descriptor2fd(file)
	-- the work is all done by save_attributes()
	if not SaveAttr[fd] then
		SaveAttr[fd] = save_attributes(fd)
	end
	CurrentMode[fd] = mode
	P.tcsetattr(fd, 0, SaveAttr[fd][mode])
end

function M.ReadKey( mode, file )
	--  0 normal read using getc,  -1 non-blocked read,  >0 timed read
	local fd = descriptor2fd(file)
	if mode == 0 then
		if CurrentMode[fd] and CurrentMode[fd] > 3 then
			while true do  -- 1.2
				local rc,msg,err = P.read(fd,1)
				-- SIGWINCH interrupts the read :-( which we don't want
				-- see man 7 signal, set SA_RESTART when creating the handler.
				-- SA_RESTART is defined in /usr/include/*/signal.h
				-- but luaposix does not define SA_RESTART; so, by hand:
				if rc then return rc end
				-- if string.match(msg, '^Interrupted') then   -- slower.
				-- luaposix doesn't document this err, but it exists.
				if err ~= P.EINTR then return '' end
				-- _debug('ReadKey received EINTR; looping...')
			end
		else
			return P.read(fd,1)
		end
		return nil  -- shouldn't reach here...
	elseif mode == -1 then
		-- http://linux.die.net/man/2/poll
		-- http://man7.org/linux/man-pages/man2/poll.2.html
		-- https://github.com/luaposix/luaposix/blob/master/examples/poll.lua
		-- local fd1 = P.open(arg[1], P.O_RDONLY)
		-- local fds = { [fd1] = { events = {IN=true} }, }
		-- for fd in pairs(fds) do if  fds[fd].revents.IN then ...
		local fds = { [fd] = { events = {IN=true}, revents = {} } }
		P.poll(fds, 1000)  -- in C, the timeout is in millisec
		-- The bits returned in revents can include any of those specified
		--  in events, or one of the values POLLERR, POLLHUP, or POLLNVAL.
		if fds[fd].revents.IN then
			return P.read(fd,1)
		else
			return nil
		end
	elseif mode > 0 then
		-- require 'alarm'   -- luarocks install lalarm
		-- the only doc is test.lua within /home/dist/lua/lalarm.tar.gz  :-(
		-- alarm(mode, function() c = filehandle:read(1) end)
		local c = nil
		-- more promising: http://linux.die.net/man/3/tcsetattr
		-- In noncanonical mode, MIN == 0; TIME > 0: TIME specifies the limit
		-- for a timer in tenths of a second. The timer is started when read(2)
		-- is called. read(2) returns either when at least one byte of data is
		-- available, or when the timer expires. If the timer expires without
		-- any input becoming available, read(2) returns 0.
		local save_attr = P.tcgetattr(fd)
		local noncanonical = deepcopy(save_attr)
		noncanonical['lflag'] = B.band(noncanonical['lflag'], B.bnot(P.ICANON))
		noncanonical['cc'][P.VMIN] = 0
		noncanonical['cc'][P.VTIME] = math.floor(0.5 + 10*mode)
		P.tcsetattr(fd, 0, noncanonical)
		c = P.read(fd,1)
		P.tcsetattr(fd, 0, save_attr)  -- fd must be int
		if c == '' then return nil else return c end
	else
		warn('ReadKey: unrecognised mode '..tostring(mode))
		return nil
	end
end

-- function M.ReadLine( mode, filehandle )
function M.ReadLine( prompt, histfile )
	--  0 normal read using getc,  -1 non-blocked read,  >0 timed read
	local using_hist = false
	if type(histfile) ~= 'string' or histfile == '' then
		RL.set_options{ auto_add=false, histfile='' }
	else
		RL.set_options{ histfile=histfile }
		using_hist =true
	end
	local str = RL.readline(tostring(prompt))
	if using_hist then RL.save_history() end
	return str
end

function M.GetTerminalSize()
-- ioctl(0, TIOCGWINSZ, {ws_row=49,ws_col=80,ws_xpixel=804,ws_ypixel=984}) = 0
-- http://man7.org/linux/man-pages/man4/tty_ioctl.4.html
-- Use of ioctl makes for nonportable programs.  Use the POSIX interface
-- described in termios(3) whenever possible; but there's no TIOCGWINSZ :-(
-- could read /usr/include/asm-generic/ioctls.h (and convert hex to decimal)

-- NASTY BUG :-(  before ReadLine has been used, all these methods respond
-- to size changes as expected :-) but after ReadLine has been invoked,
-- ENV, terminfo, tput and resize get the current size the first time,
-- but no longer respond to changes in the size for the life of the process :-(
-- also stty size; they all use the same ioctl(0, TIOCGWINSZ :-(
-- Presumably the SIGWINCH handler which the kernel used has got zapped :-(
-- http://www.softlab.ntua.gr/facilities/documentation/unix/gnu/readline/readline_43.html
-- Therefore, in 1.3, introduce  xwininfo -i $WINDOWID

	local width, height

	-- xwininfo introduced in 1.3
	local xwininfo = which('xwininfo')  -- do we have xwininfo ?
	if xwininfo and os.getenv('WINDOWID') then
		-- _debug('GetTerminalSize: using xwininfo')
		local p = io.popen(xwininfo..' -id '..os.getenv('WINDOWID'),'r')
		local txt = ''
		if p then txt = p:read('*all'); p:close() end
		local pixwidth  = tonumber(string.match(txt, 'Width:%s(%d+)') or 0)
		local pixheight = tonumber(string.match(txt, 'Height:%s(%d+)') or 0)
		width, height   = string.match(txt, '-geometry%s(%d+)x(%d+)')
		width  = tonumber(width)
		height = tonumber(height)
		if width and width>0.5 and height and height>0.5 then
			return width, height, pixwidth, pixheight
		end
	end

	-- because all these other methods use  ioctl(0, TIOCGWINSZ
	-- but readline seems to zap the kernel's SIGWINCH handler :-(
	width     = os.getenv('COLUMNS')
	height    = os.getenv('LINES')
	if width and height then
		-- _debug('GetTerminalSize: using getenv')
		return tonumber(width), tonumber(height), 0, 0
	end

	if T then  -- do we have the terminfo module ?
		-- _debug('GetTerminalSize: using terminfo')
		return T.get('cols'), T.get('lines'), 0, 0
	end

	local tput = which('tput')  -- do we have tput ?
	if tput then
		-- _debug('GetTerminalSize: using tput')
		local p = io.popen(tput..' cols','r')
		if p then width = p:read('*n'); p:close() end
		local p = io.popen(tput..' lines','r')
		if p then height = p:read('*n'); p:close() end
		if width and width>0.5 and height and height>0.5 then
			return width, height, 0, 0
		end
	end

	local we_have_resize = false  -- do we have resize ?
	local resize = '/usr/bin/resize'
	if exists(resize) then we_have_resize=true
	else
		resize = '/usr/openwin/bin/resize'  -- solaris ?
		if exists(resize) then we_have_resize=true end
	end
	if we_have_resize then
		-- _debug('GetTerminalSize: using resize')
		local p = io.popen(resize..' 2>/dev/null', 'r')
		if p then
			local o = p:read('*all'); p:close()
			if not width  or width  < 0.5 then
				width  = tonumber(string.match(o,"COLUMNS[ =]+(%d+)"))
			end
			if not height or height < 0.5 then
				height = tonumber(string.match(o,"LINES[ =]+(%d+)"))
			end
			return width, height, 0, 0
		end
	end

	if not width  or width  < 0.5 then width  = 80 end
	if not height or height < 0.5 then height = 25 end
	return width, height, 0, 0
end

function M.SetTerminalSize( width, height, xpix, ypix, filedescriptor )
	-- don't do this.
	return nil
end

function M.GetSpeeds( file )
	local inspeed  = nil
	local outspeed = nil
	return inspeed, outspeed
end

function M.GetControlChars( file )
	local fd = descriptor2fd(file)
	local attrs = P.tcgetattr(fd)
	local system_cc = attrs['cc']
	-- print('system_cc = '..DataDumper(system_cc))
	local posix_cc  = {}
	for k,v in pairs(system_cc) do
		if num2ccname[k] then
			if k == P.VTIME or k == P.VMIN then
				posix_cc[num2ccname[k]] = tonumber(v)
			else
				posix_cc[num2ccname[k]] = string.char(v)
			end
		end
	end
	return posix_cc
end

function M.SetControlChars( new_ccs, file )
	local fd = descriptor2fd(file)
	if new_ccs == {} then return nil end
	local current_mode = CurrentMode[fd] or 0
	for k,v in pairs(new_ccs) do
		if ccname2num[k] then
			if k ~= 'MIN' and k ~= 'TIME' then
				v = tostring(v)  -- should extract first char ?
			else
				if type(v)=='number' then
					v = string.char(v)
				else
					v = tostring(v)  -- should extract first char ?
				end
			end
			SaveAttr[fd][current_mode]['cc'][ccname2num[k]] = v
		else
			die('SetControlChars: unrecognised cc name '..tostring(k))
		end
	end
	M.ReadMode(current_mode, fd)
	return nil
end

return M

--[[

=pod

=head1 NAME

readkey.lua - simple terminal control, like CPAN's Term::ReadKey

=head1 SYNOPSIS

 local K = require 'readkey'
 local P = require 'posix'
 local tty = io.open(P.ctermid(), 'a+') -- the controlling terminal
 K.ReadMode( 4, tty )  -- Turn off controls keys
 local key
 while true do
      key = K.ReadKey( -1, tty )
      if key then break end
      do_something_else_meanwhile()  -- no key yet...
 end
 print("You pressed key: "..key)
 K.ReadMode( 0, tty ) -- Reset tty mode before exiting

=head1 DESCRIPTION

This Lua module is dedicated to providing simple
control over terminal modes (cbreak, raw, cooked, etc.),
and support for non-blocking reads,
and some handy functions for working with terminals.

This module started as a re-expression in Lua of
the I<Term::ReadKey> Perl module by Kenneth Albanowski and Jonathan Stowe.
The calling interface is similar,
except that I<ReadLine()> has quite different functionality,
and I<SetTerminalSize()> and I<GetSpeeds()> are not implemented.

=head1 FUNCTIONS

=over 4

=item ReadMode( mode [, filehandle] )

Takes an integer argument, which can be one of the following 
values:

  0  Restore original settings
  1  Change to cooked mode
  2  Change to cooked mode with echo off  (Good for passwords)
  3  Change to cbreak mode
  4  Change to raw mode
  5  Change to ultra-raw mode  (LF to CR/LF translation turned off) 

Or, you may use the synonyms: 

  'restore', 'normal', 'noecho', 'cbreak', 'raw', 'ultra-raw'

These functions are automatically applied to I<io.stdin> if no
other filehandle is supplied.
Mode 0 not only restores original settings, but it will cause
the next I<ReadMode> call to save a new set of default settings.
Mode 5 is similar to mode 4, except no CR/LF translation is performed,
and, if possible, parity will be disabled.

If you are executing another program that may be changing the terminal mode,
you will either want to say

    local tty = io.open(P.ctermid(), 'a+')
    K.ReadMode(1, tty)
    ...
    os.execute('someprogram')
    K.ReadMode(1, tty)

which resets the settings after the program has run, or:

    somemode = 1
    K.ReadMode(0)
    os.execute('someprogram')
    K.ReadMode(1)

which records any changes the program may have made, before resetting the
mode.

=item ReadKey( mode [, filehandle] )

Takes an integer argument, which can be one of the following values:

     0   Perform a normal read using getc
    -1   Perform a non-blocked read
    >0   Perform a timed read

If I<mode> is zero, I<ReadKey()> will wait for input, like a normal I<getc()>
(since version 1.2,
if the I<filehandle> has been set to I<raw> or I<ultra-raw>,
the underlying I<read()> call is restarted after any interrupt).
If I<mode> is less than zero, 
I<ReadKey> will return I<nil> immediately
unless a character is waiting in the buffer.
If I<mode> is greater than zero, then I<ReadKey> will use it
as a timeout value in seconds (fractional seconds are allowed),
and won't return I<nil> until that time expires.

If the filehandle is not supplied, it will default to STDIN.


=item ReadLine( prompt, histfile )

The syntax of this call is nothing like that of its Perl equivalent.
It invokes the GNU Readline and History libraries,
which display the I<prompt>, allow Tab-Filename-Completion,
and optionally save the line entered onto the end of the I<histfile>,
whose contents are available by the Up-Arrow. For example:

 local str = K.ReadLine('Delete which file ? ', '~/.filemanager_history')

If the I<histfile> parameter is I<nil>, the Up and Down Arrows
will not work, and no history-file will be created.

=item GetTerminalSize( [filehandle] )

Returns four numbers:
the width and height of the terminal in characters,
and the width and height in pixels.

Since version 1.2, I<xwininfo -id $WINDOWID> is used if possible,
since it returns up-to-date information even after I<ReadLine()>
has been invoked.

If I<xwininfo> is not available, various other means are tried,
which all fail to respond to size-changes that occur after
I<ReadLine()> has been invoked;
also the pixel sizes are returned as zero (they would need
the I<ioctl> command with the non-POSIX I<TIOCGWINSZ> parameter).

=item GetControlChars( [filehandle] )

Returns a table containing key/value pairs.
Each key is the name of the control-character/signal,
and its value is that character, as a single character,
except for MIN and TIME, which are integers.

Each key will be an entry from the following list:

    DISCARD EOF EOL EOL2 ERASE ERASEWORD INTERRUPT KILL
    MIN QUIT QUOTENEXT REPRINT START STOP SUSPEND TIME

The keys SWITCH and STATUS,
which are supported by the Term::ReadKey CPAN module,
are not present here because they are not specified by POSIX.

Thus, the following will give you the current interrupt character:

    local keys = K.GetControlChars()
    interrupt_char = keys['INTERRUPT']

=item SetControlChars( new_ccs [, filehandle] )

Takes a table containing key/value pairs.
Each key should be the name of a legal control-character or signal,
and its value should be either a single character,
or a number in the range 0-255.
I<SetControlChars> may die with a runtime error if an invalid
character name is passed or there is an error changing the settings.
The list of valid names is the keys of I<GetControlChars()>

=back

=head1 DOWNLOAD

This module is available as a LuaRock in
http://luarocks.org/repositories/rocks/index.html#readkey
so you should be able to install it with the command:

 $ su
 Password:
 # luarocks install readkey

or:

 # luarocks install http://www.pjb.com.au/comp/lua/termreadkey-1.2-0.rockspec

The Perl module is available from CPAN at
http://search.cpan.org/perldoc?Term::ReadKey

=head1 CHANGES

 20131021 1.2 xwininfo lets GetTerminalSize work even after ReadLine
 20131021     ReadKey restarts the P.read() after any EINTR interrupt
 20131005 1.1 GetTerminalSize returns numbers, ReadMode no longer sets ISTRIP
 20130922 1.0 first working version

=head1 AUTHOR

This Lua module is by Peter Billam,
see http://www.pjb.com.au/comp/contact.html

=head1 SEE ALSO

 http://search.cpan.org/perldoc?Term::ReadKey
 http://www.pjb.com.au/comp/lua/termreadkey.html
 http://luarocks.org/repositories/rocks/index.html#readkey
 http://www.pjb.com.au/comp/lua/terminfo.html
 http://luarocks.org/repositories/rocks/index.html#terminfo
 http://www.pjb.com.au/comp/lua/readline.html
 http://luarocks.org/repositories/rocks/index.html#readline
 http://luarocks.org/repositories/rocks/index.html#luaposix

=cut

]]
