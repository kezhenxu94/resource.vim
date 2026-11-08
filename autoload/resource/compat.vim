" The differences between Vim and Neovim: jobs, marks and virtual text (text
" properties in Vim, extmarks in Neovim), the table header (the WinBar menu in
" Vim, 'winbar' in Neovim), floating windows, terminals and tags.

let s:nvim = has('nvim')

" ---------------------------------------------------------------------------
" Jobs

" The running jobs by id: callers may hold copies of a job, e.g. Lua.
let s:jobs = {}
let s:next_job = 0

" See resource#job().
function! resource#compat#job(cmd, opts) abort
  let s:next_job += 1
  " An empty Lua table is a list
  let opts = type(a:opts) == v:t_dict ? a:opts : {}
  let job = {'id': s:next_job, 'done': 0, 'killed': 0, 'timed_out': 0, 'stdout': [], 'stderr': [], 'opts': opts,
        \ 'listeners': []}
  if !executable(a:cmd[0])
    let failed = 1
  elseif s:nvim
    try
      let job.job = jobstart(a:cmd, {
            \ 'stdin': 'null',
            \ 'on_stdout': {_, data, __ -> s:output(job, 'stdout', join(data, "\n"))},
            \ 'on_stderr': {_, data, __ -> s:output(job, 'stderr', join(data, "\n"))},
            \ 'on_exit': {_, code, __ -> s:finish(job, code)},
            \ })
    catch
      let job.job = -1
    endtry
    let failed = job.job <= 0
  else
    let job.exited = 0
    let job.closed = 0
    " exit_cb and close_cb arrive in either order
    let job.job = job_start(a:cmd, {
          \ 'in_io': 'null', 'out_mode': 'raw', 'err_mode': 'raw',
          \ 'out_cb': {_, data -> s:output(job, 'stdout', data)},
          \ 'err_cb': {_, data -> s:output(job, 'stderr', data)},
          \ 'exit_cb': {_, code -> s:vim_exit(job, code)},
          \ 'close_cb': {_ -> s:vim_close(job)},
          \ })
    let failed = job_status(job.job) ==# 'fail'
  endif
  if failed
    call resource#notify('Failed to run ' . join(a:cmd), 'error')
    return {}
  endif
  let s:jobs[job.id] = job
  if has_key(opts, 'timeout')
    call timer_start(opts.timeout, {-> s:timeout(job)})
  endif
  return job
endfunction

function! s:output(job, stream, chunk) abort
  if a:chunk ==# '' || a:job.killed
    return
  endif
  call add(a:job[a:stream], a:chunk)
  if has_key(a:job.opts, 'on_' . a:stream)
    call a:job.opts['on_' . a:stream](a:chunk)
  endif
endfunction

function! s:finish(job, code) abort
  if a:job.done
    return
  endif
  let a:job.done = 1
  silent! call remove(s:jobs, a:job.id)
  if a:job.killed && !a:job.timed_out
    return
  endif
  let args = [a:job.timed_out ? 124 : a:code, join(a:job.stdout, ''), join(a:job.stderr, '')]
  for Fn in (has_key(a:job.opts, 'on_exit') ? [a:job.opts.on_exit] : []) + a:job.listeners
    call call(Fn, args)
  endfor
endfunction

" Also call {Fn}(code, stdout, stderr) once {job} is done. Returns 0 when it
" is not running.
function! resource#compat#on_exit(job, Fn) abort
  let job = s:live(a:job)
  if empty(job)
    return 0
  endif
  call add(job.listeners, a:Fn)
  return 1
endfunction

function! s:vim_exit(job, code) abort
  let a:job.exited = 1
  let a:job.code = a:code
  if a:job.closed
    call s:finish(a:job, a:code)
  endif
endfunction

function! s:vim_close(job) abort
  let a:job.closed = 1
  if a:job.exited
    call s:finish(a:job, a:job.code)
  endif
endfunction

function! s:timeout(job) abort
  if !a:job.done
    let a:job.timed_out = 1
    call resource#compat#kill(a:job)
  endif
endfunction

" The job of the registry, {} when it is done.
function! s:live(job) abort
  return type(a:job) == v:t_dict ? get(s:jobs, get(a:job, 'id', 0), {}) : {}
