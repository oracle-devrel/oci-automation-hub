# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

from contextlib import AsyncExitStack
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

import httpx
from langchain_core.messages import SystemMessage, ToolMessage
from langchain_core.tools import tool
from langgraph.graph import END, StateGraph
from langgraph.prebuilt import create_react_agent
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client
from langchain_mcp_adapters.tools import load_mcp_tools
from openai import OpenAI

from .config import (
    OCI_CONFIG,
    OCI_GENAI_MEMORY_ACCESS_POLICY,
    OCI_GENAI_MEMORY_SUBJECT_ID,
    OCI_GENAI_SHORT_TERM_MEMORY_OPTIMIZATION,
    logger,
)
from .models import AgentState, ChatMessage
from .utils import _extract_trace, _filter_tools, _json_safe, _message_content_to_text, _messages_from_history, _sse

MCP_CONNECTOR_ERROR_MARKERS = (
    "Error retrieving tool list from MCP server",
    "external_connector_error",
    "Failed Dependency",
)

SYSTEM_PROMPT = (
    "You are a helpful OCI CloudOps assistant. Write naturally, clearly, and concisely. "
    "Use tools only when they are needed to answer an OCI-related question, inspect live OCI data, or perform an OCI operation. "
    "For general conversation, greetings, explanations, and questions that do not require live OCI data, answer directly without tools. "
    "If the user's request is unclear, incomplete, or ambiguous, ask one brief clarifying question before taking action. "
    "When tools are needed, choose the smallest useful set of tools. "
    "When a RAG file_search tool is available, use it for questions about uploaded documents, runbooks, SOPs, policies, architecture notes, incidents, troubleshooting guides, or any user-specific knowledge that may be in the selected RAG source. "
    "Prefer RAG over general knowledge for those document-grounded questions, and cite or summarize the retrieved evidence rather than guessing. "
    "Do not invent compartments, instances, images, shapes, or other OCI resources. "
    "If a tool returns an error, inspect the failure and explain the problem clearly. "
    "If the information cannot be determined from the tools or the available context, say so plainly instead of guessing."
)


def _base_url_for_region(region: Optional[str]) -> str:
    selected_region = region or OCI_CONFIG.get("region") or ""
    if not selected_region:
        raise RuntimeError("Select an OCI region before calling OCI Generative AI.")
    return f"https://inference.generativeai.{selected_region}.oci.oraclecloud.com/openai/v1"


def _cp_endpoint_for_region(region: Optional[str]) -> str:
    selected_region = region or OCI_CONFIG.get("region") or ""
    if not selected_region:
        raise RuntimeError("Select an OCI region before calling OCI Generative AI.")
    return f"https://generativeai.{selected_region}.oci.oraclecloud.com/20231130"


def _dp_endpoint_for_region(region: Optional[str]) -> str:
    selected_region = region or OCI_CONFIG.get("region") or ""
    if not selected_region:
        raise RuntimeError("Select an OCI region before calling OCI Generative AI.")
    return f"https://inference.generativeai.{selected_region}.oci.oraclecloud.com/20231130"


def _oci_auth(force_iam: bool = False) -> Optional[httpx.Auth]:
    try:
        from oci_genai_auth import OciResourcePrincipalAuth
    except ImportError as exc:
        raise RuntimeError("OCI resource principal auth requires the oci-genai-auth package.") from exc
    return OciResourcePrincipalAuth()


def _client(region: Optional[str], project_id: Optional[str]) -> OpenAI:
    selected_project_id = _require_project_id(project_id)

    auth = _oci_auth()
    http_client = httpx.Client(auth=auth, timeout=httpx.Timeout(120.0, read=300.0)) if auth else None
    return OpenAI(
        base_url=_base_url_for_region(region),
        api_key="oci-resource-principal",
        project=selected_project_id,
        http_client=http_client,
    )


