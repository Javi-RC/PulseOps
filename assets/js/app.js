// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/pulse_ops"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks},
})

// A styled confirmation for `data-confirm`, in place of the browser's own dialog.
//
// phoenix_html answers `data-confirm` with window.confirm from a bubbling click
// listener: a grey box that cannot be styled and cannot name what the button is
// about to do. This listener runs first, in the capture phase on window, so it
// holds the click back, asks with a <dialog>, and replays the click on a yes —
// with the attribute lifted for that one replay so the stock confirm stays quiet.
//
// The message's opening question becomes the title ("Delete Payments API?") and
// the rest the explanation. `data-confirm-label` names the button that agrees.
const confirmDialog = document.createElement("dialog")
confirmDialog.className = "modal"
confirmDialog.innerHTML = `
  <div class="modal-box max-w-md">
    <h3 class="text-lg font-semibold" data-confirm-title></h3>
    <p class="mt-2 text-sm text-base-content/70" data-confirm-message></p>
    <form method="dialog" class="modal-action">
      <button value="cancel" class="btn btn-soft">Go back</button>
      <button value="confirm" class="btn btn-error" data-confirm-accept></button>
    </form>
  </div>
  <form method="dialog" class="modal-backdrop"><button value="cancel">Close</button></form>
`
document.body.appendChild(confirmDialog)

let replayingConfirmedClick = false

const askToConfirm = element => {
  const message = element.getAttribute("data-confirm")
  const [, title, body] = message.match(/^(.*?\?)\s*(.*)$/s) || [null, "Are you sure?", message]

  confirmDialog.querySelector("[data-confirm-title]").textContent = title
  const bodyElement = confirmDialog.querySelector("[data-confirm-message]")
  bodyElement.textContent = body
  bodyElement.hidden = body === ""
  confirmDialog.querySelector("[data-confirm-accept]").textContent =
    element.dataset.confirmLabel || "Confirm"

  confirmDialog.onclose = () => {
    if (confirmDialog.returnValue !== "confirm") {
      element.focus()
      return
    }

    element.removeAttribute("data-confirm")
    replayingConfirmedClick = true
    try {
      element.click()
    } finally {
      replayingConfirmedClick = false
      element.setAttribute("data-confirm", message)
    }
  }

  confirmDialog.returnValue = ""
  confirmDialog.showModal()
  // The safe answer has the focus, so a stray Enter does not delete anything.
  confirmDialog.querySelector("button[value=cancel]").focus()
}

window.addEventListener("click", e => {
  if (replayingConfirmedClick) return
  const element = e.target.closest && e.target.closest("[data-confirm]")
  if (!element) return

  e.preventDefault()
  e.stopImmediatePropagation()
  askToConfirm(element)
}, true)

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

