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

  // tabs: links `a[data-tab]` name a panel id, and panels are `data-panel` siblings
  function selectPanel(panel) {
    var ids = []
    Array.prototype.forEach.call(panel.parentElement.children, function (sibling) {
      if (!sibling.hasAttribute("data-panel")) return
      ids.push(sibling.id)
      sibling.hidden = sibling !== panel
    })
    document.querySelectorAll("[data-tabs] a[data-tab]").forEach(function (link) {
      var id = link.getAttribute("data-tab")
      if (ids.indexOf(id) === -1) return
      if (id === panel.id) link.setAttribute("aria-current", "page")
      else link.removeAttribute("aria-current")
    })
  }

  function panelOf(link) {
    var panel = document.getElementById(link.getAttribute("data-tab"))
    return panel && panel.hasAttribute("data-panel") ? panel : null
  }

  // the panel whose tab links to `pathname`
  function panelFor(pathname) {
    var links = document.querySelectorAll("[data-tabs] a[data-tab]")
    for (var i = 0; i < links.length; i++) {
      if (links[i].pathname === pathname) return panelOf(links[i])
    }
    return null
  }

  // capture phase, so htmx's boosted link handler never sees a tab switch
  document.addEventListener("click", function (event) {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    var link = event.target instanceof Element ? event.target.closest("a[data-tab]") : null
    if (!link) return
    var panel = panelOf(link)
    if (!panel) return
    event.preventDefault()
    event.stopPropagation()
    closeMenus(null)
    selectPanel(panel)
    if (link.href !== location.href) history.pushState({ tab: true }, "", link.href)
  }, true)

  window.addEventListener("popstate", function (event) {
    if (event.state && event.state.htmx) return
    var panel = panelFor(location.pathname)
    if (panel) selectPanel(panel)
    else if (event.state && event.state.tab) location.reload()
  })

  // the ref picker's filter over the names already on the page
  document.addEventListener("input", function (event) {
    var input = event.target
    if (!(input instanceof HTMLInputElement) || !input.hasAttribute("data-filter")) return
    var list = document.getElementById(input.getAttribute("data-filter"))
    if (!list) return
    var term = input.value.trim().toLowerCase()
    list.querySelectorAll("li[data-name]").forEach(function (item) {
      item.hidden = term !== "" && item.getAttribute("data-name").toLowerCase().indexOf(term) === -1
    })
  })

  // opening a menu with a filter focuses it
  document.addEventListener("toggle", function (event) {
    var menu = event.target
    if (!(menu instanceof HTMLDetailsElement) || !menu.open) return
    var input = menu.querySelector("input[data-filter]")
    if (input && !input.closest("[hidden]")) input.focus()
  }, true)

  // copy buttons copy their command, or select it when the clipboard refuses
  document.addEventListener("click", function (event) {
    var button = event.target instanceof Element ? event.target.closest("button[data-copy]") : null
    if (!button) return
    var source = document.getElementById(button.getAttribute("data-copy"))
    if (!source) return
    function select() {
      var range = document.createRange()
      range.selectNodeContents(source)
      var selection = window.getSelection()
      selection.removeAllRanges()
      selection.addRange(range)
    }
    if (!navigator.clipboard || !navigator.clipboard.writeText) return select()
    navigator.clipboard.writeText(source.textContent).then(function () {
      button.setAttribute("data-copied", "")
      setTimeout(function () { button.removeAttribute("data-copied") }, 1500)
    }, select)
  })

  // reveal the js-only controls and match the panel to the url
  function setup() {
    document.querySelectorAll("[data-js][hidden]").forEach(function (element) {
      element.hidden = false
    })
    var panel = panelFor(location.pathname)
    if (panel) selectPanel(panel)
    if (history.state === null) history.replaceState({ tab: true }, "", location.href)
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", setup)
  else setup()
  document.addEventListener("htmx:load", setup)
})()