def _oci_vector_client(
    *,
    endpoint: str,
    project_id: Optional[str],
    compartment_id: Optional[str] = None,
    include_compartment_header: bool = False,
) -> OpenAI:
    selected_project_id = _require_project_id(project_id)

    try:
        from oci_openai import OciOpenAI
    except ImportError as exc:
        raise RuntimeError("OCI vector store operations require the oci-openai package.") from exc

    auth = _oci_auth(force_iam=True)
    return OciOpenAI(
        service_endpoint=endpoint,
        auth=auth,
        compartment_id=compartment_id,
        project=selected_project_id,
        default_headers={"opc-compartment-id": compartment_id}
        if include_compartment_header and compartment_id
        else None,
    )


def _require_project_id(project_id: Optional[str]) -> str:
    selected_project_id = project_id or ""
    if not selected_project_id:
        raise RuntimeError("Select an OCI Generative AI project before calling OCI Generative AI.")
    return selected_project_id


def _require_model_id(model_id: Optional[str]) -> str:
    selected_model_id = model_id or ""
    if not selected_model_id:
        raise RuntimeError("Select an OCI Generative AI model before chatting.")
    return selected_model_id


def cp_client(region: Optional[str], project_id: Optional[str], compartment_id: Optional[str] = None) -> OpenAI:
    return _oci_vector_client(
        endpoint=_cp_endpoint_for_region(region),
        project_id=project_id,
        compartment_id=compartment_id,
        include_compartment_header=True,
    )


def dp_client(region: Optional[str], project_id: Optional[str], compartment_id: Optional[str] = None) -> OpenAI:
    return _oci_vector_client(
        endpoint=_dp_endpoint_for_region(region),
        project_id=project_id,
        compartment_id=compartment_id,
        include_compartment_header=False,
    )


def _vector_client(
    region: Optional[str],
    project_id: Optional[str],
    compartment_id: Optional[str] = None,
    control_plane: bool = False,
) -> OpenAI:
    return cp_client(region, project_id, compartment_id) if control_plane else dp_client(region, project_id, compartment_id)


def _vector_legacy_client(region: Optional[str], project_id: Optional[str], compartment_id: Optional[str] = None) -> OpenAI:
    return dp_client(region, project_id, compartment_id)


def _conversation_metadata(
    thread_id: str,
    memory_subject_id: Optional[str],
    memory_access_policy: Optional[str],
    short_term_memory_optimization: Optional[str],
) -> Dict[str, str]:
    metadata = {
        "app_thread_id": thread_id,
        "memory_access_policy": memory_access_policy or OCI_GENAI_MEMORY_ACCESS_POLICY or "recall_and_store",
    }

    subject_id = memory_subject_id or OCI_GENAI_MEMORY_SUBJECT_ID
    if subject_id:
        metadata["memory_subject_id"] = subject_id

    optimization = short_term_memory_optimization or OCI_GENAI_SHORT_TERM_MEMORY_OPTIMIZATION
    if optimization:
        metadata["short_term_memory_optimization"] = optimization

    return metadata


def _ensure_conversation(
    client: OpenAI,
    conversation_id: Optional[str],
    thread_id: str,
    memory_subject_id: Optional[str],
    memory_access_policy: Optional[str],
    short_term_memory_optimization: Optional[str],
) -> str:
    if conversation_id:
        return conversation_id

    conversation = client.conversations.create(
        metadata=_conversation_metadata(
            thread_id,
            memory_subject_id,
            memory_access_policy,
            short_term_memory_optimization,
        )
    )
    return str(conversation.id)


