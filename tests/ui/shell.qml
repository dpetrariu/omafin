import QtQuick
import Quickshell
import Quickshell.Io

// A stand-in Omarchy shell for the off-screen UI tests: it loads Omafin's
// real Service and App, hands them a minimal shell API, and exposes an IPC
// target the test script drives. Run only against the mock Jellyfin.
ShellRoot {
  id: root

  readonly property string ui: Quickshell.env("OMAFIN_UI")
  readonly property var app: appLoader.item
  readonly property var service: serviceLoader.item

  QtObject {
    id: shellApi
    function summon(id, payload) { if (appLoader.item) appLoader.item.open(payload); return true }
    function hide(id) { if (appLoader.item) appLoader.item.close(); return true }
    function toggle(id, payload) { return summon(id, payload) }
    function serviceFor(id) { return serviceLoader.item }
  }

  Loader {
    id: serviceLoader
    source: "file://" + root.ui + "/Service.qml"
    onLoaded: {
      item.shell = shellApi
      item.manifest = { id: "omafin", version: Quickshell.env("OMAFIN_VERSION") || "test" }
    }
  }

  Loader {
    id: appLoader
    active: serviceLoader.status === Loader.Ready
    source: "file://" + root.ui + "/App.qml"
    onLoaded: {
      item.shell = shellApi
      item.manifest = { id: "omafin" }
      item.service = serviceLoader.item
      item.open("{}")
    }
  }

  IpcHandler {
    target: "test"
    function ready(): string { return root.app && root.service && root.service.ready ? "yes" : "no" }
    function nav(id: string): string { return root.app.navigate(id) }
    function key(id: string): string { root.app.runShortcut(id, id); return "ok" }
    function shot(path: string): string { return root.app.screenshot(path) }
    // Evaluate an expression with `app`, `service` and `hooks` in scope.
    function js(code: string): string {
      try {
        var f = new Function("app", "service", "hooks", "return (" + code + ")")
        var r = f(root.app, root.service, root.app ? root.app.testHooks : null)
        return typeof r === "object" ? JSON.stringify(r) : String(r)
      } catch (e) {
        return "error: " + e
      }
    }
  }
}
