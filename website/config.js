// Waitlist settings.
// Leave endpoint empty to keep the form in preview mode: nothing is sent or saved,
// and visitors are told their email wasn't saved.
// To go live, set endpoint to a URL that accepts a POST with JSON {"email": "..."}
// and returns a 2xx status only after the email is stored (for example a
// Formspree, ConvertKit/Kit, Mailchimp or Loops form endpoint, or your own API).
window.PLANDIT_WAITLIST = {
  endpoint: ""
};
