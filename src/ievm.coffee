# # IEVM

# This class represents an ievms VM and its current state, as queried through
# Virtualbox and the [modern.ie](http://modern.ie) website.

fs = require 'fs'
path = require 'path'
Q = require 'q'
url = require 'url'
http = require 'http'
child_process = require 'child_process'
debug = require 'debug'

class IEVM
  # ## Class Properties

  # A list of all available IE versions.
  @versions: [6, 7, 8, 9, 10]

  # A list of all available OS names.
  @oses: ['WinXP', 'Vista', 'Win7', 'Win8']

  # A list of all supported ievms version/OS combos.
  @names: [
    'IE6 - WinXP'
    'IE7 - WinXP'
    'IE8 - WinXP'
    'IE7 - Vista'
    'IE8 - Win7'
    'IE9 - Win7'
    'IE10 - Win8'
  ]

  # A list of possible VM statuses.
  @status:
    MISSING: -1
    POWEROFF: 0
    RUNNING: 1
    PAUSED: 2
    SAVED: 3

  # A list of initial rearms available per OS.
  @rearms:
    WinXP: 0
    Vista: 0
    Win7: 5
    Win8: 0

  # The ievms home (`INSTALL_PATH` in ievms parlance).
  @home: path.join process.env.HOME, '.ievms'

  # The command used to install virtual machines via ievms.
  @ievmsCmd: 'curl -s https://raw.github.com/xdissent/ievms/master/ievms.sh | bash'
  # @ievmsCmd: 'cd ~/Code/ievms && cat ievms.sh | bash'

  # ## Class Methods

  # Run ievms shell script with a given environment. A debug function may be
  # passed (like `console.log`) which will be called for each line of ievms
  # output.
  @ievms: (env, debug) ->
    deferred = Q.defer()
    cmd = ['bash', '-c', @ievmsCmd]
    debug "ievms: #{cmd.join ' '}" if debug?
    ievms = child_process.spawn cmd.shift(), cmd, env: env
    ievms.on 'error', (err) -> deferred.reject err
    ievms.on 'exit', -> deferred.resolve true
    if debug? then ievms.stdout.on 'readable', ->
      out = ievms.stdout.read()
      debug "ievms: #{l}" for l in out.toString().trim().split "\n" if out?
    deferred.promise

  # Build a list with an IEVM instance of each available type.
  @all: -> new @ n for n in @names

  # Build a list of all IEVM instances that match the given name, which may be
  # a specific VM (`IE6 - WinXP`), an IE version number (`9` or `7`) or an OS
  # name (`WinXP` or `Vista`).
  @find: (name) ->
    throw new Error "No name specified" unless name?
    if typeof name isnt 'string' and typeof name isnt 'number'
      throw new Error "Invalid name: '#{name}'"
    return [new IEVM name] if name.match /^IE/
    if name.match /^(Win|Vista)/
      return (new IEVM n for n in @names when n.match "- #{name}")
    if !name.match(/^\d+$/) or parseInt(name) not in @versions
      throw new Error "Invalid name: '#{name}'"
    new IEVM n for n in @names when n.match "IE#{name}"

  # Construct a `VBoxManage` command with arguments.
  @vbm: (cmd, args=[]) ->
    args = ("'#{a}'" for a in args).join ' '
    "VBoxManage #{cmd} #{args}"

  # Parse the output from `VBoxManage list hdds` into an object.
  @parseHdds: (s) ->
    hdds = {}
    for chunk in s.split "\n\n"
      hdd = {}
      for line in chunk.split "\n"
        pieces = line.split ':'
        hdd[pieces.shift()] = pieces.join(':').trim()
      hdds[hdd.UUID] = hdd
    hdds

  # Promise the parsed output from `VBoxManage list hdds`.
  @hdds: ->
    deferred = Q.defer()
    child_process.exec @vbm('list', ['hdds']), (err, stdout, stderr) =>
      return deferred.reject err if err?
      deferred.resolve @parseHdds stdout
    deferred.promise

  # Fetch a status name for a given status value.
  @statusName: (status) -> (k for k, v of @status when v is status)[0]

  # ## Instance Methods

  # Create a new IEVM object for a given ievms VM name. The name is validated
  # against all supported ievms names. The IE version and OS are extracted from
  # the name and validated as well.
  constructor: (@name) ->
    if @name not in @constructor.names
      throw new Error "Invalid name: '#{@name}'"
    pieces = @name.split ' '
    @version = parseInt pieces[0].replace 'IE', ''
    if @version not in @constructor.versions
      throw new Error "Invalid version: '#{@version}'"
    @os = pieces.pop()
    throw new Error "Invalid OS: '#{@os}'" unless @os in @constructor.oses

  ensureMissing: ->
    @missing().then (missing) -> missing or throw new Error "not missing"
  ensureNotMissing: ->
    @missing().then (missing) -> !missing or throw new Error "missing"
  ensureRunning: ->
    @running().then (running) -> running or throw new Error "not running"
  ensureNotRunning: ->
    @running().then (running) -> !running or throw new Error "running"

  # Start the virtual machine. Throws an exception if it is already running or
  # cannot be started. If the `headless` argument is `false` (the default) then
  # the VM will be started in GUI mode.
  start: (headless=false) -> @ensureNotMissing().then =>
    @ensureNotRunning().then =>
      deferred = Q.defer()
      type = if headless then 'headless' else 'gui'
      @vbm 'startvm', ['--type', type], (err, stdout, stderr) =>
        return deferred.reject err if err?
        deferred.resolve true
      deferred.promise.then => @waitForRunning()

  # Stop the virtual machine. Throws an exception if it is not running. If the
  # `save` argument is true (the default) then the VM state is saved. Otherwise,
  # the VM is powered off immediately which may result in data loss.
  stop: (save=true) -> @ensureNotMissing().then => @ensureRunning().then =>
    @debug "stop: #{if save then 'save' else 'poweroff'}"
    deferred = Q.defer()
    cmd = if save then 'savestate' else 'poweroff'
    @vbm 'controlvm', [cmd], (err, stdout, stderr) =>
      return deferred.reject err if err?
      deferred.resolve true
    deferred.promise.then => @waitForNotRunning()

  # Gracefully restart the virtual machine by calling `shutdown.exe`. Throws an
  # exception if it is not running.
  restart: -> @ensureNotMissing().then => @ensureRunning().then =>
    @debug 'restart'
    @exec('shutdown.exe', '/r', '/t', '00').then =>
      # TODO: Should return before GC comes back online but timing is hard.
      # TODO: Bullshit Vista pops up the activation thing.
      @waitForNoGuestControl().then => @waitForGuestControl()

  # Open a URL in IE within the virtual machine. Throws an exception if it is
  # not running.
  open: (url) -> @ensureNotMissing().then => @ensureRunning().then =>
    @debug "open: #{url}"
    @exec 'cmd.exe', '/c', 'start',
      'C:\\Program Files\\Internet Explorer\\iexplore.exe', url

  close: -> @ensureRunning().then =>
    @debug 'close'
    @exec 'taskkill.exe', '/f', '/im', 'iexplore.exe'

  rearm: (delay=30000) -> @ensureNotMissing().then => @ensureRunning().then =>
    @debug 'rearm'
    @rearmsLeft().then (rearmsLeft) =>
      throw new Error "no rearms left" unless rearmsLeft > 0
      @exec('schtasks.exe', '/run', '/tn', 'rearm').then =>
        @meta().then (meta) =>
          meta.rearms = (meta.rearms ? []).concat (new Date).getTime()
          @meta(meta).then => Q.delay(delay).then => @restart().then =>
            @exec('schtasks.exe', '/run', '/tn', 'activate').then =>
              Q.delay(delay).then => @restart()

  # Uninstall the VM.
  uninstall: -> @ensureNotMissing().then => @ensureNotRunning().then =>
    @debug 'uninstall'
    deferred = Q.defer()
    @vbm 'unregistervm', ['--delete'], (err, stdout, stderr) =>
      return deferred.reject err if err?
      deferred.resolve true
    deferred.promise

  # Install the VM.
  install: -> @ensureMissing().then =>
    @debug 'install'
    @constructor.ievms @ievmsEnv(), @debug.bind @

  reinstall: -> @uninstall().then => @install()

  # Clean the VM.
  clean: (force=false) -> @ensureNotMissing().then =>
    @ensureNotRunning().then =>
      deferred = Q.defer()
      @vbm 'snapshot', ['restore', 'clean'], (err, stdout, stderr) =>
        return deferred.reject err if err?
        deferred.resolve true
      deferred.promise

  # Delete the archive.
  unarchive: ->
    @debug 'unarchive'
    @archived().then (archived) =>
      throw new Error "not archived" unless archived
      Q.nfcall fs.unlink, path.join @constructor.home, @archive()

  # Delete the ova.
  unova: ->
    @debug 'unova'
    @ovaed().then (ovaed) =>
      throw new Error "not ovaed" unless ovaed
      Q.nfcall fs.unlink, path.join @constructor.home, @ova()

  # Execute a command in the VM.
  exec: (cmd, args...) -> @ensureNotMissing().then => @ensureRunning().then =>
    @waitForGuestControl().then =>
      @debug "exec: #{cmd} #{args.join ' '}"
      deferred = Q.defer()
      pass = if @os isnt 'WinXP' then ['--password', 'Passw0rd!'] else []
      args = [
        'exec', '--image', cmd,
        '--wait-exit',
        '--username', 'IEUser', pass...,
        '--', args...
      ]
      @vbm 'guestcontrol', args, (err, stdout, stderr) =>
        return deferred.reject err if err?
        deferred.resolve true
      deferred.promise

  screenshot: (file) -> @ensureNotMissing().then => @ensureRunning().then =>
    @debug 'screenshot'
    deferred = Q.defer()
    @vbm 'controlvm', ['screenshotpng', file], (err, stdout, stderr) =>
      return deferred.reject err if err?
      deferred.resolve true
    deferred.promise

  debug: (msg) ->
    @_debug ?= debug "iectrl:#{@name}"
    @_debug msg

  # Build an environment hash to pass to ievms for installation.
  ievmsEnv: ->
    IEVMS_VERSIONS: @version
    REUSE_XP: if @version in [7, 8] and @os is 'WinXP' then 'yes' else 'no'
    INSTALL_PATH: @constructor.home
    HOME: process.env.HOME
    PATH: process.env.PATH

  # Determine the name of the zip file as used by modern.ie.
  archive: ->
    # For the reused XP vms, override the default to point to the IE6 archive.
    return "IE6_WinXP.zip" if @name in ['IE7 - WinXP', 'IE8 - WinXP']
    # Simply replace dashes and spaces with an underscore and add `.zip`.
    "#{@name.replace ' - ', '_'}.zip"

  # Determine the name of the ova file as used by modern.ie.
  ova: ->
    return "IE6 - WinXP.ova" if @name in ['IE7 - WinXP', 'IE8 - WinXP']
    "#{@name}.ova"

  # Generate the full URL to the modern.ie archive.
  url: -> "http://virtualization.modern.ie/vhd/IEKitV1_Final/VirtualBox/OSX/" +
    @archive()

  # Build the command string for a given `VBoxManage` command and arguments.
  vbm: (cmd, args, callback) ->
    return @queueVbm arguments... if @_vbm
    @_vbm = true
    command = @constructor.vbm(cmd, [@name].concat args)
    @debug "vbm: #{command}"
    child_process.exec command, =>
      callback arguments...
      @_vbm = false
      @vbm @vbmQueue.shift()... if @vbmQueue? and @vbmQueue.length > 0

  queueVbm: ->
    @vbmQueue ?= []
    @vbmQueue.push arguments

  # Parse the "machinereadable" `VBoxManage` output format.
  parse: (s) ->
    obj = {}
    for line in s.split "\n"
      pieces = line.split '='
      obj[pieces.shift()] = pieces.join('=').replace(/^"/, '').replace /"$/, ''
    obj

  _info: (deferred, retries=3, delay=250) ->
    @vbm 'showvminfo', ['--machinereadable'], (err, stdout, stderr) =>
      if stderr.match /VBOX_E_OBJECT_NOT_FOUND/
        return deferred.resolve VMState: 'missing'
      if retries > 0 and stderr.match /E_ACCESSDENIED/
        @debug "info: retrying (#{retries - 1} retries left)"
        return Q.delay(250).then(=> @_info deferred, retries - 1, delay)
          .fail (err) -> deferred.reject err
      return deferred.reject err if err?
      deferred.resolve @parse stdout

  # Promise the parsed vm info as returned by `VBoxManage showvminfo`.
  info: ->
    deferred = Q.defer()
    @_info deferred
    deferred.promise

  # Promise a value from `IEVM.status` representing the vm's current status.
  status: -> @statusName().then (key) => @constructor.status[key]

  # Promise a key from `IEVM.status` representing the vm's current status.
  statusName: -> @info().then (info) -> info.VMState.toUpperCase()

  # Promise a `Date` object representing when the archive was last uploaded to
  # the modern.ie website.
  uploaded: ->
    # Return the cached uploaded date if available.
    return (Q.fcall => @_uploaded) if @_uploaded?
    # Defer a 'HEAD' request to the archive URL to determine the `last-modified`
    # time and date.
    deferred = Q.defer()
    opts = url.parse @url()
    opts.method = 'HEAD'
    req = http.request opts, (res) =>
      res.on 'data', (chunk) -> # Node needs this or it delays for a second.
      # Cache the result as property.
      @_uploaded = new Date res.headers['last-modified']
      deferred.resolve @_uploaded
    req.on 'error', (err) -> deferred.reject err
    # Send the request and return a promise for the deferred result.
    req.end()
    deferred.promise

  # Promise to set the VM metadata.
  setMeta: (data) ->
    deferred = Q.defer()
    data = JSON.stringify data
    @vbm 'setextradata', ['ievms', data], (err, stdout, stderr) =>
      return deferred.reject err if err?
      deferred.resolve true
    deferred.promise

  # Promise to get the VM metadata.
  getMeta: ->
    deferred = Q.defer()
    @vbm 'getextradata', ['ievms'], (err, stdout, stderr) =>
      return deferred.resolve {} if err?
      try
        data = JSON.parse stdout.replace 'Value: ', ''
      catch err
        return deferred.resolve {}
      deferred.resolve data
    deferred.promise

  # Promise getter/setter for VM metadata.
  meta: (data) -> if data? then @setMeta data else @getMeta()

  # Promise the UUID of the VM's hdd.
  hddUuid: -> @info().then (info) =>
    info['"SATA Controller-ImageUUID-0-0"'] ?
      info['"IDE Controller-ImageUUID-0-0"']

  # Promise an object representing the base hdd.
  hdd: -> @constructor.hdds().then (hdds) => @hddUuid().then (uid) =>
    return null unless uid? and hdds[uid]
    uid = hdds[uid]['Parent UUID'] while hdds[uid]['Parent UUID'] isnt 'base'
    hdds[uid]

  # Promise an `fs.stat` object for the VM's base hdd file.
  hddStat: -> @hdd().then (hdd) => Q.nfcall fs.stat, hdd.Location

  # Promise a `Date` object representing when the VM will expire.
  expires: -> @missing().then (missing) =>
    return null if missing
    ninetyDays = 90 * 1000 * 60 * 60 * 24
    if @os is 'WinXP' then return @uploaded().then (uploaded) ->
      new Date uploaded.getTime() + ninetyDays
    @meta().then (meta) =>
      if meta.rearms? and meta.rearms.length > 0
        # Add ninety days to the most recent rearm date.
        new Date meta.rearms[meta.rearms.length - 1] + ninetyDays
      else if meta.installed?
        # Add ninety days to the install date from metadata.
        new Date meta.installed + ninetyDays
      else
        # Fall back to the original date when the hdd was last modified.
        @hddStat().then (stat) => new Date stat.mtime.getTime() + ninetyDays

  # Promise an array of rearm dates or empty array if none exist.
  rearms: -> @meta().then (meta) => meta.rearms ? []

  # Promise the number of rearms left for the VM.
  rearmsLeft: -> @rearms().then (rearms) =>
    @constructor.rearms[@os] - rearms.length

  # Promise a boolean indicating whether the VM is missing.
  missing: -> @status().then (status) => status is @constructor.status.MISSING

  # Promise a boolean indicating whether the VM is running.
  running: -> @status().then (status) => status is @constructor.status.RUNNING

  # Promise a boolean indicating whether the VM is expired.
  expired: -> @expires().then (expires) => !expires? or expires < new Date

  # Promise a boolean indicating whether the archive exists on disk.
  archived: ->
    deferred = Q.defer()
    fs.exists path.join(@constructor.home, @archive()), (archived) ->
      deferred.resolve archived
    deferred.promise

  # Promise a boolean indicating whether the archive exists on disk.
  ovaed: ->
    deferred = Q.defer()
    fs.exists path.join(@constructor.home, @ova()), (ovaed) ->
      deferred.resolve ovaed
    deferred.promise

  _waitForStatus: (statuses, deferred, delay=1000) ->
    statuses = [].concat statuses
    statusNames = (@constructor.statusName s for s in statuses).join ', '
    @debug "_waitForStatus: #{statusNames}"
    return null if deferred.promise.isRejected()
    @status().then (status) =>
      return deferred.resolve status if status in statuses
      Q.delay(delay).then => @_waitForStatus statuses, deferred, delay

  waitForRunning: (timeout=60000, delay) ->
    @debug 'waitForRunning'
    deferred = Q.defer()
    @_waitForStatus(@constructor.status.RUNNING, deferred, delay).fail (err) ->
      deferred.reject err
    deferred.promise.timeout timeout

  waitForNotRunning: (timeout=60000, delay) ->
    @debug 'waitForNotRunning'
    deferred = Q.defer()
    @_waitForStatus([
      @constructor.status.POWEROFF
      @constructor.status.PAUSED
      @constructor.status.SAVED
    ], deferred, delay).fail (err) -> deferred.reject err
    deferred.promise.timeout timeout

  _waitForGuestControl: (deferred, delay=1000) ->
    @debug '_waitForGuestControl'
    return null if deferred.promise.isRejected()
    @info().then (info) =>
      runlevel = info.GuestAdditionsRunLevel
      @debug "_waitForGuestControl: runlevel #{runlevel}"
      return deferred.resolve true if runlevel? and parseInt(runlevel) > 2
      Q.delay(delay).then => @_waitForGuestControl deferred, delay

  waitForGuestControl: (timeout=60000, delay) ->
    @waitForRunning().then =>
      deferred = Q.defer()
      @_waitForGuestControl(deferred, delay).fail (err) -> deferred.reject err
      deferred.promise.timeout timeout

  _waitForNoGuestControl: (deferred, delay=1000) ->
    @debug "_waitForNoGuestControl"
    return null if deferred.promise.isRejected()
    @info().then (info) =>
      runlevel = info.GuestAdditionsRunLevel
      @debug "waitForNoGuestControl: runlevel #{runlevel}"
      return deferred.resolve true if !runlevel? or parseInt(runlevel) < 2
      Q.delay(delay).then => @_waitForNoGuestControl deferred, delay

  waitForNoGuestControl: (timeout=60000, delay) ->
    deferred = Q.defer()
    @_waitForNoGuestControl(deferred, delay).fail (err) -> deferred.reject err
    deferred.promise.timeout timeout

module.exports = IEVM