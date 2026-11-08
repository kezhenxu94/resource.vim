function! s:error(Fn) abort
  try
    call a:Fn()
  catch
    return v:exception
  endtry
  return ''
endfunction

function! TearDown() abort
  call RestoreStubs()
  call CleanBuffers()
endfunction

" ------------------------------------------------------------------ names

function! Test_name_and_parse_round_trip() abort
  let name = resource#name('fake', ['ctx', resource#uri_encode('a/b:c'), 'things'], {'z': 'last', 'follow': v:true, 'off': v:false})
  call assert_equal('fake://ctx/a%2fb%3ac/things?follow=true&off=false&z=last', name)
  let parts = resource#parse(name)
  call assert_equal({'scheme': 'fake', 'segments': ['ctx', 'a%2fb%3ac', 'things'],
        \ 'params': {'follow': v:true, 'off': v:false, 'z': 'last'}}, parts)
  call assert_equal('a/b:c', resource#uri_decode(parts.segments[1]))
  call assert_equal({'scheme': 'fake', 'segments': [], 'params': {'flag': v:true}}, resource#parse('fake://?flag'))
endfunction

function! Test_uri_encode_bytes() abort
  call assert_equal('ctx%2fa%3ab%c3%a4', resource#uri_encode('ctx/a:bä'))
  call assert_equal('ctx/a:bä', resource#uri_decode('ctx%2fa%3Ab%c3%a4'))
endfunction

function! Test_open_escapes_names() abort
  call SetItems('things', g:things)
  call resource#open('fake://things?owner=a%20b#x')
  call assert_equal('fake://things?owner=a%20b#x', bufname())
endfunction

" ------------------------------------------------------------------ providers

function! Test_register_requires_the_name_parse_and_load() abort
  call assert_equal('resource: the provider has no parse', s:error({-> resource#register({'name': 'x', 'load': {-> 0}})}))
endfunction

function! Test_config_g_variables_over_provider_defaults_over_core_defaults() abort
  call assert_equal(42, resource#config('fake', 'answer'))
  call assert_equal(200, resource#config('fake', 'refresh_interval'))
  call assert_equal(10000, resource#config('fake', 'logs_max_lines'))
  let g:fake_answer = 7
  call assert_equal(7, resource#config('fake', 'answer'))
  unlet g:fake_answer
  call assert_equal(v:null, resource#config('fake', 'nope'))
endfunction

function! Test_highlights_link_by_default_and_g_highlights_override() abort
  call assert_equal('Title', synIDattr(synIDtrans(hlID('FakeHeader')), 'name'))
  " The first group that exists
  call assert_equal('ErrorMsg', synIDattr(synIDtrans(hlID('FakeBad')), 'name'))
  call assert_equal('E', trim(sign_getdefined('FakeSignError')[0].text))
  let g:fake_highlights = {'FakeHeader': 'cterm=bold ctermfg=1'}
  try
    doautocmd ColorScheme
    call assert_equal('1', synIDattr(hlID('FakeHeader'), 'fg', 'cterm'))
  finally
    unlet g:fake_highlights
  endtry
endfunction

function! Test_a_second_provider() abort
  call resource#register({'name': 'other', 'parse': {name -> {}}, 'load': {rbuf -> resource#set_lines(rbuf, ['other'])}})
  edit other://x
  call assert_equal(['other'], Lines())
  call assert_equal('other', resource#get(bufnr()).scheme)
endfunction

" ------------------------------------------------------------------ jobs

function! Test_job_calls_on_exit_with_the_output() abort
  let result = []
  let job = resource#job(['sh', '-c', 'echo out; echo err >&2; exit 3'], {'on_exit': {... -> add(result, a:000)}})
  call WaitFor({-> !empty(result)}, 'the job')
  call assert_equal([[3, "out\n", "err\n"]], result)
  call assert_false(resource#running(job))
endfunction

function! Test_job_streams_the_output() abort
  let chunks = []
  call resource#job(['sh', '-c', 'echo a; sleep 0.1; echo b'], {'on_stdout': {chunk -> add(chunks, chunk)}})
  call WaitFor({-> len(chunks) == 2}, 'the chunks')
  call assert_equal(["a\n", "b\n"], chunks)
endfunction

function! Test_killed_jobs_do_not_call_back_timed_out_ones_do() abort
  let called = []
  let job = resource#job(['sleep', '5'], {'on_exit': {... -> add(called, a:000)}})
  " A copy, as from Lua
  call resource#kill(copy(job))
  call WaitFor({-> !resource#running(job)}, 'the job to end')
  sleep 50m
  call assert_equal([], called)
  let job = resource#job(['sleep', '5'], {'timeout': 50, 'on_exit': {code, ... -> add(called, code)}})
  call WaitFor({-> !empty(called)}, 'the timeout')
  call assert_equal([124], called)
  " Lists, and nothing to kill
  call assert_false(resource#running([job, {}]))
  call resource#kill([job, {}])
endfunction

function! Test_jobs_that_cannot_start() abort
  let messages = CaptureNotify()
  call assert_equal({}, resource#job(['no-such-command-xyz'], {}))
  call assert_equal('Failed to run no-such-command-xyz', messages[0].msg)
endfunction

function! Test_system() abort
  call assert_equal([0, "a\n"], resource#system(['sh', '-c', 'echo a'], 1000))
  call assert_equal([2, ''], resource#system(['sh', '-c', 'exit 2'], 1000))
  call assert_equal(-1, resource#system(['sleep', '5'], 100)[0])
endfunction

" ------------------------------------------------------------------ logs

function! Test_logs_show_stdout_and_stderr_and_can_be_edited() abort
  let g:fake_logs = 'echo out; echo err >&2; exit 1'
  call Open('fake://things/alpha/logs')
  call assert_equal(['out', 'err'], Lines())
  call assert_equal('nofile', &buftype)
  call assert_equal(1, &modifiable)
endfunction

function! Test_logs_followed_append_complete_lines_until_stopped() abort
  let g:fake_logs = 'printf "a\nb"; sleep 0.2; printf "c\nd\n"; sleep 30'
  edit fake://things/alpha/logs?follow
  call WaitFor({-> getline(1, '$') == ['a', 'bc', 'd', '']}, 'the lines, got ' . string(getline(1, '$')))
  call assert_equal([4, 'Waiting for new logs... (Ctrl+C to stop)'], resource#compat#status(bufnr()))
  call assert_true(resource#loading(bufnr()))
  execute "normal \<C-c>"
  call assert_false(resource#loading(bufnr()))
  call assert_match('^Stopped following logs', Status())
endfunction

function! Test_logs_followed_keep_the_last_lines() abort
  let g:fake_logs_max_lines = 3
  try
    let g:fake_logs = 'for i in 1 2 3 4 5; do echo $i; sleep 0.05; done'
    edit fake://things/alpha/logs?follow
    call WaitFor({-> getline(1, '$') == ['3', '4', '5', '']}, 'the last lines, got ' . string(getline(1, '$')))
  finally
    unlet g:fake_logs_max_lines
  endtry
endfunction

" ------------------------------------------------------------------ prompts

function! Test_confirm_select_and_input_are_deferred() abort
  let result = []
  call resource#confirm('Sure?', {yes -> add(result, yes)})
  call assert_equal([], result)
  call feedkeys("1\<CR>", 't')
  call WaitFor({-> !empty(result)}, 'the answer')
  call assert_equal([1], result)
  call resource#select(['a', 'b'], {'format_item': {item -> toupper(item)}}, {item, index -> add(result, [item, index])})
  call feedkeys("2\<CR>", 't')
  call WaitFor({-> len(result) == 2}, 'the choice')
  call assert_equal(['b', 2], result[1])
  call resource#input({'prompt': 'Name: ', 'default': 'x'}, {value -> add(result, value)})
  call feedkeys("y\<CR>", 't')
  call WaitFor({-> len(result) == 3}, 'the input')
  call assert_equal('xy', result[2])
endfunction

function! Test_float_hover_closes_when_the_cursor_moves() abort
  call setline(1, ['a', 'b'])
  let win = resource#float(['hello'])
  call assert_equal([[win, ['hello']]], resource#compat#floats())
  if has('nvim')
    normal j
    doautocmd CursorMoved
    call assert_equal([], resource#compat#floats())
  else
    call popup_close(win)
  endif
endfunction

function! Test_state_dir() abort
  call assert_equal(has('nvim') ? stdpath('state') : $XDG_STATE_HOME . '/vim', resource#state_dir())
endfunction
