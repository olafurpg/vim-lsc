" Use InsertCharPre to reliably know what is typed, but don't send the
" completion request until the file reflects the inserted character. Track typed
" characters in `s:next_char` and use CursorMovedI to act on the change.
"
" Every typed character can potentially start a completion request:
" - "Trigger" characters (.) always start a completion request when they are
"   typed
" - Characters that match '\w' start a completion in words of at least length 3

function! lsc#complete#insertCharPre() abort
  let s:next_char = v:char
endfunction

function! lsc#complete#textChanged() abort
  if &paste | return | endif
  " This may be <BS> or similar if not due to a character typed
  if empty(s:next_char) | return | endif
  call s:typedCharacter()
  let s:next_char = ''
endfunction

function! s:typedCharacter() abort
  if s:isTrigger(s:next_char) || (s:isCompletable() && !s:completion_waiting)
    let b:lsc_is_completing = v:true
    call s:startCompletion()
  else
    let s:completion_canceled = v:true
  endif
endfunction

if !exists('s:initialized')
  let s:next_char = ''
  let s:completion_waiting = v:false
  let s:completion_id = 1
  let s:completion_canceled = v:false
  let s:initialized = v:true
endif

" TODO: Make this customizable
function! s:isTrigger(char) abort
  return a:char == '.'
endfunction

augroup LscCompletion
  autocmd!
  autocmd CompleteDone * let b:lsc_is_completing = v:false
augroup END

" TODO: Make this customizable
" Whether the cursor follows at least 3 word characters, and completion isn't
" already in progress.
function! s:isCompletable() abort
  if exists('b:lsc_is_completing') && b:lsc_is_completing
    return v:false
  endif
  if s:next_char !~ '\w' | return v:false | endif
  let cur_col = col('.')
  if cur_col < 4 | return v:false | endif
  let word = getline('.')[cur_col - 4:cur_col - 2]
  return word =~ '^\w*$'
endfunction

" Whether the completion should still go through.
"
" - A new completion has not been started
" - Cursor position hasn't changed
" - Completion was not canceled
" TODO: Allow cursor position to change some
function! s:isCompletionValid(old_pos, completion_id) abort
  return a:completion_id == s:completion_id &&
      \ a:old_pos == getcurpos() &&
      \ !s:completion_canceled
endfunction

function! s:startCompletion() abort
  let s:completion_id += 1
  let s:completion_canceled = v:false
  let s:completion_waiting = v:true
  let data = {'old_pos': getcurpos(), 'completion_id': s:completion_id}
  function data.trigger(completions)
    let s:completion_waiting = v:false
    if s:isCompletionValid(self.old_pos, self.completion_id)
      call s:SuggestCompletions(a:completions)
    else
      let b:lsc_is_completing = v:false
    endif
  endfunction
  call s:SearchCompletions(data.trigger)
endfunction

function! s:SuggestCompletions(completion) abort
  if mode() != 'i' || len(a:completion.items) == 0 | return | endif
  let start = s:FindStart(a:completion)
  let suggestions = a:completion.items
  setl completeopt-=longest
  setl completeopt+=menu,menuone,noinsert,noselect
  call complete(start + 1, suggestions)
endfunction

function! s:FindStart(completion) abort
  if has_key(a:completion, 'start_col')
    return a:completion.start_col
  endif
  return s:GuessCompletionStart()
endfunction

" Finds the character after the last non word character behind the cursor.
function! s:GuessCompletionStart()
  let search = col('.') - 2
  let line = getline('.')
  while search > 0
    let char = line[search]
    if char !~ '\w'
      return search + 1
    endif
    let search -= 1
  endwhile
  " TODO: ??? completion at the beginning of the line?
  return 0
endfunction

" Flush file contents and call the server to request completions for the current
" cursor position.
function! s:SearchCompletions(onFound) abort
  call lsc#file#flushChanges()
  let params = { 'textDocument': {'uri': lsc#util#documentUri()},
      \ 'position': {'line': line('.') - 1, 'character': col('.') - 1}
      \ }
  call lsc#server#call(&filetype, 'textDocument/completion', params,
      \ lsc#util#compose(a:onFound, function('<SID>CompletionItems')))
endfunction

" Normalize LSP completion suggestions to the format used by vim.
"
" Returns a dict with:
" `items`: The vim complete-item values
" `start_col`: The start of the first range found, if any, in the suggestions
"
" Since different suggestions could, in theory, specify different ranges
" autocomplete behavior could be incorrect since vim `complete` only allows a
" single start columng for every suggestion.
function! s:CompletionItems(completion_result) abort
  if type(a:completion_result) == type([])
    let completion_items = a:completion_result
  else
    let completion_items = a:completion_result.items
  endif
  call map(completion_items, 's:CompletionItem(v:val)')
  let completion = {'items' : completion_items}
  for item in completion_items
    if has_key(item, 'start_col')
      let completion.start_col = item.start_col
      break
    endif
  endfor
  return completion
endfunction

" Translate from the LSP representation to the Vim representation of a
" completion item.
"
" `word` suggestions are taken from the highest priority field according to
" order `textEdit` > `insertText` > `label`.
" `label` is always expectes to be set and is used as the `abbr` shown in the
" popupmenu. This may be different from the inserted text.
function! s:CompletionItem(completion_item) abort
  let item = {'abbr': a:completion_item.label}
  if has_key(a:completion_item, 'textEdit')
    let item.word = a:completion_item.textEdit.newText
    let item.start_col = a:completion_item.textEdit.range.start.character + 1
  elseif has_key(a:completion_item, 'insertText')
    let item.word = a:completion_item.insertText
  else
    let item.word = a:completion_item.label
  endif
  if has_key(a:completion_item, 'kind')
    let item.kind = s:CompletionItemKind(a:completion_item.kind)
  endif
  if has_key(a:completion_item, 'detail') && a:completion_item.detail != v:null
    let item.menu = a:completion_item.detail
  endif
  if has_key(a:completion_item, 'documentation')
      \ && a:completion_item.documentation != v:null
    let item.info = a:completion_item.documentation
  else
    let item.info = ' '
  endif
  return item
endfunction

function! s:CompletionItemKind(completion_kind) abort
  if a:completion_kind ==  2
      \ || a:completion_kind == 3
      \ || a:completion_kind == 4
    " Method, Function, Constructor
    return 'f'
  elseif a:completion_kind == 5 " Field
    return 'm'
  elseif a:completion_kind == 6 " Variable
    return 'v'
  elseif a:completion_kind == 7
      \ || a:completion_kind == 8
      \ || a:completion_kind == 13
    " Class, Interface, Enum
    return 't'
  elseif a:completion_kind == 14
      \ a:completion_kind == 11
      \ a:completion_kind == 12
      \ a:completion_kind == 1
      \ a:completion_kind == 16
    " Keyword, Unit, Value, Text, Color
    return 'd'
  endif
  " Many kinds are unmapped
  return ''
endfunction
