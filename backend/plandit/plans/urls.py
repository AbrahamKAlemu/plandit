from rest_framework.routers import SimpleRouter

from .views import DayPlanViewSet

router = SimpleRouter()
router.register("", DayPlanViewSet, basename="plan")

urlpatterns = router.urls
