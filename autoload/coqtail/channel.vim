" Author: Wolf Honore
" Python communication channels.

function! coqtail#channel#new() abort
  let l:chan = {'handle': -1}
  for l:f in ['open', 'close', 'status', 'sendexpr', 'evalexpr']
    let l:chan[l:f] = function('s:' . l:f)
  endfor
  return l:chan
endfunction

if g:coqtail#compat#has_channel && !g:coqtail#compat#nvim
  " Channel options.
  let s:chanopts = {'mode': 'json'}

  function! s:open(address) dict abort
    let self.handle = ch_open(a:address, s:chanopts)
    return self.handle
  endfunction

  function! s:close() dict abort
    return ch_close(self.handle)
  endfunction

  function! s:status() dict abort
    return ch_status(self.handle)
  endfunction

  function! s:sendexpr(expr, options) dict abort
    return ch_sendexpr(self.handle, a:expr, a:options)
  endfunction

  function! s:evalexpr(expr, options) dict abort
    return ch_evalexpr(self.handle, a:expr, a:options)
  endfunction
elseif g:coqtail#compat#nvim
  " Handle replies from Coqtail.
  function! s:chanrecv(handle, msg, event) abort
    " Complete partial reply.
    let s:replies_raw[-1] .= a:msg[0]
    let s:replies_raw += a:msg[1:]

    " Try to parse replies
    for l:idx in range(len(s:replies_raw))
      let l:reply = s:replies_raw[l:idx]
      try
        let l:res = json_decode(l:reply)
        if l:res[0] ==# 'call'
          let [l:func, l:args; l:msg_id] = l:res[1:]
          let l:val = call(l:func, l:args)
          " Reply only if expected
          if len(l:msg_id) == 1
            call chansend(a:handle, [json_encode([l:msg_id[0], l:val]), ''])
          endif
        else
          let [l:msg_id, l:data] = l:res
          let s:replies[l:msg_id] = l:data
        endif
      catch /^Vim\%((\a\+)\)\=:E474/
        let l:idx -= 1
        break
      endtry
    endfor

    " Remove parsed replies
    let s:replies_raw = s:replies_raw[l:idx + 1:]
  endfunction

  " Channel options.
  let s:chanopts = {'on_data': function('s:chanrecv'), 'data_buffered': 0}

  " Rate in ms to check if Coqtail is done computing.
  let s:poll_rate = 10

  " Unique message ID.
  let s:msg_id = 0

  " Coqtail responses to messages.
  let s:replies_raw = ['']
  let s:replies = {}

  function! s:open(address) dict abort
    let self.handle = sockconnect('tcp', a:address, s:chanopts)
    return self.handle
  endfunction

  function! s:close() dict abort
    return chanclose(self.handle)
  endfunction

  function! s:status() dict abort
    return nvim_get_chan_info(self.handle) != {} ? 'open' : ''
  endfunction

  function! s:send(handle, expr) abort
    let s:msg_id += 1
    let l:msg = json_encode([s:msg_id, a:expr])
    call chansend(a:handle, [l:msg, ''])
    return s:msg_id
  endfunction

  function! s:sendexpr(expr, options) dict abort
    call s:send(self.handle, a:expr)
  endfunction

  function! s:evalexpr(expr, options) dict abort
    let l:msg_id = s:send(self.handle, a:expr)
    let s:replies[l:msg_id] = {}
    while s:replies[l:msg_id] == {}
      execute printf('sleep %dm', s:poll_rate)
    endwhile
    let l:res = s:replies[l:msg_id]
    unlet s:replies[l:msg_id]
    return l:res
  endfunction
else
  " Rate in ms to check if Coqtail is done computing.
  let s:poll_rate = 10

  " Unique session ID.
  let s:session = 0

  function! s:open(address) dict abort
    let self.handle = coqtail#compat#pyeval(printf(
      \ 'ChannelManager.open("%s")', a:address
    \))
    return self.handle
  endfunction

  function! s:close() dict abort
    return coqtail#compat#pyeval(printf('ChannelManager.close(%d)', self.handle))
  endfunction

  function! s:status() dict abort
    return coqtail#compat#pyeval(printf('ChannelManager.status(%d)', self.handle))
  endfunction

  function! s:sendexpr(expr, options) dict abort
    echoerr 'Calling ch_sendexpr in synchronous mode.'
  endfunction

  " Send a command to Coqtail and wait for the response.
  function! s:send_wait(handle, session, expr, reply) abort
    let l:returns = a:expr[1] !=# 'interrupt'
    call coqtail#compat#pyeval(printf(
      \ 'ChannelManager.send(%d, %s, %s, reply=%s, returns=bool(%s))',
      \ a:handle,
      \ a:expr[1] !=# 'interrupt' ? a:session : 'None',
      \ json_encode(a:expr),
      \ a:reply != 0 ? a:reply : 'None',
      \ l:returns
    \))

    " Continually check if Coqtail is done computing
    let l:poll = printf('ChannelManager.poll(%d)', a:handle)
    while l:returns
      let l:res = json_decode(coqtail#compat#pyeval(l:poll))
      if type(l:res) == g:coqtail#compat#t_list
        return l:res
      endif

      execute printf('sleep %dm', s:poll_rate)
    endwhile

    return v:null
  endfunction

  " Send a command to execute and reply to any requests from Coqtail.
  function! s:evalexpr(expr, options) dict abort
    let s:session += 1
    let l:session = s:session
    let l:res = v:null
    let l:did_int = 0

    " Retry until Coqtop responds
    while 1
      try
        let l:res = s:send_wait(self.handle, l:session, a:expr, 0)

        " Handle requests
        while type(l:res) == g:coqtail#compat#t_list && l:res[0] ==# 'call'
          let l:val = call(l:res[1], l:res[2])
          let l:res = s:send_wait(self.handle, l:session, l:val, l:res[-1])
        endwhile
      catch /^Vim:Interrupt$/
        " Interrupt Coqtop and retry
        if l:did_int
          call coqtail#util#err('Coqtail is stuck. Try restarting to fix.')
          return v:null
        endif
        let l:did_int = 1
        call s:send_wait(self.handle, l:session, [a:expr[0], 'interrupt', {}], 0)
        continue
      endtry

      return type(l:res) == g:coqtail#compat#t_list ? l:res[1] : v:null
    endwhile
  endfunction
endif
