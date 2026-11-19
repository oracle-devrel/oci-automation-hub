# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""HTTP bridge for the FSTech drive-thru web interface.

This is the web transport for the existing OCI agent,
function tools, sessions, and vehicle registration extraction.
"""

from __future__ import annotations

import asyncio
import base64
import importlib.util
import json
import logging
import os
import tempfile
import time
import uuid
from pathlib import Path

import oci
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field


AGENT_FILE = Path(__file__).with_name("agent-codex-working.py")
MAX_IMAGE_BYTES = int(os.getenv("WEB_MAX_IMAGE_BYTES", str(12 * 1024 * 1024)))
ALLOWED_IMAGE_TYPES = {"image/jpeg", "image/png", "image/webp"}
ALLOWED_AUDIO_TYPES = {
    "audio/mpeg", "audio/mp3", "audio/mp4", "audio/m4a", "audio/ogg",
    "audio/wav", "audio/x-wav", "audio/webm", "video/webm",
}
MAX_AUDIO_BYTES = int(os.getenv("WEB_MAX_AUDIO_BYTES", str(25 * 1024 * 1024)))
STT_TIMEOUT_SECONDS = int(os.getenv("STT_TIMEOUT_SECONDS", "300"))

logger = logging.getLogger("drive_thru_web")


def load_agent_module():
    spec = importlib.util.spec_from_file_location("fstech_drive_thru_agent", AGENT_FILE)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load drive-thru agent from {AGENT_FILE}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


agent = load_agent_module()


def display_money(value) -> str:
    if value in (None, ""):
        return ""
    try:
        return f"${float(value):.2f}"
    except (TypeError, ValueError):
        text = str(value).strip()
        return text if text.startswith("$") else f"${text}"


def returning_customer_summary(customer_name, orders, offers, weather) -> str:
    lines = [f"Welcome back, {customer_name}! Great to see you again."]

    lines.append("Here are your last two orders, in case you'd like a familiar favorite:")
    for order in orders[:2]:
        items = order.get("ordered_items") or "Previous order"
        total = display_money(order.get("total_cost"))
        lines.append(f"• {items} — {total}".rstrip(" —"))

    selected_offers = [offer for offer in offers if offer.get("recommended_offer")][:2]
    if selected_offers:
        lines.append("And these two offers look like a good fit for you:")
        for offer in selected_offers:
            name = offer.get("recommended_offer", "Current offer")
            included = offer.get("items_included") or "restaurant-selected items"
            discounted = display_money(offer.get("discounted_price"))
            regular = display_money(offer.get("regular_price"))
            price = discounted or regular
            if discounted and regular and discounted != regular:
                price = f"{discounted} (normally {regular})"
            lines.append(f"• {name} — Includes {included}. {price}".rstrip())

    description = weather.get("day_description", "pleasant")
    recommendation = "Coffee" if description in {"cool", "snowy"} else "Lemonade"
    lines.append(
        f"It's a {description} day, so a {recommendation} could be a nice addition if you're in the mood—no pressure."
    )
    lines.append("What sounds good today?")
    return "\n".join(lines)

NAMESPACE_NAME = os.getenv("NAMESPACE_NAME", "").strip()
BUCKET_NAME = os.getenv("BUCKET_NAME", "").strip()
COMPARTMENT_ID = os.getenv("COMPARTMENT_ID", "").strip()
TTS_VOICE_ID = os.getenv("TTS_VOICE_ID", "Victoria")

object_storage_client = oci.object_storage.ObjectStorageClient(
    agent.config, **agent.OCI_CLIENT_KWARGS
)
speech_client = oci.ai_speech.AIServiceSpeechClient(
    agent.config, **agent.OCI_CLIENT_KWARGS
)
tts_config = {**agent.config, "region": os.getenv("TTS_REGION", "us-phoenix-1")}
tts_client = oci.ai_speech.AIServiceSpeechClient(
    tts_config, **agent.OCI_CLIENT_KWARGS
)

app = FastAPI(title="FSTech Drive-Thru API", version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        origin.strip()
        for origin in os.getenv(
            "WEB_ALLOWED_ORIGINS",
            "http://localhost:3000,http://127.0.0.1:3000",
        ).split(",")
        if origin.strip()
    ],
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type"],
)


class ChatRequest(BaseModel):
    session_id: str = Field(min_length=8, max_length=100)
    message: str = Field(min_length=1, max_length=4000)


class ResetRequest(BaseModel):
    session_id: str = Field(min_length=8, max_length=100)


def web_session_key(session_id: str) -> str:
    safe = "".join(char for char in session_id if char.isalnum() or char in "-_")
    if not safe:
        raise ValueError("Invalid session id")
    return f"web:{safe}"


def require_speech_settings():
    missing = [
        name
        for name, value in {
            "COMPARTMENT_ID": COMPARTMENT_ID,
            "NAMESPACE_NAME": NAMESPACE_NAME,
            "BUCKET_NAME": BUCKET_NAME,
        }.items()
        if not value
    ]
    if missing:
        raise RuntimeError(f"Missing speech configuration: {', '.join(missing)}")


def transcript_from_payload(payload):
    transcriptions = payload.get("transcriptions") or []
    if transcriptions and isinstance(transcriptions[0], dict):
        text = transcriptions[0].get("transcription") or transcriptions[0].get("text")
        if text:
            return str(text).strip()
    text = payload.get("transcription") or payload.get("text")
    if text:
        return str(text).strip()
    raise RuntimeError("OCI Speech output did not contain a transcript")


def find_transcript(output_prefix):
    response = object_storage_client.list_objects(
        NAMESPACE_NAME,
        BUCKET_NAME,
        prefix=output_prefix,
        fields="name,size,timeCreated",
    )
    outputs = [
        item for item in response.data.objects
        if item.name.lower().endswith(".json")
    ]
    if not outputs:
        raise RuntimeError("OCI Speech produced no transcript JSON")
    outputs.sort(key=lambda item: str(getattr(item, "time_created", "")), reverse=True)
    response = object_storage_client.get_object(NAMESPACE_NAME, BUCKET_NAME, outputs[0].name)
    return transcript_from_payload(json.loads(response.data.text))


def transcribe_audio_file(path: Path):
    require_speech_settings()
    safe_name = "".join(char if char.isalnum() or char in "._-" else "_" for char in path.name)
    input_object = f"drive-thru/web-audio/{uuid.uuid4().hex}/{safe_name}"
    output_prefix = f"drive-thru/web-transcripts/{uuid.uuid4().hex}/"
    with path.open("rb") as audio:
        object_storage_client.put_object(NAMESPACE_NAME, BUCKET_NAME, input_object, audio)

    details = oci.ai_speech.models.CreateTranscriptionJobDetails(
        display_name=f"web-drive-thru-{uuid.uuid4().hex[:10]}",
        compartment_id=COMPARTMENT_ID,
        input_location=oci.ai_speech.models.ObjectListInlineInputLocation(
            location_type="OBJECT_LIST_INLINE_INPUT_LOCATION",
            object_locations=[
                oci.ai_speech.models.ObjectLocation(
                    namespace_name=NAMESPACE_NAME,
                    bucket_name=BUCKET_NAME,
                    object_names=[input_object],
                )
            ],
        ),
        output_location=oci.ai_speech.models.OutputLocation(
            namespace_name=NAMESPACE_NAME,
            bucket_name=BUCKET_NAME,
            prefix=output_prefix,
        ),
        model_details=oci.ai_speech.models.TranscriptionModelDetails(
            model_type=os.getenv("STT_MODEL_TYPE", "WHISPER_MEDIUM"),
            domain="GENERIC",
            language_code=os.getenv("STT_LANGUAGE_CODE", "en"),
        ),
    )
    job_id = speech_client.create_transcription_job(details).data.id
    deadline = time.monotonic() + STT_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        job = speech_client.get_transcription_job(job_id).data
        if job.lifecycle_state == "SUCCEEDED":
            return find_transcript(output_prefix)
        if job.lifecycle_state in {"FAILED", "CANCELED"}:
            reason = getattr(job, "lifecycle_details", "") or "No details supplied"
            raise RuntimeError(f"OCI transcription failed: {reason}")
        time.sleep(2)
    try:
        speech_client.cancel_transcription_job(job_id)
    except Exception:
        logger.warning("Could not cancel timed-out transcription job")
    raise TimeoutError("OCI transcription timed out")


def synthesize_speech(text: str):
    require_speech_settings()
    configuration = oci.ai_speech.models.TtsOracleConfiguration(
        model_family="ORACLE",
        model_details=oci.ai_speech.models.TtsOracleTts2NaturalModelDetails(
            voice_id=TTS_VOICE_ID,
        ),
        speech_settings=oci.ai_speech.models.TtsOracleSpeechSettings(
            text_type="TEXT",
            output_format="MP3",
            sample_rate_in_hz=22050,
        ),
    )
    request = oci.ai_speech.models.SynthesizeSpeechDetails(
        text=text[:10000],
        compartment_id=COMPARTMENT_ID,
        is_stream_enabled=False,
        configuration=configuration,
    )
    response = tts_client.synthesize_speech(synthesize_speech_details=request)
    return response.data.content


def tts_response_fields(text: str):
    """Generate optional Victoria audio without hiding an otherwise valid text reply."""
    try:
        speech = synthesize_speech(text)
        return {
            "audio_mime": "audio/mpeg",
            "audio_base64": base64.b64encode(speech).decode("ascii"),
            "voice": TTS_VOICE_ID,
        }
    except Exception:
        logger.exception("TTS generation failed; returning text response")
        return {"voice": TTS_VOICE_ID, "tts_unavailable": True}


@app.get("/health")
def health():
    bootstrap_status = AGENT_FILE.with_name("bootstrap-status.json")
    deployment = {}
    if bootstrap_status.exists():
        try:
            deployment = json.loads(bootstrap_status.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            logger.warning("Could not read bootstrap status file")
    return {
        "status": "ok",
        "agent": "fstech-drive-thru",
        "agent_endpoint": "ready",
        "voice": TTS_VOICE_ID,
        **deployment,
    }


@app.post("/api/chat")
async def chat(payload: ChatRequest):
    try:
        reply = await asyncio.to_thread(
            agent.run_agent,
            web_session_key(payload.session_id),
            payload.message.strip(),
        )
        audio_fields = await asyncio.to_thread(tts_response_fields, reply)
        return {"reply": reply, **audio_fields}
    except Exception:
        logger.exception("Web chat request failed")
        raise HTTPException(
            status_code=502,
            detail="The ordering assistant is temporarily unavailable. Please try again.",
        )


@app.post("/api/vehicle")
async def vehicle(session_id: str, image: UploadFile = File(...)):
    if image.content_type not in ALLOWED_IMAGE_TYPES:
        raise HTTPException(status_code=415, detail="Upload a JPG, PNG, or WebP image.")

    content = await image.read(MAX_IMAGE_BYTES + 1)
    if len(content) > MAX_IMAGE_BYTES:
        raise HTTPException(status_code=413, detail="Image must be 12 MB or smaller.")

    suffix = Path(image.filename or "vehicle.jpg").suffix.lower()
    if suffix not in {".jpg", ".jpeg", ".png", ".webp"}:
        suffix = ".jpg"

    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(prefix="drive-thru-", suffix=suffix, delete=False) as handle:
            handle.write(content)
            temporary_path = Path(handle.name)

        registration = await asyncio.to_thread(
            agent._vision_extract_registration_number_impl,
            str(temporary_path),
        )
        if registration == "NOT_FOUND":
            reply = "I couldn't read a registration number clearly. Please try a closer, well-lit photo or type it below."
            audio_fields = await asyncio.to_thread(tts_response_fields, reply)
            return {
                "registration": registration,
                "reply": reply,
                **audio_fields,
            }

        session_key = web_session_key(session_id)
        history = json.loads(await asyncio.to_thread(agent._get_order_history_impl, registration))
        if history.get("error"):
            raise RuntimeError("Order history lookup failed after registration recognition")

        orders = history.get("orders") or []
        customer_name = (history.get("customer_name") or "").strip()
        is_returning = bool(orders and customer_name)
        agent.set_customer_context(
            session_key,
            registration,
            customer_name=customer_name,
            returning_customer=is_returning,
        )

        if is_returning:
            offers = json.loads(
                await asyncio.to_thread(agent._search_offers_impl, registration)
            )
            if not isinstance(offers, list):
                offers = []
            weather = json.loads(await asyncio.to_thread(agent._get_weather_impl))

            agent.offer_contexts[session_key] = offers
            addon_state = agent.order_addon_states.setdefault(session_key, {})
            addon_state["weather"] = weather.get("day_description", "pleasant")

            recent_items = [
                order.get("ordered_items", "")
                for order in orders[:2]
                if order.get("ordered_items")
            ]
            favorite_context = "; ".join(recent_items)
            await asyncio.to_thread(
                agent.run_agent,
                session_key,
                (
                    f"Registration {registration} belongs to returning customer {customer_name}. "
                    f"Recent favorites include: {favorite_context}. Begin the response exactly with "
                    f"'Welcome back, {customer_name}!' This message is private customer context only. "
                    "Remember it for later turns, but do not treat it as an order and add nothing."
                ),
                track_customer_input=False,
            )
            reply = returning_customer_summary(
                customer_name,
                orders,
                offers,
                weather,
            )
        else:
            # The registration is already known. Ask only for the missing name;
            # order recommendations begin after the customer identifies themself.
            await asyncio.to_thread(
                agent.run_agent,
                session_key,
                (
                    f"Registration {registration} was recognized, but no customer name is stored. "
                    "This is a new or incomplete customer record. Ask only for the customer's name. "
                    "Do not discuss offers or begin checkout until they answer."
                ),
                track_customer_input=False,
            )
            reply = (
                f"Welcome to FSTech Drive-Thru! I found registration {registration}. "
                "May I have your name, please?"
            )
        audio_fields = await asyncio.to_thread(tts_response_fields, reply)
        return {"registration": registration, "reply": reply, **audio_fields}
    except HTTPException:
        raise
    except Exception:
        logger.exception("Vehicle image processing failed")
        raise HTTPException(
            status_code=502,
            detail="The vehicle image could not be processed. Please try again.",
        )
    finally:
        if temporary_path:
            temporary_path.unlink(missing_ok=True)


@app.post("/api/voice")
async def voice(session_id: str, audio: UploadFile = File(...)):
    content_type = (audio.content_type or "").split(";", 1)[0].lower()
    if content_type not in ALLOWED_AUDIO_TYPES:
        raise HTTPException(status_code=415, detail="Record or upload MP3, M4A, OGG, WAV, or WebM audio.")

    content = await audio.read(MAX_AUDIO_BYTES + 1)
    if len(content) > MAX_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail="Audio must be 25 MB or smaller.")

    extension_by_type = {
        "audio/mpeg": ".mp3", "audio/mp3": ".mp3", "audio/mp4": ".m4a",
        "audio/m4a": ".m4a", "audio/ogg": ".ogg", "audio/wav": ".wav",
        "audio/x-wav": ".wav", "audio/webm": ".webm", "video/webm": ".webm",
    }
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(
            prefix="drive-thru-voice-",
            suffix=extension_by_type.get(content_type, ".webm"),
            delete=False,
        ) as handle:
            handle.write(content)
            temporary_path = Path(handle.name)

        transcript = await asyncio.to_thread(transcribe_audio_file, temporary_path)
        reply = await asyncio.to_thread(
            agent.run_agent,
            web_session_key(session_id),
            transcript,
        )
        speech = await asyncio.to_thread(synthesize_speech, reply)
        return {
            "transcript": transcript,
            "reply": reply,
            "audio_mime": "audio/mpeg",
            "audio_base64": base64.b64encode(speech).decode("ascii"),
            "voice": TTS_VOICE_ID,
        }
    except HTTPException:
        raise
    except Exception:
        logger.exception("Voice conversation request failed")
        raise HTTPException(
            status_code=502,
            detail="The voice request could not be processed. Please try again or type your order.",
        )
    finally:
        if temporary_path:
            temporary_path.unlink(missing_ok=True)


@app.post("/api/reset")
async def reset(payload: ResetRequest):
    key = web_session_key(payload.session_id)
    session_id = agent.get_valid_session(key)
    if session_id:
        await asyncio.to_thread(agent.delete_agent_session, session_id)
    agent.clear_session(key)
    return {"status": "reset"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=int(os.getenv("WEB_API_PORT", "8000")))
