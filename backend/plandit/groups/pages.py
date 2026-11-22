"""GET /j/<token>: the page a group plan's invite link opens in a browser (architecture "Mode 3").

The same page for every well-formed token, from no database query: three steps (get the app and
sign in, copy the link, paste it in Saved), with the App Store link, and nothing about the group,
so a guessed or old token learns nothing (INV-10). Joining happens in the app, signed in (/api/group-plans/invites/).
It has the public pages' CSP, and no link out of it sends the address, which is the invitation
(INV-11). The styles are /p/'s own, so the site forwards only /j/ and /static/shares/ here.
"""

from django.shortcuts import render
from django.views.decorators.http import require_safe

from plandit.core.public_forms import public_page_csp
from plandit.shares.views import with_page_headers

from .views import INVITE_TOKEN

APP_STORE_URL = "https://apps.apple.com/app/id6826263440"


@public_page_csp
@require_safe
def join_page(request, token):
    if not INVITE_TOKEN.match(token):
        response = render(request, "groups/join_not_found.html", status=404)
    else:
        response = render(request, "groups/join.html", {"app_store_url": APP_STORE_URL})
    return with_page_headers(response, takes_answers=False)
