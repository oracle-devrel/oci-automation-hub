# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

import sqlite3
import threading
import uuid
import json
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional
from urllib.parse import urlparse

from .config import CONVERSATION_DB_PATH, DATA_DIR
from .models import ChatMessage, ConversationSaveInput

_LOCK = threading.Lock()


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _connect() -> sqlite3.Connection:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(CONVERSATION_DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def normalize_mcp_url(url: str) -> str:
    clean_url = url.strip()
    if clean_url and "://" not in clean_url:
        clean_url = f"https://{clean_url}"

    parsed = urlparse(clean_url)
    if parsed.scheme in {"http", "https"} and parsed.netloc and parsed.path in {"", "/"}:
        return clean_url.rstrip("/") + "/mcp"
    return clean_url


def init_storage() -> None:
    with _LOCK, _connect() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS conversations (
                client_id TEXT NOT NULL,
                thread_id TEXT NOT NULL,
                title TEXT NOT NULL,
                conversation_id TEXT,
                memory_subject_id TEXT,
                region TEXT,
                compartment_id TEXT,
                compartment_name TEXT,
                project_id TEXT,
                project_name TEXT,
                model_id TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (client_id, thread_id)
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS conversation_messages (
                client_id TEXT NOT NULL,
                thread_id TEXT NOT NULL,
                position INTEGER NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                created_at TEXT NOT NULL,
                PRIMARY KEY (client_id, thread_id, position),
                FOREIGN KEY (client_id, thread_id)
                    REFERENCES conversations (client_id, thread_id)
                    ON DELETE CASCADE
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS mcp_servers (
                client_id TEXT NOT NULL,
                server_id TEXT NOT NULL,
                name TEXT NOT NULL,
                url TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (client_id, server_id),
                UNIQUE (client_id, url)
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS rag_sources (
                client_id TEXT NOT NULL,
                region TEXT NOT NULL,
                compartment_id TEXT NOT NULL,
                project_id TEXT NOT NULL,
                name TEXT NOT NULL,
                vector_store_id TEXT NOT NULL,
                file_ids TEXT NOT NULL DEFAULT '[]',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (client_id, region, compartment_id, project_id)
            )
            """
        )
        conn.execute("DELETE FROM mcp_servers WHERE server_id = ?", ("primary-mcp-server",))


def _row_to_dict(row: sqlite3.Row) -> Dict[str, Any]:
    return {key: row[key] for key in row.keys()}


def list_conversations(client_id: str) -> List[Dict[str, Any]]:
    with _LOCK, _connect() as conn:
        rows = conn.execute(
            """
            SELECT *
            FROM conversations
            WHERE client_id = ?
            ORDER BY updated_at DESC
            """,
            (client_id,),
        ).fetchall()
        return [_row_to_dict(row) for row in rows]


def get_conversation(client_id: str, thread_id: str) -> Optional[Dict[str, Any]]:
    with _LOCK, _connect() as conn:
        convo = conn.execute(
            "SELECT * FROM conversations WHERE client_id = ? AND thread_id = ?",
            (client_id, thread_id),
        ).fetchone()
        if convo is None:
            return None

        messages = conn.execute(
            """
            SELECT role, content
            FROM conversation_messages
            WHERE client_id = ? AND thread_id = ?
            ORDER BY position ASC
            """,
            (client_id, thread_id),
        ).fetchall()

        result = _row_to_dict(convo)
        result["messages"] = [_row_to_dict(row) for row in messages]
        return result


def save_conversation(input_data: ConversationSaveInput) -> Dict[str, Any]:
    now = _now()
    clean_messages = [
        ChatMessage(role=item.role, content=item.content)
        for item in input_data.messages
        if item.content.strip()
    ]
    title = (input_data.title or "").strip()
    if not title and clean_messages:
        title = clean_messages[0].content.strip()[:80]
    if not title:
        title = "New conversation"

    with _LOCK, _connect() as conn:
        existing = conn.execute(
            "SELECT created_at FROM conversations WHERE client_id = ? AND thread_id = ?",
            (input_data.client_id, input_data.thread_id),
        ).fetchone()
        created_at = existing["created_at"] if existing else now

        conn.execute(
            """
            INSERT INTO conversations (
                client_id, thread_id, title, conversation_id, memory_subject_id,
                region, compartment_id, compartment_name, project_id, project_name,
                model_id, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(client_id, thread_id) DO UPDATE SET
                title = excluded.title,
                conversation_id = COALESCE(excluded.conversation_id, conversations.conversation_id),
                memory_subject_id = COALESCE(excluded.memory_subject_id, conversations.memory_subject_id),
                region = excluded.region,
                compartment_id = excluded.compartment_id,
                compartment_name = excluded.compartment_name,
                project_id = excluded.project_id,
                project_name = excluded.project_name,
                model_id = excluded.model_id,
                updated_at = excluded.updated_at
            """,
            (
                input_data.client_id,
                input_data.thread_id,
                title,
                input_data.conversation_id,
                input_data.memory_subject_id,
                input_data.region,
                input_data.compartment_id,
                input_data.compartment_name,
                input_data.project_id,
                input_data.project_name,
                input_data.model_id,
                created_at,
                now,
            ),
        )

        conn.execute(
            "DELETE FROM conversation_messages WHERE client_id = ? AND thread_id = ?",
            (input_data.client_id, input_data.thread_id),
        )
        conn.executemany(
            """
            INSERT INTO conversation_messages (client_id, thread_id, position, role, content, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                (input_data.client_id, input_data.thread_id, index, item.role, item.content, now)
                for index, item in enumerate(clean_messages)
            ],
        )

    saved = get_conversation(input_data.client_id, input_data.thread_id)
    return saved or {}


def rename_conversation(client_id: str, thread_id: str, title: str) -> Optional[Dict[str, Any]]:
    with _LOCK, _connect() as conn:
        conn.execute(
            """
            UPDATE conversations
            SET title = ?, updated_at = ?
            WHERE client_id = ? AND thread_id = ?
            """,
            (title.strip(), _now(), client_id, thread_id),
        )
    return get_conversation(client_id, thread_id)


def delete_conversation(client_id: str, thread_id: str) -> None:
    with _LOCK, _connect() as conn:
        conn.execute(
            "DELETE FROM conversations WHERE client_id = ? AND thread_id = ?",
            (client_id, thread_id),
        )


def _mcp_row_to_dict(row: sqlite3.Row) -> Dict[str, Any]:
    item = _row_to_dict(row)
    item["enabled"] = bool(item.get("enabled"))
    item["url"] = normalize_mcp_url(str(item.get("url") or ""))
    return item


def list_mcp_servers(client_id: str) -> List[Dict[str, Any]]:
    with _LOCK, _connect() as conn:
        rows = conn.execute(
            """
            SELECT *
            FROM mcp_servers
            WHERE client_id = ?
            ORDER BY created_at ASC
            """,
            (client_id,),
        ).fetchall()
        return [_mcp_row_to_dict(row) for row in rows]


def add_mcp_server(client_id: str, name: str, url: str, enabled: bool = True) -> Dict[str, Any]:
    now = _now()
    server_id = f"mcp-{uuid.uuid4().hex[:12]}"
    clean_name = name.strip()
    clean_url = normalize_mcp_url(url)
    with _LOCK, _connect() as conn:
        conn.execute(
            """
            INSERT INTO mcp_servers (
                client_id, server_id, name, url, enabled, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(client_id, url) DO UPDATE SET
                name = excluded.name,
                enabled = excluded.enabled,
                updated_at = excluded.updated_at
            """,
            (client_id, server_id, clean_name, clean_url, 1 if enabled else 0, now, now),
        )
        row = conn.execute(
            "SELECT * FROM mcp_servers WHERE client_id = ? AND url = ?",
            (client_id, clean_url),
        ).fetchone()
        return _mcp_row_to_dict(row)


def update_mcp_server(
    client_id: str,
    server_id: str,
    name: Optional[str] = None,
    enabled: Optional[bool] = None,
) -> Optional[Dict[str, Any]]:
    updates = []
    values: List[Any] = []
    if name is not None:
        updates.append("name = ?")
        values.append(name.strip())
    if enabled is not None:
        updates.append("enabled = ?")
        values.append(1 if enabled else 0)

    if updates:
        updates.append("updated_at = ?")
        values.append(_now())
        values.extend([client_id, server_id])
        with _LOCK, _connect() as conn:
            conn.execute(
                f"UPDATE mcp_servers SET {', '.join(updates)} WHERE client_id = ? AND server_id = ?",
                values,
            )

    with _LOCK, _connect() as conn:
        row = conn.execute(
            "SELECT * FROM mcp_servers WHERE client_id = ? AND server_id = ?",
            (client_id, server_id),
        ).fetchone()
        return _mcp_row_to_dict(row) if row else None


def delete_mcp_server(client_id: str, server_id: str) -> None:
    with _LOCK, _connect() as conn:
        conn.execute(
            "DELETE FROM mcp_servers WHERE client_id = ? AND server_id = ?",
            (client_id, server_id),
        )


def _rag_row_to_dict(row: sqlite3.Row) -> Dict[str, Any]:
    item = _row_to_dict(row)
    try:
        item["file_ids"] = json.loads(item.get("file_ids") or "[]")
    except Exception:
        item["file_ids"] = []
    return item


def get_rag_source(client_id: str, region: str, compartment_id: str, project_id: str) -> Optional[Dict[str, Any]]:
    with _LOCK, _connect() as conn:
        row = conn.execute(
            """
            SELECT *
            FROM rag_sources
            WHERE client_id = ? AND region = ? AND compartment_id = ? AND project_id = ?
            """,
            (client_id, region, compartment_id, project_id),
        ).fetchone()
        return _rag_row_to_dict(row) if row else None


def save_rag_source(
    client_id: str,
    region: str,
    compartment_id: str,
    project_id: str,
    name: str,
    vector_store_id: str,
    file_ids: List[str],
) -> Dict[str, Any]:
    now = _now()
    clean_file_ids = list(dict.fromkeys(item.strip() for item in file_ids if item.strip()))
    with _LOCK, _connect() as conn:
        existing = conn.execute(
            """
            SELECT created_at
            FROM rag_sources
            WHERE client_id = ? AND region = ? AND compartment_id = ? AND project_id = ?
            """,
            (client_id, region, compartment_id, project_id),
        ).fetchone()
        created_at = existing["created_at"] if existing else now
        conn.execute(
            """
            INSERT INTO rag_sources (
                client_id, region, compartment_id, project_id, name,
                vector_store_id, file_ids, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(client_id, region, compartment_id, project_id) DO UPDATE SET
                name = excluded.name,
                vector_store_id = excluded.vector_store_id,
                file_ids = excluded.file_ids,
                updated_at = excluded.updated_at
            """,
            (
                client_id,
                region,
                compartment_id,
                project_id,
                name.strip() or "RAG source",
                vector_store_id,
                json.dumps(clean_file_ids),
                created_at,
                now,
            ),
        )
    return get_rag_source(client_id, region, compartment_id, project_id) or {}
