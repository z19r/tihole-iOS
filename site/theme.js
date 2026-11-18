// Applies the saved theme before first paint. Auto follows the system:
// Gloss in dark mode, Light Luxury in light, exactly like the app.
(function () {
  var KEY = "tihole-ios-theme";
  var light = window.matchMedia("(prefers-color-scheme: light)");

  function resolve(name) {
    if (name && name !== "auto") return name;
    return light.matches ? "light-luxury" : "gloss";
  }

  function saved() {
    try {
      return localStorage.getItem(KEY) || "auto";
    } catch (_) {
      return "auto";
    }
  }

  function apply(name) {
    document.documentElement.setAttribute("data-theme", resolve(name));
  }

  apply(saved());
  light.addEventListener("change", function () {
    apply(saved());
  });

  window.tiholeTheme = {
    saved: saved,
    choose: function (name) {
      try {
        localStorage.setItem(KEY, name);
      } catch (_) {}
      apply(name);
    },
  };
})();
