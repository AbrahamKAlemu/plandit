from django.contrib import admin

from .models import Place


@admin.register(Place)
class PlaceAdmin(admin.ModelAdmin):
    list_display = ["name", "category", "neighborhood", "address", "hours"]
    list_filter = ["category", "neighborhood"]
    search_fields = ["name", "neighborhood", "address"]
