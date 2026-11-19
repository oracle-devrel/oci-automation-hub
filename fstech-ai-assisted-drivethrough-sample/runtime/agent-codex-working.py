# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

import os
import json
import base64
import requests
import oci
import asyncio
import inspect
import logging
import re
import threading
import time

from dotenv import load_dotenv

# ==============================
# ENV
# ==============================
load_dotenv()

SUPERVISOR_ENDPOINT = os.getenv("SUPERVISOR_ENDPOINT")
SEARCH_OFFERS_ENDPOINT = os.getenv("SEARCH_OFFERS_ENDPOINT")
GET_ORDER_HISTORY_ENDPOINT = os.getenv("GET_ORDER_HISTORY_ENDPOINT")
GET_ORDERS_ENDPOINT = os.getenv("GET_ORDERS_ENDPOINT")
INSERT_ORDER_ENDPOINT = os.getenv("INSERT_ORDER_ENDPOINT")
AUTH_TYPE = os.getenv("AUTH_TYPE", "api_key")
OCI_REGION = os.getenv("OCI_REGION", os.getenv("REGION", "us-chicago-1"))
VISION_REGION = os.getenv("VISION_REGION", OCI_REGION)


def build_oci_service_auth():
    """Return SDK configuration usable locally or from an OCI workload."""
    auth_type = (AUTH_TYPE or "api_key").lower()
    if auth_type in ("instance_principal", "instance_principals"):
        return {"region": OCI_REGION}, {
            "signer": oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
        }
    if auth_type in ("resource_principal", "resource_principals"):
        return {"region": OCI_REGION}, {
            "signer": oci.auth.signers.get_resource_principals_signer()
        }
    return oci.config.from_file(
        os.path.expanduser(os.getenv("OCI_CONFIG_FILE", "~/.oci/config")),
        os.getenv("OCI_PROFILE", "DEFAULT"),
    ), {}


config, OCI_CLIENT_KWARGS = build_oci_service_auth()

def build_agent_runtime_client():
    region = config.get("region", "us-chicago-1")
    service_endpoint = os.getenv(
        "GENAI_AGENT_RUNTIME_ENDPOINT",
        f"https://agent-runtime.generativeai.{region}.oci.oraclecloud.com"
    )
    auth_type = (AUTH_TYPE or "api_key").lower()

    if auth_type in ("instance_principal", "instance_principals"):
        signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
        return oci.generative_ai_agent_runtime.GenerativeAiAgentRuntimeClient(
            {},
            signer=signer,
            service_endpoint=service_endpoint
        )

    if auth_type in ("resource_principal", "resource_principals"):
        signer = oci.auth.signers.get_resource_principals_signer()
        return oci.generative_ai_agent_runtime.GenerativeAiAgentRuntimeClient(
            {},
            signer=signer,
            service_endpoint=service_endpoint
        )

    return oci.generative_ai_agent_runtime.GenerativeAiAgentRuntimeClient(
        config,
        service_endpoint=service_endpoint
    )


agent_runtime_client = build_agent_runtime_client()

# ==============================
# LOGGING
# ==============================
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("drive_thru")
TRACE_AGENT_FLOW = os.getenv("TRACE_AGENT_FLOW", "true").lower() in {"1", "true", "yes", "on"}


def trace(stage, message, *args):
    """Concise application flow logs without credentials or OCI endpoint details."""
    if TRACE_AGENT_FLOW:
        logger.info("[%s] " + message, stage, *args)

# ==============================
# SESSION
# ==============================
user_sessions = {}
session_locks = {}
session_locks_guard = threading.Lock()
order_confirmation_states = {}
customer_contexts = {}
turn_tool_results = {}
offer_contexts = {}
order_addon_states = {}
SESSION_TTL = 900

def get_session_key(conversation_id):
    return conversation_id or "unknown_conversation"

def get_session_lock(session_key):
    with session_locks_guard:
        if session_key not in session_locks:
            session_locks[session_key] = threading.Lock()
        return session_locks[session_key]

def get_valid_session(session_key):
    s = user_sessions.get(session_key)
    if not s:
        return None
    if time.time() - s["time"] > SESSION_TTL:
        user_sessions.pop(session_key, None)
        order_confirmation_states.pop(session_key, None)
        customer_contexts.pop(session_key, None)
        turn_tool_results.pop(session_key, None)
        offer_contexts.pop(session_key, None)
        order_addon_states.pop(session_key, None)
        return None
    return s["id"]

def store_session(session_key, session_id):
    if session_id:
        user_sessions[session_key] = {"id": session_id, "time": time.time()}

def clear_session(session_key, clear_customer=True):
    user_sessions.pop(session_key, None)
    order_confirmation_states.pop(session_key, None)
    turn_tool_results.pop(session_key, None)
    offer_contexts.pop(session_key, None)
    order_addon_states.pop(session_key, None)
    if clear_customer:
        customer_contexts.pop(session_key, None)

def set_customer_context(session_key, registration_number, customer_name="", returning_customer=False):
    customer_contexts[session_key] = {
        "registration_number": (registration_number or "").strip().upper(),
        "customer_name": (customer_name or "").strip(),
        "returning_customer": bool(returning_customer),
        "awaiting_name": not bool((customer_name or "").strip()),
    }

def get_customer_context(session_key):
    return customer_contexts.get(session_key, {})

def capture_customer_name(session_key, user_input):
    context = customer_contexts.get(session_key)
    if not context or not context.get("awaiting_name"):
        return ""

    text = re.sub(r"\s+", " ", (user_input or "").strip())
    explicit = re.fullmatch(
        r"(?i)(?:my name is|i am|i'm|this is)\s+([A-Za-z][A-Za-z' -]{0,60})[.!]?",
        text,
    )
    candidate = explicit.group(1).strip() if explicit else text.strip(" .!")
    words = candidate.split()
    ordering_words = re.compile(
        r"(?i)\b(order|burger|fries|drink|coke|tea|coffee|lemonade|meal|combo|sandwich|offer|yes|no)\b"
    )
    if not 1 <= len(words) <= 4 or ordering_words.search(candidate):
        return ""
    if not all(re.fullmatch(r"[A-Za-z][A-Za-z'-]*", word) for word in words):
        return ""

    context["customer_name"] = " ".join(word.capitalize() for word in words)
    context["awaiting_name"] = False
    trace("CUSTOMER", "captured customer name for registration=%s", context.get("registration_number"))
    return context["customer_name"]

def is_final_order_confirmation_prompt(text):
    normalized = (text or "").lower()
    return (
        "shall i place this order" in normalized
        or "should i place this order" in normalized
        or "would you like me to place this order" in normalized
    )

