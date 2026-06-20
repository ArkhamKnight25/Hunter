"""LLM call helper with ordered key rotation and Redis-backed exhaustion tracking.

Iterates API keys in order. When a key hits a rate-limit / quota error it is
marked exhausted in Redis (TTL 1 hour) and the next key is tried immediately.
Non-quota errors retry the same key up to 2 times before moving on.
"""
from __future__ import annotations

import logging
import time

import redis
from openai import OpenAI

from config import (
    get_openai_api_keys,
    get_openai_base_url,
    get_openai_model,
    CELERY_BROKER_URL,
)

logger = logging.getLogger(__name__)

_EXHAUSTED_KEY_TTL = 3600  # 1 hour


def _is_quota_error(exc: Exception) -> bool:
    msg = str(exc).lower()
    return any(k in msg for k in ("rate limit", "quota", "429", "insufficient_quota", "billing"))


def _redis_exhausted_key(api_key: str) -> str:
    return f"llm:exhausted:{api_key[-8:]}"


def _mark_exhausted(r: redis.Redis, api_key: str) -> None:
    r.set(_redis_exhausted_key(api_key), "1", ex=_EXHAUSTED_KEY_TTL)
    logger.warning("llm_key_exhausted", extra={"key_suffix": api_key[-8:]})


def _is_exhausted(r: redis.Redis, api_key: str) -> bool:
    return bool(r.exists(_redis_exhausted_key(api_key)))


def _call(client, model, messages, temperature, timeout, response_format):
    kwargs = dict(model=model, messages=messages, temperature=temperature, timeout=timeout)
    if response_format is not None:
        kwargs["response_format"] = response_format
    resp = client.chat.completions.create(**kwargs)
    return resp.choices[0].message.content


def chat_completion(messages, temperature=0.2, timeout=120, response_format=None):
    """Try each API key in order, skipping exhausted ones. Marks quota errors in Redis."""
    api_keys = get_openai_api_keys()
    if not api_keys:
        raise ValueError("No OpenAI API keys configured.")

    base_url = get_openai_base_url()
    model = get_openai_model()

    try:
        r = redis.Redis.from_url(CELERY_BROKER_URL)
    except Exception:
        r = None

    last_exc = None

    for api_key in api_keys:
        if r and _is_exhausted(r, api_key):
            logger.info("llm_key_skipped", extra={"key_suffix": api_key[-8:]})
            continue

        client = OpenAI(api_key=api_key, base_url=base_url)

        for attempt in range(2):
            try:
                return _call(client, model, messages, temperature, timeout, response_format)
            except Exception as exc:
                last_exc = exc
                if _is_quota_error(exc):
                    if r:
                        _mark_exhausted(r, api_key)
                    break  # move to next key immediately
                logger.warning("llm_call_failed", extra={
                    "key_suffix": api_key[-8:], "attempt": attempt + 1, "error": str(exc),
                })
                if attempt == 0:
                    time.sleep(1)

    logger.error("llm_all_keys_failed", extra={"last_error": str(last_exc)})
    raise last_exc
