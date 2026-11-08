" The API of resource.vim, see :help resource-api. Functions taking {rbuf}
" accept a buffer state, a copy of one (e.g. from Lua) or a buffer number.
" No state here, it is in autoload/resource/buffer.vim: tests stub these
" functions and source this file again to restore them.

" ---------------------------------------------------------------------------
" Providers

let s:CORE_HIGHLIGHTS = {
      \ 'Header': 'Title',
      \ 'Body': 'Normal',
      \ 'Deleted': 'DiffDelete',
      \ 'Changed': 'DiffChange',
      \ 'Editable': 'Identifier',
      \ 'SignError': ['DiagnosticSignError', 'ErrorMsg'],
      \ 'SignWarn': ['DiagnosticSignWarn', 'WarningMsg'],
      \ 'SignInfo': ['DiagnosticSignInfo', 'Comment'],
      \ }

" Register a provider, see :help resource-provider.
function! resource#register(provider) abort
  for key in ['name', 'parse', 'load']
    if !has_key(a:provider, key)
      throw 'resource: the provider has no ' . key
    endif
  endfor
  let provider = extend({'scheme': a:provider.name, 'title': a:provider.name, 'help': [], 'volatile': []}, a:provider)
  " An empty Lua table is a list
  for key in ['keymaps', 'highlights', 'defaults']
    let provider[key] = type(get(provider, key, 0)) == v:t_dict ? provider[key] : {}
  endfor
  call resource#buffer#add_provider(provider)
  call s:highlights(provider)
  let pattern = provider.scheme . '://*'
  execute 'augroup resource_' . provider.scheme
  autocmd!
  " Nested, so that the BufReadCmd of the buffer an alias redirects to runs
  execute 'autocmd BufReadCmd' pattern '++nested call resource#buffer#on_read(str2nr(expand("<abuf>")))'
  execute 'autocmd BufUnload' pattern 'call resource#buffer#on_unload(str2nr(expand("<abuf>")))'
  execute 'autocmd BufDelete,BufWipeout' pattern 'call resource#buffer#on_delete(str2nr(expand("<abuf>")))'
  execute 'autocmd BufWriteCmd' pattern 'call resource#buffer#on_write(str2nr(expand("<abuf>")), v:cmdbang)'
  execute 'autocmd TextChanged,TextChangedI' pattern 'call resource#buffer#on_text_changed(str2nr(expand("<abuf>")))'
  augroup END
endfunction

" The provider of {scheme}, {} if none.
function! resource#provider(scheme) abort
  return resource#buffer#provider(a:scheme)
endfunction

" The prefix of the highlight groups of a provider, its capitalized name.
function! resource#highlight_prefix(provider) abort
  return toupper(a:provider.name[0]) . a:provider.name[1:]
endfunction

" Link the highlights by default, so that colorschemes and :highlight take
" precedence, then apply g:{name}_highlights. A link to a list is to its first
" existing group.
function! s:highlights(provider) abort
  let prefix = resource#highlight_prefix(a:provider)
  let links = {}
  for [group, link] in items(s:CORE_HIGHLIGHTS)
    let links[prefix . group] = link
  endfor
  for [group, link] in items(extend(links, a:provider.highlights))
    let candidates = type(link) == v:t_list ? link : [link]
    let link = get(filter(copy(candidates), 'hlexists(v:val)'), 0, candidates[-1])
    execute 'highlight default link' group link
  endfor
  for [group, attributes] in items(get(g:, a:provider.name . '_highlights', {}))
    execute 'highlight' group attributes
  endfor
  for [severity, text] in [['Error', 'E'], ['Warn', 'W'], ['Info', 'I']]
    call sign_define(prefix . 'Sign' . severity, {'text': text, 'texthl': prefix . 'Sign' . severity})
  endfor
endfunction

" Set up the highlights again, e.g. after :colorscheme.
function! resource#highlights() abort
  for provider in resource#buffer#providers()
    call s:highlights(provider)
  endfor
endfunction