def has_itemized_order_summary(text):
    normalized = (text or "").lower()
    if "summary ready" in normalized and not re.search(r"[$€£]\s*\d", text or ""):
        return False
    has_total = bool(re.search(r"\b(?:total|order total)\b[^\n]{0,40}[$€£]\s*\d", text or "", re.I))
    has_priced_item = bool(re.search(
        r"(?:^|\n)\s*(?:[•*-]|\d+[.)])\s+[^\n$]{2,100}[$€£]\s*\d",
        text or "",
    ))
    return has_total and has_priced_item

def normalize_order_summary_format(text):
    """Turn inline asterisk summaries into readable Unicode bullet lines."""
    normalized = re.sub(r"(?i)(order summary\s*:)\s*\*\s*", r"\1\n• ", text or "")
    normalized = re.sub(r"\s+\*\s+(?=[A-Za-z0-9])", "\n• ", normalized)
    normalized = re.sub(r"\s+(?=your\s+total\b)", "\n", normalized, flags=re.I)
    normalized = re.sub(r"(?<!your)\s+(?=total\b)", "\n", normalized, flags=re.I)
    return normalized.strip()

def is_customer_order_confirmation(text):
    normalized = re.sub(r"[^a-z0-9 ]", " ", (text or "").lower())
    normalized = re.sub(r"\s+", " ", normalized).strip()
    if re.search(r"\b(add|change|remove|instead|without|also|actually)\b", normalized):
        return False

    exact_confirmations = {
        "yes",
        "yes please",
        "yep",
        "yeah",
        "sure",
        "sure please",
        "ok",
        "okay",
        "confirm",
        "confirmed",
        "correct",
        "sounds good",
        "go ahead",
        "go ahead please",
        "please do",
        "do it",
        "place order",
        "place the order",
        "please place order",
        "please place the order",
        "yes place order",
        "yes place the order",
        "done",
    }
    if normalized in exact_confirmations:
        return True

    return bool(
        re.search(r"\b(confirm|place)\b.*\border\b", normalized)
        or re.search(r"\b(yes|sure|ok|okay)\b.*\b(go ahead|place|confirm|do it)\b", normalized)
    )

def update_order_confirmation_state(session_key, assistant_text):
    order_confirmation_states[session_key] = {
        "awaiting_final_confirmation": (
            is_final_order_confirmation_prompt(assistant_text)
            and has_itemized_order_summary(assistant_text)
        ),
        "has_itemized_summary": has_itemized_order_summary(assistant_text),
        "last_assistant_text": assistant_text or "",
    }

def may_insert_order(session_key, user_input):
    state = order_confirmation_states.get(session_key, {})
    return (
        state.get("awaiting_final_confirmation") is True
        and is_customer_order_confirmation(user_input)
    )

def is_awaiting_final_confirmation(session_key):
    state = order_confirmation_states.get(session_key, {})
    return state.get("awaiting_final_confirmation") is True

def is_offer_display_request(text):
    normalized = (text or "").strip().lower()
    if normalized.startswith("registration ") or "web app has securely" in normalized:
        return False
    return bool(
        re.search(r"\b(offer|offers|deal|deals|special|specials)\b", normalized)
        or "what more do you have" in normalized
        or "what else do you have" in normalized
    )

def is_order_selection_request(text):
    normalized = (text or "").strip().lower()
    return bool(
        re.search(
            r"\bi\s+(?:(?:would\s+like|want)\s+to\s+|(?:will|can|may)\s+)?"
            r"(?:order|have|get|take|add)\b",
            normalized,
        )
        or re.search(r"^(?:please\s+)?(?:add|order|give\s+me)\b", normalized)
        or re.search(
            r"\b(?:can|could|would)\s+you\s+(?:please\s+)?(?:add|order|get)\b",
            normalized,
        )
        or re.search(r"\b(?:i['’]?ll|ill)\s+(?:have|take|get)\b", normalized)
        or re.search(
            r"^i\s+(?:would\s+like|want)\s+"
            r"(?!to\s+(?:know|see|hear|ask|learn)\b)",
            normalized,
        )
    )

def money(value):
    if value in (None, ""):
        return ""
    text = str(value).strip()
    if text.startswith("$"):
        return text
    try:
        return f"${float(text):.2f}"
    except ValueError:
        return text

def mentioned_offer_names(text, offers):
    normalized = (text or "").lower()
    return [
        offer.get("recommended_offer", "")
        for offer in offers
        if offer.get("recommended_offer")
        and offer.get("recommended_offer", "").lower() in normalized
    ]

def should_expand_offer_details(user_input, assistant_text, offers):
    if is_order_selection_request(user_input):
        return False
    return bool(
        is_offer_display_request(user_input)
        or mentioned_offer_names(user_input, offers)
        or mentioned_offer_names(assistant_text, offers)
    )

def is_repeating_offer_catalog(text, offers):
    return (
        len(mentioned_offer_names(text, offers)) >= 2
        or "here are three offers" in (text or "").lower()
    )

def order_acknowledgement(user_input):
    text = (user_input or "").strip()
    match = re.search(
        r"(?i)^i\s+(?:(?:would\s+like|want)\s+to\s+|(?:will|can|may)\s+)?"
        r"(?:order|have|get|take|add)\s+(.+?)[.!?]?\s*$",
        text,
    )
    if not match:
        match = re.search(
            r"(?i)^i\s+(?:would\s+like|want)\s+"
            r"(?!to\s+(?:know|see|hear|ask|learn)\b)(.+?)[.!?]?\s*$",
            text,
        )
    if not match:
        match = re.search(
            r"(?i)^(?:please\s+)?(?:add|order|give\s+me)\s+(.+?)[.!?]?\s*$",
            text,
        )
    if not match:
        match = re.search(
            r"(?i)^(?:can|could|would)\s+you\s+(?:please\s+)?"
            r"(?:add|order|get)\s+(.+?)[.!?]?\s*$",
            text,
        )
    selected = match.group(1).strip(" .!?") if match else "those items"
    return f"Got it—I’ve added {selected} to your order. Would you like anything else?"

def natural_offer_intro(assistant_text, offers):
    """Preserve a natural greeting/weather sentence before deterministic offer details."""
    positions = [
        (assistant_text or "").lower().find(name.lower())
        for name in mentioned_offer_names(assistant_text, offers)
    ]
    positions = [position for position in positions if position >= 0]
    if not positions:
        return ""
    before_offers = (assistant_text or "")[:min(positions)]
    sentence_ends = [match.end() for match in re.finditer(r"[.!?](?:\s|$)", before_offers)]
    if not sentence_ends:
        return ""
    return before_offers[:sentence_ends[-1]].strip()

