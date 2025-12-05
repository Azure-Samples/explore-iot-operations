from typing import TypeVar, Generic, Union, Optional, Protocol, Tuple, List, Any, Self
from enum import Flag, Enum, auto
from dataclasses import dataclass
from abc import abstractmethod
import weakref

from ..types import Result, Ok, Err, Some


@dataclass
class Timespec:
    secs: int
    nanos: int

@dataclass
class HybridLogicalClock:
    timestamp: Timespec
    counter: int
    node_id: str


