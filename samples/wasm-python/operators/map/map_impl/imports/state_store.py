from typing import TypeVar, Generic, Union, Optional, Protocol, Tuple, List, Any, Self
from enum import Flag, Enum, auto
from dataclasses import dataclass
from abc import abstractmethod
import weakref

from ..types import Result, Ok, Err, Some
from ..imports import hybrid_logical_clock
from ..imports import state_store_types


def get(key: bytes, timeout: Optional[state_store_types.Duration]) -> state_store_types.StateStoreGetResponse:
    """
    Raises: `map_impl.types.Err(map_impl.imports.state_store_types.StateStoreError)`
    """
    raise NotImplementedError

def set(key: bytes, value: bytes, timeout: Optional[state_store_types.Duration], fencing_token: Optional[hybrid_logical_clock.HybridLogicalClock], options: state_store_types.SetOptions) -> state_store_types.StateStoreSetResponse:
    """
    Raises: `map_impl.types.Err(map_impl.imports.state_store_types.StateStoreError)`
    """
    raise NotImplementedError

def del_(key: bytes, fencing_token: Optional[hybrid_logical_clock.HybridLogicalClock], timeout: Optional[state_store_types.Duration]) -> state_store_types.StateStoreDelResponse:
    """
    Raises: `map_impl.types.Err(map_impl.imports.state_store_types.StateStoreError)`
    """
    raise NotImplementedError

def vdel(key: bytes, value: bytes, fencing_token: Optional[hybrid_logical_clock.HybridLogicalClock], timeout: Optional[state_store_types.Duration]) -> state_store_types.StateStoreDelResponse:
    """
    Raises: `map_impl.types.Err(map_impl.imports.state_store_types.StateStoreError)`
    """
    raise NotImplementedError

