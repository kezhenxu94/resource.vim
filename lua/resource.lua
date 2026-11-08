-- The Lua API of resource.vim for Neovim: resource.{name}(...) calls the
-- autoload function resource#{name}(...), Lua functions are callbacks.
-- See :help resource-lua.
return setmetatable({}, {
  __index = function(module, name)
    local fn = function(...)
      return vim.fn["resource#" .. name](...)
    end
    rawset(module, name, fn)
    return fn
  end,
})
