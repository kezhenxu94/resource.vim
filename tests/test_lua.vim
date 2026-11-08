" The Lua API, Neovim only.
if !has('nvim')
  finish
endif

lua << LUA
local resource = require("resource")
_G.test_calls = {}

resource.register({
  name = "luaish",
  parse = function(name)
    local parts = resource.parse(name)
    return { kind = parts.segments[1] or "" }
  end,
  load = function(rbuf)
    if rbuf.kind == "text" then
      resource.set_lines(rbuf, { "some", "text" })
      return nil
    end
    return resource.job({ "sh", "-c", "echo one; echo two" }, {
      on_exit = function(code, stdout)
        local rows = {}
        for name in stdout:gmatch("%S+") do
          table.insert(rows, { row = { name, "x" }, item = { name = name } })
        end
        resource.render(rbuf, {
          headers = { "NAME", "VALUE" },
          rows = rows,
          editable = {
            VALUE = function(_, item, old, new)
              return { { title = item.name .. " " .. old .. " → " .. new, run = function()
                table.insert(_G.test_calls, "set " .. item.name .. " " .. new)
                return resource.job({ "echo", "ok" }, {})
              end }, "" }
            end,
          },
        })
      end,
    })
  end,
  delete = function(_, item)
    return { title = "Delete " .. item.name, run = function()
      table.insert(_G.test_calls, "delete " .. item.name)
    end }
  end,
  operations = function(rbuf, items)
    return { { title = "Count", run = function() table.insert(_G.test_calls, "count " .. #items) end } }
  end,
  keymaps = {
    show = { lhs = "gx", desc = "show the item", run = function(rbuf)
      table.insert(_G.test_calls, "show " .. resource.item(rbuf).name)
    end },
  },
})

-- Empty tables are lists in Vimscript
resource.register({
  name = "luaempty",
  parse = function() return {} end,
  load = function(rbuf) resource.set_lines(rbuf, { "empty" }, {}) return {} end,
  keymaps = {},
})
LUA

function! SetUp() abort
  lua _G.test_calls = {}
endfunction

function! TearDown() abort
  call RestoreStubs()
  call CleanBuffers()
endfunction

function! Test_lua_provider_renders_tables_and_text() abort
  call Open('luaish://list')
  call assert_equal(['one   x    ', 'two   x    '], Lines())
  call assert_equal('two', resource#item(bufnr(), 2).name)
  call Open('luaish://text')
  call assert_equal(['some', 'text'], Lines())
endfunction

function! Test_lua_provider_keymaps_operations_and_writes() abort
  call AnswerYes()
  call Open('luaish://list')
  normal 2Ggx
  call assert_equal(['show two'], luaeval('_G.test_calls'))
  normal gra
  call assert_equal(['show two', 'count 1'], luaeval('_G.test_calls'))
  call WaitLoaded()
  normal ggdd
  call cursor(1, 7)
  normal rY
  let messages = CaptureNotify()
  write
  call assert_equal(['show two', 'count 1', 'set two Y', 'delete one'], luaeval('_G.test_calls'))
  call WaitFor({-> !empty(messages)}, 'the message')
  call assert_equal([{'msg': 'ok', 'level': 'info'}], messages)
endfunction

function! Test_lua_empty_tables() abort
  call Open('luaempty://x')
  call assert_equal(['empty'], Lines())
endfunction

function! Test_lua_module_calls_the_autoload_functions() abort
  call assert_equal('a%2fb', luaeval('require("resource").uri_encode("a/b")'))
  call assert_equal([0, "a\n"], luaeval('require("resource").system({"echo", "a"}, 1000)'))
endfunction
