sys            = require 'sys'
client         = require 'nack/client'
{spawn}        = require 'child_process'

{EventEmitter}       = require 'events'
{BufferedReadStream} = require 'nack/buffered'

tmpSock = () ->
  pid  = process.pid
  rand = Math.floor Math.random() * 10000000000
  "/tmp/nack." + pid + "." + rand + ".sock"

exports.Process = class Process extends EventEmitter
  constructor: (@config, options) ->
    options ?= {}
    @idle  = options.idle
    @state = null

  spawn: ->
    return if @state

    @state = 'spawning'
    @sockPath = tmpSock()
    @child = spawn "nackup", ['--file', @sockPath, @config]

    @stdout = @child.stdout
    @stderr = @child.stderr

    ready = () =>
      if !@ready
        @state = 'ready'
        @emit 'ready'

    @stdout.on 'data', ready
    @stderr.on 'data', ready

    @child.on 'exit', (code, signal) =>
      @clearTimeout()
      @state = @sockPath = @child = null
      @stdout = @stderr = null
      @emit 'exit'

    @child.on 'ready', () =>
      @deferTimeout()

    @emit 'spawn'

    this

  onceOn: (event, listener) ->
    callback = (args...) =>
      @removeListener event, callback
      listener args...
    @on event, callback

  whenReady: (callback) ->
    if @child and @state is 'ready'
      callback()
    else
      @spawn()
      @onceOn 'ready', callback

  clearTimeout: () ->
    if @_timeoutId
      clearTimeout @_timeoutId

  deferTimeout: () ->
    if @idle
      @clearTimeout()

      callback = () =>
        @emit 'idle'
        @quit()
      @_timeoutId = setTimeout callback, @idle

  proxyRequest: (req, res, callback) ->
    @deferTimeout()

    reqBuf = new BufferedReadStream req
    @whenReady () =>
      connection = client.createConnection @sockPath
      connection.proxyRequest reqBuf, res, callback
      reqBuf.flush()

  quit: () ->
    if @child
      @child.kill 'SIGQUIT'

exports.createProcess = (args...) ->
  new Process args...
