// progressive niceties; every page also works without this file
(function () {
  "use strict"

  // close open <details class="menu"> elements, except the one holding `keep`
  function closeMenus(keep) {
    document.querySelectorAll("details.menu[open]").forEach(function (menu) {
      if (keep && menu.contains(keep)) return
      menu.removeAttribute("open")
    })
  }

  document.addEventListener("click", function (event) {
    closeMenus(event.target instanceof Element ? event.target : null)
  })

  document.addEventListener("keydown", function (event) {
    if (event.key !== "Escape") return
    var focused = document.activeElement
    document.querySelectorAll("details.menu[open]").forEach(function (menu) {
      menu.removeAttribute("open")
      var summary = menu.querySelector("summary")
      if (summary && menu.contains(focused)) summary.focus()
    })
  })
})()
