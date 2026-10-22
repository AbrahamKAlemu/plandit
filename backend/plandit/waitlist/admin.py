from django.contrib import admin

from .models import WaitlistSignup


@admin.register(WaitlistSignup)
class WaitlistSignupAdmin(admin.ModelAdmin):
    list_display = ["email", "source", "created_at"]
    search_fields = ["email"]
    readonly_fields = ["created_at"]
