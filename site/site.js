// Turns each beta CTA into a real link once config.js holds a TestFlight URL, and swaps
// screenshot slots between the image and its labelled placeholder.
(function () {
  "use strict";

  var cfg = window.SOUSLENS_CONFIG || {};
  var url = typeof cfg.TESTFLIGHT_URL === "string" ? cfg.TESTFLIGHT_URL.trim() : "";
  var valid = /^https:\/\/testflight\.apple\.com\/join\/[A-Za-z0-9]+$/.test(url);

  if (valid) {
    document.querySelectorAll("[data-cta]").forEach(function (el) {
      var a = document.createElement("a");
      a.className = el.className;
      a.href = url;
      a.rel = "noopener";
      a.textContent = "Join the TestFlight beta";
      el.replaceWith(a);
    });
    document.querySelectorAll("[data-cta-note]").forEach(function (el) {
      el.textContent = "Opens TestFlight on your iPhone. The beta is limited to 100 testers.";
    });
  }

  function settle(img) {
    var screen = img.closest(".screen");
    if (!screen) return;
    if (img.naturalWidth > 0) {
      screen.classList.add("has-image");
    } else {
      img.remove();
    }
  }

  document.querySelectorAll(".screen img").forEach(function (img) {
    if (img.complete) {
      settle(img);
    } else {
      img.addEventListener("load", function () { settle(img); });
      img.addEventListener("error", function () { settle(img); });
    }
  });
})();
