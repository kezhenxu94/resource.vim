" The state of resource buffers, their autocommands, keymaps, header, logs and
" periodic reload.
"
" A buffer (rbuf) is the dict returned by its provider's parse(), with:
"   bufnr, scheme, jobs (the jobs loading it, by id), silent (whether the
"   current load is a background reload), watch, table (the last rendered),
"   header_row, rows ({mark id: {item, line, signature}}), cells ({mark id:
"   {item, column, text, row}}), diagnostics ({sign id: {message,
"   severity}}), flash_generation, follow_job.

let s:buffers = {}
" By scheme
let s:providers = {}

function! resource#buffer#add_provider(provider) abort
  let s:providers[a:provider.scheme] = a:provider
endfunction

function! resource#buffer#provider(scheme) abort
  return get(s:providers, a:scheme, {})
endfunction

function! resource#buffer#providers() abort
  return values(s:providers)
endfunction

function! resource#buffer#get(buf) abort
  return get(s:buffers, a:buf, {})
endfunction

function! resource#buffer#all() abort
  return values(s:buffers)
endfunction

" The state of {rbuf}: a buffer number, or a dict with bufnr, maybe a copy
" (e.g. from Lua). {} when the buffer is gone.
function! resource#buffer#resolve(rbuf) abort
  if type(a:rbuf) == v:t_number
    return get(s:buffers, a:rbuf, {})
  endif
  return type(a:rbuf) == v:t_dict ? get(s:buffers, get(a:rbuf, 'bufnr', -1), {}) : {}
endfunction

function! s:provider(rbuf) abort
  return resource#provider(a:rbuf.scheme)
endfunction

function! s:new(buf, provider, fields) abort
  let rbuf = extend(a:fields, {
        \ 'bufnr': a:buf, 'scheme': a:provider.scheme, 'jobs': {}, 'silent': 0, 'watch': 0, 'table': {},
        \ 'header_row': {}, 'rows': {}, 'cells': {}, 'diagnostics': {}, 'flash_generation': 0, 'follow_job': {},
        \ })
  let s:buffers[a:buf] = rbuf
  call setbufvar(a:buf, 'resource', 1)
  call setbufvar(a:buf, '&swapfile', 0)
  call s:setup_keymaps(rbuf, a:provider)
  call resource#compat#setup_tags(a:buf)
  return rbuf
endfunction

" ---------------------------------------------------------------------------
" Autocommands

function! resource#buffer#on_read(buf) abort
  let name = bufname(a:buf)
  let provider = resource#provider(matchstr(name, '^[^:/]\+\ze://'))
  try
    let canonical = has_key(provider, 'canonical') ? provider.canonical(name) : name
  catch
    call resource#notify(v:exception, 'error')
    return
  endtry
  " The name is an alias: edit the canonical buffer instead, the alias is
  " wiped, it never becomes the alternate file or a jump.
  if canonical !=# name
    let target = bufadd(canonical)
    call setbufvar(target, '&buflisted', 1)
    execute 'keepalt keepjumps buffer' target
    call timer_start(0, {-> execute('silent! bwipeout! ' . a:buf)})
    return
  endif

  let rbuf = get(s:buffers, a:buf, {})
  if empty(rbuf)
    try
      let fields = provider.parse(name)
      " An empty Lua table is a list
      let fields = type(fields) == v:t_dict ? fields : {}
    catch
      call resource#notify(v:exception, 'error')
      return
    endtry
    if has_key(provider, 'term')
      let cmd = provider.term(fields)
      if type(cmd) == v:t_list
        if !empty(cmd)
          call resource#compat#term_start(cmd, name)
        endif
        return
      endif
    endif
    let rbuf = s:new(a:buf, provider, fields)
  endif
  call resource#buffer#load(rbuf, {})
endfunction

" An unloaded buffer (:bunload, leaving it with 'nohidden', :e) keeps its
" state, e.g. watching, for when it is loaded again, a deleted one (:bdelete,
" :bwipeout) starts over.
function! resource#buffer#on_unload(buf) abort
  if has_key(s:buffers, a:buf)
    call resource#buffer#stop_jobs(s:buffers[a:buf])
  endif
endfunction

