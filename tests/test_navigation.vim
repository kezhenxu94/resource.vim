let s:things = 'fake://things'

function! SetUp() abort
  call SetItems('things', g:things)
  let s:messages = CaptureNotify()
endfunction

function! TearDown() abort
  call RestoreStubs()
  call CleanBuffers()
endfunction

function! Test_aliases_edit_the_canonical_buffer() abort
  call Open('fake://')
  call assert_equal(s:things, bufname())
  call Open('fake://alias/alpha')
  call assert_equal(s:things . '/alpha', bufname())
  " The aliases are wiped, never the alternate file
  call WaitFor({-> bufnr('fake://') == -1 && bufnr('fake://alias/alpha') == -1}, 'the aliases to be wiped')
  call assert_equal(s:things, bufname('#'))
endfunction

function! Test_invalid_names_are_notified() abort
  edit fake://nope
  call assert_equal([{'msg': 'No such fake', 'level': 'error'}], s:messages)
  call assert_equal({}, resource#get(bufnr()))
endfunction

function! Test_parent_goes_up() abort
  call Open(s:things . '/alpha')
  normal -
  call WaitBufName(s:things)
  " None
  normal -
  call assert_equal(s:things, bufname())
endfunction

function! Test_tags_jump_to_what_the_cell_refers_to_and_back() abort
  call Open(s:things)
  call cursor(3, 17)
  execute "normal \<C-]>"
  call WaitBufName(s:things . '?owner=zed')
  execute "normal \<C-t>"
  call WaitBufName(s:things)
  call assert_equal([3, 17], [line('.'), col('.')])
  call cursor(2, 1)
  execute "normal \<C-]>"
  call WaitBufName(s:things . '/beta')
endfunction

function! Test_tags_not_found() abort
  call SetItems('things', [{'name': 'notag', 'status': 'ok', 'owner': ''}])
  call Open(s:things)
  call cursor(1, 1)
  call assert_fails("execute \"normal \\<C-]>\"", 'E426:')
  call assert_equal(s:things, bufname())
endfunction

function! Test_tags_in_a_split() abort
  call Open(s:things)
  call PressOn('gamma', "\<C-w>]")
  call WaitBufName(s:things . '/gamma')
  call assert_equal(2, winnr('$'))
  execute "normal \<C-t>"
  call WaitBufName(s:things)
endfunction

function! Test_provider_keymaps() abort
  let g:fake_logs = 'printf "one\ntwo\n"'
  call Open(s:things)
  call PressOn('alpha', "\<CR>")
  call WaitBufName(s:things . '/alpha/logs')
  call WaitLoaded()
  call assert_equal(['one', 'two'], Lines())
endfunction

function! Test_keymaps_are_configurable() abort
  let g:fake_keymaps = {'parent': 'gp', 'watch': ''}
  try
    call Open(s:things . '/alpha')
    call assert_equal('', maparg('-', 'n'))
    call assert_equal('', maparg('gw', 'n'))
    normal gp
    call WaitBufName(s:things)
  finally
    unlet g:fake_keymaps
  endtry
endfunction

function! Test_help_lists_the_keymaps_and_the_provider_help() abort
  let lines = resource#buffer#help_lines(resource#provider('fake'))
  call assert_equal(['Keymaps',
        \ '  -        go to the parent buffer',
        \ '  <CR>     open the item',
        \ '  R        reload the things',
        \ '  g?       show this help',
        \ '  gra      operations on the item under the cursor, or the selected ones',
        \ '  gw       toggle reloading the list periodically',
        \ '', 'More in :help fake'], lines)
  call Open(s:things)
  normal g?
  let floats = resource#compat#floats()
  call assert_equal(lines, floats[0][1])
  call resource#compat#close_float(floats[0][0])
endfunction

function! Test_terminals() abort
  call Open(s:things)
  execute 'edit' s:things . '/alpha/shell'
  call WaitFor({-> &buftype ==# 'terminal'}, 'the terminal')
  call WaitFor({-> bufname() ==# s:things . '/alpha/shell'}, 'its name')
  call assert_equal({}, resource#get(bufnr()))
  call assert_equal(s:things, bufname('#'))
endfunction

" ------------------------------------------------------------------ watching

function! Test_watch_reloads_periodically_and_flashes_the_changed_rows() abort
  call Open(s:things)
  normal gw
  call assert_match('⟳ 0.2s', resource#compat#header(win_getid()))
  let changed = deepcopy(g:things)
  let changed[2].status = 'better'
  " A volatile column
  let changed[0].age = '9m'
  call SetItems('things', changed)
  let buf = bufnr()
  " The watched buffer is not current, Vim's Ex mode (-es) is never in Normal mode
  new
  call WaitFor({-> getbufline(buf, 3)[0] =~# 'better'}, 'the reload')
  call assert_equal([3], resource#compat#highlighted_lines(buf, 'changed'))
  close
  normal gw
  call assert_notmatch('⟳', resource#compat#header(win_getid()))
endfunction

function! Test_watch_indicator_in_seconds() abort
  let g:fake_refresh_interval = 10000
  try
    call Open(s:things)
    normal gw
    call assert_match('⟳ 10s $', resource#compat#header(win_getid()))
    normal gw
  finally
    unlet g:fake_refresh_interval
  endtry
endfunction

function! Test_watch_only_lists() abort
  call Open(s:things . '/alpha')
  normal gw
  call assert_equal([{'msg': 'Only lists can be watched', 'level': 'warn'}], s:messages)
endfunction

function! Test_watch_disabled() abort
  let g:fake_refresh_interval = 0
  try
    call Open(s:things)
    normal gw
    call assert_equal([{'msg': 'Watching is disabled, set g:fake_refresh_interval to enable it', 'level': 'warn'}], s:messages)
  finally
    unlet g:fake_refresh_interval
  endtry
endfunction

function! Test_unloaded_buffers_keep_their_state_deleted_ones_start_over() abort
  call Open(s:things)
  normal gw
  let buf = bufnr()
  enew
  execute 'bunload' buf
  call assert_equal(1, resource#get(buf).watch)
  execute 'buffer' buf
  call WaitLoaded()
  call assert_equal(1, resource#get(buf).watch)
  execute 'bdelete' buf
  call assert_equal({}, resource#get(buf))
endfunction
