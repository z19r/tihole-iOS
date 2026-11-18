// tihole for iOS — page behaviour: theme menu, screens showcase, release
// feed, App Store link and analytics.
(function () {
  var config = window.TIHOLE_CONFIG || {};
  var data = window.TIHOLE_DATA || { version: "", changelog: [] };

  // ---------- theme menu ----------
  var THEMES = [
    { id: "auto", title: "Auto", swatch: "linear-gradient(135deg,"
      + "#0b0412 50%, #fbf9f4 50%)" },
    { id: "gloss", title: "Gloss", swatch: "#ff2e93" },
    { id: "deep-night", title: "Deep Night", swatch: "#7aa2f7" },
    { id: "light-luxury", title: "Light Luxury", swatch: "#b08d57" },
    { id: "pihole-classic", title: "Pi-hole Classic", swatch: "#e5322b" },
  ];
  var button = document.getElementById("theme-button");
  var menu = document.getElementById("theme-menu");
  var label = document.getElementById("theme-name");

  function renderMenu() {
    var current = window.tiholeTheme.saved();
    menu.innerHTML = "";
    THEMES.forEach(function (t) {
      var li = document.createElement("li");
      li.setAttribute("role", "none");
      var item = document.createElement("button");
      item.type = "button";
      item.setAttribute("role", "menuitemradio");
      item.setAttribute("aria-checked", String(t.id === current));
      item.setAttribute("data-umami-event", "theme-" + t.id);
      item.innerHTML = '<span class="check">'
        + (t.id === current ? "✓" : "") + "</span>" + t.title
        + '<span class="swatch" style="background:' + t.swatch
        + '"></span>';
      item.addEventListener("click", function () {
        window.tiholeTheme.choose(t.id);
        close();
        renderMenu();
      });
      li.appendChild(item);
      menu.appendChild(li);
      if (t.id === current) label.textContent = t.title;
    });
  }

  function close() {
    menu.hidden = true;
    button.setAttribute("aria-expanded", "false");
  }

  button.addEventListener("click", function (event) {
    event.stopPropagation();
    menu.hidden = !menu.hidden;
    button.setAttribute("aria-expanded", String(!menu.hidden));
    if (!menu.hidden) menu.querySelector("button").focus();
  });
  document.addEventListener("click", function (event) {
    if (!menu.contains(event.target)) close();
  });
  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape" && !menu.hidden) {
      close();
      button.focus();
    }
  });
  renderMenu();

  // ---------- screens showcase ----------
  var SCREENS = [
    { id: "dashboard", tab: "Dashboard", title: "Your Pi-hole at a glance",
      text: "Live totals, block rate, active clients and gravity size, "
        + "CPU, memory and temperature gauges, health warnings, and "
        + "queries over time." },
    { id: "queries", tab: "Queries", title: "Watch every query",
      text: "The live query log, with a domain filter. Swipe a query to "
        + "allow or block its domain. Tap it for the full detail." },
    { id: "blocking", tab: "Blocking", title: "Pause blocking anytime",
      text: "The blocking pill sits in every tab. Disable for 5, 10 or 15 "
        + "minutes with a live countdown, or until you turn it back on." },
    { id: "lists", tab: "Lists", title: "Manage your lists",
      text: "Exact and regex allow and deny rules, adlists with a "
        + "streamed gravity update, groups, clients and local DNS." },
    { id: "system", tab: "System", title: "Health and maintenance",
      text: "System info, diagnosis messages, network devices, the DNS "
        + "log, and restart DNS, flush logs and flush network." },
    { id: "settings", tab: "Settings", title: "Every FTL setting",
      text: "Search and edit Pi-hole's full configuration tree, with a "
        + "row-by-row editor for lists like upstream DNS servers." },
  ];
  var ALT = {
    dashboard: "dashboard with stat tiles and a queries over time chart",
    queries: "live query log with status badges per query",
    blocking: "blocking menu with timed disable options",
    lists: "domains list with allow and deny rules",
    system: "system info and diagnosis messages",
    settings: "searchable FTL configuration tree",
  };
  var screen = "dashboard";
  var device = "iphone";
  var tabs = document.getElementById("screen-tabs");
  var deviceTabs = document.getElementById("device-tabs");
  var frame = document.getElementById("screen-device");
  var img = document.getElementById("screen-img");

  SCREENS.forEach(function (s) {
    var b = document.createElement("button");
    b.type = "button";
    b.setAttribute("role", "tab");
    b.dataset.screen = s.id;
    b.setAttribute("data-umami-event", "screens-tab-" + s.id);
    b.textContent = s.tab;
    tabs.appendChild(b);
  });

  function showScreen() {
    var s = SCREENS.filter(function (x) { return x.id === screen; })[0];
    var name = device === "ipad" ? "iPad" : "iPhone";
    img.src = "img/screens/" + device + "-" + screen + ".webp";
    img.width = device === "ipad" ? 1000 : 640;
    img.height = device === "ipad" ? 1333 : 1391;
    img.alt = "tihole " + ALT[screen] + " on " + name + ".";
    frame.className = "device " + device;
    document.getElementById("screen-title").textContent = s.title;
    document.getElementById("screen-text").textContent = s.text;
    tabs.querySelectorAll("button").forEach(function (b) {
      b.setAttribute("aria-selected", String(b.dataset.screen === screen));
    });
    deviceTabs.querySelectorAll("button").forEach(function (b) {
      b.setAttribute("aria-selected", String(b.dataset.device === device));
    });
  }

  tabs.addEventListener("click", function (event) {
    var b = event.target.closest("button");
    if (!b) return;
    screen = b.dataset.screen;
    showScreen();
  });
  deviceTabs.addEventListener("click", function (event) {
    var b = event.target.closest("button");
    if (!b) return;
    device = b.dataset.device;
    showScreen();
  });
  showScreen();

  // ---------- release feed ----------
  var ORDER = ["breaking", "added", "changed", "fixed", "removed",
    "deprecated", "security"];
  var feed = document.getElementById("release-feed");

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text) node.textContent = text;
    return node;
  }

  data.changelog.forEach(function (release) {
    var card = el("article", "release");
    var head = el("div", "release-head");
    head.appendChild(el("span", "ver", "v" + release.ver));
    head.appendChild(el("span", "", release.date));
    card.appendChild(head);
    release.sections.slice().sort(function (a, b) {
      return ORDER.indexOf(a.name) - ORDER.indexOf(b.name);
    }).forEach(function (section) {
      card.appendChild(el("h4", "", section.name));
      var list = el("ul");
      section.bullets.forEach(function (bullet) {
        list.appendChild(el("li", "", bullet));
      });
      card.appendChild(list);
    });
    feed.appendChild(card);
  });

  document.querySelectorAll("[data-version]").forEach(function (node) {
    if (data.version) node.textContent = "v" + data.version;
  });

  // ---------- App Store link ----------
  if (config.appStoreUrl) {
    var store = document.getElementById("store-link");
    store.href = config.appStoreUrl;
    store.removeAttribute("aria-disabled");
    store.textContent = " Download on the App Store";
  }

  // ---------- analytics ----------
  if (config.umamiWebsiteId && location.hostname !== "localhost") {
    var tag = document.createElement("script");
    tag.defer = true;
    tag.src = "https://cloud.umami.is/script.js";
    tag.setAttribute("data-website-id", config.umamiWebsiteId);
    document.head.appendChild(tag);
  }
})();