function! resource#buffer#on_delete(buf) abort
  if has_key(s:buffers, a:buf)
    call resource#buffer#stop_jobs(remove(s:buffers, a:buf))
  endif
endfunction

function! resource#buffer#on_write(buf, force) abort
  let rbuf = get(s:buffers, a:buf, {})
  if empty(rbuf)
    return
  endif
  let provider = s:provider(rbuf)
  if has_key(provider, 'write') && provider.write(rbuf, a:force)
    return
  endif
  call resource#table#save(rbuf, a:force, {saved -> saved ? timer_start(0, {-> resource#buffer#load(rbuf, {})}) : 0})
endfunction

function! resource#buffer#on_text_changed(buf) abort
  let rbuf = get(s:buffers, a:buf, {})
  if !empty(rbuf) && !empty(rbuf.rows)
    call resource#table#show_pending(rbuf)
  endif
endfunction

function! resource#buffer#on_win_enter(buf) abort
  let rbuf = get(s:buffers, a:buf, {})
  if empty(rbuf)
    " A window that showed a table shows another buffer
    call resource#compat#clear_header(win_getid())
    return
  endif
  " Wrapped rows break the table layout and its alignment with the header
  if !empty(rbuf.table)
    setlocal nowrap
  endif
  call resource#buffer#update_header(rbuf)
endfunction

function! resource#buffer#on_scroll() abort
  let rbuf = get(s:buffers, bufnr(''), {})
  if !empty(rbuf)
    call resource#buffer#update_header(rbuf)
  endif
endfunction

function! resource#buffer#stop_all() abort
  for rbuf in values(s:buffers)
    call resource#buffer#stop_jobs(rbuf)
  endfor
endfunction

" ---------------------------------------------------------------------------
" Loading

" {opts}: silent, for background reloads: no loading status, no error
" notification.
function! resource#buffer#load(rbuf, opts) abort
  let rbuf = resource#buffer#resolve(a:rbuf)
  " Operations reload their buffer when done, it may be gone meanwhile
  if empty(rbuf) || !bufloaded(rbuf.bufnr)
    return
  endif
  let silent = get(a:opts, 'silent', 0)
  if resource#buffer#loading(rbuf)
    if !silent
      call resource#notify('The buffer is currently being loaded', 'warn')
    endif
    return
  endif
  call filter(rbuf.jobs, 'resource#compat#running(v:val)')
  let rbuf.silent = silent
  " Text views set it to nofile, see resource#set_lines()
  call setbufvar(rbuf.bufnr, '&buftype', 'acwrite')
  if getbufline(rbuf.bufnr, 1, '$') == ['']
    call resource#status(rbuf, 'Loading…')
  endif
  let job = s:provider(rbuf).load(rbuf)
  for job in type(job) == v:t_list ? job : [job]
    call resource#buffer#track(rbuf, job)
  endfor
endfunction

function! resource#buffer#track(rbuf, job) abort
  let rbuf = resource#buffer#resolve(a:rbuf)
  if !empty(rbuf) && type(a:job) == v:t_dict && has_key(a:job, 'id')
    let rbuf.jobs[a:job.id] = a:job
  endif
  return a:job
endfunction

function! resource#buffer#loading(rbuf) abort
  let rbuf = resource#buffer#resolve(a:rbuf)
  return !empty(rbuf) && resource#compat#running(values(rbuf.jobs))
endfunction

" Kill the jobs loading the buffer, their output has nowhere to go once it is
" unloaded.
function! resource#buffer#stop_jobs(rbuf) abort
  call resource#compat#kill(values(a:rbuf.jobs))
  let a:rbuf.jobs = {}
endfunction

" ---------------------------------------------------------------------------
" Logs