def format_relevant_offers(offers, user_input="", assistant_text=""):
    available = [offer for offer in offers if offer.get("recommended_offer")]
    requested = {
        name.lower() for name in mentioned_offer_names(user_input, available)
    }
    selected = sorted(
        available,
        key=lambda offer: 0 if offer.get("recommended_offer", "").lower() in requested else 1,
    )[:3]
    if not selected:
        return "I don't have a current offer to recommend, but I can help you choose from the menu. What sounds good?"

    intro = natural_offer_intro(assistant_text, available)
    lines = []
    if intro:
        lines.append(intro)
    lines.append("Here are three offers you might enjoy:")
    for offer in selected:
        name = offer.get("recommended_offer", "Current offer")
        included = offer.get("items_included") or "Ask us for the included items"
        discounted = money(offer.get("discounted_price"))
        regular = money(offer.get("regular_price"))
        price_text = discounted or regular
        if discounted and regular and discounted != regular:
            price_text = f"{discounted} (normally {regular})"
        lines.append(f"• {name} — Includes {included}. {price_text}".rstrip())
    lines.append("Would you like one of these, or would you prefer something else?")
    return "\n".join(lines)

DRINK_OR_DESSERT_PATTERN = re.compile(
    r"(?i)\b(coke|soda|sprite|tea|lemonade|coffee|latte|drink|beverage|milkshake|shake|ice\s*cream|sundae|brownie|cookie|dessert)\b"
)
MAIN_ITEM_PATTERN = re.compile(
    r"(?i)\b(burger|sandwich|quesadilla|ribs|sliders?|meal|combo|chicken|entree|main)\b"
)

def record_order_addon_context(session_key, user_input):
    state = order_addon_states.setdefault(session_key, {
        "has_drink_or_dessert": False,
        "suggestion_made": False,
        "main_item_seen": False,
        "weather": "",
    })
    if DRINK_OR_DESSERT_PATTERN.search(user_input or ""):
        state["has_drink_or_dessert"] = True
    if MAIN_ITEM_PATTERN.search(user_input or ""):
        state["main_item_seen"] = True

def apply_gentle_weather_suggestion(session_key, assistant_text):
    state = order_addon_states.setdefault(session_key, {})
    if (
        not state.get("main_item_seen")
        or state.get("has_drink_or_dessert")
        or state.get("suggestion_made")
    ):
        return assistant_text

    existing_suggestion = DRINK_OR_DESSERT_PATTERN.search(assistant_text or "")
    if existing_suggestion:
        state["suggestion_made"] = True
        if is_final_order_confirmation_prompt(assistant_text):
            without_confirmation = re.sub(
                r"(?i)\s*(?:shall|should)\s+i\s+place\s+this\s+order\s+for\s+you\s*\?\s*$",
                "",
                assistant_text or "",
            ).rstrip()
            return (
                f"{without_confirmation} Would you like to add that suggestion, "
                "or keep your order as it is?"
            )
        return assistant_text

    description = state.get("weather")
    if not description:
        try:
            description = json.loads(_get_weather_impl()).get("day_description", "pleasant")
        except Exception:
            description = "pleasant"
        state["weather"] = description

    item = "Lemonade" if description in {"warm", "hot", "pleasant"} else "Coffee"
    state["suggestion_made"] = True
    suggestion = (
        f"If you'd like, a {item} could be a nice match for a {description} day—"
        "but your order is fine as it is."
    )
    if is_final_order_confirmation_prompt(assistant_text):
        without_confirmation = re.sub(
            r"(?i)\s*(?:shall|should)\s+i\s+place\s+this\s+order\s+for\s+you\s*\?\s*$",
            "",
            assistant_text or "",
        ).rstrip()
        return (
            f"{without_confirmation} {suggestion} "
            f"Would you like to add the {item}, or keep your order as it is?"
        ).strip()

    trailing_question = re.search(r"([^.!?]*\?)\s*$", assistant_text or "")
    if trailing_question:
        before_question = (assistant_text or "")[:trailing_question.start()].rstrip()
        question = trailing_question.group(1).strip()
        return f"{before_question} {suggestion} {question}".strip()
    return f"{assistant_text.rstrip()} {suggestion}".strip()

def is_generic_abilities_failure(text):
    normalized = (text or "").lower()
    return (
        "outside of my abilities" in normalized
        or "out of domain" in normalized
        or "outside my domain" in normalized
        or "outside of my domain" in normalized
        or "not within my domain" in normalized
        or "based on the functions i have been given" in normalized
        or "cannot perform this task" in normalized
        or "cannot perform this task as" in normalized
        or "not able to execute this task" in normalized
        or "requires additional information" in normalized
        or "additional information that is not provided" in normalized
        or "provide more context" in normalized
        or "clarify the task" in normalized
        or "exceeds the limitations" in normalized
        or "requires additional functionality" in normalized
        or "not available in the given functions" in normalized
    )

def is_order_or_menu_request(text):
    normalized = (text or "").lower()
    return bool(re.search(
        r"\b(order|have|get|add|want|would like|suggest|suggestion|suggestions|recommend|recommendation|recommendations|best seller|best sellers|popular|favorite|favorites|menu|option|options|item|items|food|drink|offer|offers|deal|deals|special|specials|coke|diet coke|sprite|tea|lemonade|coffee|milkshake|burger|slider|snack|pack|fries|meal|combo|quesadilla|sandwich)\b",
        normalized
    ))

def build_order_repair_message(user_input):
    return (
        "The customer's last message is a normal drive-thru ordering or menu request: "
        f"{user_input!r}. You do not need a function to add items, list drink/menu options, "
        "recommend best sellers, suggest items, track the running order, apply an offer already mentioned in the conversation, "
        "or ask whether they want anything else. Use current offers already in the conversation first, then order-history favorites, "
        "then known menu items. Update the running order in conversation memory and reply naturally. If a price is known from the "
        "offer/history/menu, use it; if not, ask one short clarification. Do not say this requires additional functionality."
    )