def _mcp_tools(
    mcp_enabled: bool,
    mcp_servers: Optional[List[Dict[str, Any]]],
    allowed_mcp_tools: Optional[Dict[str, List[str]]] = None,
    allowed_tools: Optional[List[str]] = None,
) -> List[Dict[str, Any]]:
    if not mcp_enabled:
        return []

    selected_servers = [server for server in mcp_servers or [] if server.get("enabled", True)]
    if not selected_servers:
        return []

    legacy_allowed = [str(name).strip() for name in allowed_tools or [] if str(name).strip()]
    if allowed_tools is not None and not legacy_allowed and not allowed_mcp_tools:
        return []

    tools: List[Dict[str, Any]] = []
    for server in selected_servers:
        server_id = str(server.get("server_id") or server.get("id") or server.get("name") or "mcp-server")
        allowed = [
            str(name).strip()
            for name in (allowed_mcp_tools or {}).get(server_id, [])
            if str(name).strip()
        ]
        if not allowed and legacy_allowed:
            allowed = legacy_allowed

        if allowed_mcp_tools is not None and not allowed:
            continue

        tool: Dict[str, Any] = {
            "type": "mcp",
            "server_label": server_id,
            "server_description": f"Connected MCP server: {server.get('name') or server_id}",
            "server_url": server.get("url"),
            "require_approval": "never",
        }

        if allowed:
            tool["allowed_tools"] = allowed

        tools.append(tool)

    return tools


def _rag_tools(
    rag_enabled: bool,
    vector_store_id: Optional[str],
    max_results: Optional[int],
) -> List[Dict[str, Any]]:
    if not rag_enabled or not vector_store_id:
        return []

    tool: Dict[str, Any] = {
        "type": "file_search",
        "vector_store_ids": [vector_store_id],
    }
    if max_results:
        tool["max_num_results"] = max_results
    return [tool]


def _response_text(response: Any) -> str:
    text = getattr(response, "output_text", None)
    if isinstance(text, str) and text:
        return text

    parts: List[str] = []
    for item in getattr(response, "output", []) or []:
        for content in getattr(item, "content", []) or []:
            value = getattr(content, "text", None)
            if value:
                parts.append(str(value))
    return "".join(parts).strip()


def _is_mcp_connector_error(exc: BaseException) -> bool:
    message = str(exc)
    return any(marker in message for marker in MCP_CONNECTOR_ERROR_MARKERS)


def _mcp_tool_catalog(
    mcp_servers: Optional[List[Dict[str, Any]]],
    allowed_mcp_tools: Optional[Dict[str, List[str]]] = None,
) -> str:
    lines: List[str] = []
    for server in mcp_servers or []:
        if not server.get("enabled", True):
            continue
        server_id = str(server.get("server_id") or server.get("id") or server.get("name") or "mcp-server")
        allowed = set(str(name) for name in (allowed_mcp_tools or {}).get(server_id, []) if str(name).strip())
        tools = []
        for item in server.get("tools") or []:
            name = str(item.get("name") or "").strip()
            if not name or (allowed_mcp_tools is not None and name not in allowed):
                continue
            tools.append(item)
        if not tools:
            continue

        lines.append(f"MCP server {server.get('name') or server_id} ({server_id}):")
        for item in tools:
            name = str(item.get("name") or "").strip()
            description = str(item.get("description") or "No description available.").strip()
            params = item.get("parameters") or []
            param_names = ", ".join(str(param.get("name")) for param in params if param.get("name")) or "no parameters"
            lines.append(f"- {name}: {description} Parameters: {param_names}.")

    if not lines:
        return ""
    return "Available MCP tools discovered by the app backend:\n" + "\n".join(lines)


