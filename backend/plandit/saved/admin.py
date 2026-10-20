from django.contrib import admin

from .models import SavedPost


@admin.register(SavedPost)
class SavedPostAdmin(admin.ModelAdmin):
    list_display = ["__str__", "owner", "platform", "status", "place", "saved_at"]
    list_filter = ["platform", "status"]
    search_fields = ["url", "caption", "creator_handle", "place__name"]
    raw_id_fields = ["owner", "place"]
    readonly_fields = ["id", "saved_at", "updated_at"]
