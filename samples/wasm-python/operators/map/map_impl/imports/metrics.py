from typing import TypeVar, Generic, Union, Optional, Protocol, Tuple, List, Any, Self
from enum import Flag, Enum, auto
from dataclasses import dataclass
from abc import abstractmethod
import weakref

from ..types import Result, Ok, Err, Some



@dataclass
class CounterValue_U64:
    value: int


CounterValue = Union[CounterValue_U64]



@dataclass
class HistogramValue_F64:
    value: float


@dataclass
class HistogramValue_U64:
    value: int


HistogramValue = Union[HistogramValue_F64, HistogramValue_U64]



@dataclass
class MetricsError_IncompatibleType:
    value: str


@dataclass
class MetricsError_LockError:
    value: str


MetricsError = Union[MetricsError_IncompatibleType, MetricsError_LockError]


@dataclass
class Label:
    """
    labels that can be associated with a metric point.
    """
    key: str
    value: str


def add_to_counter(name: str, value: CounterValue, labels: Optional[List[Label]]) -> None:
    """
    increment a counter
    
    Raises: `map_impl.types.Err(map_impl.imports.metrics.MetricsError)`
    """
    raise NotImplementedError

def record_to_histogram(name: str, value: HistogramValue, labels: Optional[List[Label]]) -> None:
    """
    add a data point to a histogram
    
    Raises: `map_impl.types.Err(map_impl.imports.metrics.MetricsError)`
    """
    raise NotImplementedError