def _trace_from_response(response: Any, conversation_id: str, project_id: str, tools: List[Dict[str, Any]]) -> List[str]:
    mcp_tool_count = sum(1 for tool in tools if tool.get("type") == "mcp")
    rag_tool_count = sum(1 for tool in tools if tool.get("type") == "file_search")
    trace = [
        f"OCI Enterprise AI project: {project_id}",
        f"Conversation: {conversation_id}",
        f"MCP tools declared: {mcp_tool_count}",
        f"RAG file search tools declared: {rag_tool_count}",
    ]

    for item in getattr(response, "output", []) or []:
        item_type = getattr(item, "type", "")
        if item_type == "mcp_list_tools":
            imported = getattr(item, "tools", []) or []
            trace.append(f"MCP tools imported: {len(imported)}")
        elif item_type == "mcp_call":
            name = getattr(item, "name", "tool")
            status = getattr(item, "status", "")
            error = getattr(item, "error", "")
            trace.append(f"MCP call: {name} | status: {status}{f' | error: {error}' if error else ''}")
        elif "file_search" in item_type:
            status = getattr(item, "status", "")
            results = getattr(item, "results", None) or []
            trace.append(
                f"RAG file search: {item_type}"
                f"{f' | status: {status}' if status else ''}"
                f" | results: {len(results)}"
            )
    return trace


def _rag_search_context(
    region: Optional[str],
    project_id: Optional[str],
    compartment_id: Optional[str],
    vector_store_id: Optional[str],
    query: str,
    max_results: Optional[int],
) -> tuple[str, List[str]]:
    if not vector_store_id or not query.strip():
        return "", []

    result = dp_client(region, project_id, compartment_id).vector_stores.search(
        vector_store_id=vector_store_id,
        query=query,
        max_num_results=max_results or 6,
        rewrite_query=False,
    )
    items = getattr(result, "data", []) or []
    trace = [f"RAG source: searched vector store {vector_store_id} ({len(items)} result(s))"]
    blocks: List[str] = []

    for index, item in enumerate(items, start=1):
        payload = _json_safe(item)
        if not isinstance(payload, dict):
            continue

        content = payload.get("content")
        if isinstance(content, list):
            text = "\n".join(
                str(part.get("text") if isinstance(part, dict) else part)
                for part in content
                if str(part.get("text") if isinstance(part, dict) else part).strip()
            )
        else:
            text = str(
                payload.get("text")
                or payload.get("content_text")
                or payload.get("chunk_text")
                or content
                or ""
            )

        text = text.strip()
        if text:
            blocks.append(f"[{index}] file_id={payload.get('file_id', '')}\n{text}")

    if not blocks:
        return "", trace

    context = (
        "Use the following RAG source excerpts when they are relevant. "
        "If they do not answer the question, say so.\n\n"
    )
    context += "\n\n".join(blocks)
    context += f"\n\nUser question:\n{query}"
    return context, trace


def _response_kwargs(
    text: str,
    model_id: Optional[str],
    temperature: Optional[float],
    top_p: Optional[float],
    max_tokens: Optional[int],
    conversation_id: str,
    tools: List[Dict[str, Any]],
    mcp_servers: Optional[List[Dict[str, Any]]] = None,
    allowed_mcp_tools: Optional[Dict[str, List[str]]] = None,
) -> Dict[str, Any]:
    instructions = SYSTEM_PROMPT
    catalog = _mcp_tool_catalog(mcp_servers, allowed_mcp_tools)
    if catalog:
        instructions = (
            f"{SYSTEM_PROMPT}\n\n"
            "The app backend has already discovered this MCP tool catalog for the current user. "
            "Use this catalog when the user asks what MCP tools are available. "
            "If OCI Enterprise AI cannot import the MCP server, you may describe these tools but you cannot execute them through OCI until the MCP endpoint is reachable by OCI.\n\n"
            f"{catalog}"
        )

    kwargs: Dict[str, Any] = {
        "model": _require_model_id(model_id),
        "instructions": instructions,
        "input": text,
        "conversation": conversation_id,
        "store": True,
        "stream": False,
    }
    if tools:
        kwargs["tools"] = tools
    if temperature is not None:
        kwargs["temperature"] = temperature
    if top_p is not None:
        kwargs["top_p"] = top_p
    if max_tokens is not None:
        kwargs["max_output_tokens"] = max_tokens
    return kwargs


