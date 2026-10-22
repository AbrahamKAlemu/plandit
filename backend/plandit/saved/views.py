from django.db import IntegrityError, transaction
from rest_framework import status, viewsets
from rest_framework.decorators import action
from rest_framework.response import Response

from .extraction import run_extraction
from .models import ExtractionStatus, SavedPost, SourcePlatform
from .serializers import SavedPostCreateSerializer, SavedPostSerializer


class SavedPostViewSet(viewsets.ModelViewSet):
    """
    GET    /api/saved/            the caller's saved posts, newest first
    POST   /api/saved/            {"url": ..., "shared_text": ...} save and extract (200 if already saved)
    GET    /api/saved/<id>/
    PATCH  /api/saved/<id>/       caption, tags, estimated_cost, place_id (picking a place marks it ready)
    DELETE /api/saved/<id>/
    POST   /api/saved/<id>/retry/ run extraction again
    """

    serializer_class = SavedPostSerializer
    http_method_names = ["get", "post", "patch", "delete", "head", "options"]

    def get_queryset(self):
        return SavedPost.objects.filter(owner=self.request.user).select_related("place")

    def create(self, request, *args, **kwargs):
        serializer = SavedPostCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        url = serializer.validated_data["url"]

        existing = self.get_queryset().filter(url=url).first()
        if existing:
            return Response(SavedPostSerializer(existing).data, status=status.HTTP_200_OK)

        try:
            with transaction.atomic():
                post = SavedPost.objects.create(
                    owner=request.user,
                    url=url,
                    platform=SourcePlatform.from_url(url),
                    caption=serializer.validated_data.get("shared_text", ""),
                    status=ExtractionStatus.PROCESSING,
                )
        except IntegrityError:
            existing = self.get_queryset().get(url=url)
            return Response(SavedPostSerializer(existing).data, status=status.HTTP_200_OK)

        run_extraction(post)
        return Response(SavedPostSerializer(post).data, status=status.HTTP_201_CREATED)

    @action(detail=True, methods=["post"])
    def retry(self, request, pk=None):
        post = self.get_object()
        post.status = ExtractionStatus.PROCESSING
        post.failure_reason = ""
        post.save(update_fields=["status", "failure_reason", "updated_at"])
        run_extraction(post)
        return Response(SavedPostSerializer(post).data)
