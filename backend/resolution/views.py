import hashlib
import json
import time
import uuid

from django.conf import settings
from django.core.cache import cache
from django.db import IntegrityError, transaction
from django.http import HttpRequest, JsonResponse
from django.views.decorators.csrf import csrf_exempt

from .models import ResolutionAttempt
from .providers.ensembledata import EnsembleDataClient, EnsembleDataError
from .services import resolve_candidates
from .url_policy import SourceUrlError, parse_supported_source_url

MAX_EVIDENCE_LENGTH = 5000
MAX_SOCIAL_EVIDENCE_LENGTH = 20_000


@csrf_exempt
def social_evidence(request: HttpRequest) -> JsonResponse:
    if not settings.DEBUG or not settings.ENSEMBLEDATA_ENABLED:
        return _error(
            None,
            "not_found",
            "Development social evidence is disabled.",
            False,
            status=404,
        )
    if request.method != "POST":
        return _error(None, "method_not_allowed", "Use POST.", False, status=405)
    try:
        payload = json.loads(request.body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return _error(None, "invalid_request", "Request body must be valid JSON.", False)
    if not isinstance(payload, dict):
        return _error(None, "invalid_request", "Request body must be a JSON object.", False)
    source_url = payload.get("sourceUrl")
    if not isinstance(source_url, str):
        return _error(None, "invalid_url", "TikTok sourceUrl is required.", False)
    try:
        supported = parse_supported_source_url(source_url)
    except SourceUrlError:
        return _error(None, "invalid_url", "Use a supported TikTok video URL.", False)
    if supported.platform != "tiktok":
        return _error(None, "invalid_url", "Use a supported TikTok video URL.", False)
    if not settings.ENSEMBLEDATA_API_TOKEN:
        return _error(
            None,
            "provider_unavailable",
            "Development provider token is not configured.",
            True,
            status=503,
        )

    cache_key = "social-evidence:" + hashlib.sha256(
        supported.canonical_url.encode()
    ).hexdigest()
    response_payload = cache.get(cache_key)
    if response_payload is None:
        try:
            evidence = EnsembleDataClient(
                settings.ENSEMBLEDATA_API_TOKEN
            ).evidence_for(supported.canonical_url)
        except (EnsembleDataError, SourceUrlError):
            return _error(
                None,
                "provider_unavailable",
                "TikTok evidence could not be retrieved.",
                True,
                status=502,
            )

        response_payload = {
            "canonicalUrl": evidence.canonical_url,
            "caption": evidence.caption,
            "transcript": evidence.transcript,
            "transcriptLanguage": evidence.transcript_language,
            "combinedText": evidence.text[:MAX_SOCIAL_EVIDENCE_LENGTH],
        }
        cache.set(
            cache_key,
            response_payload,
            timeout=settings.SOCIAL_EVIDENCE_CACHE_SECONDS,
        )
    response = JsonResponse(response_payload)
    response["Cache-Control"] = "no-store"
    return response


@csrf_exempt
def place_resolutions(request: HttpRequest) -> JsonResponse:
    started = time.monotonic()
    if request.method != "POST":
        return _error(None, "method_not_allowed", "Use POST.", False, status=405)
    try:
        payload = json.loads(request.body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return _error(None, "invalid_request", "Request body must be valid JSON.", False)
    if not isinstance(payload, dict):
        return _error(None, "invalid_request", "Request body must be a JSON object.", False)

    request_id = payload.get("requestId")
    try:
        parsed_request_id = uuid.UUID(str(request_id))
    except (ValueError, TypeError, AttributeError):
        return _error(request_id, "invalid_request", "requestId must be a UUID.", False)

    platform = payload.get("platform")
    if platform not in {"tiktok", "instagram", "video"}:
        return _error(request_id, "invalid_request", "Unsupported platform.", False)

    source = None
    source_url = payload.get("sourceUrl")
    if platform == "tiktok":
        if not isinstance(source_url, str):
            return _error(request_id, "invalid_url", "TikTok sourceUrl is required.", False)
        try:
            supported = parse_supported_source_url(source_url)
        except SourceUrlError:
            return _error(request_id, "invalid_url", "Use a supported TikTok video URL.", False)
        if supported.platform != "tiktok":
            return _error(request_id, "invalid_url", "Platform and URL do not match.", False)
        source = {"canonicalUrl": supported.canonical_url}
    elif source_url is not None:
        return _error(
            request_id,
            "invalid_request",
            "Instagram and video requests must not include sourceUrl.",
            False,
        )

    evidence = payload.get("evidence") or {}
    if not isinstance(evidence, dict):
        return _error(request_id, "invalid_request", "evidence must be an object.", False)
    user_text = evidence.get("userText") or ""
    if not isinstance(user_text, str) or len(user_text) > MAX_EVIDENCE_LENGTH:
        return _error(request_id, "invalid_request", "Evidence is invalid or too long.", False)
    if not user_text.strip():
        return _error(request_id, "evidence_required", "Add a place name or neighborhood.", False)

    semantic_request = json.dumps(
        {
            "platform": platform,
            "sourceUrl": source["canonicalUrl"] if source else None,
            "evidenceHash": hashlib.sha256(user_text.strip().encode()).hexdigest(),
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    digest = hashlib.sha256(semantic_request.encode()).hexdigest()
    existing = ResolutionAttempt.objects.filter(request_id=parsed_request_id).first()
    if existing:
        if existing.candidate_payload is None:
            return _error(
                request_id,
                "idempotency_record_expired",
                "This request predates response replay. Use a new requestId.",
                False,
                status=409,
            )
        if existing.idempotency_digest != digest:
            return _error(
                request_id,
                "idempotency_conflict",
                "requestId was already used for a different request.",
                False,
                status=409,
            )
        return JsonResponse(
            {
                "requestId": str(parsed_request_id),
                "source": source,
                "candidates": existing.candidate_payload,
            }
        )

    candidates = resolve_candidates(user_text)
    outcome = "candidates" if candidates else "no_candidates"
    try:
        with transaction.atomic():
            ResolutionAttempt.objects.create(
                request_id=parsed_request_id,
                platform=platform,
                outcome=outcome,
                provider="fixture",
                candidate_count=len(candidates),
                latency_ms=int((time.monotonic() - started) * 1000),
                idempotency_digest=digest,
                candidate_payload=candidates,
            )
    except IntegrityError:
        existing = ResolutionAttempt.objects.get(request_id=parsed_request_id)
        if existing.candidate_payload is None:
            return _error(
                request_id,
                "idempotency_record_expired",
                "This request predates response replay. Use a new requestId.",
                False,
                status=409,
            )
        if existing.idempotency_digest != digest:
            return _error(
                request_id,
                "idempotency_conflict",
                "requestId was already used for a different request.",
                False,
                status=409,
            )
        candidates = existing.candidate_payload

    return JsonResponse(
        {
            "requestId": str(parsed_request_id),
            "source": source,
            "candidates": candidates,
        }
    )


def _error(
    request_id: object,
    code: str,
    message: str,
    retryable: bool,
    *,
    status: int = 400,
) -> JsonResponse:
    return JsonResponse(
        {
            "requestId": request_id,
            "error": {
                "code": code,
                "message": message,
                "retryable": retryable,
            },
        },
        status=status,
    )