function! s:provider_of(rbuf) abort
  if type(a:rbuf) == v:t_string
    return get(filter(resource#buffer#providers(), 'v:val.name ==# a:rbuf'), 0, {})
  endif
  let rbuf = resource#buffer#resolve(a:rbuf)
  return empty(rbuf) ? {} : resource#buffer#provider(rbuf.scheme)
endfunction

let s:DEFAULTS = {'refresh_interval': 10000, 'logs_max_lines': 10000}

" The value of g:{name}_{key} of the provider of {rbuf} (or of the provider
" {rbuf}, a name), else its default.
function! resource#config(rbuf, key) abort
  let provider = s:provider_of(a:rbuf)
  return get(g:, provider.name . '_' . a:key, get(provider.defaults, a:key, get(s:DEFAULTS, a:key, v:null)))
endfunction

" ---------------------------------------------------------------------------
" Buffer names: {scheme}://{path}[?{params}]

" Percent-encode bytes other than RFC 2396 unreserved characters.
function! resource#uri_encode(text) abort
  return substitute(a:text, "[^A-Za-z0-9_.!~*'()-]", '\=s:encode(submatch(0))', 'g')
endfunction

function! s:encode(char) abort
  return join(map(range(len(a:char)), 'printf("%%%02x", char2nr(a:char[v:val]))'), '')
endfunction

function! resource#uri_decode(text) abort
  return substitute(a:text, '%\(\x\x\)', '\=eval(''"\x'' . submatch(1) . ''"'')', 'g')
endfunction

" A param value as in names: true, false or the text.
function! resource#to_string(value) abort
  if a:value is v:true || a:value is v:false
    return a:value ? 'true' : 'false'
  endif
  return type(a:value) == v:t_string ? a:value : string(a:value)
endfunction

" The name {scheme}://{segments joined by /}[?{params}], the params sorted.
function! resource#name(scheme, segments, ...) abort
  let params = get(a:, 1, {})
  let query = sort(map(items(params), 'v:val[0] . "=" . resource#to_string(v:val[1])'))
  return a:scheme . '://' . join(a:segments, '/') . (empty(query) ? '' : '?' . join(query, '&'))
endfunction

" Split a name: {scheme, segments, params}, the values of params are v:true
" for `key` and `key=true`, v:false for `key=false`.
function! resource#parse(name) abort
  let [scheme, path, query] = (matchlist(a:name, '^\([^:/]\+\)://\([^?]*\)?\=\(.*\)$') + ['', '', '', ''])[1:3]
  let params = {}
  for param in split(query, '&')
    let [key, value] = matchlist(param, '^\([^=]\+\)=\=\(.*\)$')[1:2]
    let params[key] = value ==# '' || value ==# 'true' ? v:true : value ==# 'false' ? v:false : value
  endfor
  return {'scheme': scheme, 'segments': split(path, '/'), 'params': params}
endfunction

" Edit the buffer {name} in the current window, typing in it if it is a
" terminal.
function! resource#open(name) abort
  " Escaped as % (from encoded names) and # are expanded by :edit
  execute 'edit' fnameescape(a:name)
  call resource#compat#term_enter()
endfunction

" ---------------------------------------------------------------------------
" Buffers

" The state of the buffer {buf}, {} if it is not a resource buffer.
function! resource#get(buf) abort
  return resource#buffer#get(a:buf)
endfunction

function! resource#buffers() abort
  return resource#buffer#all()
endfunction

" Reload the buffer. {opts}: silent, for background reloads.
function! resource#load(rbuf, ...) abort
  call resource#buffer#load(a:rbuf, get(a:, 1, {}))
endfunction

" Whether the buffer is loading: a job of resource#track() is running.
function! resource#loading(rbuf) abort
  return resource#buffer#loading(a:rbuf)
endfunction

" Count {job} as loading the buffer: it is killed with the buffer.
function! resource#track(rbuf, job) abort
  return resource#buffer#track(a:rbuf, a:job)
endfunction

" Render {table} in the buffer: {headers, rows, empty, editable}, see
" :help resource-render.
function! resource#render(rbuf, table) abort
  let rbuf = resource#buffer#resolve(a:rbuf)
  if !empty(rbuf)
    call resource#table#render(rbuf, a:table)
  endif
endfunction

" Replace the lines of the buffer, leaving it unmodified. {opts}: modifiable
" (0 by default), writable (whether :w writes it, 1 by default).
function! resource#set_lines(rbuf, lines, ...) abort
  let rbuf = resource#buffer#resolve(a:rbuf)
  if empty(rbuf) || !bufloaded(rbuf.bufnr)
    return
  endif
  let opts = get(a:, 1, {})
  let buf = rbuf.bufnr
  call resource#status(rbuf, '')
  call setbufvar(buf, '&buftype', get(opts, 'writable', 1) ? 'acwrite' : 'nofile')
  call setbufvar(buf, '&modifiable', 1)
  " Not undoable, undo would empty the buffer
  call setbufvar(buf, '&undolevels', -1)
  if len(getbufline(buf, 1, '$')) > len(a:lines)
    silent call deletebufline(buf, max([len(a:lines), 1]), '$')
  endif
  call setbufline(buf, 1, empty(a:lines) ? [''] : a:lines)
  call setbufvar(buf, '&undolevels', -123456)
  call setbufvar(buf, '&modifiable', get(opts, 'modifiable', 0) ? 1 : 0)
  call setbufvar(buf, '&modified', 0)
endfunction

" Show the output of {cmd} (stdout and stderr), following it if {follow}.
" Returns the job.
function! resource#logs(rbuf, cmd, follow) abort
  return resource#buffer#logs(a:rbuf, a:cmd, a:follow)
endfunction

" Show {text} after the first line, '' to clear it.
function! resource#status(rbuf, text, ...) abort
  let rbuf = resource#buffer#resolve(a:rbuf)
  if !empty(rbuf)
    call resource#compat#set_status(rbuf.bufnr, 1, a:text, get(a:, 1, 'Comment'))
  endif
endfunction

" Show that loading the buffer failed with {err}: in the status, notified
" unless it is a background reload.
function! resource#error(rbuf, err) abort
  let rbuf = resource#buffer#resolve(a:rbuf)
  if empty(rbuf)
    return
  endif
  call resource#status(rbuf, '✗ ' . get(split(a:err, "\n"), 0, 'Failed'), 'ErrorMsg')
  if !rbuf.silent
    call resource#notify(empty(a:err) ? 'Failed' : a:err, 'error')
  endif
endfunction

" The item of the row at {lnum} (the cursor line by default), v:null if none.
function! resource#item(rbuf, ...) abort
  let rbuf = resource#buffer#resolve(a:rbuf)
  return empty(rbuf) ? v:null : resource#table#item(rbuf, get(a:, 1, line('.')))
endfunction

" The items of the rows in the lines {first} to {last}.
function! resource#items(rbuf, first, last) abort
  let rbuf = resource#buffer#resolve(a:rbuf)
  return empty(rbuf) ? [] : resource#table#items(rbuf, a:first, a:last)
endfunction

" The items of the rows deleted from the buffer, in order, e.g. for the
" write() of providers.
function! resource#deleted(rbuf) abort
  let rbuf = resource#buffer#resolve(a:rbuf)
  return empty(rbuf) ? [] : resource#table#deleted(rbuf)
endfunction

" The cell under the cursor (or at {lnum} and the 0-indexed byte {col}):
" {item, column, text}, column and text are '' between cells, {} if none.
function! resource#cell(rbuf, ...) abort
  let rbuf = resource#buffer#resolve(a:rbuf)
  return empty(rbuf) ? {} : resource#table#cell(rbuf, get(a:, 1, line('.')), get(a:, 2, col('.') - 1))
endfunction

" The name of the buffer the cell under the cursor refers to, see the tag()
" of providers, '' if none.
function! resource#tag(rbuf) abort
  let rbuf = resource#buffer#resolve(a:rbuf)
  let provider = empty(rbuf) ? {} : resource#buffer#provider(rbuf.scheme)
  let cell = empty(rbuf) ? {} : resource#table#cell(rbuf, line('.'), col('.') - 1)
  return empty(cell) || !has_key(provider, 'tag') ? '' : provider.tag(rbuf, cell)
endfunction

" Run {Call}(item) for every item, it returns the job (see resource#job()) of
" the item: notify their output (stdout when they succeed, stderr when they
" fail), then reload the buffer once all are done. With {prompt}, once
" confirmed.
function! resource#run(rbuf, items, Call, ...) abort
  let rbuf = resource#buffer#resolve(a:rbuf)
  if !empty(rbuf) && !empty(a:items)
    call resource#table#run(rbuf, a:items, a:Call, get(a:, 1, ''))
  endif
endfunction

" How messages name {items}: their labels, the first 3 and how many more.
function! resource#describe(rbuf, items) abort
  let provider = s:provider_of(a:rbuf)
  let names = map(copy(a:items), 'resource#table#label(provider, v:val)')
  if len(names) > 3
    return printf('%s and %d more', join(names[:2], ', '), len(names) - 3)
  endif
  return join(names, ', ')
endfunction

" ---------------------------------------------------------------------------
" Jobs

" Run {cmd} (a list) asynchronously. {opts}:
"   on_exit(code, stdout, stderr)  once done, not when killed
"   on_stdout(chunk), on_stderr(chunk)  output as it arrives
"   timeout  milliseconds after which it is killed, on_exit gets code 124
" Returns the job, {} when it could not be started.
function! resource#job(cmd, opts) abort
  return resource#compat#job(a:cmd, a:opts)
endfunction

" Whether {job}, or any job of a list, is running.
function! resource#running(job) abort
  return resource#compat#running(a:job)
endfunction

" Kill {job}, or the jobs of a list, if running.
function! resource#kill(job) abort
  call resource#compat#kill(a:job)
endfunction

" Run {cmd} synchronously, killed after {timeout} milliseconds: [code,
" stdout], code -1 when it could not run or timed out.
function! resource#system(cmd, timeout) abort
  return resource#compat#system(a:cmd, a:timeout)
endfunction

" ---------------------------------------------------------------------------
" Messages, prompts and windows

" {level}: 'info' (the default), 'warn' or 'error'.
function! resource#notify(msg, ...) abort
  let level = get(a:, 1, 'info')
  execute 'echohl' get({'error': 'ErrorMsg', 'warn': 'WarningMsg'}, level, 'None')
  for line in split(a:msg, "\n")
    echomsg line
  endfor
  echohl None
endfunction

" Prompts are deferred to a timer: Vim does not read the answer of a prompt
" in a job callback.

" Select one of {items}, {opts}: prompt, format_item (a funcref). Calls
" {Callback}(item, index), the index 1-based, both v:null when cancelled.
function! resource#select(items, opts, Callback) abort
  call timer_start(0, {-> s:select(a:items, a:opts, a:Callback)})
endfunction

function! s:select(items, opts, Callback) abort
  let lines = split(get(a:opts, 'prompt', 'Select:'), "\n")
  let i = 0
  for item in a:items
    let i += 1
    call add(lines, printf('%d: %s', i, has_key(a:opts, 'format_item') ? a:opts.format_item(item) : item))
  endfor
  redraw
  let choice = inputlist(lines)
  if choice < 1 || choice > len(a:items)
    call a:Callback(v:null, v:null)
  else
    call a:Callback(a:items[choice - 1], choice)
  endif
endfunction

" Ask for a value, {opts}: prompt, default. Calls {Callback}(value), v:null
" when cancelled or empty.
function! resource#input(opts, Callback) abort
  call timer_start(0, {-> s:input(a:opts, a:Callback)})
endfunction

function! s:input(opts, Callback) abort
  let value = input(get(a:opts, 'prompt', ''), get(a:opts, 'default', ''))
  call a:Callback(empty(value) ? v:null : value)
endfunction

" Ask Yes or No, calls {Callback}(confirmed).
function! resource#confirm(prompt, Callback) abort
  call resource#select(['Yes', 'No'], {'prompt': a:prompt},
        \ {choice, index -> a:Callback(type(choice) == v:t_string && choice ==# 'Yes')})
endfunction

" Show {lines} in a floating window, {opts}: title, enter (focus it, closed
" by q, <Esc> and {close_keys}), else it closes when the cursor moves.
" Returns its window id.
function! resource#float(lines, ...) abort
  let opts = get(a:, 1, {})
  return resource#compat#float(a:lines, type(opts) == v:t_dict ? opts : {})
endfunction

" The directory of the state of plugins, e.g. ~/.local/state/nvim.
function! resource#state_dir() abort
  return resource#compat#state_dir()
endfunction
