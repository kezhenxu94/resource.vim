let s:things = 'fake://things'

function! SetUp() abort
  call SetItems('things', g:things)
  let g:fake_calls = []
  let s:messages = CaptureNotify()
endfunction

function! TearDown() abort
  call RestoreStubs()
  call CleanBuffers()
endfunction

function! Test_write_deletes_the_items_of_deleted_rows_after_confirming() abort
  let prompts = AnswerYes()
  call Open(s:things)
  call PressOn('beta', 'dd')
  call PressOn('alpha', 'dd')
  write
  call assert_equal("Apply the changes (ctx: test)?\n  Delete alpha\n  Delete beta", prompts[0].prompt)
  call assert_equal(['delete alpha', 'delete beta'], g:fake_calls)
  call WaitFor({-> len(s:messages) == 2}, 'the messages')
  call assert_equal(['done: delete alpha', 'done: delete beta'], sort(map(copy(s:messages), 'v:val.msg')))
  " Reloaded once done
  call WaitFor({-> line('$') == 4}, 'the reload')
  call assert_equal(0, &modified)
endfunction

function! Test_write_bang_does_not_confirm() abort
  let prompts = AnswerYes()
  call Open(s:things)
  call PressOn('gamma', 'dd')
  write!
  call assert_equal([], prompts)
  call assert_equal(['delete gamma'], g:fake_calls)
  call WaitFor({-> !empty(s:messages)}, 'the message')
endfunction

function! Test_write_declined_keeps_the_edits() abort
  call AnswerPrompts({items, prompt -> 1})
  call Open(s:things)
  call PressOn('gamma', 'dd')
  write
  call assert_equal([], g:fake_calls)
  call assert_equal(1, &modified)
  call assert_equal(3, line('$'))
endfunction

function! Test_write_skips_items_that_cannot_be_deleted() abort
  let prompts = AnswerYes()
  call Open(s:things)
  call PressOn('keep', 'dd')
  write
  call assert_equal([], prompts)
  call assert_equal([], g:fake_calls)
  " Saved: reloaded
  call WaitFor({-> line('$') == 4}, 'the reload')
endfunction

function! Test_write_applies_the_edits_of_editable_cells() abort
  let prompts = AnswerYes()
  call Open(s:things)
  call cursor(1, 8)
  execute "normal ciwgood\<Esc>"
  write
  call assert_equal("Apply the changes (ctx: test)?\n  Set status of alpha: ok → good", prompts[0].prompt)
  call assert_equal(['status alpha good'], g:fake_calls)
  call WaitFor({-> !empty(s:messages)}, 'the message')
endfunction

function! Test_write_refuses_invalid_edits_and_cells_that_are_not_editable() abort
  call Open(s:things)
  call cursor(1, 8)
  execute "normal ciwB4D\<Esc>"
  call cursor(3, 1)
  execute "normal ciwrenamed\<Esc>"
  write
  call assert_equal([{'msg': "Invalid status: B4D\nNAME of thing gamma is not editable", 'level': 'error'}], s:messages)
  call assert_equal([], g:fake_calls)
  call assert_equal(1, &modified)
endfunction

function! Test_write_notifies_failures() abort
  call AnswerYes()
  call SetItems('things', [{'name': 'fail', 'status': 'ok'}])
  call Open(s:things)
  normal dd
  write
  call WaitFor({-> !empty(s:messages)}, 'the message')
  call assert_equal([{'msg': "Failed: Delete fail\nit failed", 'level': 'error'}], s:messages)
  " Reloaded anyway
  call WaitFor({-> line('$') == 1 && getline(1) =~# 'fail'}, 'the reload')
endfunction

function! s:write(rbuf, force) abort
  if !has_key(a:rbuf.params, 'custom')
    return 0
  endif
  call add(s:written, a:force)
  return 1
endfunction

function! Test_write_with_the_provider_write() abort
  let s:written = []
  call fake#register({'write': function('s:write')})
  try
    call Open(s:things . '?custom')
    normal dd
    write!
    call assert_equal([1], s:written)
    call assert_equal([], g:fake_calls)
    call assert_equal(1, &modified)
    " Lists fall back to the default
    call AnswerYes()
    call Open(s:things)
    call PressOn('beta', 'dd')
    write
    call assert_equal(['delete beta'], g:fake_calls)
    call WaitFor({-> !empty(s:messages)}, 'the message')
  finally
    call fake#register()
  endtry
endfunction

function! Test_deleted_rows_stay_visible_until_written() abort
  call Open(s:things)
  call PressOn('beta', 'dd')
  doautocmd TextChanged
  " Above the row that followed it
  call assert_equal([[2, ['beta   bad            2m '], 1]], resource#compat#get_virt_lines(bufnr()))
  normal Gdd
  doautocmd TextChanged
  " Below the last line without one
  call assert_equal([[2, ['beta   bad            2m '], 1], [2, ['keep   bad            4m '], 0]],
        \ resource#compat#get_virt_lines(bufnr()))
  call assert_equal('DiffDelete', synIDattr(synIDtrans(hlID('FakeDeleted')), 'name'))
endfunction

function! Test_deleted_items() abort
  call Open(s:things)
  call PressOn('gamma', 'dd')
  call PressOn('alpha', 'dd')
  call assert_equal(['alpha', 'gamma'], map(resource#deleted(bufnr()), 'v:val.name'))
endfunction

function! Test_text_views_are_not_written() abort
  call Open(s:things . '/alpha')
  call assert_equal(['name: alpha'], Lines())
  call assert_equal('nofile', &buftype)
  call assert_equal(0, &modifiable)
endfunction

" ------------------------------------------------------------------ operations

function! Test_operations_on_the_item_under_the_cursor() abort
  let prompts = AnswerPrompts({items, prompt -> 0})
  call Open(s:things)
  call PressOn('gamma', 'gra')
  call assert_equal([{'prompt': 'Operations:', 'items': ['Touch', 'Break']}], prompts)
  call assert_equal(['touch gamma'], g:fake_calls)
  call WaitFor({-> !empty(s:messages)}, 'the message')
  call assert_equal([{'msg': 'done: touch gamma', 'level': 'info'}], s:messages)
endfunction

function! Test_operations_on_a_visual_selection_confirmed() abort
  let prompts = AnswerPrompts({items, prompt -> items[0] ==# 'Yes' ? 0 : 1})
  call Open(s:things)
  call cursor(1, 1)
  normal Vjjgra
  call assert_equal('Break thing alpha, thing beta, thing gamma (ctx: test)?', prompts[1].prompt)
  call assert_equal(['touch alpha', 'touch beta', 'touch gamma'], g:fake_calls)
  call WaitFor({-> len(s:messages) == 3}, 'the messages')
endfunction

function! Test_operations_describe_more_than_3_items() abort
  call Open(s:things)
  call assert_equal('thing alpha, thing beta, thing gamma and 1 more', resource#describe(bufnr(), g:things))
endfunction

function! Test_operations_none() abort
  call Open(s:things . '/alpha')
  normal gra
  call assert_equal([{'msg': 'No operations', 'level': 'warn'}], s:messages)
endfunction
