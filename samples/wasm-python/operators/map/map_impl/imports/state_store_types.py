from typing import TypeVar, Generic, Union, Optional, Protocol, Tuple, List, Any, Self
from enum import Flag, Enum, auto
from dataclasses import dataclass
from abc import abstractmethod
import weakref

from ..types import Result, Ok, Err, Some
from ..imports import hybrid_logical_clock

@dataclass
class Duration:
    seconds: int
    nanos: int

class SetConditions(Enum):
    ONLY_IF_DOES_NOT_EXIST = 0
    ONLY_IF_EQUAL_OR_DOES_NOT_EXIST = 1
    UNCONDITIONAL = 2

@dataclass
class SetOptions:
    conditions: SetConditions
    expires: Optional[Duration]


@dataclass
class StateStoreError_RequestError:
    value: str


@dataclass
class StateStoreError_Timeout:
    pass


@dataclass
class StateStoreError_Protocol:
    pass


@dataclass
class StateStoreError_Internal:
    pass


StateStoreError = Union[StateStoreError_RequestError, StateStoreError_Timeout, StateStoreError_Protocol, StateStoreError_Internal]


@dataclass
class StateStoreGetResponse:
    response: Optional[bytes]
    version: Optional[hybrid_logical_clock.HybridLogicalClock]

@dataclass
class StateStoreDelResponse:
    response: int
    version: Optional[hybrid_logical_clock.HybridLogicalClock]

@dataclass
class StateStoreSetResponse:
    response: bool
    version: Optional[hybrid_logical_clock.HybridLogicalClock]