def fallback_for_generic_abilities_failure(session_key, user_input):
    if is_awaiting_final_confirmation(session_key):
        previous_summary = order_confirmation_states.get(session_key, {}).get("last_assistant_text", "")
        if previous_summary:
            return previous_summary

    normalized = (user_input or "").lower()
    food_names = (
        ("cheeseburger classic", "Cheeseburger Classic"),
        ("cheeseburger", "Cheeseburger"),
        ("classic burger", "Classic Burger"),
        ("chicken sandwich", "Chicken Sandwich"),
        ("veggie burger", "Veggie Burger"),
        ("seasoned fries", "Seasoned Fries"),
        ("green bean fries", "Green Bean Fries"),
        ("fries", "Fries"),
        ("onion rings", "Onion Rings"),
        ("quesadilla", "Quesadilla"),
    )
    selected_foods = []
    for phrase, display_name in food_names:
        if phrase in normalized and not any(
            phrase in longer_phrase
            for longer_phrase, _ in food_names
            if longer_phrase != phrase and longer_phrase in normalized
        ):
            selected_foods.append(display_name)

    order_intent = bool(re.search(
        r"\b(i (?:will|would|can|want to) (?:have|take|get|order)|"
        r"i(?:'| a)?ll have|can i (?:have|order|get)|add|give me)\b",
        normalized,
    ))
    if selected_foods and order_intent:
        if len(selected_foods) == 1:
            item_text = selected_foods[0]
        else:
            item_text = ", ".join(selected_foods[:-1]) + f" and {selected_foods[-1]}"
        return (
            f"Got it—I've added {item_text} to your order. "
            "Would you like a drink with that?"
        )

    beverage_match = re.search(
        r"\b(coke|diet coke|sprite|iced tea|tea|lemonade|coffee|milkshake)\b",
        normalized,
    )
    is_addition = bool(re.search(
        r"\b(i (?:can|will|would|will like|would like) (?:have|take|get)|"
        r"i want|add|give me|i'll have|ill have)\b",
        normalized,
    ))
    if beverage_match and is_addition:
        drink = beverage_match.group(1).title()
        return f"Got it—I've added {drink} to your order. Would you like anything else?"

    if "drink" in normalized:
        return (
            "We have Coke, Diet Coke, Sprite, iced tea, lemonade, coffee, and milkshakes. "
            "Which drink would you like?"
            )

    if is_order_or_menu_request(user_input):
        return (
            "Sure. Popular choices include the Cheeseburger Meal, Chicken Sandwich with fries, "
            "Veggie Burger, Slider Snack Pack, iced tea, lemonade, and milkshakes. "
            "If I already found a current offer for you, I recommend choosing from that first. "
            "Which option sounds good?"
        )

    return "I can help with your order, menu options, offers, and checkout. What would you like to add or change?"

def is_required_action_pending_error(exc):
    text = " ".join(
        str(getattr(exc, attr, ""))
        for attr in ("message", "code", "status")
    )
    text = f"{text} {exc}"
    return "Awaiting response for required action" in text or "required action(s)" in text

# ==============================
# TOOLS
# ==============================

def _get_order_history_impl(registration_number: str) -> str:
    try:
        response = requests.get(
            GET_ORDER_HISTORY_ENDPOINT,
            params={"registration_number": registration_number},
            timeout=30,
        )
        response.raise_for_status()
        rows = response.json().get("items", [])
        customer_name = ""
        if rows and rows[0].get("name"):
            customer_name = rows[0]["name"]
        return json.dumps({
            "registration_number": registration_number.strip().upper(),
            "customer_name": customer_name,
            "returning_customer": bool(rows),
            "orders": [
                {
                    "order_id": row.get("orderid"),
                    "order_date": row.get("orderdate"),
                    "ordered_items": row.get("ordereditems", ""),
                    "total_cost": row.get("totalordercost"),
                    "weather_details": row.get("weather_details", ""),
                }
                for row in rows
            ],
        })
    except Exception as e:
        logger.warning("Order history lookup failed")
        return json.dumps({
            "registration_number": (registration_number or "").strip().upper(),
            "customer_name": "",
            "returning_customer": False,
            "orders": [],
            "error": str(e),
        })

def _get_orders_impl() -> str:
    try:
        response = requests.get(GET_ORDERS_ENDPOINT, timeout=30)
        response.raise_for_status()
        rows = response.json().get("items", [])
        return json.dumps([
            {
                "order_id": row.get("orderid"),
                "registration_number": row.get("registrationnumber", ""),
                "order_date": row.get("orderdate"),
                "ordered_items": row.get("ordereditems", ""),
                "total_cost": row.get("totalordercost"),
                "customer_name": row.get("name", ""),
                "weather_details": row.get("weather_details", ""),
            }
            for row in rows
        ])
    except Exception as e:
        logger.warning("Order list lookup failed")
        return json.dumps({"orders": [], "error": str(e)})

def _search_offers_impl(registration_number: str = "GENERAL") -> str:
    try:
        registration_number = (registration_number or "GENERAL").strip()
        response = requests.get(
            SEARCH_OFFERS_ENDPOINT,
            params={"registration_number": registration_number},
            timeout=30,
        )
        response.raise_for_status()
        data = response.json()
        result = [
            {
                "top_ordered_item": item.get("top_ordered_item", ""),
                "recommended_offer": item.get("recommended_offer", ""),
                "items_included": item.get("itemsincluded", ""),
                "regular_price": item.get("regularprice", ""),
                "discounted_price": item.get("discountedprice", ""),
                "valid_until": item.get("validuntil", ""),
            }
            for item in data.get("items", [])
        ]
        return json.dumps(result)
    except Exception as e:
        logger.warning("Offer lookup failed; returning no current offers")
        return json.dumps({"offers": [], "registration_number": registration_number or "GENERAL", "error": str(e)})

def temperature_adjective(temperature):
    if temperature < 16:
        return "cool"
    if temperature < 28:
        return "warm"
    return "hot"

def _get_weather_impl() -> str:
    try:
        response = requests.get(
            "https://api.open-meteo.com/v1/forecast",
            params={
                "latitude": os.getenv("WEATHER_LATITUDE", "32.7767"),
                "longitude": os.getenv("WEATHER_LONGITUDE", "-96.7970"),
                "current": "temperature_2m,weather_code,snowfall",
            },
            timeout=20,
        )
        response.raise_for_status()
        current = response.json().get("current", {})
        temperature = float(current.get("temperature_2m", 22))
        weather_code = int(current.get("weather_code", 0) or 0)
        snowfall = float(current.get("snowfall", 0) or 0)

        if snowfall > 0 or weather_code in {71, 73, 75, 77, 85, 86}:
            description = "snowy"
        else:
            description = temperature_adjective(temperature)

        return json.dumps({
            "location": os.getenv("WEATHER_LOCATION", "Dallas"),
            "day_description": description,
            "customer_phrase": f"It is a {description} day today.",
            "instruction": "Describe the weather with this adjective only. Never state a temperature number.",
        })
    except Exception:
        logger.warning("Weather lookup failed; using a neutral day description")
        return json.dumps({
            "day_description": "pleasant",
            "customer_phrase": "It is a pleasant day today.",
            "instruction": "Never state a temperature number.",
        })

