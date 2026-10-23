(function () {
  var config = window.PLANDIT_WAITLIST || {};
  var endpoint = (config.endpoint || "").trim();
  var emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

  document.querySelectorAll(".waitlist-form").forEach(function (form) {
    var input = form.querySelector('input[type="email"]');
    var button = form.querySelector('button[type="submit"]');
    var status = form.querySelector(".form-status");
    var source = form.dataset.source || "homepage";
    var location = form.dataset.location || "closing";

    function setStatus(kind, message) {
      status.className = "form-status" + (kind ? " is-" + kind : "");
      status.textContent = message;
    }

    input.addEventListener("input", function () {
      input.removeAttribute("aria-invalid");
      setStatus("", "");
    });

    form.addEventListener("submit", function (event) {
      event.preventDefault();
      var email = input.value.trim();

      if (!emailPattern.test(email)) {
        input.setAttribute("aria-invalid", "true");
        setStatus("error", "Enter a valid email address.");
        input.focus();
        return;
      }

      if (!endpoint) {
        setStatus("preview", "Early access signups are opening soon. Your email has not been saved yet.");
        return;
      }

      button.disabled = true;
      setStatus("", "");

      fetch(endpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Accept": "application/json" },
        body: JSON.stringify({ email: email, source: source })
      })
        .then(function (response) {
          if (!response.ok) throw new Error("Request failed");
          setStatus("success", "You’re on the list. We’ll let you know when Plandit is ready.");
          if (window.planditTrack) {
            window.planditTrack("waitlist_signup", {
              page: source,
              location: location
            });
          }
          form.reset();
        })
        .catch(function () {
          setStatus("error", "That did not go through. Please try again.");
          if (window.planditTrack) {
            window.planditTrack("waitlist_error", {
              page: source,
              location: location
            });
          }
        })
        .finally(function () {
          button.disabled = false;
        });
    });
  });
})();
