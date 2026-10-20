import uuid
from datetime import UTC, datetime, timedelta

import jwt
import pytest
from django.conf import settings
from django.core.cache import cache
from rest_framework.test import APIClient

from plandit.core.models import Profile
from plandit.places.models import Place, PlaceCategory


def make_token(user_id=None, *, email="student@columbia.edu", name="Abraham", expires_in=3600, **overrides) -> str:
    now = datetime.now(UTC)
    claims = {
        "sub": str(user_id or uuid.uuid4()),
        "aud": settings.SUPABASE_JWT_AUDIENCE,
        "iss": settings.SUPABASE_JWT_ISSUER,
        "role": "authenticated",
        "email": email,
        "user_metadata": {"full_name": name},
        "iat": now,
        "exp": now + timedelta(seconds=expires_in),
    }
    claims.update(overrides)
    return jwt.encode(claims, settings.SUPABASE_JWT_SECRET, algorithm="HS256")


@pytest.fixture(autouse=True)
def clear_cache():
    cache.clear()
    yield
    cache.clear()


@pytest.fixture
def api_client():
    return APIClient()


@pytest.fixture
def user_id():
    return uuid.uuid4()


@pytest.fixture
def auth_client(user_id):
    client = APIClient()
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {make_token(user_id)}")
    return client


@pytest.fixture
def other_client():
    client = APIClient()
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {make_token(uuid.uuid4(), email='other@nyu.edu', name='Other')}")
    return client


@pytest.fixture
def profile(user_id, db):
    return Profile.objects.create(id=user_id, email="student@columbia.edu", name="Abraham", default_budget=60)


@pytest.fixture
def places(db):
    return {
        "pastry": Place.objects.create(
            name="The Hungarian Pastry Shop",
            category=PlaceCategory.COFFEE,
            neighborhood="Morningside Heights",
            address="1030 Amsterdam Ave",
            latitude=40.8036,
            longitude=-73.9636,
            hours="Open until 9 PM",
        ),
        "bagels": Place.objects.create(
            name="Absolute Bagels",
            category=PlaceCategory.FOOD,
            neighborhood="Morningside Heights",
            address="2788 Broadway",
            latitude=40.8024,
            longitude=-73.9676,
            hours="Open until 4 PM",
        ),
        "met": Place.objects.create(
            name="The Met",
            category=PlaceCategory.CULTURE,
            neighborhood="Upper East Side",
            address="1000 Fifth Ave",
            latitude=40.7794,
            longitude=-73.9632,
            hours="Open until 5 PM",
        ),
        "smalls": Place.objects.create(
            name="Smalls Jazz Club",
            category=PlaceCategory.NIGHTLIFE,
            neighborhood="West Village",
            address="183 W 10th St",
            latitude=40.7344,
            longitude=-74.0027,
            hours=None,
        ),
    }
