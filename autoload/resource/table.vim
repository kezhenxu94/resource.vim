" Tables: aligned columns, rows and cells that follow edits, deleted rows
" shown until written, :w deleting them and applying the edits of cells.

let s:MAX_COLUMN_WIDTH = 99
let s:SEPARATOR = '  '
let s:FLASH_DURATION = 1500

" An empty Lua table is a list.
function! s:dict(value) abort
  return type(a:value) == v:t_dict ? a:value : {}
endfunction

function! s:provider(rbuf) abort
  return resource#provider(a:rbuf.scheme)
endfunction

" The identity of an item that survives reloads, so that the cursor stays on
" the same row.
function! s:identity(provider, item) abort
  if type(a:item) != v:t_dict
    return ''
  endif
  return has_key(a:provider, 'identity') ? a:provider.identity(a:item) : resource#to_string(get(a:item, 'name', ''))
endfunction

" How messages name an item.
function! resource#table#label(provider, item) abort
  return has_key(a:provider, 'label') ? a:provider.label(a:item) : resource#to_string(get(a:item, 'name', ''))
endfunction

" ---------------------------------------------------------------------------
" Rows and cells

" The item of the row at {lnum}, v:null if none.
function! resource#table#item(rbuf, lnum) abort
  let ids = resource#compat#rows_in(a:rbuf.bufnr, a:lnum, a:lnum)
  let row = empty(ids) ? {} : get(a:rbuf.rows, ids[0], {})
  return get(row, 'item', v:null)
endfunction

" The items of the rows in the lines {first} to {last}.
function! resource#table#items(rbuf, first, last) abort
  let items = []
  for id in resource#compat#rows_in(a:rbuf.bufnr, a:first, a:last)
    if has_key(a:rbuf.rows, id)
      call add(items, a:rbuf.rows[id].item)
    endif
  endfor
  return items
endfunction

" The cell at {lnum} and the 0-indexed byte {col}: {item, column, text}, the
" row's {item, column: '', text: ''} between cells, {} if none.
function! resource#table#cell(rbuf, lnum, col) abort
  for id in resource#compat#cells_at(a:rbuf.bufnr, a:lnum, a:col)
    let cell = get(a:rbuf.cells, id, {})
    if !empty(cell) && cell.item isnot v:null
      return {'item': cell.item, 'column': cell.column, 'text': cell.text}
    endif
  endfor
  let item = resource#table#item(a:rbuf, a:lnum)
  return item is v:null ? {} : {'item': item, 'column': '', 'text': ''}
endfunction

" The lines of the rows by mark id, 0 for deleted rows.
function! s:row_lines(rbuf) abort
  return resource#compat#rows(a:rbuf.bufnr, keys(a:rbuf.rows))
endfunction

" The items of the deleted rows, in order.
function! resource#table#deleted(rbuf) abort
  let lines = s:row_lines(a:rbuf)
  return map(filter(sort(map(keys(lines), 'str2nr(v:val)'), 'n'), 'lines[v:val] == 0'), 'a:rbuf.rows[v:val].item')
endfunction

" The diagnostics of the line {lnum}: [{message, severity}].
function! resource#table#diagnostics(buf, lnum) abort
  let rbuf = resource#buffer#get(a:buf)
  let placed = sign_getplaced(a:buf, {'group': 'resource', 'lnum': a:lnum})[0].signs
  return map(filter(placed, 'has_key(rbuf.diagnostics, v:val.id)'), 'rbuf.diagnostics[v:val.id]')
endfunction

" The lines with diagnostics, in order.
function! resource#table#diagnostic_lines(buf) abort
  let placed = sign_getplaced(a:buf, {'group': 'resource'})[0].signs
  return uniq(sort(map(placed, 'v:val.lnum'), 'n'))
endfunction

" ---------------------------------------------------------------------------
" Formatting

" Text cut to {width} display cells, ending with ...
function! s:truncate(text, width) abort
  if a:text !~# '[^\x00-\x7f]'
    return strpart(a:text, 0, a:width - 3) . '...'
  endif
  let result = ''
  let used = 0
  for char in split(a:text, '\zs')
    let used += strwidth(char)
    if used > a:width - 3
      break
    endif
    let result .= char
  endfor
  return result . '...'
endfunction