def remove_numeric_temperature(text):
    """Remove temperature measurements without changing prices or order IDs."""
    def adjective_from_match(match):
        value = float(match.group("value"))
        unit = (match.group("unit") or "celsius").lower()
        if "f" in unit:
            value = (value - 32) * 5 / 9
        return temperature_adjective(value)

    measurement = (
        r"(?P<value>-?\d+(?:\.\d+)?)\s*"
        r"(?P<unit>°\s*[cf]?|degrees?(?:\s+(?:celsius|fahrenheit))?|[cf]\b)"
    )
    cleaned = re.sub(
        rf"(?i)\b(?:the\s+)?temperature\s+(?:is|of|around|about)?\s*{measurement}",
        lambda match: f"It is a {adjective_from_match(match)} day",
        text or "",
    )
    cleaned = re.sub(
        rf"(?i)\bit\s+is\s+{measurement}",
        lambda match: f"It is a {adjective_from_match(match)} day",
        cleaned,
    )
    cleaned = re.sub(
        rf"(?i)(?<![$\d]){measurement}",
        lambda match: f"a {adjective_from_match(match)} day",
        cleaned,
    )
    return re.sub(r"\s{2,}", " ", cleaned).strip()

def _insert_order_impl(
    registration_number: str,
    ordered_items: str,
    total_cost: float,
    customer_name: str = "",
    weather_details: str = ""
) -> str:
    try:
        payload = {
            "registration_number": registration_number,
            "ordered_items": ordered_items,
            "total_cost": total_cost,
            "customer_name": customer_name,
            "weather_details": weather_details
        }
        r = requests.post(INSERT_ORDER_ENDPOINT, json=payload, timeout=30)
        r.raise_for_status()
        try:
            return json.dumps(r.json())
        except ValueError:
            return r.text
    except Exception as e:
        logger.exception("Failed to insert order")
        return json.dumps({"status": "error", "error": str(e)})

def _vision_extract_registration_number_impl(image_path: str) -> str:
    try:
        image_path = image_path.replace("IMAGE_INPUT::", "", 1).strip()

        with open(image_path, "rb") as f:
            encoded = base64.b64encode(f.read())

        vision_config = {**config, "region": VISION_REGION}
        client = oci.ai_vision.AIServiceVisionClient(
            vision_config, **OCI_CLIENT_KWARGS
        )
        res = client.analyze_image(
            analyze_image_details=oci.ai_vision.models.AnalyzeImageDetails(
                features=[oci.ai_vision.models.ImageTextDetectionFeature()],
                image=oci.ai_vision.models.InlineImageDetails(data=encoded.decode())
            )
        )

        # Do not return the first 5-10 character OCR line. State names such as
        # "TEXAS" are commonly returned before the actual registration.
        # This flexible pattern supports compact, spaced, and hyphenated plates.
        pattern = re.compile(r"^[A-Z0-9]{2,4}(?:[- ]?[A-Z0-9]{2,6})?$")
        non_plate_words = {
            "ALABAMA", "ALASKA", "ALBERTA", "ARIZONA", "ARKANSAS",
            "CALIFORNIA", "CANADA", "COLORADO", "CONNECTICUT", "DELAWARE",
            "FLORIDA", "GEORGIA", "HAWAII", "IDAHO", "ILLINOIS", "INDIANA",
            "IOWA", "KANSAS", "KENTUCKY", "LOUISIANA", "MAINE", "MANITOBA",
            "MARYLAND", "MASSACHUSETTS", "MEXICO", "MICHIGAN", "MINNESOTA",
            "MISSISSIPPI", "MISSOURI", "MONTANA", "NEBRASKA", "NEVADA",
            "NEWHAMPSHIRE", "NEWJERSEY", "NEWMEXICO", "NEWYORK",
            "NORTHCAROLINA", "NORTHDAKOTA", "NOVASCOTIA", "OHIO", "OKLAHOMA",
            "ONTARIO", "OREGON", "PENNSYLVANIA", "QUEBEC", "RHODEISLAND",
            "SASKATCHEWAN", "SOUTHCAROLINA", "SOUTHDAKOTA", "TENNESSEE",
            "TEXAS", "UTAH", "VERMONT", "VIRGINIA", "WASHINGTON",
            "WESTVIRGINIA", "WISCONSIN", "WYOMING", "YUKON",
            "AUDI", "BMW", "CHEVROLET", "CHRYSLER", "DEALER", "DODGE",
            "FORD", "HONDA", "HYUNDAI", "JEEP", "KIA", "LEXUS", "MAXWELL",
            "MAZDA", "MERCEDES", "NISSAN", "SUBARU", "TESLA", "TOYOTA",
            "VOLKSWAGEN", "MYFLORIDA", "NYLEMAXWELL", "SKYACTIV",
            "STATE", "SUNSHINE",
        }

        candidates = []
        for index, line in enumerate(res.data.image_text.lines or []):
            raw = (line.text or "").strip().upper()
            # OCI can interpret a plate emblem (for example the Texas star or
            # Florida orange) as punctuation. Remove it before validation.
            text = re.sub(r"[^A-Z0-9 -]", "", raw)
            text = re.sub(r"\s+", " ", text).strip()
            clean = re.sub(r"[^A-Z0-9]", "", text)

            if not pattern.fullmatch(text):
                continue
            if not 5 <= len(clean) <= 10:
                continue
            if clean in non_plate_words:
                continue

            letters = sum(char.isalpha() for char in clean)
            digits = sum(char.isdigit() for char in clean)
            confidence = float(getattr(line, "confidence", 0.0) or 0.0)

            # Mixed letters/digits are strongest evidence. Length and OCR
            # confidence break ties without assuming a single state format.
            score = 0.0
            score += 20.0 if letters and digits else 2.0
            score += 5.0 if 6 <= len(clean) <= 8 else 2.0
            score += min(max(confidence, 0.0), 1.0) * 2.0
            score += min(digits, 4) * 0.25

            # Reject windshield date stickers such as 01-26.
            if digits == len(clean) and re.fullmatch(
                r"(?:0?[1-9]|1[0-2])[-/]?\d{2,4}", raw
            ):
                score -= 30.0

            candidates.append((score, -index, clean))
        if candidates:
            candidates.sort(reverse=True)
            selected = candidates[0][2]
            trace("VISION", "selected registration=%s candidates=%d", selected, len(candidates))
            return selected

        return "NOT_FOUND"
    except Exception:
        logger.exception("Failed to extract registration number")
        return "NOT_FOUND"

