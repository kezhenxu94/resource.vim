" vim9script drives the autoload API directly, Vim only.
if !has('vim9script')
  finish
endif
execute 'source' fnameescape(expand('<sfile>:p:h') . '/vim9_provider.vim')

function! TearDown() abort
  call RestoreStubs()
  call CleanBuffers()
endfunction

function! Test_vim9_provider() abort
  call Open('nine://list')
  call assert_equal(['a  1', 'b  2'], Lines())
  call assert_match('N  V', resource#compat#header(win_getid()))
  call g:Vim9Checks()
endfunction
