(function () {
  var config = window.PLANDIT_ANALYTICS || {};
  var measurementId = (config.ga4MeasurementId || "").trim();

  window.va = window.va || function () {
    (window.vaq = window.vaq || []).push(arguments);
  };

  var vercelScript = document.createElement("script");
  vercelScript.defer = true;
  vercelScript.src = "/_vercel/insights/script.js";
  document.head.appendChild(vercelScript);

  if (measurementId) {
    window.dataLayer = window.dataLayer || [];
    window.gtag = window.gtag || function () {
      window.dataLayer.push(arguments);
    };
    window.gtag("js", new Date());
    window.gtag("config", measurementId, { anonymize_ip: true });

    var gaScript = document.createElement("script");
    gaScript.async = true;
    gaScript.src = "https://www.googletagmanager.com/gtag/js?id=" + encodeURIComponent(measurementId);
    document.head.appendChild(gaScript);
  }

  window.planditTrack = function (name, data) {
    var details = data || {};
    window.va("event", { name: name, data: details });
    if (window.gtag) {
      window.gtag("event", name, details);
    }
  };

  document.querySelectorAll("[data-analytics-event]").forEach(function (element) {
    element.addEventListener("click", function () {
      window.planditTrack(element.dataset.analyticsEvent, {
        page: element.dataset.analyticsPage || window.location.pathname,
        location: element.dataset.analyticsLocation || "unknown"
      });
    });
  });
})();