LOCAL_TOOL_HANDLERS = {
    "get_order_history": _get_order_history_impl,
    "get_orders": _get_orders_impl,
    "search_offers": _search_offers_impl,
    "get_weather": _get_weather_impl,
    "insert_order": _insert_order_impl,
    "vision_extract_registration_number": _vision_extract_registration_number_impl,
}


# ==============================
# AGENT INSTRUCTIONS
# ==============================
instructions = (
    "You are a highly trained AI Agent in the customer service industry. Your primary task is to take customer orders."
    " You must always follow the instructions below without deviation.\n"

    "Input Types\n"
    "You can receive an image path, an audio filename, or a text message as input.\n"

    "Processing Rules\n"

    "1. If input is an image path (message contains a file path like /tmp/...):\n"
    "Call vision_extract_registration_number with the image path.\n"
    "This tool returns the vehicle registration number.\n"
    "Then go to Step 3.\n"

    "2. If input is an audio filename:\n"
    "Call audio_transcription_job with the filename.\n"
    "Then call extract_transcription with the returned prefix and filename.\n"
    "Use the transcribed text as the customer message and continue processing.\n"
    "Do not mention transcription to the customer.\n"

    "3. If a registration number is available (from image, audio, or text):\n"
    "Call get_order_history with the registration number.\n"
    "Call search_offers with the registration number.\n"
    "Call get_weather.\n"

    "4. If order history exists:\n"
    "Greet the customer by name warmly.\n"
    "Mention 1-2 recent favorites and the best current offer.\n"
    "Naturally reference the weather once if relevant.\n"
    "Ask what they would like today.\n"
    "Do not assume a mentioned favorite or offer is the customer's order unless the customer clearly asks to order it.\n"

    "5. If no order history exists (new customer):\n"
    "Welcome them warmly.\n"
    "If registration number was from an image: ask only for their name.\n"
    "If registration number is not yet known: ask for both name and registration number before proceeding.\n"
    "Do not place any order until both customer_name and registration_number are collected.\n"

    "6. If no registration number is found at all:\n"
    "Continue the conversation in a friendly and helpful tone.\n"
    "Ask for and record the customer's order.\n"
    "Collect name and registration number before finalizing.\n"

    "7. Taking the Order:\n"
    "Understand natural language orders including meals, combos, drinks, sides, and modifications.\n"
    "If the order is unclear, ask one short follow-up question.\n"
    "You do not need a tool to add items, track the running order, apply an offer already mentioned in the conversation, or ask whether the customer wants anything else.\n"
    "If the customer asks for menu items, options, best sellers, suggestions, recommendations, offers, deals, specials, or whether you have a food category, call search_offers before answering. If registration_number is unknown because they are a new customer, call search_offers with registration_number='GENERAL'. Also call get_weather for weather-aware suggestions.\n"
    "After those tools return, answer directly. Use this priority: current running offers returned by search_offers first, order-history favorites second, weather-aware add-ons third, and the known menu list in these instructions last. Do not invent items or prices outside known offers/history/menu.\n"
    "Known menu fallback: Classic Burger $5.99, Cheeseburger $6.49, Chicken Sandwich $6.99, Veggie Burger $6.49, Crispy Fries $2.49, Onion Rings $3.49, Soda $1.99, Iced Tea $2.49, Lemonade $2.99, Coffee $1.99, Milkshake $3.99, Meal upgrade with fries and drink add $3.49.\n"
    "Known best sellers: Cheeseburger Meal $9.98, Chicken Sandwich Combo $10.48, Classic Burger with Onion Rings $9.48, Veggie Burger Meal $9.98.\n"
    "When suggesting items, give 2-4 concise choices and ask which one they want. If current offers are available in the conversation, include the best offer as the first suggestion.\n"
    "After the customer chooses a main item, meal, combo, burger, or sandwich, do not summarize or finalize yet. If the order does not already include a drink and you have not already made a weather drink suggestion, first call search_offers and get_weather, then recommend exactly one drink from the known menu. For returning customers, call search_offers with their registration number. For new customers or customers without a known registration number, call search_offers with registration_number='GENERAL'.\n"
    "If search_offers returns a relevant offer during this drink recommendation step, mention it naturally before asking about the drink. Offers are suggestions only and must not be added unless the customer accepts.\n"
    "Weather drink rule: hot weather suggests Lemonade or Iced Tea, cold weather suggests Coffee, and pleasant weather suggests Milkshake or Lemonade.\n"
    "Ask whether they want to add that drink. Only after the drink suggestion is accepted or declined should you ask whether they would like to add anything else.\n"
    "Keep the running order in memory and update silently if the customer adds items.\n"
    "If the customer says they are interested in an offer, ask whether they want to add that exact offer to the order.\n"
    "After recording a non-main item, ask whether they would like to add anything else.\n"

    "8. Finalizing the Order:\n"
    "Only begin finalization after the weather-based drink suggestion has been offered and handled, and the customer says they do not want anything else.\n"
    "Before calling insert_order, you MUST show a clear itemized summary with item names, quantities, modifications, and total cost.\n"
    "Then ask exactly: 'Shall I place this order for you?'\n"
    "Wait for the customer's next message before calling insert_order.\n"
    "Valid final confirmations only after that exact question: yes, yes please, sure, ok, okay, confirm, sounds good, go ahead, please do, place order, yes place the order, done.\n"
    "Never treat interest in an offer, such as 'sure I am interested', as final order confirmation.\n"
    "Only after final confirmation call insert_order with registration_number, ordered_items, total_cost, customer_name, and weather_details.\n"
    "Never say 'This task is outside of my abilities based on the functions I have been given' for menu questions, adding items, drink options, final confirmation, or placing an order.\n"
    "Never say 'I cannot perform this task' for menu questions, adding items, drink options, final confirmation, or placing an order.\n"
    "Never say a customer food or drink request is 'out of domain'; adding an item to the running order does not require a tool.\n"
    "Never say you cannot provide recommendations because order history is missing. If history is missing, recommend from current offers and the known menu.\n"

    "9. After Order is Placed:\n"
    "Reply: 'Perfect, [name]! Your order has been placed. Order ID is [id]. Please proceed to the pickup window. Enjoy your meal!'\n"
    "The conversation is now complete. Send no further messages unless the customer speaks first.\n"
    "If the customer says thanks or anything casual, reply only with: 'You're welcome! See you next time!'\n"

    "10. If the original input was audio:\n"
    "After preparing the text reply, call text_to_speech_reply with that text.\n"
    "Return both the text response and the generated audio filename.\n"

    "Response Style Guidelines\n"
    "Always be friendly, polite, and customer-centric.\n"
    "Never expose JSON, tool names, internal reasoning, or system language.\n"
    "Keep replies short, natural, and conversational.\n"
    "One question per message maximum.\n"
    "Offers and recommendations are suggestions only; they are not orders until the customer explicitly adds them.\n"
    "Never call insert_order without a full summary shown and explicit confirmation received.\n"
    "Never call insert_order without both customer_name and registration_number.\n"
)

