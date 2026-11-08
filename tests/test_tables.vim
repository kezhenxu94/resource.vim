let s:things = 'fake://things'

function! SetUp() abort
  call SetItems('things', g:things)
  let s:messages = CaptureNotify()
endfunction

function! TearDown() abort
  call RestoreStubs()
  call CleanBuffers()
endfunction

function! Test_render_aligns_the_rows_under_the_header() abort
  call Open(s:things)
  call assert_equal(['alpha  ok      zed    1m ', 'beta   bad            2m ', 'gamma  ok      zed    3m ',
        \ 'keep   bad            4m '], Lines())
  call assert_match('NAME   STATUS  OWNER  AGE', resource#compat#header(win_getid()))
  call assert_equal('acwrite', &buftype)
  call assert_equal(0, &wrap)
  call assert_equal(0, &modified)
  call assert_equal(1, &modifiable)
endfunction

function! Test_render_is_stateful_items_and_cells() abort
  call Open(s:things)
  call assert_equal('beta', resource#item(bufnr(), 2).name)
  call assert_equal(['beta', 'gamma'], map(resource#items(bufnr(), 2, 3), 'v:val.name'))
  call assert_equal(v:null, resource#item(bufnr(), 9))
  call cursor(1, 17)
  call assert_equal({'item': g:things[0], 'column': 'OWNER', 'text': 'zed'}, resource#cell(bufnr()))
  " Between cells
  call assert_equal({'item': g:things[0], 'column': '', 'text': ''}, resource#cell(bufnr(), 1, 5))
endfunction

function! Test_render_items_follow_edits() abort
  call Open(s:things)
  normal ggdd
  call assert_equal('beta', resource#item(bufnr(), 1).name)
  undo
  call assert_equal('alpha', resource#item(bufnr(), 1).name)
endfunction

function! Test_render_shows_a_status_when_empty() abort
  call SetItems('things', [])
  call Open(s:things)
  call assert_equal('No things', Status())
endfunction

function! Test_render_truncates_long_cells() abort
  let [header, rows] = resource#table#format(['NAME', 'X'],
        \ [{'row': ['ä', repeat('y', 120)], 'item': {}}])
  call assert_equal('NAME  X' . repeat(' ', 98), header)
  call assert_equal('ä     ' . repeat('y', 96) . '...', rows[0].formatted)
  call assert_equal([[0, 5], [7, 106]], rows[0].ranges)
endfunction

function! Test_render_rows_without_items_are_not_rows() abort
  call Open(s:things)
  call resource#render(bufnr(), {'headers': ['A'], 'rows': [{'row': ['x']}, {'row': ['y'], 'item': {'name': 'y'}}]})
  call assert_equal(v:null, resource#item(bufnr(), 1))
  call assert_equal('y', resource#item(bufnr(), 2).name)
endfunction

function! Test_errors_are_shown_in_the_status_and_notified() abort
  call delete($FAKE_DIR . '/things.json')
  call Open(s:things)
  call assert_match('^✗ cat: ', Status())
  call assert_equal('error', s:messages[0].level)
endfunction

function! Test_reload_keeps_the_cursor_on_the_same_item() abort
  call Open(s:things)
  call cursor(3, 2)
  call SetItems('things', g:things[1:])
  normal R
  call WaitLoaded()
  call assert_equal(3, line('$'))
  call assert_equal([2, 2], [line('.'), col('.')])
  call assert_match('^gamma', getline('.'))
endfunction

function! Test_reload_while_loading_warns() abort
  call Open(s:things)
  call resource#track(bufnr(), resource#job(['sleep', '5'], {}))
  normal R
  call assert_equal({'msg': 'The buffer is currently being loaded', 'level': 'warn'}, s:messages[-1])
endfunction

function! Test_diagnostics_signs_and_keys() abort
  call Open(s:things)
  let signs = sign_getplaced(bufnr(), {'group': 'resource'})[0].signs
  call assert_equal([[2, 'FakeSignError'], [4, 'FakeSignError']], map(copy(signs), '[v:val.lnum, v:val.name]'))
  call cursor(1, 1)
  normal ]d
  call assert_equal(2, line('.'))
  normal ]d
  call assert_equal(4, line('.'))
  " Wrapping around
  normal ]d
  call assert_equal(2, line('.'))
  normal [d
  call assert_equal(4, line('.'))
  execute "normal \<C-w>d"
  let floats = resource#compat#floats()
  call assert_equal([['keep is bad']], map(copy(floats), 'v:val[1]'))
  call resource#compat#close_float(floats[0][0])
endfunction

function! Test_diagnostics_none() abort
  call SetItems('things', [g:things[0]])
  call Open(s:things)
  normal ]d
  call assert_equal({'msg': 'No diagnostics', 'level': 'warn'}, s:messages[-1])
endfunction

function! Test_highlights_of_cells() abort
  call Open(s:things)
  call assert_equal('ErrorMsg', synIDattr(synIDtrans(hlID('FakeBad')), 'name'))
  let cells = resource#compat#cells(bufnr())
  call assert_equal(16, len(cells))
  call assert_equal(['FakeBad', 'FakeBad', 'FakeEditable', 'FakeEditable'], sort(filter(map(values(cells), 'v:val[3]'), '!empty(v:val)')))
endfunction

function! Test_header_is_removed_from_windows_showing_other_buffers() abort
  call Open(s:things)
  call assert_notequal('', resource#compat#header(win_getid()))
  enew
  call assert_equal('', resource#compat#header(win_getid()))
endfunction

function! Test_header_follows_the_horizontal_scroll() abort
  call Open(s:things)
  normal 0zl
  doautocmd WinScrolled
  call assert_match('^AME', resource#buffer#header(win_getid()).text)
  " Still shown far to the right
  normal 0020zl
  doautocmd WinScrolled
  call assert_match('COMMAND\|OWNER\|AGE\|STATUS', resource#compat#header(win_getid()))
  call assert_equal(1, getwinvar(win_getid(), 'resource_header'))
endfunction
