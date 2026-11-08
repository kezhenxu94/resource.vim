" A fake provider for the tests: fake://{kind}[/{name}[/{view}]][?{params}].
" Lists are read by `cat` from $FAKE_DIR/{kind}.json, an array of {name,
" status, owner, age}, see SetItems(). fake:// is an alias of fake://things.

function! fake#register(...) abort
  call resource#register(extend({
        \ 'name': 'fake',
        \ 'title': 'fake.vim',
        \ 'parse': function('fake#parse'),
        \ 'canonical': function('fake#canonical'),
        \ 'load': function('fake#load'),
        \ 'term': function('fake#term'),
        \ 'identity': {item -> item.name},
        \ 'label': {item -> 'thing ' . item.name},
        \ 'scope': {rbuf -> 'ctx: test'},
        \ 'parent': function('fake#parent'),
        \ 'tag': function('fake#tag'),
        \ 'delete': function('fake#delete'),
        \ 'operations': function('fake#operations'),
        \ 'keymaps': {
        \   'drill_down': {'lhs': '<CR>', 'desc': 'open the item', 'run': function('fake#drill_down')},
        \   'refresh': {'desc': 'reload the things'},
        \ },
        \ 'highlights': {'FakeBad': ['NoSuchGroup', 'ErrorMsg']},
        \ 'help': ['', 'More in :help fake'],
        \ 'volatile': ['AGE'],
        \ 'defaults': {'refresh_interval': 200, 'answer': 42},
        \ }, get(a:, 1, {})))
endfunction

function! fake#parse(name) abort
  let parts = resource#parse(a:name)
  if empty(parts.segments)
    throw 'Invalid fake name: ' . a:name
  endif
  let [kind, name, view] = (parts.segments + ['', '', ''])[0:2]
  return {'kind': kind, 'name': name, 'view': view, 'params': parts.params}
endfunction

function! fake#canonical(name) abort
  if a:name ==# 'fake://nope'
    throw 'No such fake'
  endif
  return a:name ==# 'fake://' ? 'fake://things' : substitute(a:name, '^fake://alias\>', 'fake://things', '')
endfunction

function! fake#term(fields) abort
  return a:fields.view ==# 'shell' ? ['sh'] : v:null
endfunction

function! fake#load(rbuf) abort
  if a:rbuf.name ==# ''
    return resource#job(['cat', $FAKE_DIR . '/' . a:rbuf.kind . '.json'], {'on_exit': function('s:on_list', [a:rbuf])})
  elseif a:rbuf.view ==# ''
    call resource#set_lines(a:rbuf, ['name: ' . a:rbuf.name], {'writable': 0})
    return {}
  elseif a:rbuf.view ==# 'logs'
    return resource#logs(a:rbuf, ['sh', '-c', get(g:, 'fake_logs', 'echo log')], get(a:rbuf.params, 'follow') is v:true)
  endif
  call resource#error(a:rbuf, 'Unknown view: ' . a:rbuf.view)
  return {}
endfunction

function! s:on_list(rbuf, code, out, err) abort
  if a:code != 0
    call resource#error(a:rbuf, trim(a:err))
    return
  endif
  let rows = []
  for item in json_decode(a:out)
    let bad = item.status ==# 'bad'
    call add(rows, {'row': [item.name, item.status, get(item, 'owner', ''), get(item, 'age', '')], 'item': item,
          \ 'highlights': bad ? {'STATUS': 'FakeBad'} : {},
          \ 'diagnostics': bad ? [{'message': item.name . ' is bad', 'severity': 'error'}] : []})
  endfor
  call resource#render(a:rbuf, {'headers': ['NAME', 'STATUS', 'OWNER', 'AGE'], 'rows': rows, 'empty': 'No things',
        \ 'editable': {'STATUS': function('fake#edit_status')}})
endfunction

" The calls of the changes and operations, their job echoes done: {text},
" or fails when {text} contains fail.
let g:fake_calls = []

function! s:call(text) abort
  call add(g:fake_calls, a:text)
  return resource#job(['sh', '-c', a:text =~# 'fail' ? 'echo it failed >&2; exit 1' : 'echo done: ' . a:text], {})
endfunction

function! fake#edit_status(rbuf, item, old, new) abort
  if a:new !~# '^\l\+$'
    return [v:null, 'Invalid status: ' . a:new]
  endif
  return [{'title': printf('Set status of %s: %s → %s', a:item.name, a:old, a:new),
        \ 'run': function('s:call', ['status ' . a:item.name . ' ' . a:new])}, '']
endfunction

function! fake#delete(rbuf, item) abort
  return a:item.name ==# 'keep' ? v:null : {'title': 'Delete ' . a:item.name, 'run': function('s:call', ['delete ' . a:item.name])}
endfunction

function! fake#parent(rbuf) abort
  return a:rbuf.name ==# '' ? '' : resource#name('fake', [a:rbuf.kind])
endfunction

function! fake#tag(rbuf, cell) abort
  if a:cell.item.name ==# 'notag'
    return ''
  elseif a:cell.column ==# 'OWNER'
    return a:cell.text ==# '' ? '' : resource#name('fake', [a:rbuf.kind], {'owner': a:cell.text})
  endif
  return resource#name('fake', [a:rbuf.kind, a:cell.item.name])
endfunction

function! fake#drill_down(rbuf) abort
  let item = resource#item(a:rbuf)
  if item isnot v:null
    call resource#open(resource#name('fake', [a:rbuf.kind, item.name, 'logs']))
  endif
endfunction

function! fake#operations(rbuf, items) abort
  let Touch = {item -> s:call('touch ' . item.name)}
  return [
        \ {'title': 'Touch', 'run': {-> resource#run(a:rbuf, a:items, Touch)}},
        \ {'title': 'Break', 'run': {-> resource#run(a:rbuf, a:items, Touch, 'Break ' . resource#describe(a:rbuf, a:items))}},
        \ ]
endfunction
