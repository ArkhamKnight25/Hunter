"""Thin LLM call helper with an optional fallback provider.

`chat_completion()` tries the primary OpenAI-compatible provider (cycling
randomly through the OPENAI_API_KEYS pool, e.g. multiple OpenRouter keys) and,
if all attempts error, transparently retries against a configured fallback
provider (e.g. a local LM Studio / Ollama instance). The fallback is disabled
by default (empty base_url) so existing deployments are unaffected until it's
explicitly configured via the settings endpoint / env:

    OPENAI_FALLBACK_BASE_URL   e.g. http://host.docker.internal:1234/v1 (LM Studio)
    OPENAI_FALLBACK_MODEL      e.g. qwen3.5:4b / whatever is loaded in LM Studio
    OPENAI_FALLBACK_API_KEY    optional; LM Studio accepts any non-empty string

Returns the assistant message content (str). Raises the primary exception only
when no fallback is configured or the fallback also fails.
"""
from __future__ import annotations

import logging
import random
import time

from openai import OpenAI

from config import (
    get_llm_provider_mode,
    get_openai_api_keys,
    get_openai_base_url,
    get_openai_fallback_api_key,
    get_openai_fallback_base_url,
    get_openai_fallback_model,
    get_openai_model,
)

logger = logging.getLogger(__name__)

_PRIMARY_ATTEMPTS = 3
_FALLBACK_ATTEMPTS = 2


def _call(client, model, messages, temperature, timeout, response_format):
    kwargs = dict(model=model, messages=messages, temperature=temperature, timeout=timeout)
    if response_format is not None:
        kwargs["response_format"] = response_format
    resp = client.chat.completions.create(**kwargs)
    return resp.choices[0].message.content


def chat_completion(messages, temperature=0.2, timeout=120, response_format=None):
    """Chat completion honoring LLM_PROVIDER_MODE:
    auto  -> primary key pool, then fallback provider
    cloud -> primary key pool only
    local -> fallback provider (LM Studio / Ollama) only
    """
    mode = get_llm_provider_mode()
    api_keys = get_openai_api_keys()
    base_url = get_openai_base_url()
    model = get_openai_model()

    fb_base_url = (get_openai_fallback_base_url() or "").strip()
    fb_model = (get_openai_fallback_model() or "").strip() or model

    if mode == "local" and not fb_base_url:
        raise ValueError(
            "LLM_PROVIDER_MODE=local but OPENAI_FALLBACK_BASE_URL is empty. "
            "Set the LM Studio base URL in settings (e.g. http://host.docker.internal:1234/v1)."
        )
    if mode == "cloud":
        fb_base_url = ""

    last_exc = None

    if mode != "local" and api_keys:
        for attempt in range(_PRIMARY_ATTEMPTS):
            api_key = random.choice(api_keys)
            client = OpenAI(api_key=api_key, base_url=base_url)
            try:
                if attempt > 0:
                    logger.info("llm_trying_again", extra={"attempt": attempt + 1})
                return _call(client, model, messages, temperature, timeout, response_format)
            except Exception as exc:
                logger.warning("llm_call_failed", extra={"error": str(exc), "attempt": attempt + 1})
                last_exc = exc
                if attempt < _PRIMARY_ATTEMPTS - 1:
                    time.sleep(1)
                continue
    elif not fb_base_url:
        raise ValueError("No OpenAI API keys configured.")

    if fb_base_url:
        if last_exc is not None:
            logger.warning(
                "llm_primary_exhausted_using_fallback",
                extra={"fallback_base_url": fb_base_url, "fallback_model": fb_model},
            )
        fb_client = OpenAI(api_key=get_openai_fallback_api_key(), base_url=fb_base_url)
        for attempt in range(_FALLBACK_ATTEMPTS):
            try:
                return _call(fb_client, fb_model, messages, temperature, timeout, response_format)
            except Exception as exc:
                logger.warning(
                    "llm_fallback_call_failed",
                    extra={"error": str(exc), "attempt": attempt + 1},
                )
                last_exc = exc
                if attempt < _FALLBACK_ATTEMPTS - 1:
                    time.sleep(1)
                continue

    logger.error("llm_all_attempts_failed", extra={"last_error": str(last_exc)})
    raise last_exc