def ensure_event_loop():
    """
    Ensure each thread has its own asyncio event loop.
    Required for Python 3.11+ when the web server executes work in a thread pool.
    """
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)


MAX_REQUIRED_ACTION_ROUNDS = 8

def create_agent_session(session_key):
    safe_display_name = re.sub(r"[^A-Za-z0-9_.-]", "_", session_key)[:48]
    response = agent_runtime_client.create_session(
        agent_endpoint_id=SUPERVISOR_ENDPOINT,
        create_session_details=oci.generative_ai_agent_runtime.models.CreateSessionDetails(
            display_name=f"web-{safe_display_name}",
            description="Drive-thru web conversation"
        )
    )
    trace("SESSION", "created a new OCI conversation for %s", session_key)
    return response.data.id

def delete_agent_session(session_id):
    if not session_id:
        return

    try:
        agent_runtime_client.delete_session(
            agent_endpoint_id=SUPERVISOR_ENDPOINT,
            session_id=session_id
        )
    except Exception:
        logger.warning("Failed to delete OCI agent session")

def _chat(session_id, user_message=None, performed_actions=None):
    details = oci.generative_ai_agent_runtime.models.ChatDetails(
        session_id=session_id,
        should_stream=False
    )

    if user_message is not None:
        details.user_message = user_message
    if performed_actions:
        details.performed_actions = performed_actions

    if user_message is not None:
        trace("AGENT IN", "%s", user_message)
    elif performed_actions:
        trace("AGENT IN", "submitting %d completed tool action(s)", len(performed_actions))

    response = agent_runtime_client.chat(
        agent_endpoint_id=SUPERVISOR_ENDPOINT,
        chat_details=details
    )
    return response.data

def _parse_tool_arguments(raw_arguments):
    if not raw_arguments:
        return {}
    if isinstance(raw_arguments, dict):
        return raw_arguments

    try:
        parsed = json.loads(raw_arguments)
        return parsed if isinstance(parsed, dict) else {}
    except Exception:
        logger.warning("Could not parse tool arguments")
        return {}

def _execute_function_call_action(action, session_key, user_input):
    function_call = getattr(action, "function_call", None)
    if not function_call:
        raise ValueError("Function calling action did not include a function_call payload")

    function_name = getattr(function_call, "name", "")
    arguments = _parse_tool_arguments(getattr(function_call, "arguments", "{}"))
    handler = LOCAL_TOOL_HANDLERS.get(function_name)
    trace("TOOL START", "%s args=%s", function_name, json.dumps(arguments, default=str))

    if function_name == "insert_order":
        context = get_customer_context(session_key)
        registration_number = (arguments.get("registration_number") or context.get("registration_number") or "").strip().upper()
        customer_name = (arguments.get("customer_name") or context.get("customer_name") or "").strip()
        if registration_number:
            arguments["registration_number"] = registration_number
        if customer_name:
            arguments["customer_name"] = customer_name

        if not registration_number or not customer_name:
            missing = []
            if not registration_number:
                missing.append("registration number")
            if not customer_name:
                missing.append("customer name")
            output = json.dumps({
                "status": "not_placed",
                "reason": "customer_identity_missing",
                "missing": missing,
                "next_step": (
                    "Do not place the order. Ask only for the missing customer identity information. "
                    "After it is provided, show the final summary and ask for confirmation again."
                ),
            })
            logger.warning("Blocked insert_order because customer identity is incomplete: %s", ", ".join(missing))
            return oci.generative_ai_agent_runtime.models.FunctionCallingPerformedAction(
                action_id=action.action_id,
                function_call_output=output,
            )

    if function_name == "insert_order" and not may_insert_order(session_key, user_input):
        output = json.dumps({
            "status": "not_placed",
            "reason": "itemized_summary_and_confirmation_required",
            "next_step": (
                "Do not claim the summary is ready. Show every actual ordered item as a readable bullet "
                "with quantity and price, show the calculated total, then ask exactly: "
                "'Shall I place this order for you?' Wait for the customer's next message before calling insert_order."
            )
        })
        logger.warning("Blocked insert_order because an itemized summary and confirmation are required")
        trace("TOOL BLOCKED", "insert_order requires itemized summary followed by confirmation")
        return oci.generative_ai_agent_runtime.models.FunctionCallingPerformedAction(
            action_id=action.action_id,
            function_call_output=output
        )

    if not handler:
        output = json.dumps({"error": f"Unknown tool: {function_name}"})
    else:
        try:
            signature = inspect.signature(handler)
            accepts_kwargs = any(
                parameter.kind == inspect.Parameter.VAR_KEYWORD
                for parameter in signature.parameters.values()
            )
            if not accepts_kwargs:
                arguments = {
                    key: value
                    for key, value in arguments.items()
                    if key in signature.parameters
                }

            output = handler(**arguments)
            if not isinstance(output, str):
                output = json.dumps(output)

            if function_name == "get_order_history":
                history = json.loads(output)
                registration_number = (
                    history.get("registration_number")
                    or arguments.get("registration_number")
                    or ""
                ).strip().upper()
                customer_name = (history.get("customer_name") or "").strip()
                returning_customer = bool(history.get("orders") and customer_name)
                set_customer_context(
                    session_key,
                    registration_number,
                    customer_name=customer_name,
                    returning_customer=returning_customer,
                )
                if returning_customer:
                    history["required_next_response"] = (
                        f"Begin exactly with: Welcome back, {customer_name}! Then provide personalized recommendations."
                    )
                else:
                    history["required_next_response"] = (
                        "The registration is known but the customer name is missing. Ask only for their name."
                    )
                output = json.dumps(history)
            elif function_name == "search_offers":
                offers = json.loads(output)
                if isinstance(offers, list):
                    turn_tool_results.setdefault(session_key, {})["offers"] = offers
                    offer_contexts[session_key] = offers
            elif function_name == "get_weather":
                weather = json.loads(output)
                if isinstance(weather, dict):
                    turn_tool_results.setdefault(session_key, {})["weather"] = weather
                    order_addon_states.setdefault(session_key, {})["weather"] = weather.get(
                        "day_description", "pleasant"
                    )
        except Exception as e:
            logger.exception("Local tool %s failed", function_name)
            output = json.dumps({"error": str(e)})

    trace("TOOL END", "%s result=%s", function_name, output[:500])

    return oci.generative_ai_agent_runtime.models.FunctionCallingPerformedAction(
        action_id=action.action_id,
        function_call_output=output
    )

