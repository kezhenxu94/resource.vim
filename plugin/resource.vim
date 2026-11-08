" resource.vim: edit any resource as a buffer, the core of plugins that
" register a provider, see :help resource.vim
if exists('g:loaded_resource')
  finish
endif
let g:loaded_resource = 1

if has('nvim') ? !has('nvim-0.11') : !has('patch-9.1.0')
  echohl ErrorMsg
  echomsg 'resource.vim requires Vim >= 9.1 or Neovim >= 0.11'
  echohl None
  finish
endif

augroup resource
  autocmd!
  " Also for other buffers, to remove the table header of a window that showed one
  autocmd BufWinEnter * if exists('b:resource') || exists('w:resource_header')
        \ | call resource#buffer#on_win_enter(str2nr(expand('<abuf>'))) | endif
  autocmd WinScrolled * if exists('w:resource_header') | call resource#buffer#on_scroll() | endif
  if exists('##WinResized')
    autocmd WinResized * if exists('w:resource_header') | call resource#buffer#on_scroll() | endif
  endif
  autocmd ColorScheme * if exists('*resource#highlights') | call resource#highlights() | endif
  autocmd VimLeavePre * if exists('*resource#buffer#stop_all') | call resource#buffer#stop_all() | endif
augroup END
