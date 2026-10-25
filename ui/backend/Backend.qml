import QtQuick
import Quickshell.Io
import "Wire.js" as Wire

// The persistent `omafin serve` process and the request bookkeeping around
// it. Every call gets a callback(result, error); every error is an object
// with a message a person can read.
Item {
  id: root

  required property string executable
  property bool launchEnabled: executable !== ""

  readonly property bool ready: connected && info !== null
  property bool connected: false
  property var info: null
  property string failure: ""
  property var pending: ({})
  property int sequence: 0
  property int restarts: 0
  // Set when the binary answers an API this UI does not speak; restarting
  // the same binary would only fail the same way.
  property bool incompatible: false
  // The version handshake: a backend that answers a different API revision
  // than this UI was written for is stopped rather than half-understood.
  readonly property int expectedApiVersion: 1

  signal notification(string method, var params)
  signal requestFailed(string method, var error)

  function call(method, params, callback) {
    var done = function(result, error) {
      if (error) root.requestFailed(method, error)
      if (typeof callback === "function") callback(result, error)
    }
    if (!connected) {
      done(null, { code: -32010, message: failure || "Omafin's backend is not running" })
      return
    }
    var id = "q" + (++sequence)
    var next = Object.assign({}, pending)
    next[id] = { callback: done, method: method, deadline: Date.now() + budget(method) }
    pending = next
    child.write(Wire.request(id, method, params))
  }

  // Generous waits for the calls that walk a whole library or start a stream.
  function budget(method) {
    if (method === "play.prepare" || method === "play.mpv") return 90000
    if (method === "home" || method === "search" || method === "items.list") return 60000
    return 30000
  }

  function receive(line) {
    var value = Wire.parse(line)
    var reply = Wire.response(value)
    if (reply) {
      var entry = pending[reply.id]
      if (!entry) return
      var next = Object.assign({}, pending)
      delete next[reply.id]
      pending = next
      if (reply.error) entry.callback(null, reply.error)
      else entry.callback(reply.result, null)
      return
    }
    var event = Wire.notification(value)
    if (event) root.notification(event.method, event.params)
  }

  function failPending(message) {
    var waiting = pending
    pending = ({})
    for (var id in waiting) waiting[id].callback(null, { code: -32010, message: message })
  }

  Timer {
    interval: 1000
    repeat: true
    running: Object.keys(root.pending).length > 0
    onTriggered: {
      var now = Date.now()
      var expired = []
      for (var id in root.pending) if (root.pending[id].deadline < now) expired.push(id)
      if (expired.length === 0) return
      var next = Object.assign({}, root.pending)
      var callbacks = []
      for (var i = 0; i < expired.length; i++) {
        callbacks.push(next[expired[i]].callback)
        delete next[expired[i]]
      }
      // Forget them first, so a callback that throws cannot make them fire again.
      root.pending = next
      for (var j = 0; j < callbacks.length; j++) {
        try { callbacks[j](null, { code: -32011, message: "Jellyfin took too long to answer" }) } catch (e) { console.warn(e) }
      }
    }
  }

  // A crashed backend comes back on its own, more slowly each time.
  Timer {
    id: restartTimer
    repeat: false
    interval: Math.min(30000, 1000 * Math.pow(2, Math.min(root.restarts, 5)))
    onTriggered: if (root.launchEnabled) child.running = true
  }

  Process {
    id: child
    command: [root.executable, "serve"]
    running: root.launchEnabled && !root.incompatible
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: data => root.receive(data)
    }
    stderr: SplitParser {
      onRead: data => console.warn("omafin backend:", data)
    }
    onStarted: {
      root.connected = true
      root.failure = ""
      root.call("system.info", {}, function(result, error) {
        if (error) {
          root.failure = error.message
          return
        }
        if (result.apiVersion !== root.expectedApiVersion) {
          root.failure = "This Omafin backend is version " + result.version
            + "; rebuild it with `make install` in the plugin folder"
          root.incompatible = true
          child.running = false
          return
        }
        root.restarts = 0
        root.info = result
      })
    }
    onExited: function(exitCode) {
      root.connected = false
      root.info = null
      root.failPending("Omafin's backend stopped")
      if (!root.failure) root.failure = "Omafin's backend stopped (exit " + exitCode + ")"
      if (root.launchEnabled && !root.incompatible) {
        root.restarts++
        restartTimer.restart()
      }
    }
  }

  function shutdown() {
    if (connected) child.write(Wire.request("bye", "system.shutdown", {}))
  }
}
