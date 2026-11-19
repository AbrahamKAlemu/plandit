from django.contrib import admin

from .models import SharedPlan


@admin.register(SharedPlan)
class SharedPlanAdmin(admin.ModelAdmin):
    list_display = ("slug", "owner", "updated_at")
    readonly_fields = ("slug", "created_at", "updated_at")
