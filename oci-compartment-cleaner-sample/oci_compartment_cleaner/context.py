# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

import dataclasses
import logging
from typing import Any

from . import runtime


@dataclasses.dataclass
class CleanupContext:
    config: dict[str, Any]
    signer: Any
    logger: logging.Logger
    object_namespace: str | None
    sleep_between_phases: int
    delete_wait_timeout_seconds: int
    delete_wait_interval_seconds: int

    _client_cache: dict[type[Any], Any] = dataclasses.field(default_factory=dict)
    _dynamic_deleter: Any = None
    _resolved_object_namespace: str | None = None

    def client(self, client_class: type[Any]) -> Any:
        if client_class not in self._client_cache:
            self._client_cache[client_class] = runtime.make_client(
                client_class,
                self.config,
                self.signer,
            )
        return self._client_cache[client_class]

    @property
    def dynamic_deleter(self) -> Any:
        if self._dynamic_deleter is None:
            self._dynamic_deleter = runtime.DynamicOciDeleter(
                self.config,
                self.signer,
                self.logger,
            )
        return self._dynamic_deleter

    def get_object_namespace(self, object_client: Any) -> str:
        if self._resolved_object_namespace is None:
            self._resolved_object_namespace = runtime.get_object_namespace(
                object_client,
                self.object_namespace,
                self.logger,
            )
        return self._resolved_object_namespace