" Align the cells of {row} to {widths}: returns [line, ranges], the ranges are
" the 0-indexed byte ranges [start, end) of the cells.
function! s:align(row, widths) abort
  let cells = []
  let ranges = []
  let pos = 0
  for i in range(len(a:widths))
    let width = min([s:MAX_COLUMN_WIDTH, a:widths[i]])
    let cell = get(a:row, i, '')
    let cell_width = strwidth(cell)
    if cell_width > width
      let cell = s:truncate(cell, width)
      let cell_width = strwidth(cell)
    endif
    let cell .= repeat(' ', width - cell_width)
    call add(cells, cell)
    call add(ranges, [pos, pos + len(cell)])
    let pos += len(cell) + len(s:SEPARATOR)
  endfor
  return [join(cells, s:SEPARATOR), ranges]
endfunction

" Format {rows} (see resource#render()) under {headers}: returns [header,
" formatted rows], the header is the line, a formatted row {formatted (the
" line), cells, ranges, highlights, diagnostics, item}.
function! resource#table#format(headers, rows) abort
  let widths = []
  for i in range(len(a:headers))
    let width = strwidth(a:headers[i])
    for row in a:rows
      let width = max([width, strwidth(get(row.row, i, ''))])
    endfor
    call add(widths, width)
  endfor

  let formatted_rows = []
  for row in a:rows
    let [formatted, ranges] = s:align(row.row, widths)
    call add(formatted_rows, {
          \ 'formatted': formatted,
          \ 'ranges': ranges,
          \ 'cells': row.row,
          \ 'highlights': s:dict(get(row, 'highlights', {})),
          \ 'diagnostics': get(row, 'diagnostics', []),
          \ 'item': get(row, 'item', v:null),
          \ })
  endfor
  return [s:align(a:headers, widths)[0], formatted_rows]
endfunction

" ---------------------------------------------------------------------------
" Rendering

