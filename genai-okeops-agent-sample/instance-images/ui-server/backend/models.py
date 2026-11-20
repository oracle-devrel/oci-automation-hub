# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

import operator
from typing import Annotated, Dict, List, Literal, Optional, TypedDict

from langchain_core.messages import AnyMessage
from pydantic import BaseModel, Field


class ChatMessage(BaseModel):
    role: Literal["user", "assistant"] = Field(...)
    content: str = Field(..., min_length=1)


class ChatInput(BaseModel):
    text: str = Field(..., min_length=1)
    thread_id: str = Field(default="default")
    history: List[ChatMessage] = Field(default_factory=list)
    allowed_tools: Optional[List[str]] = None
    allowed_mcp_tools: Optional[Dict[str, List[str]]] = None
    enabled_mcp_servers: Optional[List[str]] = None
    mcp_enabled: bool = True
    region: Optional[str] = None
    compartment_id: Optional[str] = None
    project_id: Optional[str] = None
    model_id: Optional[str] = None
    model_provider: Optional[str] = None
    temperature: Optional[float] = Field(default=None, ge=0, le=2)
    top_p: Optional[float] = Field(default=None, ge=0, le=1)
    max_tokens: Optional[int] = Field(default=None, ge=1, le=32000)
    conversation_id: Optional[str] = None
    memory_subject_id: Optional[str] = None
    memory_access_policy: Optional[str] = None
    short_term_memory_optimization: Optional[str] = None
    rag_enabled: bool = False
    rag_vector_store_id: Optional[str] = None
    rag_max_results: Optional[int] = Field(default=6, ge=1, le=20)


class ChatOutput(BaseModel):
    reply: str
    trace: List[str]
    thread_id: str
    timestamp_utc: str
    conversation_id: Optional[str] = None


class ConversationSaveInput(BaseModel):
    client_id: str = Field(default="", min_length=0)
    thread_id: str = Field(..., min_length=1)
    title: Optional[str] = None
    conversation_id: Optional[str] = None
    memory_subject_id: Optional[str] = None
    region: Optional[str] = None
    compartment_id: Optional[str] = None
    compartment_name: Optional[str] = None
    project_id: Optional[str] = None
    project_name: Optional[str] = None
    model_id: Optional[str] = None
    messages: List[ChatMessage] = Field(default_factory=list)


class ConversationRenameInput(BaseModel):
    client_id: str = Field(default="", min_length=0)
    title: str = Field(..., min_length=1, max_length=160)


class McpServerInput(BaseModel):
    name: str = Field(..., min_length=1, max_length=80)
    url: str = Field(..., min_length=8, max_length=500)
    enabled: bool = True


class McpServerUpdateInput(BaseModel):
    name: Optional[str] = Field(default=None, min_length=1, max_length=80)
    enabled: Optional[bool] = None


class RagSourceInput(BaseModel):
    region: str = Field(..., min_length=1)
    compartment_id: str = Field(..., min_length=1)
    project_id: str = Field(..., min_length=1)
    name: str = Field(default="RAG source", min_length=1, max_length=120)
    vector_store_id: Optional[str] = None
    file_ids: List[str] = Field(default_factory=list)


class AgentState(TypedDict, total=False):
    messages: Annotated[List[AnyMessage], operator.add]
    tool_rounds: int