def _langgraph_chat_client(
    region: Optional[str],
    compartment_id: Optional[str],
    project_id: Optional[str],
    model_id: Optional[str],
    temperature: Optional[float],
    top_p: Optional[float],
    max_tokens: Optional[int],
):
    try:
        from langchain_oci import ChatOCIOpenAI
    except ImportError as exc:
        raise RuntimeError("LangGraph RAG tools require the langchain-oci package.") from exc

    kwargs: Dict[str, Any] = {
        "auth": _oci_auth(force_iam=True),
        "compartment_id": compartment_id or "",
        "model": _require_model_id(model_id),
        "base_url": _base_url_for_region(region),
        "store": False,
        "default_headers": {"OpenAi-Project": _require_project_id(project_id)},
    }
    if temperature is not None:
        kwargs["temperature"] = temperature
    if top_p is not None:
        kwargs["top_p"] = top_p
    if max_tokens is not None:
        kwargs["max_completion_tokens"] = max_tokens
    return ChatOCIOpenAI(**kwargs)


def _rag_langgraph_tool(
    region: Optional[str],
    compartment_id: Optional[str],
    project_id: Optional[str],
    vector_store_id: str,
    max_results: Optional[int],
):
    @tool("search_rag_source")
    def search_rag_source(query: str) -> str:
        """Search the selected RAG source for runbooks, SOPs, policies, architecture notes, incident notes, and uploaded documents."""
        context, _ = _rag_search_context(region, project_id, compartment_id, vector_store_id, query, max_results)
        return context or "No relevant RAG source excerpts were found."

    return search_rag_source


async def _load_langgraph_mcp_tools(
    stack: AsyncExitStack,
    mcp_enabled: bool,
    mcp_servers: Optional[List[Dict[str, Any]]],
    allowed_mcp_tools: Optional[Dict[str, List[str]]],
    allowed_tools: Optional[List[str]],
) -> tuple[List[Any], List[str]]:
    if not mcp_enabled:
        return [], []

    tools: List[Any] = []
    trace: List[str] = []
    legacy_allowed = [str(name).strip() for name in allowed_tools or [] if str(name).strip()]

    for server in mcp_servers or []:
        if not server.get("enabled", True):
            continue

        server_id = str(server.get("server_id") or server.get("id") or server.get("name") or "mcp-server")
        url = str(server.get("url") or "").strip()
        if not url:
            continue

        allowed = [
            str(name).strip()
            for name in (allowed_mcp_tools or {}).get(server_id, [])
            if str(name).strip()
        ]
        if not allowed and legacy_allowed:
            allowed = legacy_allowed
        if allowed_mcp_tools is not None and not allowed:
            continue

        reader, writer, _ = await stack.enter_async_context(streamablehttp_client(url=url))
        session = await stack.enter_async_context(ClientSession(reader, writer))
        await session.initialize()
        server_tools = await load_mcp_tools(session)
        server_tools = _filter_tools(server_tools, allowed if allowed else None)
        tools.extend(server_tools)
        trace.append(f"Loaded {len(server_tools)} MCP tool(s) from {server.get('name') or server_id}.")

    return tools, trace


