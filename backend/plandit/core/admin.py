from django.contrib import admin

from .models import Profile


@admin.register(Profile)
class ProfileAdmin(admin.ModelAdmin):
    list_display = ["id", "name", "email", "school", "default_budget", "created_at"]
    search_fields = ["name", "email", "school"]
    readonly_fields = ["id", "created_at", "updated_at"]
