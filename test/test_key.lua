#! /usr/bin/lua
local M = require 'readkey'
local P = require 'posix'
require 'DataDumper'

--------------------------- infrastructure -----------------------
local eps = .000000001
function equal(x, y)  -- unused here
    if #x ~= #y then return false end
    local i; for i in pairs(x) do
        if math.abs(x[i]-y[i]) > eps then return false end
    end
    return true
end
-- use Test::Simple tests => 6;
local Test = 73 ; local i_test = 0; local Failed = 0;
function ok(b,s)
    i_test = i_test + 1
    if b then
        io.write('ok '..i_test..' - '..s.."\n")
		return true
    else
        io.write('not ok '..i_test..' - '..s.."\n")
        Failed = Failed + 1
		return false
    end
end

local function get_dict_of_attributes (attributes)
	local dict_of_attributes = {}
	local err_fn = os.tmpname()
	local pipe = assert(io.popen('stty -a 2>'..err_fn, 'r'))
	local stty_output = pipe:read('*all')
	err_fh = assert(io.open(err_fn))
	local err_msg = err_fh:read('*all')
	err_fh:close()  -- 4.8
	os.remove(err_fn)
	pipe:close()
	-- split stty_output into words and put each word in the dict
	for w in string.gmatch(stty_output, '([-%l%d]+)') do
		dict_of_attributes[w] = true
	end
	-- os.execute('stty -a')
	return dict_of_attributes
end
local function qw(s)  -- t = qw([[ foo  bar  baz ]])
    local t = {}
	for x in s:gmatch("([-%s]+)") do t[#t+1] = x end
	return t
end

local function current_state()
	local pipe = assert(io.popen('stty -a', 'r'))
	local stty_output = pipe:read('*all')
	pipe:close()
	return string.gsub(stty_output, 'line%s*=%s*%d+', '')
end

local initial_state = current_state()
local tty = io.open(P.ctermid(), 'a+')
M.ReadMode(0, tty)
local stty_save = get_dict_of_attributes()
ok(stty_save['opost'], 'ReadMode(0) opost')

M.ReadMode(1, tty)
local stty_a = get_dict_of_attributes()
-- print("stty_a="..DataDumper(stty_a))
ok(stty_a['opost'], 'ReadMode(1) opost')
words = {'brkint','ignpar','icrnl','ixon','opost','isig','icanon'}
for k,w in ipairs(words) do
	ok(stty_a[w], 'ReadMode(1) '..w)
end

M.ReadMode(2, tty)
stty_a = get_dict_of_attributes()
words = {
	'brkint','ignpar','icrnl','ixon','opost','isig','icanon',
	'-echo','-echoe','-echok','-echoctl','-echoke',
}
for k,w in ipairs(words) do
	ok(stty_a[w], 'ReadMode(2) '..w)
end

M.ReadMode(3, tty)
stty_a = get_dict_of_attributes()
words = {
	'brkint','ignpar','icrnl','ixon','opost','isig',
	'-icanon','-echo','-echoe','-echok','-echoctl','-echoke',
}
for k,w in ipairs(words) do
	ok(stty_a[w], 'ReadMode(3) '..w)
end

M.ReadMode(4, tty)
stty_a = get_dict_of_attributes()
ok(stty_a['opost'], 'ReadMode(4) opost')
words = {
	'brkint','ignpar','icrnl','-ixon','opost','-isig',
	'-icanon','-iexten','-echo','-echoe','-echok','-echoctl','-echoke',
}
for k,w in ipairs(words) do
	ok(stty_a[w], 'ReadMode(4) '..w)
end

M.ReadMode(5, tty)
stty_a = get_dict_of_attributes()
words = {
	'brkint','ignpar','-icrnl','-ixon','-opost','-onlcr','-isig',
	'-icanon','-iexten','-echo','-echoe','-echok','noflsh','-echoctl','-echoke',
}
for k,w in ipairs(words) do
	ok(stty_a[w], 'ReadMode(5) '..w.."\r")
end

M.ReadMode(0, tty)
local final_state = current_state()
if not ok(final_state == initial_state, 'ReadMode(0) restored') then
	print('initial_state = '..initial_state)
	print('  final_state = '..  final_state)
end

local ccs = M.GetControlChars()
local nccs = 0
for k,v in pairs(ccs) do nccs = nccs+1 end
if not ok(nccs > 15, 'GetControlChars returns '..tostring(nccs)..' ccs') then
	print(DataDumper(ccs))
end

local width, height, px, py = M.GetTerminalSize()
local stty_w = tonumber(string.match(initial_state, 'columns (%d+)'))
local stty_h = tonumber(string.match(initial_state, 'rows (%d+)'))
if not ok(width == stty_w,
  'GetTerminalSize returned width = '..tostring(stty_w)) then
	print(' width='..width..' stty_w='..stty_w)
end
if not ok(height == stty_h,
  'GetTerminalSize returned height = '..tostring(stty_h)) then
	print(' height='..height..' stty_h='..stty_h)
end

c = M.ReadKey(-1)
ok(c == nil, 'poll for input returns nil')

print('DO NOT TYPE ANYTHING; read should timeout after 3 seconds:')
M.ReadMode(4)
c = M.ReadKey(3.0)
M.ReadMode(0)
if not ok(c == nil, 'ReadKey(3.0) returned nil after 3 seconds') then
	print('  c = "'..tostring(c)..'"')
end

M.ReadMode(4)
print('Now some interactive tests:  TYPE ONE CHARACTER:')
local c = M.ReadKey(0)
M.ReadMode(0)
print('  you typed '..c)

print('type ANOTHER CHARACTER within the next 3 seconds:')
M.ReadMode(4)
P.sleep(3.0)
c = M.ReadKey(-1)
M.ReadMode(0)
print('  you typed '..c)

print('type YET ANOTHER character within the next 3 seconds:')
M.ReadMode(4)
c = M.ReadKey(3.0)
M.ReadMode(0)
print('  you typed '..tostring(c))

print('Now testing ReadLine() ...');
print('Please make all answers longer than two characters !')
local histfile = '/tmp/test_key_history'
local s1 = M.ReadLine('Please enter something: ', histfile)
if not ok(type(s1)=='string', "ReadLine returned "..s1) then
    print('xc='..tostring(xc)..' xv='..tostring(xv))
end
local s2 = M.ReadLine('this time Up-arrow should work: ', histfile)
local s3 = M.ReadLine('enter a filename and test Tab-completion: ', histfile)
local s4 = M.ReadLine('this time Up-arrow should not work: ')

if Failed == 0 then
    print('Passed all '..i_test..' tests :-)')
else
    print('Failed '..Failed..' tests out of '..i_test)
end
print('\nIf you now run test_key.lua again, those answers should appear')
print('in your history-file and be accessible with the Up-Arrow key...')
os.exit()