async def _run_langgraph_tool_agent(
    text: str,
    history: List[ChatMessage],
    mcp_enabled: bool,
    mcp_servers: Optional[List[Dict[str, Any]]],
    allowed_mcp_tools: Optional[Dict[str, List[str]]],
    allowed_tools: Optional[List[str]],
    region: Optional[str],
    compartment_id: Optional[str],
    project_id: Optional[str],
    model_id: Optional[str],
    temperature: Optional[float],
    top_p: Optional[float],
    max_tokens: Optional[int],
    conversation_id: Optional[str],
    rag_vector_store_id: str,
    rag_max_results: Optional[int],
) -> Dict[str, Any]:
    selected_project_id = _require_project_id(project_id)
    trace: List[str] = []
    async with AsyncExitStack() as stack:
        tools, mcp_trace = await _load_langgraph_mcp_tools(
            stack,
            mcp_enabled,
            mcp_servers,
            allowed_mcp_tools,
            allowed_tools,
        )
        trace.extend(mcp_trace)

        if rag_vector_store_id:
            rag_tool = _rag_langgraph_tool(region, compartment_id, selected_project_id, rag_vector_store_id, rag_max_results)
            tools.append(rag_tool)
            trace.append(f"Loaded RAG tool search_rag_source for vector store {rag_vector_store_id}.")

        llm = _langgraph_chat_client(region, compartment_id, selected_project_id, model_id, temperature, top_p, max_tokens)
        agent = create_react_agent(llm, tools)
        system_prompt = (
            f"{SYSTEM_PROMPT}\n\n"
            "You are running inside the app backend with direct access to the loaded LangGraph tools. "
            "For OCI inventory, operations, and live data questions, call the relevant MCP tool. "
            "For uploaded documents and runbooks, call search_rag_source when available. "
            "When the user asks for available MCP tools, list the loaded MCP tool names and descriptions."
        )
        result = await agent.ainvoke(
            {"messages": [SystemMessage(content=system_prompt), *_messages_from_history(history, text)]},
            config={"configurable": {"thread_id": conversation_id or "default"}},
        )

    output_messages = result.get("messages", []) if isinstance(result, dict) else result
    reply = ""
    for message in reversed(output_messages):
        raw_content = getattr(message, "content", "") or ""
        content = _message_content_to_text(raw_content)
        if content.strip() and message.__class__.__name__ == "AIMessage":
            reply = content.strip()
            break

    trace.extend(_extract_trace(output_messages, len(tools), "LangGraph local MCP/RAG tools"))
    return {
        "reply": reply or "Sorry, I did not get a valid response.",
        "trace": trace,
        "conversation_id": conversation_id or "",
    }


async def _run_agent(
    text: str,
    history: List[ChatMessage],
    allowed_tools: Optional[List[str]] = None,
    thread_id: str = "default",
    mcp_enabled: bool = True,
    mcp_servers: Optional[List[Dict[str, Any]]] = None,
    allowed_mcp_tools: Optional[Dict[str, List[str]]] = None,
    region: Optional[str] = None,
    compartment_id: Optional[str] = None,
    project_id: Optional[str] = None,
    model_id: Optional[str] = None,
    model_provider: Optional[str] = None,
    temperature: Optional[float] = None,
    top_p: Optional[float] = None,
    max_tokens: Optional[int] = None,
    conversation_id: Optional[str] = None,
    memory_subject_id: Optional[str] = None,
    memory_access_policy: Optional[str] = None,
    short_term_memory_optimization: Optional[str] = None,
    rag_enabled: bool = False,
    rag_vector_store_id: Optional[str] = None,
    rag_max_results: Optional[int] = 6,
) -> Dict[str, Any]:
    selected_project_id = _require_project_id(project_id)
    if mcp_enabled and any(server.get("enabled", True) for server in mcp_servers or []):
        return await _run_langgraph_tool_agent(
            text,
            history,
            mcp_enabled,
            mcp_servers,
            allowed_mcp_tools,
            allowed_tools,
            region,
            compartment_id,
            selected_project_id,
            model_id,
            temperature,
            top_p,
            max_tokens,
            conversation_id,
            rag_vector_store_id or "",
            rag_max_results,
        )

    client = _client(region, selected_project_id)
    conversation_id = _ensure_conversation(
        client,
        conversation_id,
        thread_id,
        memory_subject_id,
        memory_access_policy,
        short_term_memory_optimization,
    )
    tools = [
        *_mcp_tools(mcp_enabled, mcp_servers, allowed_mcp_tools, allowed_tools),
        *_rag_tools(rag_enabled, rag_vector_store_id, rag_max_results),
    ]
    try:
        response = client.responses.create(
            **_response_kwargs(
                text,
                model_id,
                temperature,
                top_p,
                max_tokens,
                conversation_id,
                tools,
                mcp_servers,
                allowed_mcp_tools,
            )
        )
    except Exception as exc:
        if not _is_mcp_connector_error(exc):
            raise
        logger.warning("Retrying OCI response without MCP tools after connector error: %s", exc)
        tools = _rag_tools(rag_enabled, rag_vector_store_id, rag_max_results)
        response = client.responses.create(
            **_response_kwargs(
                text,
                model_id,
                temperature,
                top_p,
                max_tokens,
                conversation_id,
                tools,
                mcp_servers,
                allowed_mcp_tools,
            )
        )
    reply = _response_text(response) or "Sorry, I did not get a valid response."
    trace = _trace_from_response(response, conversation_id, selected_project_id, tools)
    if mcp_enabled and mcp_servers and not any(tool.get("type") == "mcp" for tool in tools):
        trace.insert(0, "MCP server tool list failed; retried without MCP tools.")
    return {
        "reply": reply,
        "trace": trace,
        "conversation_id": conversation_id,
    }


