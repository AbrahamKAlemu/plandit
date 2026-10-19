import hashlib
import json
import time
import uuid

from django.http import HttpRequest, JsonResponse
from django.views.decorators.csrf import csrf_exempt

from .models import ResolutionAttempt
from .services import resolve_candidates
from .url_policy import SourceUrlError, parse_supported_source_url

MAX_EVIDENCE_LENGTH = 5000


@csrf_exempt
def place_resolutions(request: HttpRequest) -> JsonResponse:
    started = time.monotonic()
    if request.method != "POST":
        return _error(None, "method_not_allowed", "Use POST.", False, status=405)
    try:
        payload = json.loads(request.body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return _error(None, "invalid_request", "Request body must be valid JSON.", False)

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
    user_text = evidence.get("userText") or ""
    if not isinstance(user_text, str) or len(user_text) > MAX_EVIDENCE_LENGTH:
        return _error(request_id, "invalid_request", "Evidence is invalid or too long.", False)
    if not user_text.strip():
        return _error(request_id, "evidence_required", "Add a place name or neighborhood.", False)

    candidates = resolve_candidates(user_text)
    outcome = "candidates" if candidates else "no_candidates"
    digest = hashlib.sha256(f"{platform}:{request_id}".encode()).hexdigest()
    ResolutionAttempt.objects.update_or_create(
        request_id=parsed_request_id,
        defaults={
            "platform": platform,
            "outcome": outcome,
            "provider": "fixture",
            "candidate_count": len(candidates),
            "latency_ms": int((time.monotonic() - started) * 1000),
            "idempotency_digest": digest,
        },
    )

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
