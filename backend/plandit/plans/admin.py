from django.contrib import admin

from .models import DayPlan, PlanStop, TravelLeg


class PlanStopInline(admin.TabularInline):
    model = PlanStop
    extra = 0
    raw_id_fields = ["place", "source_post"]


class TravelLegInline(admin.TabularInline):
    model = TravelLeg
    extra = 0
    raw_id_fields = ["from_stop", "to_stop"]


@admin.register(DayPlan)
class DayPlanAdmin(admin.ModelAdmin):
    list_display = ["title", "owner", "date", "budget"]
    list_filter = ["date"]
    raw_id_fields = ["owner"]
    inlines = [PlanStopInline, TravelLegInline]
