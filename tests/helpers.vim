" Helpers of the tests: the items of the fake provider (tests/autoload/fake.vim),
" waiting, prompts and messages.

function! SetItems(kind, items) abort
  call writefile([json_encode(a:items)], $FAKE_DIR . '/' . a:kind . '.json')
endfunction

let g:things = [
      \ {'name': 'alpha', 'status': 'ok', 'owner': 'zed', 'age': '1m'},
      \ {'name': 'beta', 'status': 'bad', 'owner': '', 'age': '2m'},
      \ {'name': 'gamma', 'status': 'ok', 'owner': 'zed', 'age': '3m'},
      \ {'name': 'keep', 'status': 'bad', 'owner': '', 'age': '4m'},
      \ ]

" Wait until Cond() is true, fail after timeout milliseconds (5000 by default).
function! WaitFor(Cond, what, ...) abort
  let timeout = get(a:, 1, 5000)
  let start = reltime()
  while !a:Cond()
    if reltimefloat(reltime(start)) * 1000 > timeout
      throw 'timed out waiting for ' . a:what
    endif
    sleep 10m
  endwhile
endfunction

function! WaitBufName(name) abort
  call WaitFor({-> bufname() ==# a:name}, 'buffer ' . a:name . ', current: ' . bufname())
endfunction

" Wait for the current buffer to finish loading.
function! WaitLoaded() abort
  let buf = bufnr()
  call WaitFor({-> !empty(resource#get(buf)) && !resource#loading(buf)}, 'buffer to load')
  " Let the callbacks run
  sleep 20m
endfunction

function! Open(name) abort
  execute 'edit' fnameescape(a:name)
  call WaitLoaded()
endfunction

" Answer the prompts of resource#select() with Answer(items, prompt), the
" index of the choice, -1 to cancel. Returns the prompts: [{prompt, items}].
function! AnswerPrompts(Answer) abort
  let g:test_prompts = []
  let g:TestAnswer = a:Answer
  function! resource#select(items, opts, Callback) abort
    call add(g:test_prompts, {'prompt': get(a:opts, 'prompt', ''), 'items': a:items})
    let i = g:TestAnswer(a:items, get(a:opts, 'prompt', ''))
    call a:Callback(i < 0 ? v:null : a:items[i], i < 0 ? v:null : i + 1)
  endfunction
  return g:test_prompts
endfunction

" Answer Yes, the first item.
function! AnswerYes() abort
  return AnswerPrompts({items, prompt -> 0})
endfunction

" Capture the messages of resource#notify(): [{msg, level}].
function! CaptureNotify() abort
  let g:test_messages = []
  function! resource#notify(msg, ...) abort
    call add(g:test_messages, {'msg': a:msg, 'level': get(a:, 1, 'info')})
  endfunction
  return g:test_messages
endfunction

function! RestoreStubs() abort
  runtime autoload/resource.vim
endfunction

" Kill the jobs and wipe every buffer, leaving an empty one.
function! CleanBuffers() abort
  silent! %bwipeout!
  call WaitFor({-> empty(resource#buffers())}, 'resource buffers to be cleaned up')
endfunction

function! Lines() abort
  return getline(1, '$')
endfunction

" The status after a line, '' if none.
function! Status() abort
  return get(resource#compat#status(bufnr()), 1, '')
endfunction

" Move the cursor to the first occurrence of text and press keys.
function! PressOn(text, keys) abort
  call cursor(1, 1)
  if search('\V' . escape(a:text, '\'), 'cW') == 0
    throw 'line not found: ' . a:text
  endif
  execute 'normal' a:keys
endfunction
