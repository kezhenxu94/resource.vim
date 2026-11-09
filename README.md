# resource.vim

Edit any resource as a buffer: the core of Vim and Neovim plugins that show external resources as buffers, like [kube.nvim](https://github.com/kezhenxu94/kube.nvim) (Kubernetes) and [docker.nvim](https://github.com/kezhenxu94/docker.nvim).

A plugin registers a provider: a scheme, how to parse buffer names, how to load them. resource.vim does the rest:

* **Tables** with a header (the winbar in Neovim, the WinBar menu in Vim), rows and cells that follow edits, the cursor kept on the same item across reloads.
* **Editing**: delete lines and `:w` to delete the items, edit the cells of editable columns and `:w` to apply them, after confirming (`:w!` does not). Deleted lines stay visible until written.
* **Watching**: `gw` reloads a table periodically, highlighting the rows that changed.
* **Logs**, followed like `tail -f`, and **terminals** started from buffer names, like `term://`.
* **Diagnostics**: signs on unhealthy items, `]d` / `[d` and `<C-w>d`.
* **Tags**: `<C-]>` jumps to what the cell under the cursor refers to, `<C-t>` back.
* **Operations** (`gra`) on the item under the cursor or a visual selection, the parent buffer (`-`), reload (`R`), help (`g?`).
* **Jobs, prompts and floating windows** that work the same in Vim and Neovim.

## Installation

Requirements: Vim >= 9.1 or Neovim >= 0.11. You install it as the dependency of a plugin using it.

With Vim's packages (`:help packages`):

```sh
git clone https://github.com/kezhenxu94/resource.vim ~/.vim/pack/plugins/start/resource.vim
```

With Neovim's built-in plugin manager (`:help vim.pack`, Neovim >= 0.12), before the plugins using it:

```lua
vim.pack.add({ "https://github.com/kezhenxu94/resource.vim" })
```

## Writing a plugin

A provider listing the processes, delete lines and `:w` to kill them, `gra` to kill -9:

```vim
function! s:load(rbuf) abort
  return resource#job(['ps', 'axo', 'pid=,user=,comm='],
        \ {'on_exit': {code, out, err -> s:render(a:rbuf, out)}})
endfunction

function! s:render(rbuf, out) abort
  let rows = []
  for line in split(a:out, "\n")
    let [pid, user, command] = matchlist(line, '^\s*\(\d\+\)\s\+\(\S\+\)\s\+\(.*\)$')[1:3]
    call add(rows, {'row': [pid, user, command], 'item': {'name': pid, 'command': command}})
  endfor
  call resource#render(a:rbuf, {'headers': ['PID', 'USER', 'COMMAND'], 'rows': rows})
endfunction

call resource#register({
      \ 'name': 'ps',
      \ 'parse': {name -> {}},
      \ 'load': function('s:load'),
      \ 'label': {item -> item.name . ' ' . item.command},
      \ 'delete': {rbuf, item -> {'title': 'Kill ' . item.name, 'run': {-> resource#job(['kill', item.name], {})}}},
      \ 'operations': {rbuf, items -> [{'title': 'Kill -9',
      \   'run': {-> resource#run(rbuf, items, {item -> resource#job(['kill', '-9', item.name], {})},
      \     'Kill -9 ' . resource#describe(rbuf, items))}}]},
      \ })
```

The same provider in Lua, for Neovim (e.g. in `plugin/ps.lua`):

```lua
local resource = require("resource")

resource.register({
  name = "ps",
  parse = function() return {} end,
  load = function(rbuf)
    return resource.job({ "ps", "axo", "pid=,user=,comm=" }, {
      on_exit = function(_, stdout)
        local rows = {}
        for pid, user, command in stdout:gmatch("%s*(%d+)%s+(%S+)%s+([^\n]*)") do
          table.insert(rows, { row = { pid, user, command }, item = { name = pid, command = command } })
        end
        resource.render(rbuf, { headers = { "PID", "USER", "COMMAND" }, rows = rows })
      end,
    })
  end,
  label = function(item) return item.name .. " " .. item.command end,
  delete = function(_, item)
    return {
      title = "Kill " .. item.name,
      run = function() return resource.job({ "kill", item.name }, {}) end,
    }
  end,
  operations = function(rbuf, items)
    return {
      {
        title = "Kill -9",
        run = function()
          return resource.run(rbuf, items, function(item)
            return resource.job({ "kill", "-9", item.name }, {})
          end, "Kill -9 " .. resource.describe(rbuf, items))
        end,
      },
    }
  end,
})
```

Then `:e ps://`. The API is legacy Vimscript autoload functions (`resource#…`), which vim9script calls directly, and `require("resource")` wraps them for Lua in Neovim. See `:help resource-provider`, `:help resource-api`, `:help resource-vim9` and `:help resource-lua`.

## Contributing

* `make test`: Tests in headless Vim and Neovim against a fake provider (`tests/autoload/fake.vim`), `make test EDITORS=nvim` in one of them.