function! resource#buffer#logs(rbuf, cmd, follow) abort
  let rbuf = resource#buffer#resolve(a:rbuf)
  if empty(rbuf)
    return {}
  endif
  let Show = function('s:show_logs', [rbuf, a:follow])
  if a:follow
    " Only complete lines are shown, output arrives in arbitrary chunks
    let pending = {'stdout': '', 'stderr': ''}
    let opts = {
          \ 'on_stdout': function('s:log_chunk', [pending, 'stdout', Show]),
          \ 'on_stderr': function('s:log_chunk', [pending, 'stderr', Show]),
          \ 'on_exit': {... -> s:log_flush(pending, Show)},
          \ }
  else
    let opts = {'on_exit': {code, stdout, stderr -> Show(substitute(stdout . stderr, '\n$', '', ''))}}
  endif
  let job = resource#compat#job(a:cmd, opts)
  if !empty(job) && a:follow
    let rbuf.follow_job = job
    if bufnr('') == rbuf.bufnr
      nnoremap <buffer> <silent> <C-c> <Cmd>call resource#buffer#stop_logs(bufnr(''))<CR>
    endif
  endif
  return resource#buffer#track(rbuf, job)
endfunction

function! s:log_chunk(pending, stream, Show, chunk) abort
  let a:pending[a:stream] .= a:chunk
  let last_newline = strridx(a:pending[a:stream], "\n")
  if last_newline >= 0
    call a:Show(strpart(a:pending[a:stream], 0, last_newline))
    let a:pending[a:stream] = strpart(a:pending[a:stream], last_newline + 1)
  endif
endfunction

function! s:log_flush(pending, Show) abort
  for stream in ['stdout', 'stderr']
    if a:pending[stream] !=# ''
      call a:Show(a:pending[stream])
      let a:pending[stream] = ''
    endif
  endfor
endfunction

function! s:show_logs(rbuf, follow, text) abort
  let buf = a:rbuf.bufnr
  if !bufloaded(buf)
    return
  endif
  let lines = split(a:text, "\n", 1)
  if !a:follow
    call resource#set_lines(a:rbuf, lines, {'modifiable': 1, 'writable': 0})
    return
  endif

  call setbufvar(buf, '&buftype', 'nofile')
  call setbufvar(buf, '&modifiable', 1)
  " Replace the trailing placeholder line, then add a new one for the status
  let start = len(getbufline(buf, 1, '$'))
  " Windows at the end keep showing the new lines, like tail -f
  let at_end = filter(win_findbuf(buf), 'getcurpos(v:val)[1] >= start - 1')
  call setbufline(buf, start, lines)
  call appendbufline(buf, '$', '')
  let max_lines = resource#config(a:rbuf, 'logs_max_lines')
  let excess = len(getbufline(buf, 1, '$')) - 1 - max_lines
  if max_lines >= 0 && excess > 0
    silent call deletebufline(buf, 1, excess)
  endif
  call setbufvar(buf, '&modified', 0)
  call s:logs_status(a:rbuf, 'Waiting for new logs... (Ctrl+C to stop)')
  for win in at_end
    call win_execute(win, 'call cursor(line("$"), 1)')
  endfor
endfunction

function! s:logs_status(rbuf, text) abort
  call resource#compat#set_status(a:rbuf.bufnr, len(getbufline(a:rbuf.bufnr, 1, '$')), a:text, 'Comment')
endfunction

function! resource#buffer#stop_logs(buf) abort
  let rbuf = get(s:buffers, a:buf, {})
  let job = get(rbuf, 'follow_job', {})
  if empty(job) || !has_key(rbuf.jobs, job.id)
    return
  endif
  call resource#compat#kill(job)
  call remove(rbuf.jobs, job.id)
  call s:logs_status(rbuf, 'Stopped following logs, to restart, re-edit this buffer with `:e`')
endfunction

" ---------------------------------------------------------------------------
" The table header, at the top of the windows showing a table

