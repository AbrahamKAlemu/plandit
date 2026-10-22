from django.db.models import Q
from rest_framework import viewsets
from rest_framework.response import Response

from .models import Place
from .serializers import PlaceSerializer


class PlaceViewSet(viewsets.ReadOnlyModelViewSet):
    """GET /api/places/?q=<text>&category=<category> and GET /api/places/<id>/."""

    serializer_class = PlaceSerializer

    def get_queryset(self):
        queryset = Place.objects.all()
        query = self.request.query_params.get("q", "").strip()
        if query:
            queryset = queryset.filter(Q(name__icontains=query) | Q(neighborhood__icontains=query))
        category = self.request.query_params.get("category", "").strip()
        if category:
            queryset = queryset.filter(category=category)
        return queryset

    def list(self, request, *args, **kwargs):
        queryset = self.filter_queryset(self.get_queryset())[:100]
        return Response(self.get_serializer(queryset, many=True).data)
