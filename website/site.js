(function () {
  var header = document.querySelector(".site-header");
  var menuButton = document.querySelector(".menu-button");
  var nav = document.querySelector(".nav");

  function updateHeader() {
    header.classList.toggle("scrolled", window.scrollY > 16);
  }

  updateHeader();
  window.addEventListener("scroll", updateHeader, { passive: true });

  menuButton.addEventListener("click", function () {
    var isOpen = menuButton.getAttribute("aria-expanded") === "true";
    menuButton.setAttribute("aria-expanded", String(!isOpen));
    menuButton.setAttribute("aria-label", isOpen ? "Open menu" : "Close menu");
    nav.classList.toggle("open", !isOpen);
  });

  nav.querySelectorAll("a").forEach(function (link) {
    link.addEventListener("click", function () {
      menuButton.setAttribute("aria-expanded", "false");
      menuButton.setAttribute("aria-label", "Open menu");
      nav.classList.remove("open");
    });
  });

  if (!("IntersectionObserver" in window)) {
    document.querySelectorAll(".reveal").forEach(function (element) {
      element.classList.add("is-visible");
    });
    return;
  }

  var observer = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (entry.isIntersecting) {
        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      }
    });
  }, { threshold: 0.12 });

  document.querySelectorAll(".reveal").forEach(function (element) {
    observer.observe(element);
  });
})();