" The header of the table of the buffer of {win}, aligned with its number and
" sign columns and its horizontal scroll: {textoff, text, indicator,
" highlight}, {} if none.
function! resource#buffer#header(win) abort
  let rbuf = get(s:buffers, winbufnr(a:win), {})
  if empty(rbuf) || empty(rbuf.header_row)
    return {}
  endif
  let info = getwininfo(a:win)[0]
  " Vim's %g keeps .0
  let indicator = rbuf.watch ? printf(' ⟳ %ss ', substitute(printf('%g', resource#buffer#interval(rbuf) / 1000.0), '\.0$', '', '')) : ''
  let s:view = {}
  call win_execute(a:win, 'let s:view = winsaveview()')
  let width = info.width - info.textoff - strdisplaywidth(indicator)
  return {'textoff': info.textoff, 'indicator': indicator, 'highlight': rbuf.header_row.highlight,
        \ 'text': strpart(rbuf.header_row.formatted, s:view.leftcol, max([width, 0]))}
endfunction

function! resource#buffer#update_header(rbuf) abort
  for win in win_findbuf(a:rbuf.bufnr)
    call resource#compat#set_header(win)
  endfor
endfunction

" ---------------------------------------------------------------------------
" Watching: reloading tables periodically, toggled per buffer

let s:timer = -1

" The interval in milliseconds, 0 when watching is disabled.
function! resource#buffer#interval(rbuf) abort
  let interval = resource#config(a:rbuf, 'refresh_interval')
  return type(interval) == v:t_number ? interval : 0
endfunction

function! s:should_refresh(rbuf) abort
  let buf = a:rbuf.bufnr
  if !a:rbuf.watch || !bufloaded(buf) || getbufvar(buf, '&modified') || resource#buffer#loading(a:rbuf)
    return 0
  endif
  if empty(win_findbuf(buf))
    return 0
  endif
  " Do not move lines under a visual selection or a pending operator
  return bufnr('') != buf || mode() ==# 'n'
endfunction

function! s:tick(...) abort
  let s:timer = -1
  let watching = 0
  for rbuf in values(s:buffers)
    let watching = watching || rbuf.watch
    if s:should_refresh(rbuf)
      call resource#buffer#load(rbuf, {'silent': 1})
    endif
  endfor
  if watching
    call s:start()
  endif
endfunction

" Started again after each tick, with the shortest interval of the watched
" buffers.
function! s:start() abort
  let intervals = filter(map(filter(values(s:buffers), 'v:val.watch'), 'resource#buffer#interval(v:val)'), 'v:val > 0')
  if s:timer == -1 && !empty(intervals)
    let s:timer = timer_start(min(intervals), function('s:tick'))
  endif
endfunction

function! resource#buffer#toggle_watch(rbuf) abort
  if empty(a:rbuf.table)
    call resource#notify('Only lists can be watched', 'warn')
    return
  endif
  if resource#buffer#interval(a:rbuf) <= 0
    call resource#notify(printf('Watching is disabled, set g:%s_refresh_interval to enable it', s:provider(a:rbuf).name), 'warn')
    return
  endif
  let a:rbuf.watch = !a:rbuf.watch
  if a:rbuf.watch
    call s:start()
  endif
  call resource#buffer#update_header(a:rbuf)
endfunction

" ---------------------------------------------------------------------------
" Keymaps

let s:keymaps = {
      \ 'parent': {'lhs': '-', 'desc': 'go to the parent buffer', 'run': {rbuf -> s:parent(rbuf)}},
      \ 'refresh': {'lhs': 'R', 'desc': 'reload the buffer', 'run': {rbuf -> resource#buffer#load(rbuf, {})}},
      \ 'watch': {'lhs': 'gw', 'desc': 'toggle reloading the list periodically', 'run': {rbuf -> resource#buffer#toggle_watch(rbuf)}},
      \ 'operations': {'lhs': 'gra', 'desc': 'operations on the item under the cursor, or the selected ones',
      \   'run': {rbuf -> s:operations(rbuf, line('.'), line('.'))}},
      \ 'help': {'lhs': 'g?', 'desc': 'show this help', 'run': {rbuf -> resource#buffer#help(rbuf)}},
      \ }

" The keymaps of {provider}: {name: {lhs, desc, run}}, g:{name}_keymaps
" overrides the lhs.
function! resource#buffer#keymaps(provider) abort
  let keymaps = {}
  for name in uniq(sort(keys(s:keymaps) + keys(a:provider.keymaps)))
    let keymaps[name] = extend(copy(get(s:keymaps, name, {})), get(a:provider.keymaps, name, {}))
  endfor
  for [name, lhs] in items(get(g:, a:provider.name . '_keymaps', {}))
    if has_key(keymaps, name)
      let keymaps[name].lhs = lhs
    endif
  endfor
  return filter(keymaps, '!empty(get(v:val, "lhs", "")) && has_key(v:val, "run")')
endfunction

function! s:setup_keymaps(rbuf, provider) abort
  for [name, keymap] in items(resource#buffer#keymaps(a:provider))
    execute 'nnoremap <buffer> <silent> <nowait>' keymap.lhs '<Cmd>call resource#buffer#keymap(' . string(name) . ')<CR>'
    if name ==# 'operations'
      execute 'xnoremap <buffer> <silent> <nowait>' keymap.lhs '<Cmd>call resource#buffer#keymap("operations")<CR>'
    endif
  endfor
  " Unhealthy items, like diagnostics
  nnoremap <buffer> <silent> ]d <Cmd>call resource#buffer#diagnostic(1)<CR>
  nnoremap <buffer> <silent> [d <Cmd>call resource#buffer#diagnostic(0)<CR>
  nnoremap <buffer> <silent> <C-w>d <Cmd>call resource#buffer#show_diagnostics()<CR>
endfunction

function! resource#buffer#keymap(name) abort
  let rbuf = get(s:buffers, bufnr(''), {})
  if empty(rbuf)
    return
  endif
  if a:name ==# 'operations' && mode() !=# 'n'
    let [first, last] = [line('v'), line('.')]
    execute "normal! \<Esc>"
    call s:operations(rbuf, min([first, last]), max([first, last]))
    return
  endif
  call resource#buffer#keymaps(s:provider(rbuf))[a:name].run(rbuf)
endfunction

function! s:parent(rbuf) abort
  let provider = s:provider(a:rbuf)
  let parent = has_key(provider, 'parent') ? provider.parent(a:rbuf) : ''
  if !empty(parent)
    call resource#open(parent)
  endif
endfunction

" Pick an operation on the items of the rows in [first, last] and run it.
function! s:operations(rbuf, first, last) abort
  let provider = s:provider(a:rbuf)
  let items = resource#table#items(a:rbuf, a:first, a:last)
  let operations = has_key(provider, 'operations') && !empty(items) ? provider.operations(a:rbuf, items) : []
  if empty(operations)
    call resource#notify('No operations', 'warn')
    return
  endif
  call resource#select(map(copy(operations), 'v:val.title'), {'prompt': 'Operations:'},
        \ {choice, index -> choice is v:null ? 0 : operations[index - 1].run()})
endfunction

" ---------------------------------------------------------------------------
" Help

function! resource#buffer#help_lines(provider) abort
  let keymaps = sort(map(values(resource#buffer#keymaps(a:provider)), '[v:val.lhs, get(v:val, "desc", "")]'))
  return ['Keymaps'] + map(keymaps, 'printf("  %-8s %s", v:val[0], v:val[1])') + get(a:provider, 'help', [])
endfunction

function! resource#buffer#help(rbuf) abort
  let provider = s:provider(a:rbuf)
  let keymaps = resource#buffer#keymaps(provider)
  return resource#float(resource#buffer#help_lines(provider), {'enter': 1, 'title': ' ' . provider.title . ' ',
        \ 'close_keys': has_key(keymaps, 'help') ? [keymaps.help.lhs] : []})
endfunction

" ---------------------------------------------------------------------------
" Diagnostics and tags

" Go to the next (or previous) line with diagnostics, wrapping around.
function! resource#buffer#diagnostic(forward) abort
  let lines = resource#table#diagnostic_lines(bufnr(''))
  if empty(lines)
    call resource#notify('No diagnostics', 'warn')
    return
  endif
  let current = line('.')
  if a:forward
    let next = filter(copy(lines), 'v:val > current')
    let lnum = empty(next) ? lines[0] : next[0]
  else
    let previous = filter(copy(lines), 'v:val < current')
    let lnum = empty(previous) ? lines[-1] : previous[-1]
  endif
  normal! m'
  call cursor(lnum, 1)
endfunction

" Show why the item of the cursor line is unhealthy.
function! resource#buffer#show_diagnostics() abort
  let diagnostics = resource#table#diagnostics(bufnr(''), line('.'))
  if !empty(diagnostics)
    call resource#float(map(copy(diagnostics), 'v:val.message'), {})
  endif
endfunction
