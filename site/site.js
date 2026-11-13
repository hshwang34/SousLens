// Turns each beta CTA into a real link once config.js holds a valid TestFlight URL.
// Anything else (empty, a typo, another host) leaves the "Beta opening soon" label in place.
(function () {
  "use strict";

  var cfg = window.UMMA_CONFIG || {};
  var url = typeof cfg.TESTFLIGHT_URL === "string" ? cfg.TESTFLIGHT_URL.trim() : "";
  if (!/^https:\/\/testflight\.apple\.com\/join\/[A-Za-z0-9]+$/.test(url)) return;

  document.querySelectorAll("[data-cta]").forEach(function (el) {
    var a = document.createElement("a");
    a.className = el.className;
    a.href = url;
    a.rel = "noopener";
    a.textContent = "Join the TestFlight beta";
    el.replaceWith(a);
  });
  document.querySelectorAll("[data-cta-note]").forEach(function (el) {
    el.textContent = "Opens TestFlight on your iPhone. The free beta is limited to 100 testers.";
  });
})();
