vim9script
# A provider in vim9script, see tests/test_vim9.vim

def Parse(name: string): dict<any>
  return {kind: resource#parse(name).segments[0]}
enddef

def Load(rbuf: dict<any>): dict<any>
  return resource#job(['sh', '-c', 'printf "a 1\nb 2\n"'], {
    on_exit: (code: number, stdout: string, stderr: string) => {
      var rows = split(stdout, "\n")->mapnew((_, line) => {
        var [name, value] = split(line)
        return {row: [name, value], item: {name: name, value: value}}
      })
      resource#render(rbuf, {headers: ['N', 'V'], rows: rows})
    }})
enddef

resource#register({name: 'nine', parse: Parse, load: Load, label: (item) => 'nine ' .. item.name})

def g:Vim9Checks()
  var rbuf = resource#get(bufnr())
  assert_equal('b', resource#item(rbuf, 2).name)
  assert_equal('nine a, nine b', resource#describe(rbuf, resource#items(rbuf, 1, 2)))
  assert_equal(10000, resource#config('nine', 'refresh_interval'))
enddef
