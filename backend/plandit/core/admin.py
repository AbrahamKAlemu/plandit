from django.contrib import admin

from .models import ActivityDay, ActivityEvent, AppSnapshot, DeletedAccount, Profile


@admin.register(Profile)
class ProfileAdmin(admin.ModelAdmin):
    list_display = [
        "id",
        "name",
        "email",
        "school",
        "default_budget",
        "auth_provider",
        "is_anonymous",
        "signed_up_at",
        "activated_at",
        "last_seen_at",
        "created_at",
    ]
    list_filter = ["is_anonymous", "auth_provider"]
    search_fields = ["name", "email", "school"]
    readonly_fields = ["id", "signed_up_at", "last_seen_at", "activated_at", "created_at", "updated_at"]


class ReadOnlyAdmin(admin.ModelAdmin):
    """Rows written by the API only; the admin is for looking."""

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False


@admin.register(AppSnapshot)
class AppSnapshotAdmin(ReadOnlyAdmin):
    list_display = ["profile", "version", "saved_count", "past_plans_count", "today_stop_count", "updated_at"]
    search_fields = ["profile__email", "profile__name"]
    readonly_fields = [
        "profile",
        "version",
        "saved_count",
        "past_plans_count",
        "today_stop_count",
        "created_at",
        "updated_at",
    ]
    exclude = ["data"]


@admin.register(DeletedAccount)
class DeletedAccountAdmin(ReadOnlyAdmin):
    list_display = ["id", "deleted_at"]
    readonly_fields = ["id", "deleted_at"]


@admin.register(ActivityDay)
class ActivityDayAdmin(ReadOnlyAdmin):
    list_display = ["profile", "date"]
    list_filter = ["date"]
    search_fields = ["profile__email", "profile__name"]


@admin.register(ActivityEvent)
class ActivityEventAdmin(ReadOnlyAdmin):
    list_display = ["profile", "name", "occurred_at", "created_at"]
    list_filter = ["name"]
    search_fields = ["profile__email", "profile__name"]
    date_hierarchy = "occurred_at"
