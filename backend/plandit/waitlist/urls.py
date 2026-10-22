from django.urls import path

from .views import WaitlistView

urlpatterns = [path("", WaitlistView.as_view(), name="waitlist")]
