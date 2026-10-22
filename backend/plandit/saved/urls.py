from rest_framework.routers import SimpleRouter

from .views import SavedPostViewSet

router = SimpleRouter()
router.register("", SavedPostViewSet, basename="saved-post")

urlpatterns = router.urls