" Remember the row under the cursor of every window showing the buffer.
function! s:save_cursors(rbuf, provider) abort
  let saved = []
  for win in win_findbuf(a:rbuf.bufnr)
    let [lnum, col] = getcurpos(win)[1:2]
    call add(saved, {'win': win, 'cursor': [lnum, col],
          \ 'identity': s:identity(a:provider, resource#table#item(a:rbuf, lnum))})
  endfor
  return saved
endfunction

" Move the cursors back to the rows of the same items, or keep the line when
" the item is gone.
function! s:restore_cursors(saved, provider, rows) abort
  for entry in a:saved
    let lnum = min([entry.cursor[0], max([len(a:rows), 1])])
    if !empty(entry.identity)
      for i in range(len(a:rows))
        if s:identity(a:provider, a:rows[i].item) ==# entry.identity
          let lnum = i + 1
          break
        endif
      endfor
    endif
    call win_execute(entry.win, printf('call cursor(%d, %d)', lnum, entry.cursor[1]))
  endfor
endfunction

function! s:signature(provider, headers, cells) abort
  let values = []
  for i in range(len(a:headers))
    if index(get(a:provider, 'volatile', []), a:headers[i]) < 0
      call add(values, get(a:cells, i, ''))
    endif
  endfor
  return join(values, "\x01")
endfunction

" The signatures of the rendered rows by identity, v:null before the first
" render.
function! s:signatures(rbuf, provider) abort
  if empty(a:rbuf.rows)
    return v:null
  endif
  let result = {}
  for row in values(a:rbuf.rows)
    let identity = s:identity(a:provider, row.item)
    if !empty(identity)
      let result[identity] = row.signature
    endif
  endfor
  return result
endfunction

" Highlight the lines {lnums} for a moment.
function! s:flash(rbuf, prefix, lnums) abort
  if empty(a:lnums)
    return
  endif
  for lnum in a:lnums
    call resource#compat#line_hl(a:rbuf.bufnr, 'changed', lnum, a:prefix . 'Changed')
  endfor
  let a:rbuf.flash_generation += 1
  let generation = a:rbuf.flash_generation
  " A later reload flashes its own rows
  call timer_start(s:FLASH_DURATION, {-> a:rbuf.flash_generation == generation
        \ ? resource#compat#clear(a:rbuf.bufnr, 'changed') : 0})
endfunction

let s:SIGNS = {'error': 'SignError', 'warn': 'SignWarn', 'info': 'SignInfo'}

" See resource#render().
function! resource#table#render(rbuf, table) abort
  let rbuf = a:rbuf
  let buf = rbuf.bufnr
  " Edits made while a background reload was running win over the reload
  if !bufloaded(buf) || (rbuf.silent && getbufvar(buf, '&modified'))
    return
  endif
  let provider = s:provider(rbuf)
  let prefix = resource#highlight_prefix(provider)
  let headers = a:table.headers
  let cursors = s:save_cursors(rbuf, provider)
  let previous = s:signatures(rbuf, provider)

  for kind in ['row', 'body', 'cell', 'pending', 'changed']
    call resource#compat#clear(buf, kind)
  endfor
  call sign_unplace('resource', {'buffer': buf})
  let rbuf.rows = {}
  let rbuf.cells = {}
  let rbuf.diagnostics = {}
  let rbuf.table = a:table

  let [header, rows] = resource#table#format(headers, a:table.rows)
  let rbuf.header_row = {'formatted': header, 'highlight': prefix . 'Header'}
  call resource#set_lines(rbuf, map(copy(rows), 'v:val.formatted'), {'modifiable': 1})
  call s:restore_cursors(cursors, provider, rows)
  if empty(rows)
    call resource#status(rbuf, get(a:table, 'empty', 'Nothing found'))
  endif

  let editable = s:dict(get(a:table, 'editable', {}))
  let changed = []
  let lnum = 0
  for row in rows
    let lnum += 1
    let row_mark = v:null
    if row.item isnot v:null
      let row_mark = resource#compat#mark_row(buf, lnum, prefix . 'Body')
      let signature = s:signature(provider, headers, row.cells)
      let rbuf.rows[row_mark] = {'item': row.item, 'line': row.formatted, 'signature': signature}
      let identity = s:identity(provider, row.item)
      let before = previous is v:null ? signature : get(previous, identity, v:null)
      if !empty(identity) && (type(before) != v:t_string || before !=# signature)
        call add(changed, lnum)
      endif
    endif

    for i in range(len(row.ranges))
      let [start, end] = row.ranges[i]
      let column = headers[i]
      let hl = get(row.highlights, column, has_key(editable, column) ? prefix . 'Editable' : '')
      let id = resource#compat#mark_cell(buf, lnum, start, end, hl)
      let rbuf.cells[id] = {'item': row.item, 'column': column, 'text': trim(strpart(row.formatted, start, end - start)), 'row': row_mark}
    endfor

    for diagnostic in row.diagnostics
      let id = sign_place(0, 'resource', prefix . s:SIGNS[diagnostic.severity], buf, {'lnum': lnum})
      let rbuf.diagnostics[id] = diagnostic
    endfor
  endfor

  for win in win_findbuf(buf)
    " Wrapped rows break the table layout and its alignment with the header
    call win_execute(win, 'setlocal nowrap')
  endfor
  " After the signs, which may change the width of the sign column the header
  " is aligned with
  call resource#buffer#update_header(rbuf)
  " Only reloads of a watched list: a reload asked for shows the changes it
  " was asked for
  if rbuf.silent
    call s:flash(rbuf, prefix, changed)
  endif
endfunction

" Show the rows deleted from the buffer, which :w deletes, where they were:
" above the next row, below the last line when no row is left after them.
function! resource#table#show_pending(rbuf) abort
  let buf = a:rbuf.bufnr
  call resource#compat#clear(buf, 'pending')
  let lines = s:row_lines(a:rbuf)
  " Marks are created in the order of the rows
  let ids = sort(map(keys(lines), 'str2nr(v:val)'), 'n')
  let groups = []
  let deleted = []
  for id in ids
    if lines[id] == 0
      call add(deleted, a:rbuf.rows[id].line)
    elseif !empty(deleted)
      call add(groups, [lines[id], deleted, 1])
      let deleted = []
    endif
  endfor
  if !empty(deleted)
    call add(groups, [len(getbufline(buf, 1, '$')), deleted, 0])
  endif
  let hl = resource#highlight_prefix(s:provider(a:rbuf)) . 'Deleted'
  for [lnum, rows, above] in groups
    call resource#compat#virt_lines(buf, lnum, rows, hl, above)
  endfor
endfunction

" ---------------------------------------------------------------------------
" :w

" The changes of the edited cells: [changes, errors], the errors of the
" invalid edits and of the cells of columns that cannot be edited.
function! s:cell_changes(rbuf, provider, lines) abort
  let changes = []
  let errors = []
  let editable = s:dict(get(a:rbuf.table, 'editable', {}))
  let cells = resource#compat#cells(a:rbuf.bufnr)
  " Marks are created in the order of the cells
  for id in sort(map(keys(a:rbuf.cells), 'str2nr(v:val)'), 'n')
    let cell = a:rbuf.cells[id]
    if cell.item is v:null || cell.row is v:null || get(a:lines, cell.row, 0) == 0
      continue
    endif
    " A cell whose text was deleted may be gone
    let text = ''
    if has_key(cells, id)
      let [lnum, start, end] = cells[id][0:2]
      let text = trim(strpart(getbufline(a:rbuf.bufnr, lnum)[0], start, end - start))
    endif
    if text ==# cell.text
      continue
    endif
    if !has_key(editable, cell.column)
      call add(errors, printf('%s of %s is not editable', cell.column, resource#table#label(a:provider, cell.item)))
      continue
    endif
    let [change, err] = editable[cell.column](a:rbuf, cell.item, cell.text, text)
    if change is v:null
      call add(errors, err)
    else
      call add(changes, change)
    endif
  endfor
  return [changes, errors]
endfunction

" Apply the edits of the cells and delete the items of the deleted rows,
" after confirming unless {force}. {Done}(saved).
function! resource#table#save(rbuf, force, Done) abort
  let provider = s:provider(a:rbuf)
  let lines = s:row_lines(a:rbuf)
  let [changes, errors] = s:cell_changes(a:rbuf, provider, lines)
  if !empty(errors)
    call resource#notify(join(errors, "\n"), 'error')
    call a:Done(0)
    return
  endif

  " In the order of the rows
  for id in sort(map(keys(lines), 'str2nr(v:val)'), 'n')
    if lines[id] == 0 && has_key(provider, 'delete')
      let change = provider.delete(a:rbuf, a:rbuf.rows[id].item)
      if type(change) == v:t_dict
        call add(changes, change)
      endif
    endif
  endfor

  if empty(changes)
    call a:Done(1)
    return
  endif
  if a:force
    call s:apply(changes, a:Done)
    return
  endif
  let prompt = resource#table#prompt(a:rbuf, 'Apply the changes') . "\n" . join(map(copy(changes), '"  " . v:val.title'), "\n")
  call resource#confirm(prompt, {yes -> yes ? s:apply(changes, a:Done) : a:Done(0)})
endfunction

" {text} (scope)?
function! resource#table#prompt(rbuf, text) abort
  let provider = s:provider(a:rbuf)
  let scope = has_key(provider, 'scope') ? provider.scope(a:rbuf) : ''
  return empty(scope) ? a:text . '?' : printf('%s (%s)?', a:text, scope)
endfunction

" Run the changes, {Done}(1) once all are done, failed or not.
function! s:apply(changes, Done) abort
  let state = {'remaining': len(a:changes)}
  for change in a:changes
    call s:wait(change.run(), 'Failed: ' . change.title . "\n", state, a:Done)
  endfor
endfunction

" Wait for {job}, notify its output, or its error after {failed}. Once the
" jobs of {state} are done, call {Done}(1).
function! s:wait(job, failed, state, Done) abort
  if !resource#compat#on_exit(a:job, function('s:done', [a:failed, a:state, a:Done]))
    call s:done(a:failed, a:state, a:Done, 0, '', '')
  endif
endfunction

function! s:done(failed, state, Done, code, stdout, stderr) abort
  if a:code != 0
    call resource#notify(a:failed . trim(a:stderr), 'error')
  elseif trim(a:stdout) !=# ''
    call resource#notify(trim(a:stdout))
  endif
  let a:state.remaining -= 1
  if a:state.remaining == 0
    call a:Done(1)
  endif
endfunction

" See resource#run().
function! resource#table#run(rbuf, items, Call, prompt) abort
  if !empty(a:prompt)
    call resource#confirm(resource#table#prompt(a:rbuf, a:prompt),
          \ {yes -> yes ? resource#table#run(a:rbuf, a:items, a:Call, '') : 0})
    return
  endif
  let state = {'remaining': len(a:items)}
  let Done = {... -> resource#buffer#load(a:rbuf, {})}
  for item in a:items
    call s:wait(a:Call(item), '', state, Done)
  endfor
endfunction
