from dataclasses import dataclass


@dataclass(frozen=True)
class FixturePlace:
    id: str
    name: str
    category: str
    neighborhood: str
    address: str
    latitude: float
    longitude: float
    estimated_cost: float | None
    aliases: tuple[str, ...]


PLACES = (
    FixturePlace(
        id="fixture:levain",
        name="Levain Bakery",
        category="food",
        neighborhood="Upper West Side",
        address="167 W 74th St, New York, NY",
        latitude=40.7799,
        longitude=-73.9805,
        estimated_cost=6,
        aliases=("levain", "cookie worth the line"),
    ),
    FixturePlace(
        id="fixture:los-tacos",
        name="Los Tacos No. 1",
        category="food",
        neighborhood="Chelsea",
        address="75 Ninth Ave, New York, NY",
        latitude=40.7424,
        longitude=-74.0061,
        estimated_cost=15,
        aliases=("los tacos", "adobada taco", "chelsea market"),
    ),
    FixturePlace(
        id="fixture:hungarian-pastry",
        name="The Hungarian Pastry Shop",
        category="coffee",
        neighborhood="Morningside Heights",
        address="1030 Amsterdam Ave, New York, NY",
        latitude=40.8036,
        longitude=-73.9636,
        estimated_cost=9,
        aliases=("hungarian pastry", "study spot near campus"),
    ),
)


def resolve_candidates(evidence: str) -> list[dict]:
    normalized = evidence.casefold()
    matches = [
        place
        for place in PLACES
        if any(alias.casefold() in normalized for alias in place.aliases)
    ][:3]
    return [
        {
            "id": place.id,
            "provider": "fixture",
            "providerPlaceId": place.id,
            "name": place.name,
            "category": place.category,
            "address": place.address,
            "neighborhood": place.neighborhood,
            "latitude": place.latitude,
            "longitude": place.longitude,
            "confidence": "high",
            "reason": "Place name or description matched the approved evidence",
            "estimatedCost": place.estimated_cost,
            "attribution": {"name": "Plandit fixture", "url": None},
        }
        for place in matches
    ]