endfunction

function! resource#compat#running(job) abort
  if type(a:job) == v:t_list
    return !empty(filter(copy(a:job), 'resource#compat#running(v:val)'))
  endif
  return !empty(s:live(a:job))
endfunction

function! resource#compat#kill(job) abort
  if type(a:job) == v:t_list
    call map(copy(a:job), 'resource#compat#kill(v:val)')
    return
  endif
  let job = s:live(a:job)
  if empty(job)
    return
  endif
  let job.killed = 1
  if s:nvim
    silent! call jobstop(job.job)
  else
    call job_stop(job.job, 'term')
  endif
endfunction

" See resource#system().
function! resource#compat#system(cmd, timeout) abort
  let out = {'stdout': [], 'closed': 0}
  if s:nvim
    try
      let id = jobstart(a:cmd, {'stdin': 'null', 'stdout_buffered': 1,
            \ 'on_stdout': {_, data, __ -> extend(out.stdout, [join(data, "\n")])}})
    catch
      return [-1, '']
    endtry
    if id <= 0
      return [-1, '']
    endif
    let code = jobwait([id], a:timeout)[0]
    if code < 0
      silent! call jobstop(id)
      return [-1, '']
    endif
    return [code, join(out.stdout, '')]
  endif
  let job = job_start(a:cmd, {'in_io': 'null', 'err_io': 'null', 'out_mode': 'raw',
        \ 'out_cb': {_, msg -> add(out.stdout, msg)},
        \ 'close_cb': {_ -> extend(out, {'closed': 1})}})
  if job_status(job) ==# 'fail'
    return [-1, '']
  endif
  let start = reltime()
  while (job_status(job) ==# 'run' || !out.closed) && reltimefloat(reltime(start)) * 1000 < a:timeout
    sleep 5m
  endwhile
  if job_status(job) ==# 'run'
    call job_stop(job, 'kill')
    return [-1, '']
  endif
  return [job_info(job).exitval, join(out.stdout, '')]
endfunction

" ---------------------------------------------------------------------------
" Marks: the rows and cells of tables, which follow edits, and virtual text.
" Kinds: row, body (Vim: the highlight of rows), cell, changed, pending
" (deleted rows), status.

let s:namespaces = {}
" Vim text property types by kind, one per highlight
let s:types = {}
let s:next_mark = 0

function! s:ns(kind) abort
  if !has_key(s:namespaces, a:kind)
    let s:namespaces[a:kind] = nvim_create_namespace('resource_' . a:kind)
  endif
  return s:namespaces[a:kind]
endfunction

function! s:type(kind, hl) abort
  let name = 'resource_' . a:kind . (empty(a:hl) ? '' : '_' . a:hl)
  if empty(prop_type_get(name))
    let opts = {'priority': a:kind ==# 'body' ? -1 : a:kind ==# 'changed' ? 20 : 10}
    if !empty(a:hl)
      let opts.highlight = a:hl
    endif
    " Text typed at either end of a cell, as by `ciw`, stays in the cell
    if a:kind ==# 'cell'
      call extend(opts, {'start_incl': 1, 'end_incl': 1})
    endif
    call prop_type_add(name, opts)
  endif
  let s:types[a:kind] = get(s:types, a:kind, [])
  if index(s:types[a:kind], name) < 0
    call add(s:types[a:kind], name)
  endif
  return name
endfunction

function! s:props(buf, kind, first, last) abort
  let types = get(s:types, a:kind, [])
  if empty(types) || !bufloaded(a:buf) || a:first > len(getbufline(a:buf, 1, '$'))
    return []
  endif
  return prop_list(a:first, {'bufnr': a:buf, 'end_lnum': a:last, 'types': types})
endfunction

function! resource#compat#clear(buf, kind) abort
  if !bufloaded(a:buf)
    return
  endif
  if s:nvim
    call nvim_buf_clear_namespace(a:buf, s:ns(a:kind), 0, -1)
  elseif !empty(get(s:types, a:kind, []))
    call prop_remove({'types': s:types[a:kind], 'bufnr': a:buf, 'all': 1})
  endif
endfunction

" Mark the row at {lnum}, highlighted with {hl}: the mark is gone once the
" line is deleted, back when that is undone. Returns its id.
function! resource#compat#mark_row(buf, lnum, hl) abort
  if s:nvim
    return nvim_buf_set_extmark(a:buf, s:ns('row'), a:lnum - 1, 0, {'invalidate': v:true, 'line_hl_group': a:hl})
  endif
  let s:next_mark += 1
  call prop_add(a:lnum, 1, {'type': s:type('row', ''), 'id': s:next_mark, 'bufnr': a:buf, 'length': 0})
  let length = len(getbufline(a:buf, a:lnum)[0])
  if length > 0
    call prop_add(a:lnum, 1, {'type': s:type('body', a:hl), 'bufnr': a:buf, 'length': length})
  endif
  return s:next_mark
endfunction

" The lines of the rows {ids} by id, 0 for deleted rows.
function! resource#compat#rows(buf, ids) abort
  let lines = {}
  for id in a:ids
    let lines[id] = 0
  endfor
  if !bufloaded(a:buf)
    return lines
  endif
  if s:nvim
    for [id, row, col, details] in nvim_buf_get_extmarks(a:buf, s:ns('row'), 0, -1, {'details': v:true})
      if has_key(lines, id) && !get(details, 'invalid', v:false)
        let lines[id] = row + 1
      endif
    endfor
  else
    for prop in s:props(a:buf, 'row', 1, -1)
      if has_key(lines, prop.id)
        let lines[prop.id] = prop.lnum
      endif
    endfor
  endif
  return lines
endfunction

" The ids of the rows in the lines {first} to {last}, in order.
function! resource#compat#rows_in(buf, first, last) abort
  if s:nvim
    let marks = nvim_buf_get_extmarks(a:buf, s:ns('row'), [a:first - 1, 0], [a:last - 1, -1], {'details': v:true})
    return map(filter(marks, '!get(v:val[3], "invalid", v:false)'), 'v:val[0]')
  endif
  return map(s:props(a:buf, 'row', a:first, a:last), 'v:val.id')
endfunction

" Mark the cell of the 0-indexed byte range [{start}, {end}) of {lnum},
" highlighted with {hl} unless empty. Returns its id.
function! resource#compat#mark_cell(buf, lnum, start, end, hl) abort
  if s:nvim
    let opts = {'end_col': a:end, 'right_gravity': v:false, 'end_right_gravity': v:true}
    if !empty(a:hl)
      let opts.hl_group = a:hl
    endif
    return nvim_buf_set_extmark(a:buf, s:ns('cell'), a:lnum - 1, a:start, opts)
  endif
  let s:next_mark += 1
  call prop_add(a:lnum, a:start + 1, {'type': s:type('cell', a:hl), 'id': s:next_mark, 'bufnr': a:buf, 'length': a:end - a:start})
  return s:next_mark
endfunction

" The cells by id: [lnum, start, end, hl], the 0-indexed byte range [start,
" end).
function! resource#compat#cells(buf) abort
  let cells = {}
  if s:nvim
    for [id, row, col, details] in nvim_buf_get_extmarks(a:buf, s:ns('cell'), 0, -1, {'details': v:true})
      let cells[id] = [row + 1, col, details.end_col, get(details, 'hl_group', '')]
    endfor
  else
    for prop in s:props(a:buf, 'cell', 1, -1)
      let cells[prop.id] = [prop.lnum, prop.col - 1, prop.col - 1 + prop.length, prop.type[len('resource_cell_'):]]
    endfor
  endif
  return cells
endfunction

" The ids of the cells containing the 0-indexed byte {col} of {lnum}.
function! resource#compat#cells_at(buf, lnum, col) abort
  let ids = []
  if s:nvim
    for [id, row, start, details] in nvim_buf_get_extmarks(a:buf, s:ns('cell'), [a:lnum - 1, 0], [a:lnum - 1, -1], {'details': v:true})
      if start <= a:col && a:col < details.end_col && details.end_row == row
        call add(ids, id)
      endif
    endfor
  else
    for prop in s:props(a:buf, 'cell', a:lnum, a:lnum)
      if prop.col - 1 <= a:col && a:col < prop.col - 1 + prop.length
        call add(ids, prop.id)
      endif
    endfor
  endif
  return ids
endfunction

" Highlight the line {lnum} with {hl}, as a mark of {kind}.
function! resource#compat#line_hl(buf, kind, lnum, hl) abort
  if s:nvim
    call nvim_buf_set_extmark(a:buf, s:ns(a:kind), a:lnum - 1, 0, {'line_hl_group': a:hl, 'priority': 200})
    return
  endif
  let length = len(getbufline(a:buf, a:lnum)[0])
  call prop_add(a:lnum, 1, {'type': s:type(a:kind, a:hl), 'bufnr': a:buf, 'length': length})
endfunction

" The lines highlighted by line_hl() with {kind}.
function! resource#compat#highlighted_lines(buf, kind) abort
  if s:nvim
    return map(nvim_buf_get_extmarks(a:buf, s:ns(a:kind), 0, -1, {}), 'v:val[1] + 1')
  endif
  return map(s:props(a:buf, a:kind, 1, -1), 'v:val.lnum')
endfunction

" Show {text} after the line {lnum}, replacing the status, none when ''.
function! resource#compat#set_status(buf, lnum, text, hl) abort
  call resource#compat#clear(a:buf, 'status')
  if !bufloaded(a:buf) || empty(a:text)
    return
  endif
  if s:nvim
    call nvim_buf_set_extmark(a:buf, s:ns('status'), a:lnum - 1, 0, {'virt_text': [[a:text, a:hl]], 'virt_text_pos': 'eol'})
  else
    call prop_add(a:lnum, 0, {'type': s:type('status', a:hl), 'bufnr': a:buf, 'text': a:text, 'text_align': 'after', 'text_padding_left': 1})
  endif
endfunction

" The status: [lnum, text], [] without status.
function! resource#compat#status(buf) abort
  if s:nvim
    let marks = nvim_buf_get_extmarks(a:buf, s:ns('status'), 0, -1, {'details': v:true})
    return empty(marks) ? [] : [marks[0][1] + 1, marks[0][3].virt_text[0][0]]
  endif
  let props = s:props(a:buf, 'status', 1, -1)
  return empty(props) ? [] : [props[0].lnum, props[0].text]
endfunction

" Show {lines} highlighted with {hl} above (or below) {lnum}.
function! resource#compat#virt_lines(buf, lnum, lines, hl, above) abort
  if s:nvim
    call nvim_buf_set_extmark(a:buf, s:ns('pending'), a:lnum - 1, 0, {
          \ 'virt_lines': map(copy(a:lines), '[[v:val, a:hl]]'),
          \ 'virt_lines_above': a:above ? v:true : v:false,
          \ })
    " Lines above the first line are only shown as filler of the top line
    if a:above && a:lnum == 1
      for win in win_findbuf(a:buf)
        call win_execute(win, 'if line("w0") == 1 | call winrestview({"topfill": ' . len(a:lines) . '}) | endif')
      endfor
    endif
    return
  endif
  for line in a:lines
    call prop_add(a:lnum, 0, {'type': s:type('pending', a:hl), 'bufnr': a:buf, 'text': line, 'text_align': a:above ? 'above' : 'below'})
  endfor
endfunction

" The virtual lines: [[lnum, lines, above], ...].
function! resource#compat#get_virt_lines(buf) abort
  if s:nvim
    return map(nvim_buf_get_extmarks(a:buf, s:ns('pending'), 0, -1, {'details': v:true}),
          \ '[v:val[1] + 1, map(copy(v:val[3].virt_lines), "v:val[0][0]"), get(v:val[3], "virt_lines_above", v:false) ? 1 : 0]')
  endif
  let result = []
  for prop in s:props(a:buf, 'pending', 1, -1)
    let above = prop.text_align ==# 'above'
    if !empty(result) && result[-1][0] == prop.lnum && result[-1][2] == above
      call add(result[-1][1], prop.text)
    else
      call add(result, [prop.lnum, [prop.text], above])
    endif
  endfor
  return result
endfunction

" ---------------------------------------------------------------------------
" The table header, see resource#buffer#header()

function! resource#compat#set_header(win) abort
  let header = resource#buffer#header(a:win)
  if empty(header)
    call resource#compat#clear_header(a:win)
    return
  endif
  call setwinvar(a:win, 'resource_header', 1)
  if s:nvim
    " Evaluated when drawn, once the width of the sign column is known
    call setwinvar(a:win, '&winbar', '%!resource#compat#winbar()')
    redrawstatus!
    return
  endif
  if !has('menu')
    return
  endif
  " The WinBar item is padded by a space, after a space
  let item = repeat(' ', max([header.textoff - 2, 0])) . header.text . header.indicator
  call win_execute(a:win, ['silent! aunmenu WinBar', 'nnoremenu <silent> 1.10 WinBar.'
        \ . escape(substitute(item, '&', '&&', 'g'), ' .\|"<') . ' <Nop>'])
endfunction

" The 'winbar' of a window showing a table, Neovim only.
function! resource#compat#winbar(...) abort
  let header = resource#buffer#header(a:0 ? a:1 : g:statusline_winid)
  if empty(header)
    return ''
  endif
  let Escape = {text -> substitute(text, '%', '%%', 'g')}
  return printf('%s%%#%s#%s%%=%%#Comment#%s', repeat(' ', header.textoff), header.highlight,
        \ Escape(header.text), Escape(header.indicator))
endfunction

function! resource#compat#clear_header(win) abort
  if !getwinvar(a:win, 'resource_header', 0)
    return
  endif
  call win_execute(a:win, 'unlet w:resource_header')
  if s:nvim
    call win_execute(a:win, 'setlocal winbar<')
  elseif has('menu')
    call win_execute(a:win, 'silent! aunmenu WinBar')
  endif
endfunction

" The text of the header of a window, '' if none.
function! resource#compat#header(win) abort
  if !getwinvar(a:win, 'resource_header', 0)
    return ''
  endif
  if s:nvim
    return resource#compat#winbar(a:win)
  endif
  let s:menu = {}
  call win_execute(a:win, 'let s:menu = menu_info("WinBar")')
  return join(get(s:menu, 'submenus', []), ' ')
endfunction

" ---------------------------------------------------------------------------
" Floating windows, see resource#float()

function! resource#compat#float(lines, opts) abort
  let width = max(map(copy(a:lines), 'strdisplaywidth(v:val)') + [1])
  let title = get(a:opts, 'title', '')
  let enter = get(a:opts, 'enter', 0)
  let close_keys = get(a:opts, 'close_keys', [])
  if s:nvim
    let buf = nvim_create_buf(v:false, v:true)
    call nvim_buf_set_lines(buf, 0, -1, v:false, a:lines)
    call setbufvar(buf, '&modifiable', 0)
    call setbufvar(buf, '&bufhidden', 'wipe')
    let config = {'width': min([width + 2, &columns - 4]), 'height': max([1, min([len(a:lines), &lines - 4])]),
          \ 'style': 'minimal', 'border': 'rounded'}
    if enter
      call extend(config, {'relative': 'editor',
            \ 'row': max([0, (&lines - len(a:lines)) / 2]), 'col': max([0, (&columns - width) / 2])})
    else
      call extend(config, {'relative': 'cursor', 'row': 1, 'col': 0})
    endif
    if !empty(title)
      call extend(config, {'title': title, 'title_pos': 'center'})
    endif
    let win = nvim_open_win(buf, enter ? v:true : v:false, config)
    if enter
      for lhs in ['q', '<Esc>'] + close_keys
        call win_execute(win, 'nnoremap <buffer> <nowait> <silent> ' . lhs . ' <Cmd>close<CR>')
      endfor
      call win_execute(win, 'autocmd WinLeave <buffer> ++once silent! close')
    else
      execute 'autocmd CursorMoved,BufLeave,InsertEnter <buffer> ++once call s:close_hover(' . win . ')'
    endif
    return win
  endif
  let options = {'border': [], 'borderchars': ['─', '│', '─', '│', '╭', '╮', '╯', '╰'], 'padding': [0, 1, 0, 1],
        \ 'title': title, 'maxheight': &lines - 4, 'maxwidth': &columns - 4, 'scrollbar': 1}
  if enter
    call extend(options, {'filter': function('s:popup_filter', [['q'] + close_keys]), 'mapping': 0, 'pos': 'center'})
    return popup_create(a:lines, options)
  endif
  return popup_atcursor(a:lines, options)
endfunction

function! s:close_hover(win) abort
  if nvim_win_is_valid(a:win)
    call nvim_win_close(a:win, v:true)
  endif
endfunction

" Close keys of several characters, e.g. g?, close on their last one.
function! s:popup_filter(close_keys, win, key) abort
  if a:key ==# "\<Esc>" || index(map(copy(a:close_keys), 'v:val[-1:]'), a:key) >= 0
    call popup_close(a:win)
  elseif index(['j', "\<Down>", "\<C-e>"], a:key) >= 0
    call win_execute(a:win, "normal! \<C-e>")
  elseif index(['k', "\<Up>", "\<C-y>"], a:key) >= 0
    call win_execute(a:win, "normal! \<C-y>")
  endif
  return 1
endfunction

" The floating windows: [[winid, lines], ...].
function! resource#compat#floats() abort
  let wins = s:nvim ? filter(nvim_list_wins(), 'nvim_win_get_config(v:val).relative !=# ""') : popup_list()
  return map(wins, '[v:val, getbufline(winbufnr(v:val), 1, "$")]')
endfunction

function! resource#compat#close_float(win) abort
  if s:nvim
    call nvim_win_close(a:win, v:true)
  else
    call popup_close(a:win)
  endif
endfunction

" ---------------------------------------------------------------------------
" Terminals

" Start {cmd} in a terminal in the current window, in place of the buffer
" being read, named {name} so that editing it again finds the terminal.
function! resource#compat#term_start(cmd, name) abort
  let alternate = bufnr('#')
  let buf = bufnr('')
  if s:nvim
    call jobstart(a:cmd, {'term': v:true})
    " jobstart() names the buffer term://..., :file leaves a buffer with it
    let term_name = bufname('')
    if term_name !=# a:name
      execute 'keepalt file' fnameescape(a:name)
      for info in getbufinfo()
        if info.name ==# term_name
          execute 'bwipeout!' info.bufnr
        endif
      endfor
    endif
  else
    call term_start(a:cmd, {'curwin': 1, 'term_name': a:name})
    " The buffer being read cannot be wiped until it is read
    call timer_start(0, {-> execute('silent! bwipeout! ' . buf)})
    if alternate > 0
      let @# = alternate
    endif
  endif
  setlocal nonumber norelativenumber
endfunction

" Start typing in the terminal of the current window: Vim starts terminals in
" Terminal-Job mode.
function! resource#compat#term_enter() abort
  if s:nvim && &buftype ==# 'terminal'
    startinsert
  endif
endfunction

" ---------------------------------------------------------------------------
" Tags: <C-]> jumps to what the cell under the cursor refers to. Vim refuses
" tags of URLs (E1576): the keys are mapped and the jumps pushed on the tag
" stack instead, so that <C-t> goes back, in both editors.

function! resource#compat#setup_tags(buf) abort
  nnoremap <buffer> <silent> <C-]> <Cmd>call resource#compat#tag_jump(0)<CR>
  nnoremap <buffer> <silent> <C-w>] <Cmd>call resource#compat#tag_jump(1)<CR>
  nnoremap <buffer> <silent> <C-w><C-]> <Cmd>call resource#compat#tag_jump(1)<CR>
endfunction

function! resource#compat#tag_jump(split) abort
  let target = resource#tag(bufnr(''))
  if empty(target)
    echoerr 'E426: Tag not found: ' . expand('<cword>')
    return
  endif
  let item = {'bufnr': bufnr(''), 'from': [bufnr(''), line('.'), col('.'), 0], 'tagname': expand('<cword>')}
  if a:split
    split
  endif
  call settagstack(win_getid(), {'items': [item]}, 't')
  call resource#open(target)
endfunction

" ---------------------------------------------------------------------------

function! resource#compat#state_dir() abort
  if s:nvim
    return stdpath('state')
  endif
  return (empty($XDG_STATE_HOME) ? expand('~/.local/state') : $XDG_STATE_HOME) . '/vim'
endfunction