def _build_performed_actions(required_actions, session_key, user_input):
    performed_actions = []

    for action in required_actions:
        action_type = getattr(action, "required_action_type", "")

        if action_type == "FUNCTION_CALLING_REQUIRED_ACTION":
            performed_actions.append(_execute_function_call_action(action, session_key, user_input))
            continue

        raise ValueError(f"Unsupported OCI required action type: {action_type}")

    return performed_actions

def _extract_text_from_chat_result(chat_result):
    message = getattr(chat_result, "message", None)
    content = getattr(message, "content", None)
    text = getattr(content, "text", None)

    if text:
        return text
    if isinstance(content, str):
        return content
    if message:
        return str(message)

    return "Sorry, I could not generate a response. Please try again."

def _run_agent_once(user_input, session_id, session_key):
    turn_tool_results[session_key] = {}
    chat_result = _chat(session_id=session_id, user_message=user_input)
    confirmation_repair_attempted = False
    order_repair_attempted = False
    offer_repetition_repair_attempted = False
    summary_repair_attempted = False

    for _ in range(MAX_REQUIRED_ACTION_ROUNDS):
        required_actions = getattr(chat_result, "required_actions", None) or []
        if not required_actions:
            final_output = normalize_order_summary_format(
                _extract_text_from_chat_result(chat_result)
            )

            if (
                is_final_order_confirmation_prompt(final_output)
                and not has_itemized_order_summary(final_output)
                and not summary_repair_attempted
            ):
                summary_repair_attempted = True
                chat_result = _chat(
                    session_id=session_id,
                    user_message=(
                        "You have not yet shown the actual order summary. Do not say the summary is ready. "
                        "Using the running order in this conversation, show each ordered item on its own "
                        "bullet with quantity and price, then show the total. End by asking exactly: "
                        "'Shall I place this order for you?' Do not call insert_order in this response."
                    ),
                )
                continue

            available_offers = (
                turn_tool_results.get(session_key, {}).get("offers")
                or offer_contexts.get(session_key, [])
            )
            if (
                available_offers
                and is_order_selection_request(user_input)
                and is_repeating_offer_catalog(final_output, available_offers)
            ):
                if not offer_repetition_repair_attempted:
                    offer_repetition_repair_attempted = True
                    chat_result = _chat(
                        session_id=session_id,
                        user_message=(
                            f"The customer selected items with this message: {user_input!r}. "
                            "Acknowledge those items and keep them in the running order. Do not repeat, "
                            "re-list, or describe the offer catalog. If no drink or dessert is in the "
                            "order, make one brief optional weather-aware suggestion; otherwise ask "
                            "whether they want anything else."
                        ),
                    )
                    continue
                final_output = order_acknowledgement(user_input)

            if is_generic_abilities_failure(final_output):
                logger.warning("Agent returned a generic abilities failure; applying fallback")
                if (
                    not confirmation_repair_attempted
                    and is_awaiting_final_confirmation(session_key)
                    and is_customer_order_confirmation(user_input)
                ):
                    confirmation_repair_attempted = True
                    chat_result = _chat(
                        session_id=session_id,
                        user_message=(
                            "The customer has explicitly confirmed the final summarized order. "
                            "This is a normal drive-thru checkout task. Use the existing order details "
                            "from this conversation and call insert_order now. Do not say this is outside your abilities."
                        ),
                    )
                    continue

                if not order_repair_attempted and is_order_or_menu_request(user_input):
                    order_repair_attempted = True
                    chat_result = _chat(
                        session_id=session_id,
                        user_message=build_order_repair_message(user_input),
                    )
                    continue

                final_output = fallback_for_generic_abilities_failure(session_key, user_input)

            offers = available_offers
            if offers and should_expand_offer_details(user_input, final_output, offers):
                final_output = format_relevant_offers(
                    offers,
                    user_input=user_input,
                    assistant_text=final_output,
                )
            else:
                final_output = apply_gentle_weather_suggestion(session_key, final_output)
            final_output = remove_numeric_temperature(final_output)
            update_order_confirmation_state(session_key, final_output)
            trace("AGENT OUT", "%s", final_output)
            return final_output
        trace(
            "AGENT ACTION",
            "requested tools=%s",
            ", ".join(
                getattr(getattr(action, "function_call", None), "name", "unknown")
                for action in required_actions
            ),
        )
        performed_actions = _build_performed_actions(required_actions, session_key, user_input)
        chat_result = _chat(session_id=session_id, performed_actions=performed_actions)

    raise RuntimeError("OCI agent kept requesting required actions after the maximum tool rounds")

def run_agent(conversation_id, user_input, track_customer_input=True):
    ensure_event_loop()

    session_key = get_session_key(conversation_id)
    captured_name = ""
    if track_customer_input:
        captured_name = capture_customer_name(session_key, user_input)
        record_order_addon_context(session_key, user_input)
    lock = get_session_lock(session_key)

    with lock:
        session_id = get_valid_session(session_key)
        if not session_id:
            session_id = create_agent_session(session_key)
            store_session(session_key, session_id)

        try:
            final_output = _run_agent_once(user_input, session_id=session_id, session_key=session_key)
        except Exception as e:
            if session_id and is_required_action_pending_error(e):
                logger.warning("Resetting an OCI session with an unfinished required action")
                delete_agent_session(session_id)
                clear_session(session_key, clear_customer=False)
                session_id = create_agent_session(session_key)
                store_session(session_key, session_id)
                final_output = _run_agent_once(user_input, session_id=session_id, session_key=session_key)
            else:
                delete_agent_session(session_id)
                clear_session(session_key)
                logger.exception("Agent run failed")
                raise

        if captured_name and not final_output.lower().startswith(("nice to meet you", "welcome")):
            final_output = f"Nice to meet you, {captured_name}! {final_output.lstrip()}"
        return final_output
