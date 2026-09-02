/* Hermes Mobile site — tiny progressive enhancements. The page works with JS disabled. */
(function () {
  "use strict";

  // Mobile nav toggle.
  var toggle = document.querySelector(".nav-toggle");
  var nav = document.getElementById("site-nav");
  if (toggle && nav) {
    toggle.addEventListener("click", function () {
      var open = nav.classList.toggle("is-open");
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
    });
    // Close the menu after tapping a link.
    nav.addEventListener("click", function (event) {
      if (event.target.closest("a")) {
        nav.classList.remove("is-open");
        toggle.setAttribute("aria-expanded", "false");
      }
    });
  }

  // Reveal-on-scroll (skipped entirely for reduced-motion users: CSS already
  // forces .reveal visible when the media query matches).
  var reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var revealables = document.querySelectorAll(".reveal");
  if (!reducedMotion && "IntersectionObserver" in window) {
    var observer = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            observer.unobserve(entry.target);
          }
        });
      },
      { rootMargin: "0px 0px -8% 0px", threshold: 0.08 }
    );
    revealables.forEach(function (el) { observer.observe(el); });
  } else {
    revealables.forEach(function (el) { el.classList.add("is-visible"); });
  }

  // Copy buttons on code blocks.
  document.querySelectorAll(".copy-btn").forEach(function (button) {
    button.addEventListener("click", function () {
      var code = button.parentElement.querySelector("code");
      if (!code) return;
      var finish = function () {
        button.textContent = "Copied ✓";
        button.classList.add("copied");
        setTimeout(function () {
          button.textContent = "Copy";
          button.classList.remove("copied");
        }, 1800);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(code.textContent).then(finish, function () {});
      } else {
        // Fallback for non-secure contexts.
        var range = document.createRange();
        range.selectNodeContents(code);
        var selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        try { document.execCommand("copy"); finish(); } catch (e) { /* no-op */ }
        selection.removeAllRanges();
      }
    });
  });

  // CI-token fallback: the deploy workflow sed-replaces {{COMMITS}} etc. at
  // build time; when the page is previewed locally (tokens unreplaced), fall
  // back to the data-fallback values so nothing renders as "{{…}}". An empty
  // fallback collapses the whole span (its separators live inside it).
  document.querySelectorAll("[data-token]").forEach(function (el) {
    if (el.textContent.indexOf("{{") !== -1) {
      el.textContent = el.getAttribute("data-fallback") || "";
    }
  });
})();
