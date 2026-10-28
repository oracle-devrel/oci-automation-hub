# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

import json
from typing import Any, List, Optional

from langchain_core.messages import AIMessage, AnyMessage, HumanMessage, ToolMessage

from .models import ChatMessage


def _json_safe(value: Any) -> Any:
    if value is None:
        return None
    if isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, dict):
        return {str(k): _json_safe(v) for k, v in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_json_safe(v) for v in value]
    if hasattr(value, "model_dump"):
        return _json_safe(value.model_dump())
    if hasattr(value, "__dict__"):
        return _json_safe(vars(value))
    return str(value)


async def summarize_tool_output(text: str, _model=None) -> str:
    if not text:
        return ""
    if len(text) <= 1000:
        return text
    return text[:700] + "\n...[truncated output]..."


def _messages_from_history(history: List[ChatMessage], current_text: str) -> List[AnyMessage]:
    messages: List[AnyMessage] = []
    for item in history:
        if item.role == "user":
            messages.append(HumanMessage(content=item.content))
        elif item.role == "assistant":
            messages.append(AIMessage(content=item.content))
    messages.append(HumanMessage(content=current_text))
    return messages


def _normalize_allowed_tools(allowed_tools: Optional[List[str]]) -> Optional[set[str]]:
    if allowed_tools is None:
        return None
    normalized = {str(name).strip() for name in allowed_tools if str(name).strip()}
    return normalized


def _filter_tools(tools: List[Any], allowed_tools: Optional[List[str]] = None) -> List[Any]:
    requested_tools = _normalize_allowed_tools(allowed_tools)
    if requested_tools is None:
        return list(tools)
    return [tool for tool in tools if getattr(tool, "name", None) in requested_tools]


def _tool_result_to_text(result: Any) -> str:
    if result is None:
        return ""
    if isinstance(result, str):
        text = result
    else:
        text = json.dumps(_json_safe(result), ensure_ascii=False, indent=2)

    text = text.strip()
    if len(text) > 6000:
        return text[:5600] + "\n...[truncated tool output]..."
    return text


def _message_content_to_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: List[str] = []
        for item in content:
            if isinstance(item, dict):
                if item.get("type") == "text" and item.get("text"):
                    parts.append(str(item["text"]))
                elif item.get("type") in {"output_text", "input_text"} and item.get("text"):
                    parts.append(str(item["text"]))
            elif isinstance(item, str):
                parts.append(item)
        if parts:
            return "\n".join(parts)
    return json.dumps(_json_safe(content), ensure_ascii=False)


def _extract_trace(messages: List[AnyMessage], tool_count: int, mcp_url: str) -> List[str]:
    trace: List[str] = [
        f"Opened MCP session to {mcp_url}",
        "Initialized MCP session",
        f"Loaded {tool_count} MCP tools",
        "Built LangGraph planner node",
        "Built LangGraph tool-result chaining loop",
        "Invoked agent graph",
    ]

    for msg in messages:
        name = msg.__class__.__name__
        raw_content = getattr(msg, "content", "") or ""
        content = _message_content_to_text(raw_content)
        if name == "ToolMessage":
            tool_name = getattr(msg, "name", "unknown_tool")
            trace.append(f"Tool result from {tool_name}: {content[:800]}")
        elif name == "AIMessage" and content.strip():
            tool_calls = getattr(msg, "tool_calls", None) or []
            if tool_calls:
                call_names = ", ".join(str(call.get("name", "unknown")) for call in tool_calls)
                trace.append(f"Planner requested tool call(s): {call_names}")
            else:
                trace.append(f"Assistant message: {content[:800]}")
    return trace


def _sse(event: str, data: Any) -> str:
    payload = json.dumps(_json_safe(data), ensure_ascii=False)
    return f"event: {event}\ndata: {payload}\n\n"
