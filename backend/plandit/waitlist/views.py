from rest_framework import permissions, serializers, status
from rest_framework.response import Response
from rest_framework.throttling import AnonRateThrottle
from rest_framework.views import APIView

from .models import WaitlistSignup


class WaitlistSerializer(serializers.Serializer):
    email = serializers.EmailField(max_length=254)
    source = serializers.CharField(required=False, allow_blank=True, max_length=60)


class WaitlistThrottle(AnonRateThrottle):
    scope = "waitlist"


class WaitlistView(APIView):
    """POST /api/waitlist/ {"email": ..., "source": "plandit.app"}. Public; rate limited per IP.
    Returns 2xx only once the email is stored, which is what website/waitlist.js expects."""

    authentication_classes: list = []
    permission_classes = [permissions.AllowAny]
    throttle_classes = [WaitlistThrottle]

    def post(self, request):
        serializer = WaitlistSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        email = serializer.validated_data["email"].strip().lower()
        _, created = WaitlistSignup.objects.get_or_create(
            email=email, defaults={"source": serializer.validated_data.get("source", "")}
        )
        return Response({"ok": True}, status=status.HTTP_201_CREATED if created else status.HTTP_200_OK)