async def _build_stream(
    text: str,
    history: List[ChatMessage],
    thread_id: str,
    allowed_tools: Optional[List[str]] = None,
    mcp_enabled: bool = True,
    mcp_servers: Optional[List[Dict[str, Any]]] = None,
    allowed_mcp_tools: Optional[Dict[str, List[str]]] = None,
    region: Optional[str] = None,
    compartment_id: Optional[str] = None,
    project_id: Optional[str] = None,
    model_id: Optional[str] = None,
    model_provider: Optional[str] = None,
    temperature: Optional[float] = None,
    top_p: Optional[float] = None,
    max_tokens: Optional[int] = None,
    conversation_id: Optional[str] = None,
    memory_subject_id: Optional[str] = None,
    memory_access_policy: Optional[str] = None,
    short_term_memory_optimization: Optional[str] = None,
    rag_enabled: bool = False,
    rag_vector_store_id: Optional[str] = None,
    rag_max_results: Optional[int] = 6,
):
    try:
        selected_project_id = _require_project_id(project_id)
        if mcp_enabled and any(server.get("enabled", True) for server in mcp_servers or []):
            yield _sse("status", {"message": f"Using local LangGraph MCP agent with {_require_model_id(model_id)}"})
            result = await _run_langgraph_tool_agent(
                text,
                history,
                mcp_enabled,
                mcp_servers,
                allowed_mcp_tools,
                allowed_tools,
                region,
                compartment_id,
                selected_project_id,
                model_id,
                temperature,
                top_p,
                max_tokens,
                conversation_id,
                rag_vector_store_id or "",
                rag_max_results,
            )
            for line in result["trace"]:
                yield _sse("trace", {"line": line})
            yield _sse("delta", {"text": result["reply"]})
            yield _sse(
                "done",
                {
                    "reply": result["reply"],
                    "trace": result["trace"],
                    "thread_id": thread_id,
                    "conversation_id": result.get("conversation_id") or conversation_id,
                    "timestamp_utc": datetime.now(timezone.utc).isoformat(),
                },
            )
            return

        client = _client(region, selected_project_id)
        conversation_id = _ensure_conversation(
            client,
            conversation_id,
            thread_id,
            memory_subject_id,
            memory_access_policy,
            short_term_memory_optimization,
        )
        tools = [
            *_mcp_tools(mcp_enabled, mcp_servers, allowed_mcp_tools, allowed_tools),
            *_rag_tools(rag_enabled, rag_vector_store_id, rag_max_results),
        ]
        yield _sse(
            "conversation",
            {
                "conversation_id": conversation_id,
                "project_id": selected_project_id,
                "memory_subject_id": memory_subject_id or OCI_GENAI_MEMORY_SUBJECT_ID,
            },
        )
        yield _sse("status", {"message": f"Using OCI Enterprise AI Responses API with {_require_model_id(model_id)}"})
        if rag_enabled and rag_vector_store_id:
            yield _sse("trace", {"line": f"RAG file_search tool enabled for vector store {rag_vector_store_id}"})
        yield _sse(
            "tools",
            {
                "servers": [server.get("name") for server in mcp_servers or [] if server.get("enabled", True)],
                "tool_count": sum(len(item.get("allowed_tools", [])) for item in tools) if mcp_enabled else 0,
                "rag_enabled": bool(rag_enabled and rag_vector_store_id),
                "rag_vector_store_id": rag_vector_store_id,
                "tools": allowed_mcp_tools or allowed_tools or [],
                "enabled": mcp_enabled,
            },
        )

        try:
            stream = client.responses.create(
                **{
                    **_response_kwargs(
                        text,
                        model_id,
                        temperature,
                        top_p,
                        max_tokens,
                        conversation_id,
                        tools,
                        mcp_servers,
                        allowed_mcp_tools,
                    ),
                    "stream": True,
                }
            )
        except Exception as exc:
            if not _is_mcp_connector_error(exc):
                raise
            logger.warning("Retrying OCI streaming response without MCP tools after connector error: %s", exc)
            yield _sse("trace", {"line": "MCP server tool list failed; retrying without MCP tools."})
            tools = _rag_tools(rag_enabled, rag_vector_store_id, rag_max_results)
            stream = client.responses.create(
                **{
                    **_response_kwargs(
                        text,
                        model_id,
                        temperature,
                        top_p,
                        max_tokens,
                        conversation_id,
                        tools,
                        mcp_servers,
                        allowed_mcp_tools,
                    ),
                    "stream": True,
                }
            )

        final_reply = ""
        trace_items = [
            f"OCI Enterprise AI project: {selected_project_id}",
            f"Conversation: {conversation_id}",
            f"Memory subject: {memory_subject_id or OCI_GENAI_MEMORY_SUBJECT_ID or 'project default'}",
            f"Memory access policy: {memory_access_policy or OCI_GENAI_MEMORY_ACCESS_POLICY or 'project default'}",
            f"RAG file_search tool: {'enabled' if rag_enabled and rag_vector_store_id else 'disabled'}",
        ]

        for event in stream:
            event_type = getattr(event, "type", "")
            if event_type == "response.output_text.delta":
                delta = getattr(event, "delta", "") or ""
                final_reply += delta
                yield _sse("delta", {"text": delta})
            elif event_type == "response.mcp_list_tools.completed":
                trace_text = "MCP tools imported by OCI Enterprise AI"
                trace_items.append(trace_text)
                yield _sse("trace", {"line": trace_text})
            elif event_type in {"response.mcp_call.in_progress", "response.mcp_call.completed", "response.mcp_call.failed"}:
                item = getattr(event, "item", None)
                tool_name = getattr(item, "name", "MCP tool")
                trace_text = f"{event_type}: {tool_name}"
                trace_items.append(trace_text)
                yield _sse("trace", {"line": trace_text})
            elif "file_search" in event_type:
                trace_text = f"RAG {event_type}"
                trace_items.append(trace_text)
                yield _sse("trace", {"line": trace_text})
            elif event_type == "response.completed":
                response = getattr(event, "response", None)
                if response is not None:
                    final_reply = _response_text(response) or final_reply
                    trace_items = _trace_from_response(response, conversation_id, selected_project_id, tools) or trace_items
            elif event_type == "response.failed":
                response = getattr(event, "response", None)
                error = getattr(response, "error", None)
                raise RuntimeError(str(_json_safe(error) if error else "OCI Enterprise AI response failed"))

        if not final_reply:
            final_reply = "Sorry, I did not get a valid response."

        yield _sse(
            "done",
            {
                "reply": final_reply,
                "trace": trace_items,
                "thread_id": thread_id,
                "conversation_id": conversation_id,
                "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            },
        )
    except Exception as exc:
        logger.exception("Streaming chat failed")
        yield _sse("error", {"message": str(exc)})
